# Ollama Smart Router — Setup & Operations

A Proxmox LXC that puts one OpenAI-compatible endpoint in front of a pool of
self-hosted model servers. It routes each request by complexity, spreads load,
serves a chat UI and alerts on host health. Design and rationale are in
[ARCHITECTURE.md](ARCHITECTURE.md); test details are in [tests/README.md](tests/README.md).

## What gets deployed

An unprivileged Debian 13 CT (default 2 vCPU, 4 GB RAM, 32 GB disk) running
four hardened systemd services as the `ollama-router` user:

| Service | Unit | Port | Role |
|---|---|---|---|
| Smart Router | `ollama-router.service` | 8000 | OpenAI API; picks a model and host per request |
| Open WebUI | `open-webui.service` | 8080 | Chat UI; talks to the router |
| LiteLLM | `litellm-proxy.service` | 127.0.0.1:4000 | Static tier fallback and non-chat `/v1` routes |
| Health monitor | `ollama-monitor.service` | — | Probes hosts and local services, alerts to Mattermost, keeps models loaded |

Normal request path: **client or Open WebUI → router :8000 → model host**.
LiteLLM handles static tiers when discovery is off or the inventory is empty.

The pool can mix Ollama, LM Studio, llama.cpp, AirLLM, Strata, Basalt, Maya,
Xolotl, Avalon and Kindi. Optional service and companion CTs are listed under
[Inference targets](#inference-targets).

## Install

From a full repository checkout, run as root on the Proxmox host:

```bash
bash ollama-smart-router-install.sh
```

The installer asks which targets to create: Gitea and Mattermost services;
Ollama, llama.cpp, AirLLM, Kindi, Strata, Basalt, Maya, Xolotl and Avalon model servers; and
Honcho memory, Hermes, OpenClaw and DeepSeek Harness agents, and Open Terminal and ComfyUI tools. Enter comma-separated names or
menu numbers, or press Enter for none. Gitea stores configuration history and
Mattermost receives alerts; both are optional and can also be installed
separately from [targets/gitea](targets/gitea/README.md) and
[targets/mattermost](targets/mattermost/README.md).

Enter the router's CT ID and static IP/CIDR, then a unique CT ID, static
IP/CIDR and storage for each selected target. The installer does not choose
CT IDs or IP addresses; environment presets prefill the prompts when supplied.
Strata, Basalt, Maya, Xolotl, Avalon and Kindi also ask for a template. The installer then
checks the host GPU, creates selected service CTs, verifies the Gitea token,
creates the router CT, provisions model targets, then Honcho and the selected
agents and tools. The menu groups CPU and GPU targets by purpose. Choose **Default** in the Gitea, Mattermost and
ComfyUI community-script menus. Companions that register with Open WebUI require an admin API key:
create the first admin account in the browser, enable API keys and create one
when prompted. A failed service stops the install before the router is built;
a failed model or companion target leaves the router running and is listed with
retry instructions at the end. Honcho additionally requires a router model
with tools and structured output, an embedding model and its vector size, and
an Open WebUI admin API token for MCP registration. Its
[target README](targets/honcho/README.md) lists the network and model checks.

Ollama and AirLLM install their engines during provisioning. The llama.cpp
target creates only a CT unless `MODEL_ALIAS` and either `MODEL_DOWNLOAD_URL`
or `MODEL_PATH` are set; see its [README](targets/llamacpp/README.md).
Generated Gitea and Mattermost admin passwords are in
`/etc/<service>-target/admin-password` inside their respective CTs.

### LXC distribution support

| LXC | Default | Other supported releases |
|---|---|---|
| Router, Gitea, ComfyUI | Debian 13 | — |
| Open Terminal, Hermes, OpenClaw, DeepSeek Harness | Debian 13 | Debian 12 |
| Honcho | Debian 13 | — |
| Ollama | Debian 13 | Debian 12; Ubuntu 22.04, 24.04, 26.04 (`OLLAMA_CT_OS`, `OLLAMA_CT_VERSION`) |
| Mattermost | Ubuntu 24.04 | Ubuntu 22.04 (`MATTERMOST_CT_VERSION`); Ubuntu only |
| AirLLM | chosen at prompt | Debian 12/13; Ubuntu 24.04/26.04 (Python 3.11+) |
| llama.cpp | Debian 13 listed first | Debian 12/13 for CUDA or CPU; Debian 13 for Vulkan |
| Basalt, Maya, Xolotl | Debian 13 | Debian 12; Ubuntu 22.04, 24.04, 26.04 |
| Strata | Debian 13 | Debian 12; Ubuntu 22.04/24.04 (no Ubuntu 26.04) |
| Kindi | Debian 13 | Debian 12; Ubuntu 22.04/24.04 (the CUDA 10.2 runfile; no Ubuntu 26.04) |
| Avalon | Ubuntu 24.04 | Ubuntu 22.04 (AMD ROCm); with CUDA also Debian 12/13, Ubuntu 26.04 |

Mattermost's `MATTERMOST_CT_VERSION` also accepts Ubuntu 26.04 as an explicit
override for future testing, but Mattermost does not currently support it.

The installer asks for the router's template storage, defaulting to `local`,
then prompts for its Debian 13 template reference before target prompts. Enter a
full reference such as `local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst`
to override the offered default. `TEMPLATE_REF` presets that choice; an explicit
`TEMPLATE_STORAGE` restricts automatic discovery to that storage. Strata defaults
to the router's selected reference and lists other downloaded compatible templates
at its prompt. Other GPU target template prompts prefer a downloaded Debian 13
template, then supported Ubuntu and Debian releases; they download their preferred
release if needed. Maya on a GPU
with compute capability below 7.5 (such as V100) defaults to Ubuntu 24.04:
CUDA 13 cannot build for that card. Debian 13's NVIDIA repository starts at
CUDA 13.1 and Ubuntu 26.04's at 13.3; Basalt, Maya and Xolotl use those
versions unless overridden. The CT's NVIDIA user-space libraries must match
the loaded host driver version. Ubuntu 26.04 needs an available Proxmox template
(`pveam update`, `pveam available`) and a current `pve-container`. See each
target README for Python, CUDA and GPU requirements.

### Host GPU

| Target | Requirement |
|---|---|
| Strata, Maya, Xolotl | NVIDIA required |
| Basalt | NVIDIA Blackwell (sm_120: RTX 50 or RTX PRO Blackwell) required |
| Avalon | AMD Radeon RX 7000 (RDNA 3, ROCm) or NVIDIA (CUDA, RTX 20 or newer), 16 GB+ VRAM, AVX2 CPU |
| llama.cpp | NVIDIA CUDA or AMD/Intel Vulkan; `BACKEND=cpu` needs no GPU |
| AirLLM | NVIDIA when `GPU_DEVICES` is set |
| Ollama, ComfyUI | NVIDIA, AMD or Intel if present; otherwise CPU |
| Kindi | NVIDIA of any generation from Kepler (sm_30) if present, on the host's driver (Kepler: the 470 driver, installed by hand); otherwise its CPU engine (AVX2) |

**Which GPU each target gets.** The installer lists the host's NVIDIA cards
and its AMD Radeon RX 7000/9000 and Intel Arc A/B cards (from `lspci`; Intel
iGPUs and older Radeons are not listed). Ollama, llama.cpp and ComfyUI, the
targets that also run on AMD and Intel, then each ask which of those cards to
use, so one host can give Ollama a Radeon, llama.cpp an Arc and ComfyUI an
NVIDIA card. Avalon is asked too: an RDNA 3 Radeon (built with ROCm) or an
NVIDIA card (CUDA). So is Kindi, which is meant for a spare old or small
NVIDIA card. Ollama, Kindi and ComfyUI also offer `none` (the CPU). Several targets
may pick the same card. When only one card fits a target that needs a GPU,
it is taken without asking. Cards bound to `vfio-pci` are not offered.
Presets: `OLLAMA_GPU_CARD`, `LLAMACPP_GPU_CARD`, `AVALON_GPU_CARD`, `KINDI_GPU_CARD`, `COMFYUI_GPU_CARD` (a PCI
address such as `0000:03:00.0`, or `none`). Strata, Basalt, Maya, Xolotl and
AirLLM run on NVIDIA only and are not asked; they use the NVIDIA driver's
GPU 0 (or their `GPU_DEVICES`).

**Each model target's context window.** Next, the installer asks for the
context window (tokens per request) of each selected Ollama, llama.cpp,
Strata, Basalt, Maya, Xolotl, Avalon and Kindi target. Every one defaults to 65536 (Kindi to `auto`).
Each prompt shows a recommendation that weighs three things:

- the target's GPU memory, read from `nvidia-smi` or amdgpu's sysfs file.
  It is unknown on a host whose driver is not set up yet;
- the target's engine: Avalon and Kindi follow their own `auto` rules, Xolotl's 128k needs
  a 24 GB card, and Strata, Basalt and Maya keep a small KV cache. Ollama and
  llama.cpp are sized for full-attention models, whose cache grows fastest;
- the selected agents: Hermes needs 64000 tokens or more, OpenClaw 32768,
  DeepSeek Harness 16384, and Honcho runs its full budgets at 131072.

A window too small for a selected agent is flagged. Honcho's and DeepSeek
Harness's windows are asked last and default to the smallest window chosen
above. A llama.cpp window is multiplied by its `PARALLEL_SLOTS` for
`CONTEXT_SIZE`. Presets are the defaults: `OLLAMA_CONTEXT_LENGTH`,
`LLAMACPP_CONTEXT` (or `CONTEXT_SIZE`), `STRATA_CONTEXT`, `BASALT_CONTEXT`,
`MAYA_CONTEXT`, `XOLOTL_CONTEXT`, `AVALON_CONTEXT`, `KINDI_CONTEXT` (both also `auto`),
`HONCHO_CONTEXT_TOKENS` and `DEEPSEEK_HARNESS_CONTEXT_WINDOW`. AirLLM, which
streams layers from disk, keeps its own small window.

Before creating CTs, the installer checks for a working host driver for each
chosen card, and once for the NVIDIA-only targets. If one is missing, [tools/setup-host-gpu.sh](tools/setup-host-gpu.sh) identifies the
card and offers to install it: NVIDIA 580.173.02, or the Proxmox kernel driver
and missing firmware for AMD/Intel. It reports blacklisted or `vfio-pci`-bound
cards without changing them. For unattended driver setup, set
`GPU_GENERATION` (for example `rtx40`, `7900`, `9070`, `A770`, `B580`) and
`INSTALL_HOST_DRIVER=yes`. A required GPU missing or needing a reboot stops
the install before any CT is created; reboot and rerun when asked. The chosen
card is passed to Ollama and ComfyUI as `GPU` (its vendor) and `GPU_CARD` (its
address): their community scripts pass every card of that vendor into the CT,
and the provisioner then keeps only that card's device nodes. llama.cpp gets
`BACKEND` and `GPU_DEVICES` for the card (its render node for Vulkan, its
`/dev/nvidia<minor>` for CUDA). Settings you preset are kept. Intel Arc B needs a Proxmox
kernel with Linux 6.12 or newer.

### Router settings

The router prompts for its CT ID (required), root password, network, storage and size; Gitea
URL, account, repository and token; Mattermost webhook (blank disables
alerts); and 1–20 model servers, tiers and model tags. Selected model targets
fill the first server slots. Increase the count to include existing servers.
Inputs are validated before `pct create`; a failed router build removes its
half-built CT. A service CT that failed setup is kept for `--reconfigure`.

Settings can be preset as environment variables:

| Area | Variables (default) |
|---|---|
| CT | `CT_ID`, `CT_NAME`, `IP_CIDR`, `GATEWAY`, `BRIDGE`, `NAMESERVER`, `STORAGE`, `TEMPLATE_REF`, `TEMPLATE_STORAGE`, `TEMPLATE_MIN_GIB` (2), `CORES` (2), `MEMORY` (4096), `SWAP` (1024), `ROOTFS_GB` (32; ~16 with CPU-only torch) |
| Firewall | `FIREWALL`, `API_ALLOW_CIDR` (set it when enabling the firewall or 8000/8080 may be dropped) |
| Open WebUI | `OPENWEBUI_VERSION` (0.12.4), `OPENWEBUI_PORT` (8080), `OPENWEBUI_PY_VERSION` (3.12), `OPENWEBUI_PY_DIR` (`/opt/python`), `TORCH_CPU_ONLY` (true) |
| Model servers | `MODEL_SERVER_COUNT`, `MODEL_SERVER_<n>`, `OLLAMA_PORT` (11434), `MODEL_SERVER_MIN`/`_MAX` |
| Tiers | `TIER_FAST_SERVERS` … `TIER_XLARGE_SERVERS` (e.g. `1,3`), `MODEL_FAST` … `MODEL_XLARGE`, `OLLAMA_KEEP_ALIVE` |
| Gitea | `GITEA_SERVER_URL`, `GITEA_ADMIN_USER`, `GITEA_DEPLOY_TOKEN`, `GITEA_REPO_NAME` (`ollama-smart-router`), `GITEA_REPO_OWNER` (auto), `GITEA_REPO_PRIVATE` |
| Mattermost | `MATTERMOST_WEBHOOK_URL`, `MATTERMOST_MONITOR_USER`, `MATTERMOST_CHANNEL` (`ollama-monitor`) |
| Targets | `INSTALL_TARGETS` (comma-separated target names, pre-fills the menu; menu numbers are refused there because they change when targets are regrouped), `INSTALL_GITEA` / `INSTALL_MATTERMOST` (pre-select), `<NAME>_CT_ID`, `<NAME>_IP_CIDR`, `<NAME>_STORAGE`, `<NAME>_TEMPLATE`, `COMFYUI_IMAGE_VARIANT` (`klein-4b` or `klein-9b`), `HF_TOKEN`, `OPENWEBUI_ADMIN_TOKEN`, `OPENWEBUI_WAIT_SECONDS` (900), `TARGETS_DIR`; see target READMEs for engine options, script pins and ports |

`NONINTERACTIVE=true` requires `CT_ID`, `IP_CIDR`, `GATEWAY`, and a
`MODEL_SERVER_<n>` address for every configured server. It accepts the
remaining router defaults without prompts and refuses
selected targets: community-script menus, GPU selection and the Open WebUI
admin key require interaction. Install the router unattended, then run each
target's `provision-lxc.sh` from the full checkout. Target CT variables are
separate from the router's `CT_ID`, `IP_CIDR` and `STORAGE`; targets share its
bridge and gateway. Target-specific options (`GPU_DEVICES`, `BACKEND`,
`OLLAMA_PULL_MODELS`, `HERMES_MODEL`, `OPENCLAW_MODEL`, `COMFYUI_MODEL_URL`, etc.) are documented
in their READMEs.

Model server addresses may be IPs, `host:port`, URLs, or `kind://host` for
non-Ollama servers. No model server address is prefilled unless you set its
`MODEL_SERVER_<n>` preset. Set `MODEL_LARGE`
to a model actually present on your host (its inherited default is
`qwen3.8:27b`). Hosts are divided among four tiers; with fewer than four
hosts, upper tiers share the last host. Override assignments with
`TIER_<tier>_SERVERS`.

For Gitea, use the final URL scheme, address and port (`:3000` for the
community CT, HTTPS 443 for TurnKey); an HTTP-to-HTTPS redirect can lose the
token. A dedicated non-admin account needs `read:user` and
`write:repository` for an existing repo, or `write:user` and
`write:repository` to create one under its account. Set `GITEA_REPO_OWNER`
if repository lookup is ambiguous; a repo under another owner must already
exist. Without a usable token, installation continues in local mode without
version control. For self-signed TLS, verification defaults off; install the
CA and change `GITEA_VERIFY_TLS` in `prompt_gitea_credentials` to enable it.
Protect tokens on untrusted networks with a TLS reverse proxy.

With a usable Gitea token, the installer tests write access by committing
`provisioning-tests/<timestamp>.md`, then attempts to delete it in a second
commit. The history retains a "Provisioning test commit" and a "Remove
provisioning test marker" commit even when the file is gone. If cleanup fails
or an older installer left markers, remove them from the config checkout with
`git rm -r provisioning-tests` and commit.

**After install**

```
http://<ct-ip>:8000/v1      OpenAI-compatible API (Bearer ROUTER_API_KEY)
http://<ct-ip>:8080         Open WebUI: the first visitor creates the admin account
```

The generated API key is in `/app/router/secrets.env` inside the router CT.

**Gitea and Mattermost on their own.** Run
`targets/gitea/provision-lxc.sh` or `targets/mattermost/provision-lxc.sh` for
an existing router. `--reconfigure` repairs an existing CT; `--create-only`
(also used by `tools/install-*.sh`) leaves browser setup to you. See their
READMEs for credentials and retry steps.

Open WebUI's first start downloads an embedding model and can take up to ten
minutes. `/etc/motd` lists ports, tiers and paths; the full runtime layout is
in [ARCHITECTURE.md, Appendix A](ARCHITECTURE.md#appendix-a--runtime-file-layout).

## Inference targets

Each target has a host-side `provision-lxc.sh`, guest-side
`install-target.sh` (also `--upgrade`) and a README with requirements, settings
and recovery steps. Provisioners support `--dry-run`.

| Target | Register as | Port | Key requirement |
|---|---|---|---|
| [Ollama](targets/ollama/README.md) | plain address | 11434 | NVIDIA, AMD, Intel or CPU |
| [llama.cpp](targets/llamacpp/README.md) | plain address | 11434 | GGUF; CUDA, Vulkan or CPU |
| [AirLLM](targets/airllm/README.md) | plain address | 11434 | Large disk; slow inference, so give it its own tier |
| [Strata](targets/strata/README.md) | `strata://` | 8080 | NVIDIA |
| [Basalt](targets/basalt/README.md) | `basalt://` | 8080 | Blackwell GPU (sm_120) and CUDA 13 |
| [Maya](targets/maya/README.md) | `maya://` | 8080 | NVIDIA; CUDA version must suit CT and card |
| [Xolotl](targets/xolotl/README.md) | `xolotl://` | 8080 | NVIDIA; ~372 GB of pinned weights |
| [Avalon](targets/avalon/README.md) | `avalon://` | 8080 | Qwen3.8-Flash-Next on an AMD RX 7000 (ROCm) or NVIDIA GPU, experts in RAM; ~90 GiB of pinned weights |
| [Kindi](targets/kindi/README.md) | `kindi://` | 8093 | Ternary-Bonsai-2 2B to 27B (or Nanbeige 33B) on an old or small NVIDIA card from a 1 GB Kepler up, or the CPU; one request at a time |

[Gitea](targets/gitea/README.md) and
[Mattermost](targets/mattermost/README.md) provide config history and alerts.
[Honcho AI](targets/honcho/README.md) provides CPU-only agent memory and an
MCP tool server for Open WebUI. Selecting it with Hermes or OpenClaw connects
their native memory integrations to the same `osr` workspace. Honcho needs an
OpenAI-compatible embedding model; the installer asks for its name, vector
dimensions and `/v1` endpoint. Its loopback proxy uses router inventory to
select a compatible chat model and sends inference directly to model hosts.
Reconfigure Honcho after router or model backend key rotation to refresh its
proxy credentials.
[Open Terminal](targets/open-terminal/README.md) adds a terminal tool.
[DeepSeek Harness](targets/deepseek-harness/README.md) runs as a separate agent
in its own CPU-only LXC, with a Web UI on port 3080 and OSR as its model
provider. It does not require an Open WebUI admin token. With Honcho selected
it connects to Honcho's MCP server for the shared `osr` memory; its model
calls the memory tools itself (Hermes and OpenClaw record every turn through
their plugins).
[Hermes](targets/hermes/README.md) is an agent client, registered in Open
WebUI as `hermes-agent`, not a pool model; it needs a tool-capable model with
at least 64K context. Re-run its provisioner with `--reconfigure` after a
router or backend key rotation or a new model host.
[OpenClaw](targets/openclaw/README.md) is a second agent client on the same
pattern, registered as `openclaw`, with its Control UI on port 18789. It is
installed with nvm, Node 24 and `npm install -g openclaw` (the
[brax.me script](https://brax.me/openclaw/install.sh)'s steps, without its
Ollama install) and uses Hermes's direct dispatcher.
[ComfyUI](targets/comfyui/README.md) adds image generation to Open WebUI on
port 8188. Select distilled FLUX.2 Klein 4B or 9B; 9B needs a Hugging Face
token for an account that accepted the license.

### Proxmox tags

Each installer tags the CT it creates, so the Proxmox tree can be filtered by
role. `osr-target` marks every CT installed alongside the router (model
servers, services and companions); the last tag names the target.

| CT | Tags |
|---|---|
| Router (`ollama-smart-router-install.sh`) | `ai`, `ai-tools`, `osr-router`, `openwebui` |
| Ollama, llama.cpp, AirLLM, Strata, Basalt, Maya, Xolotl, Avalon, Kindi, ComfyUI | `ai`, `ai-model`, `osr-target`, `<target>` |
| Gitea, Mattermost, Honcho, Open Terminal, Hermes, OpenClaw, DeepSeek Harness | `ai`, `ai-tools`, `osr-target`, `<target>` |

`<target>` is the target's directory name under `targets/` (`ollama`,
`llamacpp`, `open-terminal` and so on). The Proxmox community script that
creates the Ollama, ComfyUI, Gitea and Mattermost CTs also adds its own
`community-script` tag. Tags are set only when a CT is created; to tag an
existing CT, run `pct set <CT_ID> --tags '<tag>;<tag>'` on the host. The tag
lists are in each `provision-lxc.sh` (the router's in
`ollama-smart-router-install.sh`); keep this table in step when changing them.

### Provisioner questions

Run on a terminal, every `targets/<target>/provision-lxc.sh` asks its
questions in sections, one subject at a time, and shows a summary to confirm
before it changes anything:

```
== Router ==
  Router CT ID or address [280]:

== Hermes container ==
  New Hermes CT ID (unused): 282
  (numbered template and storage menus)
  Hermes IP/CIDR: 192.0.2.82/24
  Hermes gateway [192.0.2.1]:

== Hermes settings ==
  OSR model or tier [auto]:
  Context window the model serves (tokens) [65536]:
  Offer Hermes in Open WebUI (as hermes-agent)? [Y/n]:
  Run the Hermes dashboard? [Y/n]:

== Honcho memory ==
  Honcho API URL (none to skip) [http://192.0.2.85:8000]:

== Hermes: create ==
  Router                     CT 280, http://192.0.2.80:8000
  Hermes CT                  282 (hermes-target), ...
Create Hermes CT 282? [Y/n]:
```

A `--reconfigure` of the same CT starts with the CT and offers what it has:

```
== Hermes container to reconfigure ==
  Hermes CT ID [282]:
== Router ==
  Router CT ID or address [280]:
== Hermes settings ==
  OSR model or tier [auto]:
  ...
```

- **Router first, then the target.** Targets that talk to the router ask
  for it in a *Router* section, offered from the CT tagged `osr-router`. The
  new CT's ID, template, storage, address and gateway follow together; the
  gateway is offered from the router CT's network. The target's own settings
  come last.
- **Enter takes the value in brackets.** A new install offers defaults; a
  CT ID or address is only ever *offered* to a person (the cluster's next free
  ID, the router's gateway), never chosen for an unattended run. Optional
  settings accept `none` to leave them off.
- **`--reconfigure` starts from what is installed.** It first asks which CT
  to reconfigure (offering the one with the target's tag), then the router
  (offering the one the target already uses), and every setting shows the
  CT's recorded value, so pressing Enter all the way keeps the install as it
  is. Recorded values are read only from a running CT.
- **Environment variables still win.** A preset variable is not asked, and
  without a terminal (or with `NONINTERACTIVE=true`) nothing is asked: missing
  required settings stop the run with the variable to set, and
  `--reconfigure` keeps the recorded settings. `PVE_CONFIRM=false` skips the
  confirmation. The router installer runs provisioners with
  `PVE_ACCEPT_DEFAULTS=true PVE_CONFIRM=false`, since it has already asked
  its questions and shown its own summary.

The shared helpers are `targets/pve-select.sh`; each target directory keeps an
identical copy (`targets/test-pve-select.sh` checks them). llama.cpp and
AirLLM keep their own container prompts with the same order.

## How routing works

The router polls configured hosts every 60 seconds and inventories their
models. It classifies the newest user message as `fast`, `medium`, `large` or
`xlarge`, then scores each available host/model pair by size, code or vision
fit, tool support and residency. Close scores rotate across hosts. A named
model is used if available; `auto` and tier aliases ask the router to choose.
Embedding-only models are excluded from chat.

Connect errors, timeouts, 404s and 5xx responses try the next candidate until
streaming starts. A tool-support rejection also tries the next candidate;
other 400s go back to the client. If discovery is off or inventory empty,
LiteLLM handles the request by static tier (`X-Router-Mode: litellm`).
`X-Router-Model`, `-Server`, `-Class`, `-Mode`, `-Candidates` and optional
`-Warning` response headers explain the choice. Use:

```text
GET  /routing/inventory   host models, capabilities and errors
POST /routing/refresh     poll now
POST /routing/explain     {"prompt": "..."} -> scored candidates
GET  /healthz             unauthenticated liveness
```

Tune thresholds, keywords, weights, timeouts and model sizes in
`services/ollama-router/router.ini`. See [ARCHITECTURE.md](ARCHITECTURE.md#5-request-routing)
for the decision and failover rules.

The router reads `ROUTER_HOST` and `ROUTER_PORT` from its environment (default
`0.0.0.0:8000`); the installer sets neither. To change its binding, set the
needed variables in `env/router.env`, then update `OPENAI_API_BASE_URLS` in
`env/openwebui.env`, `ollama-router` in `monitor.ini [local_services]`, the CT
firewall and client URLs. On an existing Open WebUI, check its saved OpenAI
connection under **Admin Settings > Connections** too. Management health
checks use a separate `ROUTER_URL`
defaulting to `http://127.0.0.1:8000`; set it to the new reachable base URL
when running `apply`, `discover` or the updater inside the CT. The host-side
management and update wrappers do not forward that override. Reconfigure
Hermes and OpenClaw if they use the old router URL. Their `--reconfigure` derives
`ROUTER_URL` again from the router's IP and `ROUTER_PORT` in
`/app/router/.env` unless you pass `ROUTER_URL` on that run; it does not
remember one given at install, so pass a custom URL (a DNS name or proxy)
again each time.
With no API key on a non-loopback address, the router logs a warning at start-up.

New installs generate `ROUTER_API_KEY`;
for an older install, run `manage-model-servers set-api-key --apply` and enter
the printed key in Open WebUI **Admin Settings > Connections > OpenAI**.

## Managing model servers

The installer puts `manage-model-servers` in the OSR CT only, as
`/usr/local/bin/manage-model-servers`, a symlink to
`/app/config-repo/install/manage-model-servers.sh`. Every `apply` makes the link
again, so an update to the config repo updates the command. Nothing is
installed on the Proxmox host. Run it as root in one of these ways; `<CT_ID>` is
the OSR CT's ID, printed as `Container ID` at the end of the install and listed
by `pct list` (named `ollama-smart-router` unless `CT_NAME` was set):

```bash
# In the OSR CT, where /usr/local/bin is on root's PATH:
pct enter <CT_ID>
manage-model-servers list

# One command from the Proxmox host (the full path does not depend on pct's PATH):
pct exec <CT_ID> -- /usr/local/bin/manage-model-servers list

# From a clone of this repo on the Proxmox host: it finds the CT that holds the
# config and re-runs itself there (CT_ID=<CT_ID> skips the search).
bash /path/to/clone/manage-model-servers.sh list
```

The examples below use the command name, as inside the CT. Commands that write
take the config lock, and `--apply` validates, applies and health-checks (see
[Applying changes](#applying-configuration-changes)).

```bash
manage-model-servers list | status | discover | models     # config, live probe, router inventory, tags per host
manage-model-servers add 10.0.0.55 --tier large --apply      # probed before it is accepted (--no-probe skips)
manage-model-servers add lmstudio://10.0.0.9:1234 --tier fast   # or --type <kind>
manage-model-servers remove 10.0.0.55 --apply                # by address or list number
manage-model-servers set-tier large 10.0.0.54 10.0.0.55 --apply
manage-model-servers set-model large qwen3:32b --apply       # every server in the tier
manage-model-servers set-server-model large 10.0.0.54 llama3.3:70b --apply   # one server
manage-model-servers set-keepalive 2h --apply
manage-model-servers set-api-key [key|--generate|--off]
manage-model-servers set-<kind>-token [token|--off]          # lmstudio, strata, basalt, maya, xolotl, avalon, kindi
manage-model-servers set-token | set-webhook [url] | test-alert [message]
manage-model-servers set-webui-version [version|latest] [--apply]
manage-model-servers apply [--all] | commit [message]
manage-model-servers clear-lock [--force]
```

- Servers are keyed by URL, never by position, so removing one never re-points
  a tier at the wrong host.
- Models are set per (tier, server), and both model commands check that the
  tag exists on the server first. Pass full Ollama names without the `ollama/`
  prefix, e.g. `smtek/Qwen3.8-27B:Q3_K_XL-16gb`.
- A tier's model tag drives the LiteLLM fallback and the keep-alive pinning.
  Discovery-mode routing picks from the live inventory regardless.
- `commit` pushes with the deploy token from `secrets.env` (Gitea refuses
  passwords over HTTP). Replace the token with `set-token`.

### Server kinds

Non-Ollama servers are stored with a kind prefix (`maya+http://host:8080`);
`add` accepts `kind://host` or `--type kind`. A bare address is auto-detected
without sending a key: Ollama `/api/tags`, then the public `/health` markers of
Strata, Basalt, Maya and Xolotl, then LM Studio's model API, trying each kind's
default port. Xolotl runs Strata's server, so its `/health` says `strata`; a
DeepSeek-V4 model there identifies Xolotl. Avalon is a llama-server whose
`/health` says only `status`; it is identified from `/v1/models`
(`"owned_by": "llamacpp"` and an Avalon model id), which needs its key once
one is set, so add a keyed Avalon as `avalon://host`. Kindi's public `/health`
names it (`"kindi": "<version>"`), so it is found without a key.

| Kind | Default port | Token (in `secrets.env`) | Notes |
|---|---|---|---|
| Ollama (also llama.cpp bridge, AirLLM) | 11434 | — | Keep-alive pinned by the monitor |
| LM Studio | 1234 | `set-lmstudio-token` | Resident models are preferred; `lmstudio_loaded_only = true` never triggers a just-in-time load. Model names differ (`qwen/qwen3-14b`). Set LM Studio's own idle TTL. |
| Strata | 8080 | `set-strata-token` | Must listen on an address the router can reach (see below). Can run on 11434: `strata://host:11434`. |
| Basalt | 8080 | `set-basalt-token` | Model ID is `BASALT_ALIAS` (default `qwen3.8-flash-next`) |
| Maya | 8080 | `set-maya-token` | Model ID `glm-5.3-flash` |
| Xolotl | 8080 | `set-xolotl-token` | Model ID `XOLOTL_MODEL_NAME` (default `deepseek-v4.1-flash`, sized 552B) |
| Avalon | 8080 | `set-avalon-token` | Model ID `AVALON_MODEL_NAME` (default `qwen3.8-flash-next-avalon`, sized 125B) |
| Kindi | 8093 | `set-kindi-token` | Model ID `bonsai2-<size>` or `nanbeige-33b-iq3`, sized from the id; serves one request at a time |

Example for a keyed Strata-style server. Set the token first, so the probe can
authenticate:

```bash
manage-model-servers set-maya-token --apply
manage-model-servers add maya://10.0.0.9 --tier xlarge --apply
manage-model-servers set-server-model xlarge maya://10.0.0.9 glm-5.3-flash --apply
```

A Strata you run yourself, rather than the [Strata target](targets/strata/README.md),
binds to `127.0.0.1` by default and is unreachable from the router. Run its
setup (`./setup.sh` on Linux, `START-HERE.bat` on Windows) with `--host` set to
a reachable address, `--port 11434` if you want that port, and `--api-key` to
require a key; see [Strata's setup options at the tested commit](https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/docs/INSTALL.md#options-without-questions).
For the newer Strata launcher on `main`, use `strata launch --access lan`
instead of `--host`; it [creates a key by default](https://github.com/Niko1221/Strata/blob/main/docs/TERMINAL_LAUNCH.md)
(`--no-api-key` skips it).

If an older keyed Strata cannot be identified without a key, add it as
`strata://host` (that probe uses the key) or with `--no-probe`. Strata, Basalt,
Maya, Xolotl, Avalon and Kindi load models themselves, so no keep-alive is sent. The monitor counts
them as down while `/v1/models` is empty, which is how they answer when the
engine is not running.

### Model sizes for unsized IDs

Strata, Basalt, Maya, Xolotl and Avalon report no parameter count (Kindi's ids name it). `[model_sizes]` in
`router.ini` maps exact model IDs (case-insensitive) to a size:

```ini
[model_sizes]
strata = 125B
qwen3.8-flash-next = 125B
glm-5.3-flash = 321B
deepseek-v4.1-flash = 552B
```

Add a line for a custom alias; a blank value removes a built-in entry. A size
in the ID (`coder:62b`) or a reported `parameter_size` wins. The older
`[discovery] *_default_params` / `*_default_id` keys are still read.

### Keeping models loaded

Ollama unloads idle models after ~5 minutes, and its OpenAI-compatible
endpoint ignores `keep_alive`. Set `OLLAMA_KEEP_ALIVE` (at install, or
`set-keepalive 30m|2h|-1|0|<seconds> --apply`) and two things happen:

- LiteLLM sends `keep_alive` on its native-API calls.
- The monitor calls each up Ollama host's native `/api/chat` with an empty
  message every 240 s (`monitor.ini [keep_alive] refresh_seconds`, or
  `KEEP_ALIVE_REFRESH_SECONDS` in its environment), keeping
  each tier's model loaded.

Blank (the default) sends nothing and leaves each server's own setting in
charge.

## Applying configuration changes

The config repo is cloned once, at provisioning, so services never need Gitea
to start. To change config on a running CT:

```bash
cd /app/config-repo && git pull
manage-model-servers apply          # or --all to restart every service
```

In local mode, edit `/app/config-repo` directly and skip `git pull`.

`apply`:

1. **Validates** the LiteLLM YAML (models, `api_base`, fallbacks), the ini
   files and keyword JSON, the env files, and that `router.py`/`monitor.py`
   compile. On any error nothing is changed.
2. **Snapshots** the installed files to `/var/backups/ollama-smart-router/`
   (root-only; `APPLY_BACKUP_KEEP`, default 5).
3. **Applies** the files, brings the LiteLLM and Open WebUI venvs in line with
   their pins (Open WebUI's `webui.db` is backed up first), and restarts only
   the affected services.
4. **Health-checks** the router `/healthz`, LiteLLM `/health/liveliness`,
   Open WebUI `/health` and the monitor. On failure it restores the snapshot
   and restarts the old files. Rebuilt venvs are not rolled back, except that
   a failed Open WebUI upgrade reinstalls the previous version and database.

Regenerating the LiteLLM config keeps model tags and hand-edited
`router_settings` (`num_retries: 2`, `timeout: 600`). It rebuilds `fallbacks`
from the existing tiers and never falls back to an identical tier, or into a
tier with Kindi except from a tier on other Kindi servers. It keeps operator
retry policies (block or flow style) for other current tiers and writes Kindi's
own for Kindi tiers (see targets/kindi/README.md).

**Secrets** (deploy token, webhook, router key, backend tokens) live only in
`/app/router/secrets.env` (`0640 root:ollama-router`). `apply` and `commit`
move any secret they find in `env/router.env` into that file. Commits made
before 2026-09 still contain the old deploy token, so rotate it in Gitea.

**Config lock.** `update-router.sh` and every writing command take
`/run/lock/ollama-smart-router-config.lock`. A second change fails at once;
`CONFIG_LOCK_WAIT=<seconds>` makes it wait instead. The lock dies with its
process, so a crash never leaves it held. For a hung holder,
`clear-lock --force` asks for confirmation, then sends SIGTERM and SIGKILL
after `LOCK_KILL_WAIT` (10) seconds if needed. `--yes` skips the prompt;
without a terminal, the prompt cancels. A change stopped midway can leave
the config repo or services half-updated.

## Updating

### Router components

To update the router, monitor, units, requirements and management tools from
a newer clone, without reinstalling, run this as root from a clone on the
Proxmox host:

```bash
bash /path/to/clone/tools/update-router-services.sh --dry-run --diff   # review
bash /path/to/clone/tools/update-router-services.sh                     # prompts for the CT (or set CT_ID; --host skips the location prompt)
```

To run it inside the CT, use a clone separate from `/app/config-repo` and add
`--container`. It refuses a missing or nonstandard installation, then stages
the installer-owned files and runs
`install/update-router.sh` in the CT. That script commits them to
`/app/config-repo`, rebuilds the router venv if its requirements changed, runs
`manage-model-servers apply`, and pushes. On a failed apply it undoes the
commit and restores the previous venv packages. It never touches your servers,
tiers, `env/*.env`, `litellm_config.yaml` or secrets. `router.ini` and
`monitor.ini` are replaced only with `--with-tunables`. `--no-apply` and
`--no-push` stop early. It refuses a config repo with uncommitted changes, so
commit pending edits first. A failed push exits non-zero but keeps the
applied update.

Re-running the installer also updates installer-owned code in the Gitea repo
(`CONFIG_UPDATE_CODE=true`). Configuration files are only seeded if missing.

### Open WebUI

```bash
manage-model-servers set-webui-version                 # pinned / installed / latest
manage-model-servers set-webui-version latest --apply  # or a specific version
```

The pin lives in `services/open-webui/requirements.txt`. The version is
checked against PyPI and against the venv's Python before the pin is written.
If the upgraded UI fails its health check, the previous version and
`webui.db` are restored.

New installs get Open WebUI 0.12.4. To bring an existing router up to it, run
`manage-model-servers set-webui-version 0.12.4 --apply`. Open WebUI 0.11.1,
0.12.0 and 0.12.1 migrate the database, so an older version cannot open it
afterwards. `apply` copies `webui.db` into its snapshot under
`/var/backups/ollama-smart-router/<timestamp>/openwebui-data/` before
upgrading; only the last `APPLY_BACKUP_KEEP` (5) snapshots are kept, so copy
that directory elsewhere if you may want to roll back later. Re-run a ComfyUI
router's `targets/comfyui/integrate-webui.py` only if its image settings need
to change: it handles both the 0.11.4+ connection check and the older one.

### Targets

Target upgrades check readiness and restore the prior code and settings on
failure. Strata, Basalt, Maya, Xolotl, Avalon and Kindi need disk for one runtime snapshot;
their existing installation settings carry forward unless explicitly
overridden. See the target README and [architecture upgrade contract](ARCHITECTURE.md#16-inference-targets-targets)
before upgrading. Interrupting an upgrade (Ctrl-C, a closed SSH session)
rolls it back like a failure; after a hangup its output is in the CT's
`/var/log/osr-install-interrupted.log`. If a model target's rollback fails
too, its next run stops at `/var/lib/<target>-target/rollback-failed` until
you have inspected the kept snapshot and deleted that file.

### GPU drivers

To check the GPU drivers of the host and of every container a GPU is passed
through to, and update them to the newest compatible release, run this as
root on the Proxmox host:

```bash
bash /path/to/clone/tools/update-gpu-drivers.sh --check   # report only (exit 3: updates available)
bash /path/to/clone/tools/update-gpu-drivers.sh           # shows the plan and asks before each change
```

It finds the GPU containers from their configs (`/dev/nvidia*`, `/dev/dri/*`,
`/dev/kfd`) and checks each running one. Stopped ones are checked with
`--include-stopped`, which starts them and stops them again afterwards.

**NVIDIA.** The host driver and the libraries in every container must be the
same release. The script offers the newest production release from NVIDIA's
archive (recommended), the newest release of the installed branch, and the
newest new-feature-branch release. Cards older than Turing (Maxwell, Pascal,
Volta) stay on the 580 branch. Before anything stops, it downloads the chosen
release, checks its SHA-256 and that its `supported-gpus.json` lists every
NVIDIA card here (with the open kernel modules, when those are in use), and
test-builds its kernel modules for the running kernel and any newer installed
one. Then it stops the NVIDIA containers, unloads the old modules, installs the
release with `tools/install-nvidia-driver.sh host`, builds it with DKMS for newer
installed kernels, installs the same installer's libraries in each container
(`tools/install-nvidia-driver.sh lxc`) and restarts them. A stopped NVIDIA
container is started and checked before the host changes, then stopped again
when the update finishes. Debian's apt NVIDIA packages in a container (`libcuda1`,
`libnvidia-ml1`, `nvidia-smi` and the libraries that depend on
`nvidia-alternative`) are replaced with the `.run` libraries, using the same
cleanup as the provisioners. Every NVIDIA container is checked before anything
is downloaded, including ones `--ct` leaves out. A container blocks the host
update when it cannot be checked or started, does not see the host driver, or
has apt NVIDIA packages that cleanup does not remove (Ubuntu's
`libnvidia-compute-*`, the CUDA repository's `cuda-drivers`). It also blocks
when removing its packages would take something else along, such as
`nvidia-cuda-toolkit`. `--check` lists what blocks the update. If the new host install
fails, the previous release is put back. If a host process still holds the GPU,
nothing is installed. A container whose NVML or CUDA driver library does not
match the host is offered the host's release. A host with an apt-installed
driver is reported but not changed. `--nvidia <version>`
also rolls back, but not below the branch a container's CUDA toolkit needs
(CUDA 13: 580).

**AMD and Intel.** `amdgpu`, `i915` and `xe` ship with the Proxmox kernel, so
their newest compatible versions are the pending updates of `pve-firmware`
and the running kernel series. A newer opt-in kernel series is reported but
not installed. In containers, Mesa (Vulkan), Intel's compute runtime and
apt-installed ROCm are upgraded from the container's own repositories. ROCm,
CUDA and PyTorch bundled with Ollama or ComfyUI move with the target's
`install-target.sh --upgrade`.

`--yes` takes the recommended answers (`--nvidia production|branch|newest|keep|<version>`
picks the NVIDIA release), `--ct 201,202` limits the containers (a new NVIDIA
host release still updates every NVIDIA container), `--dry-run` shows the
commands, `--no-probe` skips the test build. Checking a release needs about 2 GB
free in `DOWNLOAD_DIR` (default `/root`), and each NVIDIA container about 1 GB
while its libraries are installed. Exit status 2 means the host
needs a reboot (new kernel, firmware, or a driver that could not be loaded
live); run the script again afterwards to confirm.

## Troubleshooting

Start with the services' logs and the router's view of the pool, inside the
router CT (`pct enter <CT_ID>`):

```bash
KEY=$(sed -n 's/^ROUTER_API_KEY=//p' /app/router/secrets.env)
systemctl status open-webui ollama-router litellm-proxy ollama-monitor
manage-model-servers status           # configured hosts + live probe
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/routing/inventory
journalctl -u ollama-router -f        # decisions for chats sent to /v1/chat/completions
```

Hermes `custom:osr` (including `auto`) reads the router's inventory and ranking,
then sends chat directly from the Hermes CT to a model server. In the Hermes CT,
use `journalctl -u hermes-direct -f` to see `direct dispatch MODEL -> SERVER`.
The router CT shows Hermes inventory requests and, for a new or unpinned task,
`/routing/explain` requests, but no `route class=` line for those chats.
OpenClaw's provider `osr` works the same way; its dispatcher logs to
`journalctl -u openclaw-direct -f` in the OpenClaw CT.

| Symptom | Cause / fix |
|---|---|
| Installer: no storage found | The storage does not declare `rootdir`. Run `pvesm set <storage> --content rootdir,images`. Storages too small for `ROOTFS_GB` are listed but cannot be selected. |
| Installer: Gitea 401 or TLS error | Use the final URL (community CT: `http://<ip>:3000`; TurnKey: HTTPS 443), avoiding redirects. The installer diagnoses DNS, connection, TLS and token errors. After 3 bad tokens it falls back to local mode. |
| `open-webui==… (from versions: none)` | Open WebUI needs Python 3.11–3.12. The installer provisions 3.12 (system package, otherwise `uv` into `/opt/python`, which needs PyPI/GitHub). If neither is reachable, install 3.12 manually and re-run. |
| Open WebUI venv ~7.5 GB | `TORCH_CPU_ONLY=false`, or `download.pytorch.org` was unreachable. `apply` installs CPU torch and purges `nvidia-*`/`triton` wheels. |
| Open WebUI shows no models / 401 | The router key changed. Paste it into Admin Settings > Connections > OpenAI. |
| A host or its models are missing | Check `/routing/inventory` for the error. Common causes: a wrong or missing `set-<kind>-token` (401), a Strata-style engine not running (empty `/v1/models`), or a server bound to `127.0.0.1`. A refused connection takes a host out of rotation until its next good poll. |
| Request went to an unexpected model | Look at the `X-Router-*` headers, or `POST /routing/explain`. `model-unavailable` means the named model's hosts were down. Unknown-size models score low; give them a `[model_sizes]` entry. |
| Long prompt fails with 4xx | Context windows are not considered, and a 4xx does not fail forward. Use a model with a larger context. |
| Agent or function-calling request fails with "does not support tools" | No discovered model reports tool support (`X-Router-Warning: no-tool-model`). Check `tools` per model in `/routing/inventory`; for llama.cpp add `tools` to `MODEL_CAPABILITIES`. |
| Models unload after ~5 min | Set `OLLAMA_KEEP_ALIVE` (see above). If you rely on the host's own setting, check that it is in the unit (`Environment="OLLAMA_KEEP_ALIVE=2h"`, then `daemon-reload` and restart). |
| No Mattermost alerts | `journalctl -u ollama-monitor` shows rejected webhooks. Use `set-webhook` and `test-alert`. Alerts fire after 3 failed checks and recover after 2; the startup notice is sent at most hourly. |
| `apply` failed | The snapshot was restored and the services were restarted on the old files. Read the reported check, then `journalctl -u <unit>`. Snapshots are in `/var/backups/ollama-smart-router/`. |
| "config is locked" | Another change is running. A hung one: `manage-model-servers clear-lock` shows the holder, and `--force` stops it. Afterwards check `git -C /app/config-repo status` and re-run `apply`. |
| Target upgrade failed | The installer says whether the previous version is "running again". If not, use `journalctl -u <unit>` in the target CT. Replaced files are kept as `*.prev` (llama.cpp, AirLLM, Ollama); Strata, Basalt, Maya, Xolotl, Avalon and Kindi keep their snapshot in `/var/lib/<target>-target/` when the rollback fails. Maya, Basalt and Xolotl: the CT's distro must carry the CUDA release, or the toolkit must already be installed. Debian 13 starts at 13.1 (no V100 support for Maya; set `CUDA_VERSION=13.1` for Basalt). |

## Development

`services/`, `install/` and `targets/` are the sources. After editing embedded
`services/` or `install/` files, run `tools/sync-embedded.py --write`.
`bash tests/run-tests.sh` runs the shell and pytest suites; use `--list` or a
suite name to narrow it. Some target tests require root and skip otherwise;
CI runs them with `--strict`. See [tests/README.md](tests/README.md) for the
test and CI details.

To run CI (`.gitea/workflows/tests.yml`) in Gitea, enable Actions on the
repository and register an `act_runner` with an ubuntu-latest style image.
Configure its job containers to run as root, because
`--strict` fails on skipped root-only tests. The `strata-upstream`,
`maya-upstream`, `xolotl-upstream`, `avalon-upstream` and `kindi-upstream` jobs also need access to GitHub.
