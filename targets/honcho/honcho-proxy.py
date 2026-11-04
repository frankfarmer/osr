#!/usr/bin/env python3
"""Honcho's loopback OpenAI endpoint. The router supplies inventory and ranking;
chat and embedding payloads go to model targets from this process only.

The HTTP relay is the same implementation used by Hermes and OpenClaw. Keep
direct_dispatch.py in this target synchronized when that relay is fixed.
"""

import json
import logging
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request

import direct_dispatch as direct


LOG = logging.getLogger("honcho-proxy")
MAX_EMBEDDING_BODY = 16 * 1024 * 1024
TOOL_PROBE_ATTEMPTS = 2
NOOP_TOOL = {"type": "function", "function": {"name": "noop", "description": "Do nothing",
                                              "parameters": {"type": "object", "properties": {}}}}


def same_model(a, b):
    """Model names as the router lists them: case aside, Ollama's implicit
    ":latest" tag is the same model ("nomic-embed-text" is "nomic-embed-text:latest")."""
    def plain(name):
        name = str(name).lower()
        return name[:-len(":latest")] if name.endswith(":latest") else name
    return plain(a) == plain(b)


def json_content(content):
    """The JSON object in a reply's content, also when wrapped in a Markdown
    code fence (Honcho repairs such replies itself), else None."""
    if not isinstance(content, str):
        return None
    text = content.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else ""
        text = text.rsplit("```", 1)[0]
    try:
        value = json.loads(text)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def no_model_error(min_context):
    return ValueError(
        "router inventory has no reachable model that reports tool support and at least "
        f"{min_context} context tokens. Set HONCHO_CONTEXT_TOKENS to the context window your "
        "model server gives the model (it is 131072 when unset), or serve a tool-capable model "
        "that reports its context (Ollama, the llama.cpp bridge with tools in "
        "MODEL_CAPABILITIES, or LM Studio)")


def settings(directory):
    values = direct.read_env(os.path.join(directory, "proxy.settings"))
    required = ("ROUTER_URL", "HONCHO_MODEL", "HONCHO_CONTEXT_TOKENS",
                "EMBEDDING_BASE_URL", "EMBEDDING_MODEL", "EMBEDDING_DIMENSIONS")
    missing = [name for name in required if not values.get(name)]
    if missing:
        raise ValueError("missing proxy settings: " + ", ".join(missing))
    values["HONCHO_CONTEXT_TOKENS"] = int(values["HONCHO_CONTEXT_TOKENS"])
    values["EMBEDDING_DIMENSIONS"] = int(values["EMBEDDING_DIMENSIONS"])
    if values["HONCHO_CONTEXT_TOKENS"] < 8192 or values["EMBEDDING_DIMENSIONS"] < 1:
        raise ValueError("invalid model context or embedding dimensions")
    return values


def router_key(directory):
    with open(os.path.join(directory, "router-api-key"), encoding="utf-8") as source:
        key = source.read().strip()
    return "" if key == "no-key" else key


class HonchoDispatcher(direct.Dispatcher):
    def __init__(self, config, key, backend_keys):
        super().__init__(config["ROUTER_URL"], key, backend_keys,
                         config["HONCHO_CONTEXT_TOKENS"])
        self.alias = config["HONCHO_MODEL"]
        self.resolved_model = config.get("RESOLVED_MODEL", "")
        self.embedding_base = config["EMBEDDING_BASE_URL"].rstrip("/")
        self.embedding_model = config["EMBEDDING_MODEL"]
        self.embedding_dimensions = config["EMBEDDING_DIMENSIONS"]

    def usable(self, entry):
        # Honcho's background jobs use tools even when one individual request
        # does not. Unknown capability/context is not enough to trust a target.
        context = entry.get("context_length")
        return (entry.get("tools") is True and isinstance(context, int)
                and context >= self.min_context)

    def candidates(self, body, unpinned=False):
        requested = body.get("model")
        if requested != self.alias:
            raise ValueError(f"Honcho proxy is configured for {self.alias!r}, not {requested!r}")
        chosen = self.resolved_model or self.alias
        ranked = super().candidates(dict(body, model=chosen), unpinned)
        if not self.resolved_model:
            return ranked
        # A pinned Honcho workload never silently changes model when a host
        # disappears. Replicas of the selected model remain eligible.
        matches = direct.Candidates(entry for entry in ranked
                                    if entry["name"].lower() == self.resolved_model.lower())
        matches.pinned = ranked.pinned
        return matches

    def model_list(self):
        # Honcho sees stable chat and embedding names. The resolved host and
        # chat model stay in proxy settings, outside Honcho's environment.
        names = dict.fromkeys((self.alias, self.embedding_model))
        return {"object": "list", "data": [{"id": name, "object": "model"}
                                           for name in names]}

    def embedding_targets(self):
        """(base URL, key, model name to send) for each place to embed."""
        if self.embedding_base != self.router_url + "/v1":
            return [(self.embedding_base, "no-key", self.embedding_model)]
        inventory = self.inventory()
        matches = [entry for entry in inventory["models"]
                   if entry.get("is_embedding") and same_model(entry.get("name", ""), self.embedding_model)]
        matches.sort(key=lambda entry: direct.LOADED_ORDER.get(entry.get("loaded"), 1))
        return [(direct.server_parts(entry["server"])[1] + "/v1",
                 self.backend_key(entry["server"]), entry["name"]) for entry in matches]

    def embed(self, body):
        if body.get("model") != self.embedding_model:
            raise ValueError("Honcho proxy received an unconfigured embedding model")
        targets = self.embedding_targets()
        if not targets:
            raise ValueError(f"embedding model {self.embedding_model!r} is absent from the router's "
                             "live inventory (or not marked as an embedding model there)")
        error = None
        for base, key, name in targets:
            headers = {"Content-Type": "application/json", "Accept": "application/json"}
            if key:
                headers["Authorization"] = "Bearer " + key
            request = Request(base + "/embeddings", json.dumps(dict(body, model=name)).encode(), headers)
            try:
                with direct.BACKEND.open(request, timeout=90) as response:
                    return json.load(response)
            except (HTTPError, URLError, OSError, ValueError) as exc:
                error = exc
                LOG.warning("embedding target %s failed: %s", base, exc)
        raise ValueError("no embedding target answered: " + str(error))


class HonchoHandler(direct.Handler):
    def do_POST(self):
        if self.path != "/v1/embeddings":
            return super().do_POST()
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_EMBEDDING_BODY:
                self.error(413, "Invalid embedding request size")
                return
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("embedding request must be a JSON object")
            self.json_response(200, self.dispatcher.embed(body))
        except (ValueError, TypeError, OSError) as exc:
            self.error(502, "Embedding request failed: " + str(exc))


def tool_probe(dispatcher, entry, model):
    """The model calls a tool when told to. Ollama ignores tool_choice, so the
    instruction is in the messages too, and a model gets a second, firmer try."""
    prompts = ("Call the noop tool now, with no arguments.",
               "You must respond only by calling the noop tool with no arguments. Do not write text.")
    for prompt in prompts[:TOOL_PROBE_ATTEMPTS]:
        body = {"model": model, "messages": [{"role": "system", "content": "Use the provided tools."},
                                             {"role": "user", "content": prompt}],
                "tools": [NOOP_TOOL], "tool_choice": "required", "max_tokens": 256, "stream": False}
        with dispatcher.open_backend(entry, body) as response:
            result = json.load(response)
        if result["choices"][0]["message"].get("tool_calls"):
            return
    raise ValueError(
        f"{entry['name']} answered in text instead of calling a tool in {TOOL_PROBE_ATTEMPTS} tries. "
        "Honcho's dialectic and dreams need tool calls: choose another HONCHO_MODEL, or, if you "
        "have checked that this model calls tools reliably, set HONCHO_SKIP_CHAT_PROBE=true")


def chat_probe(dispatcher, model, output_mode):
    if not dispatcher.resolved_model:
        body = {"model": model, "messages": [{"role": "user", "content": "Choose a model for Honcho."}],
                "tools": [NOOP_TOOL]}
        candidates = dispatcher.candidates(body)
        if not candidates:
            raise no_model_error(dispatcher.min_context)
        dispatcher.resolved_model = candidates[0]["name"]
    entry = dispatcher.candidates({"model": model, "messages": []})[0]
    tool_probe(dispatcher, entry, model)
    schema_body = {"model": model, "messages": [{"role": "user", "content": 'Return {"ready": true}.'}],
                   "max_tokens": 256, "stream": False}
    if output_mode == "json_object":
        schema_body["response_format"] = {"type": "json_object"}
    else:
        schema_body["response_format"] = {"type": "json_schema", "json_schema": {
            "name": "ready", "schema": {"type": "object", "properties": {"ready": {"type": "boolean"}},
                                        "required": ["ready"]}}}
    try:
        with dispatcher.open_backend(entry, schema_body) as response:
            result = json.load(response)
    except HTTPError as exc:
        hint = ("set HONCHO_STRUCTURED_OUTPUT_MODE=json_object if JSON-schema output is unsupported"
                if output_mode != "json_object" else "choose another HONCHO_MODEL")
        raise ValueError(f"{entry['name']} rejected structured output (HTTP {exc.code}); {hint}") from exc
    reply = json_content(result["choices"][0]["message"].get("content"))
    if not reply or reply.get("ready") is not True:
        hint = ("try HONCHO_STRUCTURED_OUTPUT_MODE=json_object" if output_mode != "json_object"
                else "choose another HONCHO_MODEL")
        raise ValueError(f"{entry['name']} did not return the requested JSON object; {hint}, or set "
                         "HONCHO_SKIP_CHAT_PROBE=true if the deriver's log shows it stores observations")


def probe(directory):
    config = settings(directory)
    dispatcher = HonchoDispatcher(config, router_key(directory),
                                  direct.read_env(os.path.join(directory, "backend-keys")))
    model = dispatcher.alias
    if model not in dispatcher.router_models():
        raise ValueError(f"router does not advertise Honcho model {model!r} at /v1/models")
    if config.get("HONCHO_SKIP_CHAT_PROBE") == "true":
        candidates = dispatcher.candidates({"model": model, "messages": []})
        if not candidates:
            raise no_model_error(dispatcher.min_context)
        dispatcher.resolved_model = candidates[0]["name"]
    else:
        chat_probe(dispatcher, model, config.get("HONCHO_STRUCTURED_OUTPUT_MODE", ""))
    embedding_body = {"model": dispatcher.embedding_model, "input": "Honcho setup check",
                      "encoding_format": "float"}
    if config.get("EMBEDDING_DIMENSIONS_MODE") in ("auto", "always"):
        embedding_body["dimensions"] = dispatcher.embedding_dimensions
    result = dispatcher.embed(embedding_body)
    vector = result["data"][0]["embedding"]
    if len(vector) != dispatcher.embedding_dimensions:
        raise ValueError("embedding returned %d values; configured %d" %
                         (len(vector), dispatcher.embedding_dimensions))
    print(dispatcher.resolved_model)


def serve(directory):
    config = settings(directory)
    if not config.get("RESOLVED_MODEL"):
        raise ValueError("RESOLVED_MODEL missing: run the provisioner to select a model")
    HonchoHandler.dispatcher = HonchoDispatcher(config, router_key(directory),
                                                 direct.read_env(os.path.join(directory, "backend-keys")))
    logging.basicConfig(level=logging.INFO)
    port = int(os.environ.get("HONCHO_PROXY_PORT", "8765"))
    direct.DispatchServer(("127.0.0.1", port), HonchoHandler).serve_forever()


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3 or sys.argv[1] not in ("--probe", "--serve"):
            raise ValueError("Usage: honcho-proxy.py --probe|--serve CONFIG_DIR")
        (probe if sys.argv[1] == "--probe" else serve)(sys.argv[2])
    except (ValueError, KeyError, IndexError, TypeError, OSError, HTTPError, URLError) as exc:
        raise SystemExit("Honcho proxy: " + str(exc)) from None
