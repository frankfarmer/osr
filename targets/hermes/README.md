# Hermes Agent companion for Ollama Smart Router

On an interactive new install, `provision-lxc.sh` lists downloaded Debian 12/13 templates and active `rootdir` storage with enough free space for `ROOTFS_GB`. Set `TEMPLATE` and `STORAGE` to skip the menus. Integration or repair modes and dry runs skip these Proxmox queries.

Hermes is an **agent client** of the router, not a model-serving inference
target. This target creates a dedicated unprivileged Debian LXC with nesting
enabled and installs
[Hermes Agent](https://hermes-agent.nousresearch.com/) with the [official POSIX
installer](https://hermes-agent.nousresearch.com/install.sh). Hermes's custom
OpenAI-compatible provider points at `127.0.0.1:8765/v1` inside the CT. The
local dispatcher reads the router's inventory and task ranking with
`ROUTER_API_KEY`, then sends chat requests straight to the chosen model server.
When the [Honcho target](../honcho/README.md) is selected, the installer also
installs Hermes's Honcho memory plugin and configures the shared `osr`
workspace. For a separately installed Honcho CT, set `HONCHO_URL` and
`HONCHO_CT_ID` when provisioning Hermes. A later `--reconfigure` keeps Honcho as the last
run set it up (URL, key and egress rule); `HONCHO_URL=` (empty) turns it off.

By default Hermes's **API server** also runs in the CT (`hermes-gateway.service`,
TCP 8642). It is registered in the router's Open WebUI as a second OpenAI
connection, so `hermes-agent` appears in the model list next to the router's
models. The request path is:

```
browser -> Open WebUI :8080 -> Hermes API server :8642 -> local dispatcher :8765 -> model server
                                                       \-> router :8000 (inventory and ranking only)
```

The agent's tools (terminal, files, web) run as the unprivileged `hermes`
account inside the Hermes CT.

The Hermes web dashboard also starts on boot at `http://<Hermes-CT-IP>:9119/`.
It binds to `0.0.0.0`, so every CT IPv4 address can serve it. The installer
generates a dashboard login when none is configured; the login is required for
a non-loopback bind. Its generated username is `admin`, not the CT's Linux
`hermes` user; its password is a random value stored in `~/.hermes/.env`.
The dashboard can manage agent settings and secrets, so
reach this HTTP endpoint only over a trusted LAN or VPN.

## Before you start

- **The router is installed** and its API port (8000) is reachable from the
  Proxmox host and from the new CT's address. With the router CT's firewall
  on, `API_ALLOW_CIDR` must include the Hermes CT.
- **The model server ports accept the Hermes CT's address.** The Hermes CT
  firewall permits outbound traffic to discovered servers, but a model host's
  own firewall may still allow only the router. Admit the Hermes CT there too.
- **An Open WebUI admin API key or JWT**, as for Open Terminal: Settings →
  Account (enable API keys in Admin Settings → Authentication first). The
  script prompts for it without echo; for unattended runs set
  `OPENWEBUI_ADMIN_TOKEN`. It is removed from the environment at once and
  deleted from temporary files after use. Not needed with `OPENWEBUI=false`.
- **A tool-capable model with at least 64K context.** Hermes needs 64,000
  tokens of context for agent work with tools.
  Every model the dispatcher may select needs this context; the router's
  inventory does not report configured context length.
  - The pool's defaults are smaller: the Ollama target ships
    `OLLAMA_CONTEXT_LENGTH=8192`, and llama.cpp `CONTEXT_SIZE=8192` is split
    across `PARALLEL_SLOTS`.
  - Raise the host that will serve Hermes: `OLLAMA_CONTEXT_LENGTH=65536` in
    `/etc/ollama-target/ollama.env`, or `CONTEXT_SIZE` of at least
    65536 × `PARALLEL_SLOTS` for llama.cpp. Otherwise Ollama silently drops the
    start of the prompt (Hermes's tool definitions), and llama.cpp rejects it.
  - The router does not know context sizes (ARCHITECTURE §14), so
    `HERMES_CONTEXT_LENGTH` must match what the host really serves.
  - llama.cpp models need `tools` in the bridge's `MODEL_CAPABILITIES` before
    the router sends them tool requests.

## Provision on the Proxmox host

Run `bash targets/hermes/provision-lxc.sh` interactively to enter the existing
router CT ID or IP address, then a separate **new Hermes CT ID**, Debian template,
storage and network settings. The new CT's static IP/CIDR and gateway are
required and prompted when unset; no CT ID or IP is selected automatically.
To resume or update an existing Hermes CT, use
`bash targets/hermes/provision-lxc.sh --reconfigure`; enter that **existing
Hermes CT ID** when prompted. `--integrate-only` needs the existing Hermes CT ID
and registers its API server in Open WebUI again.

```bash
bash targets/hermes/provision-lxc.sh
```

`ROUTER` is the router CT's ID on this host, or the IP address or hostname of
a router LXC/VM that root can log in to over SSH (as for Open Terminal).

Before creating anything, the provisioner:

1. Reads `ROUTER_API_KEY` and model server keys from the router's
   `/app/router/secrets.env` into 0600 files. Keys never appear in a command
   line. Rerun `--reconfigure` after rotating a backend key.
2. Detects the address the router uses to reach the new CT. The default
   `ROUTER_URL` is `http://<that address>:<router port>`.
3. Checks that `ROUTER_URL/v1/models` accepts the key, then reads
   `/routing/inventory` to admit the registered model server IPs and ports
   through the CT firewall. A server URL without a port means port 80 (http)
   or 443 (https).
4. Checks Open WebUI's health and asks for the admin token.

It then creates the CT and its firewall. Once the CT is running, it resolves
model servers given by host name inside the CT, with the resolver the
dispatcher uses, and admits every IPv4 address returned. It then pushes the
installer, dispatcher, systemd units and keys. The guest installer then:

1. Checks the router's advertised models and installs Hermes as the `hermes`
   account.
2. Configures the provider: `model.provider custom`, `model.base_url` at the
   loopback dispatcher, `model.default`, `model.context_length` and a local
   placeholder `model.api_key`.
3. Starts `hermes-direct.service` and sends one chat request with a tool
   through it to a model server. This checks the direct path before the
   gateway is exposed.
4. Generates the API server key in `/etc/hermes-target/api-key` (0600) and
   writes the `API_SERVER_*` settings to `~/.hermes/.env`.
5. Starts `hermes-gateway.service` and waits for `/health` and `/v1/models`.
6. Creates dashboard login credentials if needed, then enables
   `hermes-dashboard.service` and checks that `/api/status` requires login.

Finally, `integrate-webui.py` runs in the router CT:

1. Checks the Hermes key against Hermes.
2. Has Open WebUI's own backend verify the connection, which also proves the
   firewall admits the router.
3. Adds or updates the OpenAI connection by URL. The router's connection and
   any others are kept as they are.

| Setting | Default | Meaning |
|---|---|---|
| `HERMES_MODEL` | `auto` | The default model of provider `custom:osr`: a model ID from the router's `/v1/models`. With `auto`, the dispatcher uses `/routing/explain`, prefers models reported loaded, and keeps an agent task on one model while a server for it works. If every server for that model fails, the pin is dropped and the router ranks afresh, so the task moves to the best healthy model, and stays there. Name a model for a fixed choice. |
| `HERMES_CONTEXT_LENGTH` | `65536` | Context the model's host serves; at least 64000. The dispatcher never uses a model the router reports with less (`context_length` in `/routing/inventory`), nor one reported without tool support, for any request. AirLLM is excluded on both counts. |
| `HERMES_CHANNEL` | `stable` | Upstream update channel (`stable` or `main`). |
| `HERMES_COMMIT` | — | Pin the Hermes checkout to a commit. A changed pin is applied on the next run. The installer reports the installed commit so you can pin it. |
| `HERMES_INSTALLER_SHA256` | — | Refuse an `install.sh` with another SHA-256. Every run prints the downloaded installer's checksum. |
| `OPENWEBUI` | `true` | `false`: no Open WebUI integration or Hermes API server; no admin token needed. The dashboard remains available unless `HERMES_DASHBOARD=false`. |
| `HERMES_DASHBOARD` | `true` | Enable the authenticated Hermes web dashboard on every CT IPv4 address, TCP 9119. Set `false` to stop it and close its firewall port. |
| `TASK_MODEL` | `fast` | Router model for Open WebUI's titles, tags and follow-ups (Admin Settings → Interface → Task Model (External)). It is set only when unset, or when it points at Hermes. Blank leaves it alone. |
| `HERMES_API_PORT` / `HERMES_API_MODEL_NAME` | `8642` / `hermes-agent` | API server port, and the model name Open WebUI shows. Ports 8644–8646 are reserved by Hermes. |
| `EGRESS` | `restricted` | See [Network](#network). |
| `ROUTER_URL`, `ROUTER_IP`, `OPENWEBUI_PORT` | detected | Override the router URL, the router's source address, or Open WebUI's port. |
| `BRIDGE`, `CT_HOSTNAME`, `CORES`, `MEMORY_MB`, `SWAP_MB`, `ROOTFS_GB`, `ONBOOT`, `NAMESERVER`, `VLAN_TAG` | 2 cores, 4096 MB, 1024 MB swap, 32 GB | CT settings. |

### Modes

| Run | Does |
|---|---|
| default | Creates a new CT. A failed run leaves the CT for inspection; fix the error and use `--reconfigure`. |
| `--reconfigure` | An existing Hermes CT. Pushes the router's **current** and backend keys, installer, dispatcher and units; updates the CT's Hermes firewall rules from the current inventory; then registers it again. Use it after a key rotation, adding a model server, or changing model, context, port, `OPENWEBUI` or router address. |
| `--integrate-only` | Registers an existing CT's API server in Open WebUI again, for example after resetting `webui.db`. |

For a CT created before nesting was enabled by this target, enable **Nesting**
under the CT's **Options → Features** in Proxmox and restart the CT.
`--reconfigure` does not change CT features.

If the first install failed after creating the CT, rerun `--reconfigure` on the
Proxmox host after fixing the reported cause. It can resume a CT created by
this target even if the guest installer never wrote its settings file, provided
the CT description and firewall file remain. Running `install-target.sh`
directly inside the CT asks for the router base URL if `ROUTER_URL` is unset.
It does not need a CT ID or the Hermes CT IP: those belong to the existing
container. Set `ROUTER_URL` explicitly for unattended guest runs. Use the
host `--reconfigure` path after key changes so it supplies current keys.

Rerunning the guest installer with unchanged settings says "nothing to do".
It compares a settings record that includes hashes of the router and backend
keys, so a rotated key counts as a change. A failure while configuring restores
the previous `config.yaml`, `.env` and units, and health-checks the previous API
server: it reports "running again" or "did not become healthy either".

## Open WebUI

After provisioning, choose **hermes-agent** in the model picker. The
connection uses the Chat Completions API (the default). Hermes streams tool
progress and keepalives, so long tool runs do not time out.

- **Who can use it.** Check the model's visibility under Admin Settings →
  Models before sharing it. Anyone who can chat with `hermes-agent` runs tools
  as `hermes` in this CT. They also share one Hermes profile: its memory,
  skills and the router and backend keys in its configuration. For separate users, run one
  Hermes profile per user or group, each with its own `API_SERVER_PORT`, key
  and Open WebUI connection.
- **Task model.** Titles, tags and follow-ups go to `TASK_MODEL`. If that
  setting pointed at Hermes, every chat title would start an agent run and end
  up in Hermes's memory.
- **One agent at a time.** Don't attach Open WebUI tools, Open Terminal or web
  search to the Hermes model; Hermes has its own.
- **Files.** Open WebUI's document retrieval puts file text into the prompt,
  which works. Hermes refuses raw file attachments (`input_file`); inline
  images work.

## Network

With the Proxmox firewall enabled at datacenter level, the CT's
`/etc/pve/firewall/<CT_ID>.fw` admits the API server port only from the router's
address and admits dashboard TCP 9119 when enabled. Inbound SSH is not admitted; use
`pct enter <CT_ID>`.

With `EGRESS=restricted` (default), outbound traffic is allowed, in this order:

1. The router's API, from `ROUTER_URL`, for inventory and ranking.
2. The model server IPs and TCP ports registered in router inventory when the
   CT was provisioned or last reconfigured. Host names are resolved inside the
   Hermes CT, so the rules match the addresses the dispatcher connects to; a
   name the CT cannot resolve is reported and left out.
3. DNS.
4. HTTP(S) to the internet, for packages, `hermes update`, and Hermes's web
   tools.

All other outbound traffic is dropped, including private (RFC 1918), CGNAT
and link-local addresses. A newly added model server, or a host name whose
address changed, needs `--reconfigure` to be admitted; model additions on an
already admitted host are discovered automatically. Until then the dispatcher
skips it: a server it cannot connect to within 5 seconds, or that drops a
response while streaming, is left out of candidate lists for 60 seconds, then
tried again (unless every candidate is skipped). A response the backend breaks
off reaches Hermes as an incomplete chunked response, which its HTTP client
reports as an error. For backends whose response ends only when the connection
closes, the dispatcher requires complete JSON or an SSE `[DONE]` event before
finishing the chunked response. `EGRESS=open`
allows all outbound traffic, for example when packages must come through a LAN
proxy.

**What `--reconfigure` changes.** The inbound API and dashboard rules, outbound router rule
and outbound model rules belong to this target. They carry rule comments
`ollama-smart-router hermes-api`, `hermes-dashboard`, `hermes-router` and `hermes-model`, which Proxmox keeps when
you edit the firewall in its GUI. `--reconfigure` replaces only those rules,
puts them first in `[RULES]` so they match first, and leaves every other line
as it is.
- **Order.** Before anything in the CT changes, the new rules are added next
  to the old ones, so the guest installer can reach a moved router. Once it
  has succeeded, the old ones are removed. A failed run therefore leaves the
  CT reachable as before; rerun `--reconfigure` to finish.
- **Changing the egress mode.** The egress mode is read from the file's
  `policy_out` and never changed; edit `policy_out` and the rules yourself, or
  recreate the CT, to switch.
- **CTs from earlier versions.** Their rules have no comment. The layout those
  versions wrote is recognised: the API rule first in `[RULES]`, then the
  router rule. An unmarked inbound rule is adopted only if the CT's prior
  settings say its API server was enabled on that port. If the file was edited
  so that it is unclear which rules are Hermes's, the run stops before
  changing anything, and says so.
- **No firewall file.** If `/etc/pve/firewall/<CT_ID>.fw` is missing,
  `--reconfigure` warns and does not create one.

## Use and maintain Hermes

Open the CLI from the Proxmox host:

```bash
pct exec 282 -- runuser -u hermes -- env HOME=/home/hermes /home/hermes/.local/bin/hermes
```

The installer uses Hermes's non-interactive mode and skips the browser and
computer-use downloads for this headless CT. Code and profile live under
`/home/hermes/.hermes`. `hermes-gateway.service` runs `hermes gateway run`,
hardened: the agent can write only to `/home/hermes` and a private `/tmp`.

To read the generated dashboard login from the Proxmox host, run:

```bash
pct exec 282 -- grep -E '^HERMES_DASHBOARD_BASIC_AUTH_(USERNAME|PASSWORD)=' /home/hermes/.hermes/.env
```

The password and session signing secret are kept in that 0600 file and are
preserved on reconfigure. Existing OAuth dashboard credentials are also kept.

### Choosing a model in Hermes

The installer registers named providers, so Hermes's `/model` switcher can
pick them:

| Provider | Goes to | Example |
|---|---|---|
| `custom:osr` | The router-ranked dispatcher, as with `HERMES_MODEL` (the default provider). Accepts `auto`, the tier names and any router model. | `/model custom:osr:xlarge` |
| `custom:<target>` | One model server, directly. The dispatcher lists that server's own models (`/api/tags` for Ollama-style servers, `/v1/models` for the others) and sends chat only to it, with its backend key. No router inventory, ranking or failover is involved, so it keeps working while the router is down. | `/model custom:strata-192-168-11-154-8080:qwen3.8-flash-next-iq3_xxs` |

A plain HTTP target on an IPv4 address uses its kind, host and port as its name:
`strata-192-168-11-154-8080`, `ollama-192-168-11-153-11434`. Other
endpoints have a stable URL-derived suffix, so targets sharing a host and port
keep their names when one is removed. Names come from the router's inventory
when the CT is provisioned or last reconfigured. The list is kept in
`/etc/hermes-target/targets`. After adding or removing a model server, run
`--reconfigure`: new servers get a provider (and a firewall rule), and
providers of servers the router no longer lists are removed. On the first
reconfigure after this naming change, reselect any saved DNS, HTTPS or
path-based target in Hermes; its provider name will have the new suffix. A
direct pick skips the dispatcher's tool and context checks, since nothing but
the server answers it; choose a model with tool support and at least
`HERMES_CONTEXT_LENGTH` of context.

Upgrade the agent with Hermes's own updater, then restart the gateway:

```bash
pct exec 282 -- runuser -u hermes -- env HOME=/home/hermes /home/hermes/.local/bin/hermes update
pct exec 282 -- systemctl restart hermes-gateway
```

With `HERMES_COMMIT` set, a rerun moves the checkout back to the pin. Unpin it,
or set the new commit, when you upgrade.

| Symptom | Cause / fix |
|---|---|
| "rejected the API key … --reconfigure" | The router key was rotated. Run `provision-lxc.sh --reconfigure`. |
| `model server … is unreachable; skipping it` in `journalctl -u hermes-direct` | The CT cannot connect to that server: not yet admitted (run `--reconfigure` after adding a server or changing its DNS), down, or blocked by the model host's own firewall. |
| 503 "No available chat model with tool support and at least … tokens of context" | Every candidate is unusable for Hermes. Check `tools` and `context_length` per model in `/routing/inventory`: raise the model's context on its host (Ollama `num_ctx`, llama.cpp `CONTEXT_SIZE`), or add `tools` to llama.cpp's `MODEL_CAPABILITIES`. |
| "Direct model-server chat probe failed" | Check `/routing/inventory`, backend keys, and direct access from the Hermes CT to the model host. Ollama reports `tools` per model; llama.cpp needs `MODEL_CAPABILITIES=…,tools`. |
| The agent forgets its instructions or tools mid-task | The host's context is smaller than `HERMES_CONTEXT_LENGTH`. Raise it on the host (see above). |
| Open WebUI lists no `hermes-agent` | `systemctl status hermes-gateway` in the CT, then `--integrate-only`. With the firewall on, the router's address needs TCP 8642. |
| Chats are slow to get a title | Check that the Task Model (External) is a router model, not `hermes-agent`. |
