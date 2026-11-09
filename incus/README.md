# Running the stack on Incus instead of Proxmox

The main installer targets a Proxmox host and builds LXC containers with `pct`. The scripts
here do the same job on a host running [Incus](https://linuxcontainers.org/incus/): they
create the containers with `incus` and then reuse this repository's own guest-side
`install-target.sh` scripts and service files unchanged. They are non-interactive, and
every setting is an environment variable (see the comment block at the top of each script).

## What is ported

| Script | Does |
|---|---|
| `install-router-incus.sh` | Router container: Smart Router, LiteLLM, Open WebUI, health monitor. Forwards ports 8000 and 8080 from the host. No Gitea (local configuration mode). |
| `install-ollama-incus.sh` | Ollama target with an NVIDIA GPU attached; installs the repo-pinned release, then runs `targets/ollama/install-target.sh`. |
| `install-comfyui-incus.sh` | ComfyUI image-generation target (FLUX.2 Klein), adopted with `targets/comfyui/install-target.sh`. |
| `integrate-comfyui-incus.sh` | Registers ComfyUI as Open WebUI's image engine. Needs an Open WebUI admin API key. |
| `install-honcho-incus.sh` | Honcho memory target (PostgreSQL, embeddings on CPU), installed with `targets/honcho/install-target.sh`. |
| `integrate-honcho-incus.sh` | Registers Honcho's MCP tools with Open WebUI. Needs an admin API key. |

Not ported: Gitea, Mattermost, the other model targets, and the agent targets (Hermes,
OpenClaw, DeepSeek Harness, Open Terminal).

## Optional utility: voice (Speaches)

`install-speaches-incus.sh` is not part of the original stack. It adds a container running
[Speaches](https://github.com/speaches-ai/speaches), an OpenAI-compatible server for
speech-to-text (faster-whisper) and text-to-speech (Kokoro), which Open WebUI can use for
voice chat (Admin Settings, Audio). It pins a reviewed upstream commit and installs its
dependencies natively with `uv` (no Docker). **Status: experimental, not yet run end to end.**
It installs third-party code, so read it first. Browsers only allow the microphone on HTTPS or
`localhost`, so from another machine use an SSH tunnel or a TLS proxy.

## Suggested order

1. `install-router-incus.sh`
2. `install-ollama-incus.sh`, then register it with `manage-model-servers add` in the router container.
3. Optionally `install-comfyui-incus.sh` and `integrate-comfyui-incus.sh`.
4. Optionally `install-honcho-incus.sh` and `integrate-honcho-incus.sh`.

## Host requirements

- Incus 6.0 or newer, a user in the `incus-admin` group, a storage pool, and the default
  `incusbr0` bridge. Default container addresses are `.10` (Ollama), `.11` (ComfyUI),
  `.12` (Speaches) and `.13` (Honcho) in the bridge's /24, which is read from the host; set
  `CT_IP` to choose another, or `BRIDGE` for a different bridge.
- For GPU containers: the NVIDIA driver installed on the host from the distribution's archive.
  The container installs the same-version user-space libraries from the same archive, so the
  two always match. The container gets the GPU as an Incus `gpu` device.
- `security.nesting=true` on the containers (the scripts set it). Without it, systemd's service
  sandboxing can hang a Debian 13 container's boot.

## Differences from the Proxmox setup

- No Proxmox community scripts, templates or firewall. Containers sit on the Incus bridge and
  reach the router through the bridge gateway, where the router's API port is forwarded.
- Only the router's API (8000) and Open WebUI (8080) are forwarded to the LAN; everything else
  stays on the bridge.
- All containers share one GPU. Ollama holds one model at a time by default, and ComfyUI and
  the LLM compete for VRAM, so plan memory accordingly.
- Tested on Ubuntu 26.04 with Incus 6.0.5 and a Tesla T4.
