# Honcho AI memory target

[Honcho](https://github.com/plastic-labs/honcho) stores conversations and
derives persistent peer memory. This CPU-only target creates a separate
unprivileged Debian 13 LXC with PostgreSQL/pgvector, the Honcho API and
deriver, the upstream HTTP MCP server and Honcho's own embedding model:
[Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF)
(Q8_0, 1024 dimensions) on llama.cpp's `llama-server`, on the CT's CPU. No
GPU is passed through, and no embedding server elsewhere is needed. The
Proxmox firewall allows the router and the selected agent CTs (Hermes,
OpenClaw, DeepSeek Harness) to reach API port 8000 and MCP port 3000. Other
inbound traffic is blocked. Honcho uses JWT authentication with two keys in
its CT: `/etc/honcho-target/api-key` is the admin key and never leaves the CT;
`/etc/honcho-target/client-api-key` is scoped to the shared `osr` workspace
and is the only key Open WebUI and the agents receive. Hermes and OpenClaw use
the API through their native plugins; DeepSeek Harness uses the MCP server
(the same key reaches the same data either way, so the agents get both ports;
an agent's MCP rule is tagged `# osr-honcho-client-mcp`).

## Requirements

Honcho itself needs no GPU; its chat model runs on your model servers (an
Ollama CT or another target behind the router), and its embedding model in
its own CT. Before installing, check
that you have all of the following.

**The Honcho CT (this target)**

- A Debian 13 amd64 LXC template: Honcho needs Python 3.13, which Debian 12
  does not ship.
- 4 cores, 8 GiB RAM and 48 GiB disk by default, plus room in
  `/var/lib/honcho-target/` for a database dump during each reconfigure. The
  embedding model takes up to about 3.3 GiB of that RAM while it embeds, and
  about 2 GiB of disk with llama.cpp's build tools.
- Network access to GitHub (the Honcho release, Bun and llama.cpp), Hugging
  Face (the 639 MB model file, once) and the Debian mirrors during install,
  and to the router inventory and selected chat model targets at all times. The router CT's Proxmox firewall must admit the Honcho CT; the
  provisioner adds that rule when the router CT has a firewall file. If a
  model CT blocks inbound requests, allow the Honcho CT's IP to reach its
  inference port as well.
- An Open WebUI admin API key, to register Honcho's MCP tools.

**A chat model listed in the router inventory that has all of these:**

- **Tool calling.** Honcho's question answering (the dialectic) and its
  background consolidation (dreams) call tools in loops of up to 10-12 steps.
- **Structured JSON output.** The memory worker (the deriver) asks for output
  that matches a JSON schema and cannot store anything it cannot parse. A
  backend that only does JSON mode works with
  `HONCHO_STRUCTURED_OUTPUT_MODE=json_object`.
- **A context window that matches Honcho's budgets.** By default the deriver
  sends up to 25,000 tokens per request, and the dialectic and summaries budget
  up to 100,000 tokens of input, which assumes a window of about 128k. On a
  smaller window, tell Honcho its size with `HONCHO_CONTEXT_TOKENS` (see
  [Fitting a small context window](#fitting-a-small-context-window)); without
  it, requests larger than the window are cut off by the model server without
  an error. Ollama's default context window is far smaller than either: raise
  it with `OLLAMA_CONTEXT_LENGTH` on the model server (or `num_ctx` for the
  model), and give `HONCHO_CONTEXT_TOKENS` the same number. A first install
  that does not set it uses 65536, the model targets' default window. Honcho's
  proxy only chooses a model whose reported context is at least
  `HONCHO_CONTEXT_TOKENS` (131072 when it is blank, for Honcho's own budgets),
  so with a blank value only models reporting about 128k qualify.
- **A model target that reports both.** The proxy only chooses a model whose
  inventory entry says it supports tools and gives its context window.
  Ollama, the llama.cpp bridge (with `tools` in `MODEL_CAPABILITIES`) and LM
  Studio models trained for tool use report both, as do Strata, Basalt, Maya,
  Xolotl, Avalon and Kindi (the router's `tool_kinds` setting marks their text
  models tool-capable, and their `/v1/models` gives the served context).
  AirLLM supports neither tools nor a long context. The model targets serve
  65536 tokens by default, below the 131072 the proxy asks for when
  `HONCHO_CONTEXT_TOKENS` is blank: keep it at their window, or raise theirs.
  Strata,
  Xolotl and Maya produce JSON by prompting rather than by constrained
  decoding (Basalt and Avalon constrain it), and Maya does not check the
  result against the schema. The reported context is a ceiling, not
  proof: for Ollama it is the model's own limit or a Modelfile `num_ctx`, and
  a server-wide `OLLAMA_CONTEXT_LENGTH` is not visible to it. Make sure the
  server really serves `HONCHO_CONTEXT_TOKENS`.
- **Steady capacity.** The deriver works on every batch of new messages, not
  only when someone asks a question, so it competes with interactive chats on
  the same GPU.

**No embedding model elsewhere.** The CT runs its own (see
[The local embedding model](#the-local-embedding-model)); there is nothing to
choose and no vector size to give.

### Choosing a model for your GPU

Match the model to the GPU of the model server that will serve it, and leave
VRAM for the context window: every extra 8-16k tokens of context takes roughly
another 1 GB or more. Point `HONCHO_MODEL` at that model's exact name as the
router lists it in `/v1/models` when you want to pin a particular model.
The default `fast` tier is also safe: the local proxy selects a target from
`/routing/inventory` only when it reports tool support and enough context.
It records the chosen model until the next reconfigure.

The best options available as of November 3, 2026 are listed below. This
space changes quickly; the reliability figures behind these picks come from
small published tests and self-reported benchmarks, none of them of Honcho
itself, and Ollama tag names change. Check the tags in the Ollama library
before pulling.

| GPU VRAM | Suggested model (Ollama tag, default 4-bit) | Model size | Why | Alternative |
|---|---|---|---|---|
| 8 GB | `qwen3:8b` | ~5.2 GB | Widely used for tool calling (~85% in one 20-request test) and reported to produce structured output reliably under Ollama; leaves ~2.5 GB for context. | `llama3.1:8b` (~4.9 GB, somewhat less accurate) |
| 10 GB | `qwen3.5:9b` | ~6.6-7.6 GB | Newer model of the same size class with tool support; still leaves room for a 16-32k context. | `qwen3:8b` with a larger context |
| 12 GB | `gemma4:12b` | ~8 GB | Best all-round pick at this size; the Gemma 4 family was the most stable at chained tool calls (~90%). | `qwen3:14b` (~9.3 GB, less room for context) |
| 16 GB | `qwen3:14b` | ~9.3 GB | ~88% tool-call reliability, with room for a 32k context, which matters more here than a larger model. | `gemma4:12b` at 8-bit |
| 24 GB | `gemma4:26b` | ~18 GB | Mixture-of-experts (about 4B active parameters), so it is fast; ~93-95% tool-call reliability and strict JSON-schema adherence in published tests. | A Qwen 3.x 27B model (~18-19 GB) |

On 8 and 10 GB cards a 32k context barely fits next to the model; use a
16-24k window there and set `HONCHO_CONTEXT_TOKENS` to match. Answers over
long histories then draw on less of them; a larger card, or a model server
reserved for Honcho, avoids that.

`gpt-oss:20b` is often recommended for 16 GB cards, but it has documented
problems producing strict JSON-schema output under Ollama, which the deriver
depends on. If you use it, set `HONCHO_STRUCTURED_OUTPUT_MODE=json_object` and
check the deriver's log.

**Checking your choice.** Before it changes Honcho's data, the install sends
the chosen model separate tool-call and structured-output requests, and stops
if either fails. Ollama ignores `tool_choice`, so the tool-call check asks
twice, the second time more firmly, before it gives up; a JSON reply wrapped
in a Markdown code fence passes, as Honcho repairs those itself. Passing
proves the model answers both checks, not that it uses them well. If you have
confirmed that a refused model works (for example from the deriver's log),
`HONCHO_SKIP_CHAT_PROBE=true` skips the checks. After installing,
talk to Hermes or OpenClaw for a few turns, then check inside the Honcho CT
that `journalctl -u honcho-deriver` shows no parse errors and that the `user`
peer gains observations. If the deriver logs no errors but stores nothing, the
backend is ignoring the JSON schema: switch to
`HONCHO_STRUCTURED_OUTPUT_MODE=json_object`.

### Fitting a small context window

Set `HONCHO_CONTEXT_TOKENS` to the context window the model server gives the
model (8192 to 1048576). The OSR installer asks for it after the model
targets' windows and offers the smallest of them; a first install that does
not set it uses 65536. The install then sizes
every budget Honcho has so that each request, its answer, and the system
prompt and tool definitions fit in that window. Set it to the same number as
`OLLAMA_CONTEXT_LENGTH`, or a little less. Suggested windows, next to the
models above: 16384 on 8 GB, 24576 on 10 GB, 32768 on 12 and 16 GB, and
32768-65536 on 24 GB.

| `HONCHO_CONTEXT_TOKENS` | Dialectic input / output | Deriver input / output | Summary input / long cap | Dream output | Tool result cap (characters) |
|---|---|---|---|---|---|
| 16384 | 12288 / 2048 | 12288 / 2048 | 12288 / 2048 | 2048 | 1706 |
| 32768 | 24576 / 4096 | 25000 / 2500 | 24576 / 4096 | 4096 | 3413 |
| 65536 | 53248 / 8192 | 25000 / 2500 | 55440 / 6000 | 8192 | 7509 |
| unset, or 131072 and up | Honcho's defaults: 100000 / 8192 | 25000 / 2500 | 100000 / 6000 | 8192 | 10000 |

Dreams have no input budget in Honcho: their context grows with every tool
result over up to 12 rounds. The derived cap on tool results keeps that within
the window. On a very small window, also lower their rounds or turn them off
(below). With a reasoning ("thinking") model, the thinking counts against the
output budgets; if answers end early, raise `HONCHO_DIALECTIC_MAX_OUTPUT_TOKENS`.

Each budget can also be set on its own, which wins over the derived value.
Each name is Honcho's own setting with a `HONCHO_` prefix:

| Variable | Range | Honcho's default |
|---|---|---|
| `HONCHO_DERIVER_MAX_INPUT_TOKENS` | 1024-25000 | 25000 |
| `HONCHO_DIALECTIC_MAX_INPUT_TOKENS` | 1024-200000 | 100000 |
| `HONCHO_DIALECTIC_MAX_OUTPUT_TOKENS` | 256-100000 | 8192 |
| `HONCHO_DIALECTIC_SESSION_HISTORY_MAX_TOKENS` | 0-16384 | 4096 |
| `HONCHO_SUMMARY_MAX_INPUT_TOKENS` | 1024-200000, at least twice the larger summary cap | 100000 |
| `HONCHO_SUMMARY_MAX_TOKENS_SHORT` / `_LONG` | 128-10000 / 128-20000 | 1500 / 6000 |
| `HONCHO_LLM_DEFAULT_MAX_TOKENS` (the deriver's output) | 256-100000 | 2500 |
| `HONCHO_LLM_MAX_TOOL_OUTPUT_CHARS` | 500-100000 | 10000 |
| `HONCHO_DREAM_MAX_OUTPUT_TOKENS` (deduction and induction) | 256-100000 | 8192 |
| `HONCHO_DREAM_DEDUCTION_MAX_TOOL_ITERATIONS` / `_INDUCTION_` | 1-50 | 12 / 10 |
| `HONCHO_DREAM_ENABLED` | `true` or `false` | `true` |

The values are checked before the install changes anything. They are kept in
`/etc/honcho-target/budgets.env` in the Honcho CT, so a later `--reconfigure`
that does not set a variable keeps its last value; set one to an empty value
(`HONCHO_CONTEXT_TOKENS=`) to return it to Honcho's default (also on a first
install, instead of 65536). The install prints
the budgets it set.

## Configuration

The local `honcho-proxy` service listens only on `127.0.0.1:8765`. Honcho's
chat settings always point to its `/v1` endpoint with a placeholder API key.
The proxy alone reads the router key and model backend keys, consults
`/routing/inventory` and `/routing/explain`, and sends chat requests directly
to the selected model target. The router does not handle Honcho's chat
payloads, and embeddings never leave the CT. The proxy requires a live inventory entry
that explicitly reports tool support and a context window at least as large as
`HONCHO_CONTEXT_TOKENS`. At install or reconfigure it probes the selected
model's tool calling and structured JSON output, then records the resolved
model in `/etc/honcho-target/proxy.settings`. Replicas of that model can be
used if one host fails. To select a different model after the router inventory
changes, reconfigure Honcho. Reconfigure after a router or model backend key
rotation too, so the proxy receives the current credentials. `HONCHO_MODEL=fast`
is the default tier; an exact model name can pin the choice. If the backend
only has JSON mode, set
`HONCHO_STRUCTURED_OUTPUT_MODE=json_object`. `HONCHO_SKIP_CHAT_PROBE=true`
skips active chat probes, but still requires inventory to report tools and
sufficient context. The target installs the upstream release
`HONCHO_REF=v3.5.0`; set another release tag, a full commit SHA, or `main`
(the choice is kept by later reconfigures).
Its MCP server runs on Bun 1.4.4 from the release zip, checked against a
pinned SHA-256 (the baseline build on CPUs without AVX2). For another Bun set
`HONCHO_BUN_VERSION` with the checksum of the build this CPU takes:
`HONCHO_BUN_SHA256` for `bun-linux-x64.zip`, `HONCHO_BUN_BASELINE_SHA256` for
`bun-linux-x64-baseline.zip` (the error names the one missing). The services
run `uv run --frozen`, so they use exactly the locked dependencies.

### The local embedding model

`honcho-embedding.service` runs llama.cpp's `llama-server` on
`127.0.0.1:8766` only (no key; Honcho in the CT is its only client) with
Qwen3-Embedding-0.6B, Q8_0, 1024 dimensions, last-token pooling. Honcho
calls it directly; it is not behind the proxy or the router.

- **llama.cpp** is the release the llama.cpp target uses, `v0.5.0`, fetched
  by its tag and refused unless it is commit
  `7fe450e19305b828c199d602c23a8337aaa1f03b`. It is built in the CT for its
  CPU: `llama-server` only, static, without the web UI or HTTPS, and with the
  x86 instruction sets this CPU has (AVX, F16C, FMA, AVX2, BMI2) rather than
  a native build, which has died with SIGILL on older CPUs. That takes a few
  minutes on the first install; later runs reuse the binary until the commit
  or the CPU's instruction sets change (a CT moved to another host is
  rebuilt). It lives in `/opt/honcho-llama/` with its `build-info`.
- **The model file** `Qwen3-Embedding-0.6B-Q8_0.gguf` (639 MB) is downloaded
  once from one fixed revision of Qwen's repository and checked against its
  SHA-256 (`06507c7b...c3e439`) on every run; a damaged file is downloaded
  again, a mismatch stops the run. It lives in `/var/lib/honcho-embedding/`.
- **The install checks it** with one embedding (1024 values) before Honcho
  is stopped or its data touched.
- **Sized for a CPU.** For an embedding, llama.cpp also scores the model's
  151k-word vocabulary for every token of the batch, about 1.2 GB per 1000
  tokens at the peak, so the server's batch (and context) is 2048 tokens:
  about 3.3 GB with the model. Honcho splits messages into chunks of at most
  1536 tokens (`EMBEDDING_MAX_INPUT_TOKENS`; it counts with another tokenizer,
  so the room is kept), sends at most 4096 tokens a request and two requests
  at a time, and waits up to 600 s for one. A full chunk takes seconds on a
  few cores, and the embedding work shares the CT's cores with Honcho.
- Honcho's settings: `EMBEDDING_MODEL_CONFIG__MODEL=qwen3-embedding-0.6b`,
  `EMBEDDING_VECTOR_DIMENSIONS=1024`, no `dimensions=` field and float
  vectors. `journalctl -u honcho-embedding` shows the server.

Settings for an embedding server elsewhere (`HONCHO_EMBEDDING_MODEL`,
`HONCHO_EMBEDDING_DIMENSIONS`, `HONCHO_EMBEDDING_BASE_URL`,
`HONCHO_EMBEDDING_DIMENSIONS_MODE`) are no longer used; a run that is given
one says so and goes on.

### Changing an existing embedding model

An existing CT configured with another embedding model (for example,
`nomic-embed-text`) cannot switch to the local model through `--reconfigure`.
The Proxmox provisioner checks this before changing firewall rules or staging
the Open WebUI admin token; the guest checks it again before dumping the
database, stopping Honcho or clearing any vectors. Honcho does not provide a
verified in-place rebuild of all stored message and document embeddings; its
pgvector-only reconciler does not process pending documents. To move an
existing deployment, provision a new Honcho CT with the local model. Migrate
its data using a separately verified procedure. Keep the old CT and its
database until you have checked the new deployment's search results.

## Upgrades, rollback and keys

Change the `HONCHO_REF` default only after
`targets/honcho/test-pinned-upstream.py` passes against the new release (the
`honcho-upstream` CI job). It runs Honcho's own settings loader and request
builder on the `honcho.env` this target writes and checks that every model
config sends the OpenAI client the model-client timeout (twice the router's
Kindi read budget), and that the pinned OpenAI SDK stops a silent request at
that timeout. It also checks that Honcho reads the local embedding model's
settings as written: model, URL, vector size, no `dimensions=` field, float
vectors and the input and request limits.

A reconfigure keeps the PostgreSQL database, JWT secret and both keys. Before
it changes an installed CT, it sets aside the env file, keys, units, Bun and
`llama-server` in `/var/lib/honcho-target/rollback/` (root-only), stops the
five services,
and dumps the database there (`pg_dump -Fc`; leave room for it). The dump is
taken even when the commit is unchanged because embedding configuration can
change empty vector columns. If any later
step fails, the previous commit, its dependencies, the database (dropped,
recreated and restored from the dump), the env file, keys, units, Bun and
`llama-server` are put back and the services the previous install had are
started again; the run reports whether the
previous version is healthy. The set-aside copies are deleted after a
successful run or a clean rollback, and kept for inspection otherwise.

### When a rollback does not complete

If the previous version does not come back healthy (or a restore step fails),
the run says so and keeps `/var/lib/honcho-target/rollback/`. The next
reconfigure stops at once, changes nothing and points here, so a second run
cannot overwrite the only copy of the old database. Inside the Honcho CT:

1. Look at `systemctl status honcho-embedding honcho-proxy honcho-api honcho-deriver honcho-mcp`
   and `journalctl -u honcho-embedding -u honcho-proxy -u honcho-api -u honcho-deriver -u honcho-mcp`.
   The rollback has already put the files back; often the cause is outside
   Honcho (the router, a chat model target, disk space).
2. If the database is not as it was, restore the dump with the services
   stopped:

   ```bash
   systemctl stop honcho-mcp honcho-deriver honcho-api honcho-proxy honcho-embedding
   runuser -u postgres -- dropdb --if-exists honcho
   runuser -u postgres -- createdb -O honcho --encoding=UTF8 --template=template0 honcho
   runuser -u postgres -- pg_restore --exit-on-error -d honcho < /var/lib/honcho-target/rollback/honcho.dump
   systemctl start honcho-embedding honcho-proxy honcho-api honcho-deriver honcho-mcp
   ```

   `honcho.env`, `budgets.env`, `settings.env`, `embedding.env`, `jwt-secret`,
   `api-key`, `client-api-key`, proxy settings and credentials, the units,
   the proxy scripts, `bun`, `llama-server` and its `build-info` in the same
   directory are the copies from before the failed run; they belong in
   `/etc/honcho-target/`, `/etc/systemd/system/`, `/opt/honcho-bun/` and
   `/opt/honcho-llama/` (`bin/` for `llama-server`).
3. Once Honcho is healthy (`curl -fsS http://127.0.0.1:8000/health` and
   `http://127.0.0.1:3000/health`), remove the directory with
   `rm -r -- /var/lib/honcho-target/rollback` and run the reconfigure again.

The first install migrates with Honcho's default 1536-dimension columns and
then sets them to the local model's 1024, as upstream documents. Later runs
migrate with the configured size, so a future migration that touches the
vector columns keeps it. `configure_embeddings.py` refuses to change the size
of columns that already hold vectors; reconfigure does not clear them.

### A first install stopped at the PostgreSQL version check

If Alembic ends with `TypeError: cannot use a string pattern on a bytes-like
object` while SQLAlchemy reads the PostgreSQL version, the database may have
inherited `SQL_ASCII` from the template. New installs create the `honcho`
database as UTF8. A rerun refuses an existing database with another encoding
instead of silently replacing it. Inside the Honcho CT, check the failed
database:

```bash
runuser -u postgres -- psql -d honcho -Atqc 'SHOW server_encoding'
runuser -u postgres -- psql -d honcho -Atqc \
  "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')"
```

Only if this was a fresh install, the encoding is `SQL_ASCII`, and the table
count is `0`, remove that empty database with
`runuser -u postgres -- dropdb honcho`. Then rerun the Proxmox provisioner
with `--reconfigure` and the same settings. Preserve any database with Honcho
tables or existing data; inspect it before changing its encoding.

`--reconfigure --rotate-keys` replaces the JWT secret, which invalidates every
existing key, and makes a new admin key and `osr` workspace key. The
provisioner verifies Open WebUI admin access first and keeps a separate copy
of the old secret and keys, and of the Open WebUI connection, until MCP
registration succeeds. Hermes, OpenClaw and DeepSeek Harness keep failing to
reach Honcho until each is reconfigured with `HONCHO_CT_ID`; the run prints
those commands. The
keys do not expire.

If a run with `--rotate-keys` fails, the provisioner checks in the Honcho CT
whether the secret actually changed:

- **Not changed** (the run stopped before the rotation): the keys are left
  alone and the copies are removed.
- **Changed:** it puts back the old secret and keys (and the matching
  `AUTH_JWT_SECRET` line; the rest of `honcho.env` stays as the run wrote it),
  restarts Honcho and restores the saved Open WebUI connection.
- **That restore fails, or the Honcho CT cannot be reached to check:** automatic
  recovery stops. The old secret and keys stay in `/root/honcho-rotation-<pid>/`
  in the Honcho CT and the old Open WebUI connection in
  `/root/honcho-integration-<pid>/webui-honcho-snapshot.json` in the router CT;
  the run prints both paths. The Open WebUI admin token and the new client key
  are removed from the router CT when it is reachable; the run warns if this
  cleanup fails. Once Honcho is reachable and healthy, a plain `--reconfigure`
  (without `--rotate-keys`) registers Open WebUI with whatever key Honcho has
  then; reconfigure the agents with `HONCHO_CT_ID` if the keys did
  change, and remove both directories.

## Install with the router

Select `honcho` in `ollama-smart-router-install.sh` together with the agents
(the installer always creates Honcho before them). The installer gives Honcho
the router's URL and key, creates the CT, and registers
`http://<honcho-ip>:3000/mcp` as an authenticated Streamable HTTP tool server
in Open WebUI. When Hermes or OpenClaw is also selected, their native Honcho
integrations are installed and use the same `osr` workspace and `user` peer.
DeepSeek Harness connects to the MCP server with the same workspace and peer;
its model calls the memory tools itself (see
[its README](../deepseek-harness/README.md#honcho-memory)). Open WebUI's MCP tools are available for an
admin to enable in a chat; the MCP connection does not automatically make
every Open WebUI conversation a Honcho memory session.

The router CT's Proxmox firewall must let the Honcho CT reach the router API.
When `/etc/pve/firewall/<router CT>.fw` exists, the provisioner keeps one rule
there for it (`# osr-honcho-router`, replaced when the Honcho address or
router port changes; every other line stays). It writes the file under the
CT's Proxmox firewall lock (`targets/pve-firewall-swap.pl`) and only if nobody
changed it meanwhile; otherwise it stops and says where the previous content
is saved. Set `HONCHO_ROUTER_FIREWALL=false` to manage that file yourself. The selected chat model hosts
must also be reachable from the Honcho CT.

The selection menu requires you to enter the router CT ID and IP/CIDR and,
for every selected target, its own CT ID and static IP/CIDR. It does not
choose IDs or addresses for you. For Honcho it also asks which router chat
model or tier to use (default `fast`); the embedding model needs no answer.
Enter the IPs of Hermes, OpenClaw and
DeepSeek Harness at their own target prompts if you select them; Honcho uses
those addresses for its firewall rules. `HONCHO_CT_ID`, `HONCHO_IP_CIDR`,
`HONCHO_STORAGE`, and `HONCHO_TEMPLATE` can preset Honcho's answers. The CT
defaults to 4 cores, 8 GiB RAM, and 48 GiB disk. To override the guest
defaults, set any of `HONCHO_MODEL`, `HONCHO_REF`,
`HONCHO_STRUCTURED_OUTPUT_MODE` and `HONCHO_SKIP_CHAT_PROBE` before launching
the installer.
An Open WebUI admin API key or JWT is required for the MCP registration. The
installer asks for it before creating Honcho and stops if none is provided.

## Install or repair separately

On the Proxmox host running the router CT, run as root:

```bash
bash targets/honcho/provision-lxc.sh
```

The standalone installer asks for the Honcho CT ID and static IP/CIDR, the
router/Open WebUI CT ID and router IP, and Honcho's gateway. Once it has the
router's address, it reads the router's model inventory with curl
(`/routing/inventory`, with the router key read from the router CT and given
to curl on stdin; from inside the router CT if its firewall turns the host
away). It then asks for the **chat model**, with a suggestion that Enter
accepts: it lists the models the proxy can use (tool support reported and at
least `HONCHO_CONTEXT_TOKENS` of context; 65536 on a first install), loaded
ones first, then larger ones, and names the others with the reason they are
left out. Answer with a number, a model name or a tier (`fast`, `medium`,
`large`, `xlarge`). With no usable model it suggests `fast` and says the
install will need one. A preset `HONCHO_MODEL` is not asked for; if the
inventory cannot be read, the installer says so and asks for the name without
a list. There are no embedding questions: the model runs in the Honcho CT. Give the Hermes, OpenClaw and
DeepSeek Harness CT IPs at the optional prompts if those agents should access
Honcho. The router IP must
match the source address its CT uses to reach Honcho; the installer checks
this. Open WebUI runs in the router CT, so it needs no separate address.

The installer offers downloaded Debian 13 templates and root-disk storage,
then asks for the Open WebUI admin API token without echoing it. Have a
tool-capable chat model with structured output on the router before
starting. The Proxmox host needs `pct`, `pvesh`,
`pvesm`, and `curl`. The Honcho CT needs outbound access for package downloads.
No CT ID or IP address is inferred for a new standalone install. To preset
answers, set `CT_ID`, `IP_CIDR`, `ROUTER_CT_ID`, `ROUTER_IP`, `GATEWAY`,
`HONCHO_MODEL` and `HONCHO_CLIENT_IPS` (space-separated agent IPs).
`TEMPLATE` and `STORAGE` may also be set. An unattended run requires the
mandatory values, template, storage, and `OPENWEBUI_ADMIN_TOKEN`.
`--dry-run` prints the plan without needing the token; preset `TEMPLATE` and
`STORAGE` because their selection menus do not run in dry-run mode.

Inside an existing Honcho CT, `install-target.sh` asks for the router base
URL if it is unset; an unattended guest run needs `ROUTER_URL`. The guest installer
does not create an LXC or use a CT ID. Use the Proxmox `--reconfigure` path
when keys or router integration also need updating.

Use `--reconfigure` to repair or update a CT this target created. It asks
for the Honcho CT (offering the one tagged `honcho`), then the router
(offering the one Honcho already uses), and reads the Honcho address from the
CT. The chat model, context window and the agents admitted to Honcho are
all offered from what the running CT recorded (`/etc/honcho-target/proxy.settings`, `budgets.env` and its
firewall), so Enter keeps each one; unattended, the recorded values are kept.
Before asking for the Open WebUI admin token, the installer checks that the
CT is running, has the `honcho` tag, and uses the expected embedding model.
The Open WebUI admin token is requested again. A dry-run reconfigure also
needs `IP_CIDR` because it does not inspect the CT.

A reconfigure only changes the settings it is given. The CT keeps
`HONCHO_REF`, `HONCHO_MODEL`, `HONCHO_STRUCTURED_OUTPUT_MODE` and the
`HONCHO_BUN_*` pins from the run
that last set them (in `/etc/honcho-target/settings.env`), and the token
budgets in `budgets.env`; the run prints what it kept. So a repair or key
rotation does not move a CT back to the default release or model. To change
one, set it; to return one to its default, set it to an empty value
(`HONCHO_STRUCTURED_OUTPUT_MODE=`). A CT that never set `HONCHO_REF` follows
this target's pinned release, so it is upgraded on the first reconfigure
after the pin in this repository moves. Existing agent firewall allowances are preserved
unless `HONCHO_CLIENT_IPS` is explicitly set. When adding an agent
separately, set every agent's actual IP in `HONCHO_CLIENT_IPS` (the list
replaces the old one). Then run their
provisioners with `HONCHO_URL` and the actual `HONCHO_CT_ID`; they pull the
`osr` workspace key without putting it on a command line. For an external
Honcho instance, supply `HONCHO_API_KEY_FILE`
instead. Later `--reconfigure` runs of an agent keep the Honcho URL,
key and firewall rule from the last run; set `HONCHO_CT_ID` again to fetch a
new key, or `HONCHO_URL=` (empty) to turn Honcho off for that agent. A Honcho CT
made before the workspace key existed gets it on its next `--reconfigure`; run
that before reconfiguring the agents.

Inside the Honcho CT, inspect `systemctl status honcho-proxy honcho-api
honcho-deriver honcho-mcp` or their journals. PostgreSQL data is under the distribution's
usual `/var/lib/postgresql` directory. The API and MCP health checks are
`http://127.0.0.1:8000/health` and `http://127.0.0.1:3000/health`.
The proxy health check is `http://127.0.0.1:8765/healthz`.

Upstream deployment and integration guidance:
[self hosting](https://github.com/plastic-labs/honcho#self-hosting),
[OpenClaw plugin](https://github.com/plastic-labs/openclaw-honcho), and
[MCP server](https://honcho.dev/docs/v3/guides/integrations/mcp).
