# DeepSeek Harness LXC target

This target runs [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`) as a separate CPU-only agent in its own unprivileged Debian 12/13 LXC.
Its Web UI, sessions, shell tools and workspace live in that CT. Harness uses
Ollama Smart Router as a custom OpenAI-compatible model provider; it is not an
inference model in OSR's pool and is not an Open WebUI tool. With Honcho
selected, Harness also gets Honcho as its long-term memory, shared with Hermes
and OpenClaw (see [Honcho memory](#honcho-memory)).

The main OSR installer offers `deepseek-harness` in its target menu. It creates
the router first, then this CT. Unlike the Open WebUI companions, Harness needs
no Open WebUI admin token. It reads the OSR API key from the router CT and
places it in a root-only systemd environment file in the Harness CT; the
generated Harness patch contains only the environment variable's name.

**Trust.** Harness's shell tools inherit the service's environment, so the
agent (and anything it runs) can read the router key and, with Honcho, the
`osr` workspace key. Limit Web UI access to people trusted to operate OSR.

## Requirements

- Proxmox VE with a downloaded Debian 12 or 13 amd64 LXC template, rootdir
  storage, a free CT ID and a static IPv4 address with DNS and internet access.
- The OSR router must be a running CT **on the same PVE host**: this target
  reads its address and key through `pct exec`.
- At least one OSR model that supports tool calls and serves the configured
  context. Check `/routing/inventory` for `tools` and `context_length`.
  Harness's own tools take about 6,000 tokens of every request (29 tool
  definitions in 0.2.1); Honcho's MCP tools add several thousand more.
- The router's port must accept the Harness CT. When the router CT has a
  Proxmox firewall file, the provisioner keeps one rule there for it
  (`# osr-deepseek-harness-router`); `DSH_ROUTER_FIREWALL=false` leaves that
  file to you.

The guest installer installs Node.js 24.9+ (from NodeSource's signed Node 24
apt repository when the CT has none), then the official `@deepseek-ai/dsh` npm
package as the unprivileged `deepseek-harness` account. No DeepSeek API
subscription is needed when OSR supplies the model.

**Pinned release.** Harness is a developer preview with breaking changes
between releases, so this target installs `0.2.1-rc.5` (npm `latest` on
2026-11-03) unless `DSH_VERSION` says otherwise. That release was checked
against this target's generated patch (`dsh --dump-config`), a headless chat
through the OSR provider (system role, `max_tokens`, bearer key) and the Honcho
MCP connection (key and workspace headers, tool discovery). The newer
`0.2.2-alpha` releases add MCP options this target does not use; move the pin
only after testing. `DSH_VERSION=latest` resolves the current npm `latest` at each run and
records the exact version it installed.

## Provision

From the repository root on the PVE host, select `deepseek-harness` in the
main `ollama-smart-router-install.sh` menu, or provision after OSR is running:

```bash
ROUTER_CT_ID=250 CT_ID=281 \
TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.81/24 GATEWAY=192.0.2.1 \
DSH_MODEL=auto DSH_ACCESS_CIDR=192.0.2.0/24 \
bash targets/deepseek-harness/provision-lxc.sh --dry-run
```

Drop `--dry-run` to create the CT. Change the CT IDs, template, storage and
addresses to your environment. An interactive run prompts for missing required
values. `--dry-run` prints the plan without touching Proxmox. The script never
deletes an existing CT.

| Setting | Default | Meaning |
|---|---|---|
| `DSH_MODEL` | `auto` | OSR model ID or tier alias. A concrete tool-capable model is preferable for stable agent sessions. |
| `DSH_CONTEXT_WINDOW` | `32768` | Context the selected model serves; an exact model is checked against every reported host. 32768 or more with Honcho. |
| `DSH_MAX_TOKENS` | `8192` | Maximum response tokens; must be less than the context window. |
| `DSH_VERSION` | `0.2.1-rc.5` | An exact npm release, or `latest`. |
| `DSH_PORT` | `3080` | Harness Web UI port. |
| `DSH_ACCESS_CIDR` | the CT's network | Source range allowed through the CT's Proxmox firewall to the Web UI (a host address such as `192.0.2.81/24` is written as its network, `192.0.2.0/24`). |
| `DSH_ROUTER_FIREWALL` | `true` | Keep this CT's rule in the router CT's firewall file, when there is one. |
| `HONCHO_URL`, `HONCHO_CT_ID` | unset | Honcho memory (below). |
| `CORES`, `MEMORY_MB`, `ROOTFS_GB` | `2`, `4096`, `32` | CT sizing. Each release takes about 860 MB in `/opt/deepseek-harness/releases/`; an upgrade holds two for a moment. |

The OSR installer accepts the matching `DEEPSEEK_HARNESS_*` settings, including
`DEEPSEEK_HARNESS_MODEL`, `DEEPSEEK_HARNESS_CONTEXT_WINDOW`,
`DEEPSEEK_HARNESS_VERSION`, `DEEPSEEK_HARNESS_PORT` and
`DEEPSEEK_HARNESS_ACCESS_CIDR`. It prompts for model and context; its
`API_ALLOW_CIDR` becomes the Harness Web UI allow range when no Harness
specific value is supplied.

## Honcho memory

Hermes and OpenClaw use Honcho through their own native plugins, which record
every turn and inject what Honcho knows without the model doing anything.
Harness has no Honcho plugin. It connects to Honcho's MCP server instead
(`@deepseek-ai/dsh-mcp-client`, the route DeepSeek documents for third-party
memory), so the memory tools appear to the model as `mcp__honcho__*` and the
model decides when to call them:

- **Same memory.** Harness uses the shared `osr` workspace and the `user` peer,
  so what Hermes or OpenClaw learned about you is available to Harness and the
  other way round. Harness writes as its own peer, `deepseek-harness`.
- **Model-driven.** Honcho's own MCP instructions and a short managed block in
  Harness's user-global `AGENTS.md` (`/var/lib/deepseek-harness/home/AGENTS.md`,
  between `osr-honcho` markers; the rest of that file is yours) tell the model
  to look up the user's context, open a session and record each exchange. How
  reliably that happens depends on the model's tool use; a weak tool caller
  forgets to record, which the native plugins never do.
- **Cost.** Recording takes extra tool calls on every turn, and Honcho's tools
  add their definitions to every request: give Harness 32768 tokens or more.

With the OSR installer, select `honcho` together with `deepseek-harness`: Honcho
is created first, admits the Harness CT to its API and MCP ports, and Harness
gets `HONCHO_URL` and `HONCHO_CT_ID`. On an existing install:

```bash
# Admit Harness in the Honcho CT's firewall (list every agent's IP).
CT_ID=285 ROUTER_CT_ID=250 HONCHO_CLIENT_IPS='192.0.2.94 192.0.2.98 192.0.2.81' \
  bash targets/honcho/provision-lxc.sh --reconfigure
# Turn Honcho on for Harness; the osr workspace key is fetched from CT 285.
CT_ID=281 ROUTER_CT_ID=250 HONCHO_URL=http://192.0.2.85:8000 HONCHO_CT_ID=285 \
  bash targets/deepseek-harness/provision-lxc.sh --reconfigure
```

The provisioner derives the MCP endpoint, `http://<honcho-ip>:3000/mcp`, from
`HONCHO_URL` (set `HONCHO_MCP_URL` for another Honcho, with
`HONCHO_API_KEY_FILE` for its key). It refuses, before changing anything, when
the Honcho CT's firewall does not admit this CT, and prints the Honcho command
to run. The guest checks the key with an MCP `initialize` before it writes the
overlay. The key is only in `/etc/deepseek-harness/service.env` (root-only)
and the service's environment; the overlay reads it with a `!!js` expression
when it connects.

Later reconfigures keep Honcho on. `HONCHO_URL=` (set, empty) turns it off:
the MCP entry, the key and the `AGENTS.md` block are removed. After a Honcho
`--rotate-keys`, reconfigure Harness with `HONCHO_CT_ID` again.

To check it: in one Harness session, ask it to remember something unique and
watch for an `mcp__honcho__add_messages_to_session` or `create_conclusions`
call; in a new session, ask for it back. Hermes or OpenClaw should be able to
recall it too, once Honcho's deriver has processed the messages
(`journalctl -u honcho-deriver` in the Honcho CT).

## Use and recovery

The service binds to the CT's IPv4 address and answers browsers that use that
address (Harness rejects other host names unless they are added with
`--trusted-host`). It prints a tokenized login URL at every start; read the
newest one from the journal and open it from an address allowed by
`DSH_ACCESS_CIDR`:

```bash
pct exec 281 -- journalctl -u deepseek-harness.service -b --no-pager | grep 'dsh web:' | tail -n1
```

The Web UI is plain HTTP, so the token crosses your LAN unencrypted. The
workspace is `/var/lib/deepseek-harness/workspace` and the Harness profile home
is `/var/lib/deepseek-harness/home`. Tools run as `deepseek-harness` under
Harness's permission preset; the installed releases are owned by root, so the
agent cannot change its own code. The CT firewall restricts inbound Web UI
access. Outbound traffic is allowed for npm installs and agent tools, subject
to Harness's own permission policy.

**Models chosen in the Web UI.** Settings > Models edits the same plugin
entries (`llm-pi-ai`, `agent-default-model`) in the profile's own
`cordis.patch.yml`. This target's overlay is applied after that file and a
Cordis override replaces an entry's whole configuration, so expect such edits
not to stick. Change the provider's model with a reconfigure instead.

After a router key rotation, model change or package upgrade, rerun on the PVE
host with the **existing** Harness CT ID:

```bash
ROUTER_CT_ID=250 CT_ID=281 DSH_MODEL=code-model \
bash targets/deepseek-harness/provision-lxc.sh --reconfigure
```

A reconfigure refreshes the router key and guest files, then regenerates the
overlay and restarts the service. It only touches a CT with this target's
description and firewall rule, and keeps the other firewall rules. Settings it
is not given (`DSH_MODEL`, `DSH_CONTEXT_WINDOW`, `DSH_MAX_TOKENS`,
`DSH_VERSION`, `DSH_PORT`, Honcho) keep the values recorded by the CT's last
completed run in `/etc/deepseek-harness/settings`; the run says which it kept.
A recorded release is kept too: set `DSH_VERSION` to move to this target's pin.
A rerun that changes nothing (same settings, keys, release and target files,
service healthy) says so and does nothing.

### Upgrades and rollback

Each release is installed into its own directory,
`/opt/deepseek-harness/releases/<version>_<time>_<pid>`, next to the running
one, and `/opt/deepseek-harness/current` points at the one in use. An npm
failure therefore changes nothing. Before an installed CT is changed, the run
sets aside the overlay, service environment, settings record, keys, unit,
`AGENTS.md` and the Harness profiles (`home/profiles/`) in
`/var/lib/deepseek-harness-target/rollback/` (root-only). Then:

- If the router or Honcho check fails, or Harness rejects the new patch
  (`--dump-config` with the new release), the previous files are put back and
  the running service is never restarted.
- If the new release does not answer within 90 seconds after the restart, the
  previous release and files are put back, the service is restarted and
  health-checked, and the run says whether the previous release is running
  again.
- After success, the copies and the previous release are deleted.

Session logs are not part of the snapshot: a newer Harness may upgrade the
format of sessions it opened, which an older release then cannot read.

**When the rollback does not complete**, the snapshot stays and the next run
refuses to start, so it cannot overwrite the only copy. Inside the Harness CT,
check `systemctl status deepseek-harness` and its journal, then restore by
hand: in `/var/lib/deepseek-harness-target/rollback/`, `release` names the
previous release (point `/opt/deepseek-harness/current` at it), the
`file.<n>` copies go back to, in order, `/etc/deepseek-harness/osr.patch.yml`,
`service.env`, `settings`, `router-api-key`, `honcho-api-key`,
`/etc/systemd/system/deepseek-harness.service` and
`/var/lib/deepseek-harness/home/AGENTS.md` (an `absent.<n>` marker means that
file did not exist), and `profiles.tar` unpacks into
`/var/lib/deepseek-harness/home`. Run `systemctl daemon-reload` and restart the
service; once it is healthy, remove the rollback directory and reconfigure
again.

A failed first install leaves its CT and release for inspection; use
`--reconfigure` after correcting DNS, model or npm errors.

A CT created by the first version of this target (Harness installed directly
in `/opt/deepseek-harness`, no settings record) is moved to the release layout
by its first reconfigure; pass `DSH_MODEL` and the other settings that time,
since there is no record to keep them from.

## Local checks

`test-provision.sh` covers the provisioner's helpers and plans, the guest's
dry run and the unit, and runs `configure.test.mjs` (Node.js 20+).
`test-install.sh` runs the guest installer end to end against a fake router
and Honcho MCP server with stubbed apt, npm and systemd: fresh install,
unchanged rerun, reconfigure, both rollback paths, npm and patch failures,
`latest`, Honcho on and off, and the first layout. Neither needs root or a
Proxmox host.

```bash
bash tests/run-tests.sh deepseek-harness-provision
bash tests/run-tests.sh deepseek-harness-install
```
