# Kindi (Ternary-Bonsai-2 on small and old GPUs) inference target for Proxmox VE 9

On an interactive Proxmox run, `provision-lxc.sh` asks for an unused CT ID,
the CT IP/CIDR (or `dhcp`), and a gateway for a static IP. It lists downloaded
compatible templates and active `rootdir` storage with enough free space for
`ROOTFS_GB`. Preset `CT_ID`, `IP_CIDR`, `GATEWAY`, `TEMPLATE`, and `STORAGE`
to skip the corresponding prompts. No CT ID or IP is selected automatically.
Dry runs make no Proxmox queries, so supply template and storage explicitly.

[Kindi](https://github.com/ahtx/kindi) (Amir Husain, AGPL-3.0) is an inference
engine for Prism ML's ternary
[Ternary-Bonsai-2](https://huggingface.co/prism-ml) models (2B, 4B, 9B and 27B)
and for AH-Nanbeige4.3-33B, on **cheap and old NVIDIA cards**: it started on a
1 GB Quadro K420 (Kepler, 2014), and Kindi 0.4.0 runs from there to the RTX 50
series, or on the CPU. Its greedy output is token for token llama.cpp's for the
same model file, several times as fast on the small cards (upstream: 20.8
against 1.65 tokens/s for the 2B on a K420; 63 tokens/s for the 27B on an RTX
3080, up to 1.8 times that with the 2B as a draft model). Every Kindi server
speaks the OpenAI API with tool calls, so the router and its agents can use a
spare old card as a fast-tier host.

`provision-lxc.sh` creates an unprivileged LXC, passes one NVIDIA card through
(or none) and runs `install-target.sh` in it, which installs Kindi natively,
as its `docker/Dockerfile` builds its image:

- the **CUDA 10.2** toolkit, user space only (`cuda-toolkit.sh`): NVIDIA's
  runfile with `--toolkit`, checked against its published MD5. CUDA 10.2 is the
  last toolkit for Kepler and the one CuPy 9.6 is built for; no NVIDIA apt
  repository carries it for a current distro;
- a standalone **Python 3.9** (CuPy 9.6 supports 3.6 to 3.9) and Kindi's venv,
  both through a pinned uv, from hash locks of Kindi's own pins
  (`requirements-cuda.lock`, or `requirements-cpu.lock` without CuPy);
- Kindi itself at the tested commit;
- the pinned GGUF of the model the card holds (`kindi-weights.txt`), which
  `kindi convert` turns into Kindi's pack, and `kindi verify`, which checks the
  output against llama.cpp's reference before anything is served;
- a hardened systemd service under its own `kindi` account, with Kindi's own
  engine settings for the card (`kindi.env`) and a generated API key in its
  config file.

The router recognizes the target as `kindi://<CT address>` (port 8093) and
sizes its model ids (`bonsai2-2b` ... `bonsai2-27b`, `nanbeige-33b-iq3`) from
the size in the id. Kindi lists its fitted context as `context_length`, which
Hermes and OpenClaw read.

## Requirements

- **GPU:** an NVIDIA card of compute capability 3.0 (Kepler) or newer, one per
  CT. Upstream tested the Quadro K420 (1 and 2 GB), K1200, K6000, Tesla P100,
  GTX 1080 and RTX 3080; the RTX 20 to 50 series pass `kindi verify`.
- **Host driver:** whatever the host runs, at least 440.33 (CUDA 10.2's
  minimum). **Kepler cards need the NVIDIA 470 driver**, the last branch with
  Kepler support; Maxwell, Pascal and Volta cards need branch 580 or older and
  the proprietary kernel modules. `tools/setup-host-gpu.sh` installs the 580
  open modules, which only Turing (RTX 20) and newer use, so for an older card
  install the host driver yourself first (for Maxwell to Volta:
  `KERNEL_MODULE_TYPE=proprietary bash tools/install-nvidia-driver.sh host`).
  The CT then gets the matching user space through `targets/nvidia-lxc.sh`.
- **No GPU:** `KINDI_BACKEND=cpu` (also `auto` on a host without an NVIDIA
  driver) runs Kindi's CPU engine, the 2B, 4B or 9B; the CPU needs AVX2.
- **RAM:** 4 GB for the 2B and 4B, 6 GB for the 9B, 10 GB for Nanbeige and
  about 14 GB for the 27B's first start; the CT gets 16 GiB by default.
- **Disk:** about 3 GB for CUDA 10.2 (and 2.6 GB for its runfile while it
  installs), 1 GB for the venv, the model and its pack (0.9 GB for the 2B, 12
  GB for the 27B plus 5.6 GB of 5-trit weights on Pascal and newer, 13 GB for
  Nanbeige) and one rollback snapshot of the checkout and venv. The CT gets
  64 GiB by default.
- **Templates:** Debian 12/13 or Ubuntu 22.04/24.04 (the CUDA 10.2 runfile's
  installer needs their `libxml2.so.2`).

## Models and profiles

`KINDI_MODEL=auto` and `KINDI_PROFILE=auto` read GPU 0 in the CT with
`nvidia-smi` and pick what Kindi's own installer picks for one server on its
own card (`install.sh`, `card_class`, `card_models` and `profile_of`; CI checks
they still match):

| Profile | Card | Model (auto) | Context (auto) | Engine settings |
|---|---|---|---|---|
| `tc` | compute capability 8.0+, 9.5 GB+ (RTX 30 and newer) | 27B, with the 2B as draft model | 131072 | tensor cores, flash-decode, speculative decoding (`KINDI_SPEC=auto`) |
| `pascal8` | 6.1+, 7.5 GB+ (GTX 1080, RTX 20, an 8 GB RTX 30) | 27B | 65536 | one-card engine, blocking sync off |
| `p100` | 6.0, 12 GB+ (Tesla P100) | 27B | 65536 | as `pascal8` |
| `kepler` | below 5.0 (Quadro K, Tesla K, GTX 600/700) | 27B from 11 GB, 9B from 3.8 GB, 4B from 1.9 GB, else 2B | 24576, or 65536 from 1.5 GB (23808 for the 4B on a 2 GB card) | blocking sync off |
| `maxwell` | the rest (Maxwell, small Pascal and Turing cards) | 9B from 3.8 GB, 4B from 1.9 GB, else 2B | 24576 | blocking sync off |
| `nanbeige` | 8.0+ or a P100, 16.2 GB+ | `nanbeige-33b` only when asked for | 16384 | `KINDI_MAX_TOKENS=16384` |
| `cpu` | no GPU | 2B (4B and 9B when asked for) | 24576 | `KINDI_DEVICE=cpu`, the CT's cores |

The engine fits the context to the free card memory and reports what it got
(`/health`, `/v1/models`); the installer prints it when it differs. The 470
driver does not report the compute capability, so a Kepler card is recognized by
its name; for another card without one, set `KINDI_PROFILE`.

## Create and launch

From this repository's root on the Proxmox host:

```bash
CT_ID=284 \
TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.84/24 GATEWAY=192.0.2.1 \
GPU_DEVICES='/dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm' \
bash targets/kindi/provision-lxc.sh --dry-run
```

Drop `--dry-run` to create it. `KINDI_BACKEND=auto` takes CUDA when
`GPU_DEVICES` names an NVIDIA node or the host's driver lists a GPU (then GPU 0,
`/dev/nvidia0`), else the CPU engine. On a host with several cards, give the
old card's `/dev/nvidia<minor>` in `GPU_DEVICES` (`nvidia-smi
--query-gpu=index,pci.bus_id` and `/proc/driver/nvidia/gpus/<bus id>/information`
show it). The router installer asks which card Kindi gets, or `none` for the
CPU, and passes `KINDI_BACKEND` and `GPU_DEVICES` itself.

The script refuses an existing CT ID and keeps a newly created CT for
inspection if a later step fails. An interrupted download resumes where it
stopped when the installer runs again (see [Upgrade](#upgrade)).

Settings (environment variables of either script):

| Setting | Default | |
|---|---|---|
| `KINDI_REF` / `KINDI_COMMIT` | tested commit in `upstream-commit.txt` | set a branch or another full commit to override it |
| `KINDI_BACKEND` | `auto` | `cuda` or `cpu` |
| `KINDI_MODEL` | `auto` | `bonsai-2b`, `bonsai-4b`, `bonsai-9b`, `bonsai-27b` or `nanbeige-33b` |
| `KINDI_PROFILE` | `auto` | one of the profiles above |
| `KINDI_PORT` | `8093` | the API port (Kindi's own default) |
| `KINDI_CONTEXT` | `auto` | the context asked for, 1024-262144; the engine fits it to the free memory |
| `KINDI_HEAD` | `exact` | `fast`: the shortlist output head (about 15% faster, picks the same token 99.4% of the time; `kindi fast-head` builds it, about 2 minutes) |
| `KINDI_SPEC` | `auto` | the 27B on a `tc` card drafts with the 2B (also downloaded); `off` |
| `KINDI_THREADS` | `auto` | the CPU engine's threads (the CT's cores) |
| `KINDI_MODEL_NAME` | `auto` | the model id the API lists (`bonsai2-<size>`, `nanbeige-33b-iq3`) |
| `KINDI_VERIFY` | `true` | run `kindi verify` before the server is (re)started |
| `KINDI_PYTHON_VERSION` | `3.9.25` | the standalone Python of the venv (3.9.x) |
| `KINDI_READY_TIMEOUT` | `1800` | seconds to wait for `/health` (the first start compiles the kernels, and the 27B on Pascal and newer writes its 5-trit weights, up to 15 minutes) |

Host-side settings (`CORES=4`, `MEMORY_MB=16384`, `ROOTFS_GB=64`,
`GPU_DEVICES`, `GPU_GID=44`, `BRIDGE`, `VLAN_TAG`, `NAMESERVER`,
`SSH_PUBLIC_KEY`, ...) work as for the other GPU targets; `--help` lists them.

## Connect the router

```bash
pct exec 284 -- cat /etc/kindi-target/api-key
manage-model-servers set-kindi-token --apply
manage-model-servers add kindi://192.0.2.84 --tier fast --apply
```

`set-kindi-token` prompts for the key. Kindi's `/health` is public and names
it (`"kindi": "<version>"`), so `manage-model-servers add 192.0.2.84:8093`
identifies it without a key too. The router, monitor and LiteLLM use the key
from `secrets.env`; Hermes, OpenClaw and Honcho's dispatchers read it from
there when they are installed or reconfigured. Kindi serves one request at a
time and reads prompts slowly on the small cards (about 30 tokens/s on a K420),
so give it a tier whose requests are short, and leave its context to Hermes and
OpenClaw only where it is large enough (Hermes needs 64000 tokens).
Kindi's own guide asks clients for a 30 to 60 minute timeout and one retry at
most, because a retry waits behind the request Kindi is still reading. OSR
follows it:

- The router waits up to `kindi_read_timeout_seconds` (router.ini, default
  3600) between bytes from an assigned Kindi server, including the LiteLLM
  hop. Reconfiguring Hermes, OpenClaw or Honcho reads that limit from the
  router and gives their direct dispatchers the same idle-read budget. The
  router publishes it in `/routing/inventory`. After an edit, a dispatcher
  takes a lower budget at once. A higher one waits for that CT's
  `provision-lxc.sh --reconfigure`, because its callers' limits were sized for
  the old one; the dispatcher logs that, and `manage-model-servers apply` says
  so when it applies the change.
- LiteLLM gives each Kindi deployment that timeout. Regenerating the model
  list writes it, and `manage-model-servers apply` brings it in line after an
  edit to `router.ini`. Kindi tiers have no retry after a timeout and one after
  a 429. LiteLLM 1.75 does not read `InternalServerErrorRetries`, so the router
  also sends `x-litellm-num-retries: 1` for those tiers, which caps every other
  error at one retry. Other tiers keep their retry settings. A tier with Kindi
  is a fallback only for another Kindi tier on other Kindi servers: a request
  for a tier without Kindi gets the router's 300 seconds, and a fallback to the
  same Kindi server would queue behind the request it is still reading.
- The callers wait longer than the dispatcher, so the dispatcher reports a
  silent Kindi first. Honcho's model client, which limits each read, waits
  twice the Kindi budget. Hermes's stream read and stale limits and its Kindi
  providers' request and stale limits, and OpenClaw's `timeoutSeconds` for
  Kindi providers and `osr`, also bound the whole reply: they allow twice the
  budget plus a reply at one token a second (8192 tokens for Hermes,
  `OPENCLAW_MAX_TOKENS` for OpenClaw). Open WebUI sets no timeout by default.
- A request Kindi accepted but did not answer within the budget is not replayed
  by the router or direct dispatcher, since a retry would queue behind it. A
  streamed request rarely gets there: Kindi sends an SSE keep-alive every 15
  seconds while it reads.
  - The router and the dispatchers of Hermes, OpenClaw and Honcho answer such a
    request with HTTP 424, `x-should-retry: false` and error type
    `upstream_no_reply`, after any other candidate has failed too. The OpenAI
    SDKs do not retry it. Honcho treats it as final. Hermes classifies an
    unlisted 4xx as non-retryable for that provider, but can use a configured
    fallback provider. Both Hermes and OpenClaw route their named providers
    through the same local dispatcher as their `osr` provider: a fallback to
    the same Kindi receives 503 while `/health` still reports busy. OpenClaw's
    current classifier has no 424 status rule, so the message also avoids the
    words its message rules read as a timeout.
  - For a non-streaming reply, the router and direct dispatchers read the
    whole body before sending 200, including on the router's LiteLLM hop for
    a Kindi tier. A later body timeout can therefore still return 424. For a
    streaming direct reply, they wait for the first chunk; a stall after that
    chunk closes the stream and gates Kindi until it reports idle.
  - On the LiteLLM path, a tier with Kindi gets the same 424 for LiteLLM's own
    timeout (408) or a hop that got no reply.
  - A failed connection stays a retryable 502: nothing reached Kindi.
  - On direct paths, having hung up, the router or dispatcher sends Kindi
    nothing more until its `/health` shows no request in progress (Kindi stops
    an abandoned one at its next prompt batch or token). A failed health probe
    keeps it gated until a later probe confirms idle. A newer busy request does
    not release the gate because the abandoned request could still be queued.
    Continuous traffic from other clients can keep the gate closed until a
    probe catches Kindi idle. Meanwhile callers get a retryable 503 with
    `Retry-After: 15`.

Logs: `pct exec 284 -- journalctl -u kindi -f`. The CT's Proxmox firewall flag
is enabled; configure the host's actual firewall rules so only the router and
intended clients reach the API port.

## Where things are

| Path | |
|---|---|
| `/opt/kindi` | the checkout and its `.venv` (read-only for the service) |
| `/opt/kindi-runtime` | the pinned uv and the standalone Pythons it installed |
| `/usr/local/cuda-10.2` | the CUDA 10.2 toolkit (CUDA only) |
| `/var/lib/kindi/models` | the GGUF files |
| `/var/lib/kindi/packs/<model>-f<format>` | Kindi's packs, one per pack format (a rollback keeps the old one) |
| `/var/lib/kindi/state` | the kernel caches, saved prompt openings and the head mode |
| `/etc/kindi/kindi.conf` | the server config with the key (root-owned, readable by the `kindi` group only) |
| `/etc/kindi-target/` | root-only records: the key, settings, verified weights; `kindi.env` (engine settings, no key) |

The key is in the config file Kindi reads (`KINDI_CONFIG`); it is never on a
command line, in the unit or in its environment file. Kindi's other commands
run as the service: `pct exec 284 -- runuser -u kindi -- env
PYTHONPATH=/opt/kindi KINDI_CONFIG=/etc/kindi/kindi.conf /opt/kindi/.venv/bin/python
-m kindi info` (or `head fast`, `bench` with the service stopped).

## Weights

`kindi-weights.txt` lists each model's GGUF with its size and SHA-256 at one
pinned commit of its Hugging Face repository; the values are Kindi's own
catalog's (`kindi/catalog.py`), and CI checks they still are.

- Before downloading, the installer asks Hugging Face for each missing file's
  size and SHA-256 and refuses one that differs from the list, then checks the
  free disk space against what is missing (twice that, for the pack).
- Each file is downloaded beside its place, verified, and moved in.
  Interrupted downloads resume on the next run; a corrupt file is deleted.
- Verified files are recorded (`/etc/kindi-target/verified-weights`), so a
  rerun neither hashes them again nor needs the network for them.

Packs of a model that is no longer used, and of an older pack format, stay on
disk until you delete them.

## Kindi versions

By default every run fetches the tested commit in `upstream-commit.txt`
(currently `917ae685b2c54af17787a92cae1132cab8dcd1ce`, Kindi 0.4.0), the
commit `test-pinned-upstream.py` and CI's `kindi-upstream` job check. Set
`KINDI_REF=main` to follow the branch or `KINDI_COMMIT` for another full
commit. The installer checks the checkout for the files, config keys,
commands, engine settings and Dockerfile pins it relies on before it builds
anything, and every upgrade runs `kindi verify`; a failed upgrade rolls back.

Move `upstream-commit.txt` deliberately, after that check passes against the
new commit (see [Local checks](#local-checks)). If upstream moves its pins in
`docker/Dockerfile`, recompile the locks from `requirements-*.in` as their
headers say.

Kindi is AGPL-3.0 (its author also sells commercial licenses). The AGPL's
network clause is about changed copies: one served to users must offer them its
source. This target serves the upstream code unchanged.

## Upgrade

Every rerun of the installer, with or without `--upgrade`, keeps the
installation's settings from `/etc/kindi-target/installed-env`. Non-empty
environment settings override the corresponding saved values; a new
`KINDI_MODEL` or `KINDI_BACKEND` sizes the profile, context and model id for the
card again unless they are given. Only a fresh install uses the defaults. A
fresh install records the settings it runs with in
`/etc/kindi-target/pending-env` before its first change, so an install that
stops part-way resumes with them. An existing checkout or unit with no readable
record requires every setting explicitly.

Copy the current files into the CT, then rerun:

```bash
for f in install-target.sh cuda-toolkit.sh kindi.service kindi-weights.txt upstream-commit.txt \
         requirements-cpu.lock requirements-cuda.lock uv.lock; do
    pct push 284 targets/kindi/$f /root/kindi-target-deploy/$f
done
pct exec 284 -- bash /root/kindi-target-deploy/install-target.sh --upgrade
```

A rerun fetches the selected commit and verifies (or finishes downloading) the
model files **while the service keeps running**; if either fails, nothing is
stopped or changed. When the commit, settings, unit and files are unchanged
and the server answers, it does nothing. Otherwise it stops the service and
snapshots the runnable checkout (with its venv), the unit, its environment and
the config file into the root-only `/var/lib/kindi-target/`; then it checks out
the commit, rebuilds the venv, converts a model when its GGUF or pack format
changed, runs `kindi verify` and restarts. A replaced pack is moved into that
snapshot before the new pack takes its place. If any step fails, it restores
the previous commit, runtime and replaced packs without building or downloading
anything, then health-checks the previous service. The snapshot is
deleted after a successful upgrade or rollback and kept only when the rollback
fails too. When the rollback fails too, a `rollback-failed` file is left in
`/var/lib/kindi-target/` and every later run stops there, changing nothing, so
the last good runtime is not overwritten: inspect or restore the snapshot, then
delete that file and rerun. A pack still in `rollback-packs/` there belongs in
`/var/lib/kindi/packs/` (or can be deleted); the next upgrade waits until that
directory is empty.

## Local checks

```bash
bash targets/kindi/test-install.sh         # helpers, plus stubbed end-to-end runs as root
bash targets/kindi/test-provision.sh       # dry-run plans and validation
bash targets/kindi/test-cuda-toolkit.sh    # the distro table and the runfile's checksum and flags
git init /tmp/kindi-source-check
git -C /tmp/kindi-source-check fetch --depth 1 \
    https://github.com/ahtx/kindi.git "$(cat targets/kindi/upstream-commit.txt)"
git -C /tmp/kindi-source-check checkout -q FETCH_HEAD
python3 targets/kindi/test-pinned-upstream.py /tmp/kindi-source-check
```

`tests/run-tests.sh` runs the first three. `test-pinned-upstream.py` needs the
network and runs as CI's separate `kindi-upstream` job: it checks the pinned
checkout with the installer's own `validate_checkout`, loads the config file
the target writes with Kindi's own loader, checks every engine setting of the
unit's environment, the weights against Kindi's catalog, the venv pins against
its Dockerfile, the profiles against its `install.sh`, and the API behaviour the
readiness probe, the router and the manager rely on. None of these download a
model or need a GPU.

## Not tested

Nothing here has run on real hardware: the CUDA 10.2 runfile in an
unprivileged CT on Debian 13 and Ubuntu 24.04, CuPy 9.6 against the 470 and
580 drivers' user space installed by `nvidia-lxc.sh` (and that helper's `lxc`
mode with a 470 runfile), the Kepler name fallback, `kindi verify` and the
27B's first start against `KINDI_READY_TIMEOUT`, and a Proxmox 9 host running
the 470 driver at all (its kernel module has to build for the PVE kernel).
