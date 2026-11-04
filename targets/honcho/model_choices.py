#!/usr/bin/env python3
"""Model choices for the Honcho provisioner, from the router's inventory.

Usage:
  model_choices.py chat INVENTORY MIN_CONTEXT   chat models the proxy can use
  model_choices.py embedding INVENTORY          embedding models
  model_choices.py dimensions NAME              a model's known vector size
  model_choices.py measured RESPONSE            the vector size in an answer

chat and embedding print one model per line, best first, as
NAME<TAB>DESCRIPTION<TAB>BASE_URL (the model host's OpenAI-compatible /v1).
chat writes the models it left out, and why, to stderr. dimensions prints the
size a common embedding model is known to have, measured the length of the
first vector in RESPONSE (a /v1/embeddings answer); either prints nothing when
it does not know.
"""
import json
import re
import sys

# Vector sizes of common embedding models, by the name without tag or
# namespace. Longest prefix wins, so "bge-m3" is not read as "bge".
KNOWN_DIMENSIONS = {
    "nomic-embed-text": 768,
    "nomic-embed-text-v2": 768,
    "mxbai-embed-large": 1024,
    "all-minilm": 384,
    "bge-m3": 1024,
    "bge-large": 1024,
    "bge-base": 768,
    "bge-small": 384,
    "snowflake-arctic-embed": 1024,
    "snowflake-arctic-embed2": 1024,
    "embeddinggemma": 768,
    "granite-embedding": 384,
    "paraphrase-multilingual": 768,
    "multilingual-e5-large": 1024,
    "e5-large": 1024,
    "e5-base": 768,
    "e5-small": 384,
    "jina-embeddings-v2": 768,
    "text-embedding-3-small": 1536,
    "text-embedding-3-large": 3072,
    "text-embedding-ada-002": 1536,
    "qwen3-embedding": 4096,
}
# Sizes that a variant decides, in the tag or the rest of the name (an Ollama
# tag such as qwen3-embedding:0.6b, or a GGUF repo such as
# Qwen3-Embedding-0.6B-GGUF): (name prefix, variant pattern, size).
SIZED_VARIANTS = (
    ("qwen3-embedding", r"0\.6b", 1024),
    ("qwen3-embedding", r"4b", 2560),
    ("qwen3-embedding", r"8b", 4096),
    ("snowflake-arctic-embed2", r"568m", 1024),
    ("snowflake-arctic-embed", r"22m|33m|xs|s", 384),
    ("snowflake-arctic-embed", r"110m|137m|m", 768),
    ("granite-embedding", r"278m", 768),
)


def base_url(server):
    """The /v1 URL of an inventory server entry (strata+http://h:8080 -> http://h:8080/v1)."""
    url = server.split("+", 1)[1] if re.match(r"^[a-z]+\+https?://", server) else server
    return url.rstrip("/") + "/v1"


def load(path):
    with open(path, encoding="utf-8") as source:
        models = json.load(source).get("models") or []
    return [m for m in models if isinstance(m, dict) and isinstance(m.get("name"), str) and m["name"]]


def describe(entry, hosts):
    parts = []
    if isinstance(entry.get("context_length"), int):
        parts.append(f"{entry['context_length']}-token context")
    if entry.get("params_b"):
        parts.append(f"{entry['params_b']:g}B")
    if entry.get("loaded") is True:
        parts.append("loaded")
    parts.append(f"on {len(hosts)} servers" if len(hosts) > 1 else "on " + hosts[0])
    return ", ".join(parts)


def grouped(entries):
    """One line per model name (a model on several servers is one choice),
    keeping the best entry: loaded first, then the larger context."""
    seen = {}
    for entry in entries:
        key = entry["name"].lower()
        best, hosts = seen.get(key, (None, []))
        hosts.append(base_url(entry.get("server", "")).removesuffix("/v1"))
        if best is None or (entry.get("loaded") is True, entry.get("context_length") or 0) > \
                (best.get("loaded") is True, best.get("context_length") or 0):
            best = entry
        seen[key] = (best, hosts)
    return list(seen.values())


def ranked(groups):
    return sorted(groups, key=lambda g: (g[0].get("loaded") is not True, -(g[0].get("params_b") or 0),
                                         -(g[0].get("context_length") or 0), g[0]["name"].lower()))


def chat(models, min_context):
    """(usable, left out): the proxy's own test, tools reported and enough context."""
    usable, skipped = [], []
    for entry in models:
        if entry.get("is_embedding"):
            continue
        context = entry.get("context_length")
        if entry.get("tools") is not True:
            reason = "no tool support" if entry.get("tools") is False else "tool support not reported"
        elif not isinstance(context, int) or isinstance(context, bool):
            reason = "no reported context"
        elif context < min_context:
            reason = f"{context}-token context"
        else:
            usable.append(entry)
            continue
        skipped.append((entry["name"], reason))
    return ranked(grouped(usable)), sorted(set(skipped))


def embedding(models):
    return ranked(grouped([m for m in models if m.get("is_embedding")]))


def known_dimensions(name):
    lowered = name.lower().rsplit("/", 1)[-1]
    model = lowered.partition(":")[0]
    for prefix, pattern, size in SIZED_VARIANTS:
        if lowered.startswith(prefix) and re.search(
                rf"(?:^|[-:_])(?:{pattern})(?:$|[-:_])", lowered[len(prefix):]):
            return size
    matches = [p for p in KNOWN_DIMENSIONS if model == p or model.startswith(p + "-")]
    return KNOWN_DIMENSIONS[max(matches, key=len)] if matches else None


def probed_dimensions(path):
    try:
        with open(path, encoding="utf-8") as source:
            vector = json.load(source)["data"][0]["embedding"]
    except (OSError, ValueError, KeyError, IndexError, TypeError):
        return None
    return len(vector) if isinstance(vector, list) and vector else None


def print_groups(groups):
    for best, hosts in groups:
        print(f"{best['name']}\t{describe(best, hosts)}\t{base_url(best.get('server', ''))}")


def main(argv):
    if len(argv) == 3 and argv[0] == "chat":
        usable, skipped = chat(load(argv[1]), int(argv[2]))
        print_groups(usable)
        if skipped:
            print("Left out (the proxy needs reported tool support and context): "
                  + "; ".join(f"{name} ({reason})" for name, reason in skipped), file=sys.stderr)
    elif len(argv) == 2 and argv[0] == "embedding":
        print_groups(embedding(load(argv[1])))
    elif len(argv) == 2 and argv[0] in ("dimensions", "measured"):
        size = known_dimensions(argv[1]) if argv[0] == "dimensions" else probed_dimensions(argv[1])
        if size:
            print(size)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
