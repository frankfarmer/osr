# OpenClaw companion for Ollama Smart Router

On an interactive new install, `provision-lxc.sh` lists downloaded Debian 12/13 templates and active `rootdir` storage with enough free space for `ROOTFS_GB`. Set `TEMPLATE` and `STORAGE` to skip the menus. Integration or repair modes and dry runs skip these Proxmox queries.

[OpenClaw](https://docs.openclaw.ai/) is an **agent client** of the router,
like [Hermes](../hermes/README.md), not a model-serving inference target. This
target creates a dedicated unprivileged Debian LXC with nesting enabled and
installs OpenClaw the way [brax.me's install script](https://brax.me/openclaw/install.sh)
does. OpenClaw's provider `osr` points at `127.0.0.1:8765/v1` inside the CT:
the Hermes target's dispatcher (`targets/hermes/direct-dispatch.py`), run with
this target's files. It reads the router's inventory and task ranking with
`ROUTER_API_KEY`, then sends chat requests straight to the chosen model server.
When the [Honcho target](../honcho/README.md) is selected, the installer also
installs the official OpenClaw Honcho plugin with conversation access and the
shared `osr` workspace. It runs alongside OpenClaw's own memory plugin. For a
separately installed Honcho CT, set `HONCHO_URL` and `HONCHO_CT_ID` when
provisioning OpenClaw. A later `--reconfigure` keeps Honcho as the last
run set it up (URL, key and egress rule); `HONCHO_URL=` (empty) turns it off.

OpenClaw's **Gateway** (`openclaw-gateway.service`, TCP 18789) serves the
agent, its Control UI and, with Open WebUI, its OpenAI-compatible
`/v1/chat/completions`. It is registered in the router's Open WebUI as a
second OpenAI connection, so `openclaw` appears in the model list next to the
router's models. The request path is:

```
browser -> Open WebUI :8080 -> OpenClaw Gateway :18789 -> local dispatcher :8765 -> model server
                                                        \-> router :8000 (inventory and ranking only)
```

The agent's tools (exec, files, web) run as the unprivileged `openclaw`
account inside the OpenClaw CT. The dispatcher runs as a separate account,
`openclaw-direct`. The router and backend keys are readable only by that
account, so the agent's tools cannot read them. (Hermes's dispatcher shares
its agent's account.)

## How OpenClaw is installed

The brax.me script, checked against the [official install docs](https://docs.openclaw.ai/install):

| brax.me `install.sh` | Official docs | This target |
|---|---|---|
| nvm v0.40.4 (`curl … \| bash`) | The installer uses NodeSource on Linux, or nvm when present; nvm is a supported runtime source | nvm v0.40.4, checked against its known SHA-256 before it runs (`NVM_INSTALLER_SHA256`), as the `openclaw` account, with `PROFILE=/dev/null` |
| `nvm install 24` | Node 24.16+ on the 24 line or 26.1+; 24.22.1+/26.12.1+ are strongly recommended for security | `nvm install 24` (`OPENCLAW_NODE_VERSION`), then the installed Node is checked against this target's stricter security floor |
| `npm install -g openclaw` | npm is a supported install method; npm 11.16+ and 12 require `--allow-scripts=openclaw` | `npm install -g openclaw@latest` (`OPENCLAW_VERSION` pins a release), with the lifecycle-script flag when supported |
| No onboarding | The installer starts onboarding unless `--no-onboard` | `openclaw setup --baseline` (the scripted baseline), then `openclaw config set` |
| Installs Ollama | Not part of OpenClaw | **Left out.** The router's model pool serves the agent. |
| No checks, nothing pinned | | Root and lock checks, a settings record, rollback and health checks, as for Hermes |

nvm downloads Node from nodejs.org and checks it against nodejs.org's
`SHASUMS256.txt`. `node`, `npm` and `openclaw` are linked into
`/home/openclaw/.local/bin`, which is on the unit's `PATH`.

## Before you start

- **The router is installed** and its API port (8000) is reachable from the
  Proxmox host and from the new CT's address. With the router CT's firewall
  on, `API_ALLOW_CIDR` must include the OpenClaw CT.
- **The model server ports accept the OpenClaw CT's address.** The OpenClaw CT
  firewall permits outbound traffic to discovered servers, but a model host's
  own firewall may still allow only the router. Admit the OpenClaw CT there too.
- **An Open WebUI admin API key or JWT**, as for Hermes: Settings → Account
  (enable API keys in Admin Settings → Authentication first). The script
  prompts for it without echo; for unattended runs set
  `OPENWEBUI_ADMIN_TOKEN`. Not needed with `OPENWEBUI=false`.
- **A tool-capable model with enough context.** OpenClaw's prompt, tools and
  history need room; its own managed local-model recipes use 64K. The
  dispatcher never selects a model the router reports with less than
  `OPENCLAW_CONTEXT_LENGTH` (default 65536, at least 32768), or without tool
  support. As for Hermes, raise the serving host's context: Ollama
  `OLLAMA_CONTEXT_LENGTH=65536`, llama.cpp `CONTEXT_SIZE` of at least
  65536 × `PARALLEL_SLOTS`, and `tools` in llama.cpp's `MODEL_CAPABILITIES`.

## Provision on the Proxmox host

Run `bash targets/openclaw/provision-lxc.sh` interactively to enter the
existing router CT ID or IP address, then a separate **new OpenClaw CT ID**,
Debian template, storage and network settings. The new CT's static IP/CIDR
and gateway are required and prompted when unset; no CT ID or IP is selected
automatically. To resume or update an
existing OpenClaw CT, use `bash targets/openclaw/provision-lxc.sh --reconfigure`
with that **existing OpenClaw CT ID**. `--integrate-only` registers its Gateway
in Open WebUI again.

```bash
bash targets/openclaw/provision-lxc.sh
```

`ROUTER` is the router CT's ID on this host, or the IP address or hostname of
a router LXC/VM that root can log in to over SSH.

Before creating anything, the provisioner reads `ROUTER_API_KEY` and the model
server keys from the router's `/app/router/secrets.env` into 0600 files (keys
never appear in a command line), detects the address the router uses to reach
the new CT, checks that `ROUTER_URL/v1/models` accepts the key, reads
`/routing/inventory` for the firewall and the direct targets, and checks Open
WebUI's health and the admin token.

It then creates the CT and its firewall, waits for DNS (Debian and the npm
registry), admits model servers by the addresses the CT resolves, and pushes
the installer, the dispatcher, the units and the keys. The guest installer:

1. Checks the router's advertised models, creates the `openclaw` and
   `openclaw-direct` accounts and installs nvm, Node and OpenClaw (above).
2. Starts `openclaw-direct.service` and sends one chat request with a tool
   through it to a model server, which checks the direct path.
3. Writes the providers from the dispatcher's model lists: `osr` (`auto`, the
   tiers and the router's models) and one per model server. Each model gets
   `contextWindow` = `OPENCLAW_CONTEXT_LENGTH`, `maxTokens` =
   `OPENCLAW_MAX_TOKENS`, tool support and the `max_tokens` field.
4. Creates the config with `openclaw setup --baseline` on the first run and
   sets `gateway.mode=local`, the port, token auth, the bind address, the chat
   completions endpoint, the Control UI and `agents.defaults.model.primary`
   (`osr/<OPENCLAW_MODEL>`), then runs `openclaw config validate`.
5. Generates the Gateway token in `/etc/openclaw-target/api-key` (0600) and
   puts it in OpenClaw's `~/.openclaw/.env` as `OPENCLAW_GATEWAY_TOKEN`; the
   config only references it (`gateway.auth.token`, an env SecretRef).
6. Starts `openclaw-gateway.service` and waits for `/healthz`, the agent model
   on `/v1/models` and the Control UI.

Finally, `integrate-webui.py` runs in the router CT: it checks the token
against OpenClaw, has Open WebUI's own backend verify the connection (which
also proves the firewall admits the router), and adds or updates the OpenAI
connection by URL. A new connection shows only `openclaw`: OpenClaw also lists
`openclaw/default` and `openclaw/<agentId>`, the same agent again.

| Setting | Default | Meaning |
|---|---|---|
| `OPENCLAW_MODEL` | `auto` | The default model, `osr/<this>`: `auto`, a tier or a model from the router's `/v1/models`. With `auto` the dispatcher uses `/routing/explain`, prefers loaded models and keeps a task on one model while its server works, as for Hermes. |
| `OPENCLAW_CONTEXT_LENGTH` | `65536` | Context the model hosts serve; at least 32768. Every provider model gets it as `contextWindow`; the dispatcher never uses a model the router reports with less, nor one without tools. |
| `OPENCLAW_MAX_TOKENS` | `8192` | `maxTokens` per model: at most half the context. |
| `OPENCLAW_VERSION` | `latest` | npm dist-tag or exact release. An exact release is enforced on every run; the installer reports the installed one so you can pin it. |
| `OPENCLAW_NODE_VERSION` | `24` | nvm's Node: `24` or `26`, or an exact `24.x.y`/`26.x.y`. Below this target's security floor (24.22.1, 26.12.1) is refused. Changing it reinstalls OpenClaw for the new Node. |
| `NVM_VERSION` / `NVM_INSTALLER_SHA256` | `v0.40.4` / its known hash | The nvm release, and the SHA-256 its `install.sh` must have. Another `NVM_VERSION` has no default hash; set one, or it is reported unchecked. |
| `OPENWEBUI` | `true` | `false`: no `/v1/chat/completions`, no registration, no admin token. The Gateway still runs: the CLI, the Control UI and channels need it. |
| `OPENCLAW_DASHBOARD` | `true` | The Control UI on every CT IPv4 address, on `OPENCLAW_PORT`. With neither this nor Open WebUI the Gateway binds loopback only. |
| `TASK_MODEL` | `fast` | Router model for Open WebUI's titles, tags and follow-ups. Set only when unset or when it points at an OpenClaw agent. Blank leaves it alone. |
| `OPENCLAW_PORT` | `18789` | The Gateway port (WebSocket, Control UI and HTTP API). |
| `EGRESS` | `restricted` | See [Network](#network). |
| `ROUTER_URL`, `ROUTER_IP`, `OPENWEBUI_PORT` | detected | Override the router URL, the router's source address, or Open WebUI's port. |
| `BRIDGE`, `CT_HOSTNAME`, `CORES`, `MEMORY_MB`, `SWAP_MB`, `ROOTFS_GB`, `ONBOOT`, `NAMESERVER`, `VLAN_TAG` | `openclaw`, 2 cores, 4096 MB, 1024 MB swap, 32 GB | CT settings. |

### Modes

| Run | Does |
|---|---|
| default | Creates a new CT. A failed run leaves the CT for inspection; fix the error and use `--reconfigure`. |
| `--reconfigure` | An existing OpenClaw CT. Pushes the router's **current** and backend keys, installer, dispatcher and units; updates the CT's OpenClaw firewall rules from the current inventory; then registers it again. Use it after a key rotation, after adding a model server or models, or after changing the model, context, port, `OPENWEBUI` or router address. |
| `--integrate-only` | Registers an existing CT's Gateway in Open WebUI again, for example after resetting `webui.db`. |

Rerunning the guest installer with unchanged settings, keys, model servers and
models says "nothing to do". A failure while configuring restores
`openclaw.json`, `.env`, the units and the dispatcher's files, and
health-checks the previous Gateway: it reports "running again" or "did not
become healthy either". Node and OpenClaw themselves are not rolled back.

When run directly inside an existing CT, `install-target.sh` asks for the
router base URL if `ROUTER_URL` is unset. Set it explicitly for unattended
guest runs. The guest installer does not need a CT ID or the OpenClaw CT IP;
the Proxmox `provision-lxc.sh` asks for those when creating the container.
Use `--reconfigure` on the Proxmox host to refresh router and backend keys.

## Open WebUI

After provisioning, choose **openclaw** in the model picker.

- **Who can use it.** Check the model's visibility under Admin Settings →
  Models before sharing it. Anyone who can chat with `openclaw` runs tools as
  `openclaw` in this CT and shares one agent, its memory and workspace.
  OpenClaw documents the token of `/v1/chat/completions` as full operator
  access to the Gateway: keep the connection admin-only or limited to one
  group.
- **Task model.** Titles, tags and follow-ups go to `TASK_MODEL`; pointed at
  OpenClaw, every chat title would start an agent run.
- **One agent at a time.** Don't attach Open WebUI tools, Open Terminal or web
  search to the OpenClaw model; OpenClaw has its own.

## Control UI

Open `http://<OpenClaw-CT-IP>:18789/` and log in with the Gateway token:

```bash
pct exec 283 -- cat /etc/openclaw-target/api-key
```

OpenClaw then asks to pair the browser. Approve it from the Proxmox host:

```bash
oc="pct exec 283 -- runuser -u openclaw -- env HOME=/home/openclaw PATH=/home/openclaw/.local/bin:/usr/bin:/bin openclaw"
$oc devices list
$oc devices approve <requestId>
```

The browser origins `http://<each CT IPv4>:<port>` are allowed
(`gateway.controlUi.allowedOrigins`). OpenClaw calls plain HTTP on a LAN a
downgraded transport: reach the Control UI only over a trusted LAN or VPN.

## Network

With the Proxmox firewall enabled at datacenter level, the CT's
`/etc/pve/firewall/<CT_ID>.fw` admits the Gateway port from the router's
address (Open WebUI) and, with the Control UI, from anywhere. Inbound SSH is
not admitted; use `pct enter <CT_ID>`.

With `EGRESS=restricted` (default), outbound traffic is allowed, in this order:

1. The router's API, from `ROUTER_URL`, for inventory and ranking.
2. The model server IPs and TCP ports registered in router inventory when the
   CT was provisioned or last reconfigured, resolved inside the OpenClaw CT.
3. DNS.
4. HTTP(S) to the internet: npm, nvm and Node downloads, `openclaw update`
   and OpenClaw's web tools.

All other outbound traffic is dropped, including private (RFC 1918), CGNAT
and link-local addresses. The dispatcher's handling of unreachable or failing
servers is Hermes's (see [its Network section](../hermes/README.md#network)).
`EGRESS=open` allows all outbound traffic.

The rules this target owns carry the comments `ollama-smart-router
openclaw-api`, `-dashboard`, `-router` and `-model`. `--reconfigure` replaces
only those, puts them first in `[RULES]` and keeps every other line. Before
the guest step the new rules are added next to the old ones; once it has
succeeded, the old ones are removed. The egress mode is read from the file's
`policy_out` and never changed. A missing firewall file is left missing.

## Use and maintain OpenClaw

The CLI, from the Proxmox host:

```bash
pct exec 283 -- runuser -u openclaw -- env HOME=/home/openclaw PATH=/home/openclaw/.local/bin:/usr/bin:/bin openclaw status
```

Code is in `/home/openclaw/.nvm`, the config and state in
`/home/openclaw/.openclaw` (`openclaw.json`, `.env`, the workspace).
`openclaw-gateway.service` runs `openclaw gateway run`, hardened: the agent can
write only to `/home/openclaw` and a private `/tmp`.

### Choosing a model in OpenClaw

| Provider | Goes to | Example |
|---|---|---|
| `osr` | The router-ranked dispatcher (the default). `auto`, the tiers and every router model the dispatcher can use. | `/model osr/xlarge` |
| `<target>` | One model server, directly: the same names as Hermes's `custom:<target>`. No router inventory, ranking or failover, so it keeps working while the router is down. | `/model strata-192-168-11-154-8080/qwen3.8-flash-next-iq3_xxs` |

Provider model lists are written when the guest installer runs. A model added
to the pool later is reachable at once through `osr/auto` and the tiers; to
pick it by name, rerun `--reconfigure`. A model server that cannot list its
models during a rerun keeps its previous models. A direct pick skips the
dispatcher's tool and context checks: choose a model with tool support and at
least `OPENCLAW_CONTEXT_LENGTH` of context.

### Updates

Update OpenClaw with its own updater, then restart the Gateway:

```bash
pct exec 283 -- runuser -u openclaw -- env HOME=/home/openclaw PATH=/home/openclaw/.local/bin:/usr/bin:/bin openclaw update
pct exec 283 -- systemctl restart openclaw-gateway
```

With an exact `OPENCLAW_VERSION`, a rerun installs that release again. Unpin
it, or set the new release, when you upgrade.

| Symptom | Cause / fix |
|---|---|
| "rejected the API key … --reconfigure" | The router key was rotated. Run `provision-lxc.sh --reconfigure`. |
| "SHA-256 … not NVM_INSTALLER_SHA256" | The downloaded nvm installer changed, or `NVM_VERSION` was changed without its hash. Check it, then set `NVM_INSTALLER_SHA256`. |
| "below this target's security floor" | nvm installed a Node below 24.22.1 (or 26.12.1). Set `OPENCLAW_NODE_VERSION` to a newer release. |
| `model server … is unreachable; skipping it` in `journalctl -u openclaw-direct` | Not yet admitted (run `--reconfigure` after adding a server or changing its DNS), down, or blocked by the model host's own firewall. |
| "does not offer OPENCLAW_MODEL" | Every server for that model lacks tools or reports less context than `OPENCLAW_CONTEXT_LENGTH`. Check `/routing/inventory`. |
| `openclaw-gateway` restarts or exits 78 | Invalid configuration: `journalctl -u openclaw-gateway`, then `openclaw config validate` as `openclaw`. |
| Open WebUI lists no `openclaw` | `systemctl status openclaw-gateway` in the CT, then `--integrate-only`. With the firewall on, the router's address needs the Gateway port. |
| Chats are slow to get a title | Check that the Task Model (External) is a router model, not `openclaw`. |
