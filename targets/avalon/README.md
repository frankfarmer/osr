# Avalon (Qwen3.8-Flash-Next) inference target for Proxmox VE 9

On an interactive Proxmox run, `provision-lxc.sh` asks for an unused CT ID,
the CT IP/CIDR (or `dhcp`), and a gateway for a static IP. It lists downloaded
compatible templates and active `rootdir` storage with enough free space for
`ROOTFS_GB`. Preset `CT_ID`, `IP_CIDR`, `GATEWAY`, `TEMPLATE`, and `STORAGE`
to skip the corresponding prompts. No CT ID or IP is selected automatically.
Dry runs make no Proxmox queries, so supply template and storage explicitly.

[Avalon](https://github.com/freriadoc/Avalon) is a fork of
[llama.cpp](https://github.com/ggml-org/llama.cpp) built for one model,
[Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) (125B MoE,
512 experts, 10 active), on **one consumer GPU with the experts in system
RAM**. The GPU holds the dense weights, the KV cache and a cache of the
hottest experts; the CPU computes the experts that miss it (AVX2 kernels), and
an MTP draft head speeds up generation. Upstream measures 91 tok/s on an
AMD RX 7900 XT (20 GB, ROCm) with 64 GB of DDR4, and 120 tok/s on one RTX 4090
(CUDA, measured once).

It serves the same model family as the [Strata](../strata/README.md) and
[Basalt](../basalt/README.md) targets, but on AMD Radeon cards as well as
NVIDIA ones, from its own IQ3_KS hybrid quant (about 90 GiB). `provision-lxc.sh`
creates an unprivileged LXC on the GPU node and runs `install-target.sh` in
it, which:

- installs the GPU toolkit, user space only: **ROCm 7.2.4** from AMD's
  repository (`rocm-toolkit.sh`, the release upstream tests) for an AMD card,
  or a **CUDA** toolkit (12.9 by default, `cuda-toolkit.sh`) for an NVIDIA one;
- fetches Avalon at the tested commit and builds `llama-server` as upstream's
  README does (`-DGGML_HIP=ON -DAMDGPU_TARGETS=<gfx>` with ROCm's `amdclang`,
  or `-DGGML_CUDA=ON` for the card's compute capability), without the web UI;
- downloads the pinned
  [Qwen3.8-Flash-Next-Avalon-GGUF](https://huggingface.co/freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF)
  files: the 33 shards of the model, its MTP draft head and the expert ranking
  that prefills the GPU cache (`avalon-weights.txt`);
- serves it with upstream's launcher settings (q8_0/q4_0 KV cache, MTP with
  2 draft tokens, `--parallel 1`) and a 64k context by default as a hardened systemd
  service under its own `avalon` account, with a generated API key.

The router recognizes the target as `avalon://<CT address>` (port 8080), and
sizes its model id `qwen3.8-flash-next-avalon` as 125B.

## Requirements

- **GPU, AMD (the default and upstream's reference):** a Radeon RX 7000 or
  Radeon PRO W7000 card, RDNA 3 (`gfx1100`: RX 7900 XTX/XT/GRE, `gfx1101`:
  RX 7800/7700, `gfx1102`: RX 7600). Avalon's HIP kernels target RDNA 3 only:
  RDNA 4 (RX 9000) and older cards are refused. Upstream measured only
  `gfx1100`; the others should work. The host runs the in-kernel `amdgpu`
  driver; the CT gets `/dev/kfd` and the card's render node.
- **GPU, NVIDIA:** compute capability 7.5 or newer. Upstream measured an
  RTX 4090 once; its kernels are tuned for RDNA 3, not NVIDIA, yet.
- **VRAM:** 16 GB or more. The context is 64k tokens by default;
  `AVALON_CONTEXT=auto` gives upstream's full 256k with 19 GB or more and 64k
  below that, as upstream suggests.
- **CPU:** AVX2 (any recent x86 CPU; the experts that miss the GPU are
  computed with it). The CT gets 8 cores by default.
- **RAM:** the ~90 GiB model is memory-mapped, so what does not fit is read
  from the disk again. Upstream measured 32 GB (generation 2-6% slower than
  with 64 GB, a new 19k prompt's prefill about 30% slower); the CT gets 64 GiB
  by default and needs at least 32 GiB (`MEMORY_MB`).
- **Disk:** the root disk defaults to 160 GiB (at least 130): the weights, ROCm
  (about 8 GB) or the CUDA toolkit, the build and its rollback snapshot. Put
  it on NVMe when the CT has less RAM than the model.
- **Templates:** Ubuntu 24.04 (default) or 22.04 amd64. AMD supports ROCm on
  Radeon cards only on Ubuntu (and RHEL), and its 7.2.4 repository has noble
  and jammy only. With `AVALON_BACKEND=cuda` the provisioner also accepts
  Debian 12/13 and Ubuntu 26.04 (set `AVALON_CUDA_VERSION=13.1` or `13.3` there).
- **Host:** Proxmox VE 9. For NVIDIA, a loaded driver (CUDA 12.9 needs the 570
  series or newer; the repository's driver is 580). A host without a GPU driver
  gets one from `tools/setup-host-gpu.sh`, which the router installer runs for
  every selected GPU target.

The first install downloads about 90 GiB (hours on a slow connection) and then
loads the model; plan for both.

## Create and launch

From this repository's root on the Proxmox GPU host:

```bash
CT_ID=283 \
TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.83/24 GATEWAY=192.0.2.1 \
bash targets/avalon/provision-lxc.sh --dry-run

CT_ID=283 \
TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.83/24 GATEWAY=192.0.2.1 \
bash targets/avalon/provision-lxc.sh
```

`AVALON_BACKEND=auto` takes the backend from `GPU_DEVICES` when it is given
(`/dev/kfd /dev/dri/renderD<n>` is ROCm, `/dev/nvidia*` is CUDA), else ROCm
when the host has one RDNA 3 card on `amdgpu` (its render node is used), else
CUDA when an NVIDIA driver lists a GPU (`/dev/nvidia0`). With several RDNA 3
cards, set `GPU_DEVICES` for the one Avalon uses. The router installer asks
which card Avalon gets and passes `AVALON_BACKEND` and `GPU_DEVICES` itself.

The script refuses an existing CT ID and keeps a newly created CT for
inspection if a later step fails. An interrupted download resumes where it
stopped when the installer runs again (see [Upgrade](#upgrade)).

Settings (environment variables of either script):

| Setting | Default | |
|---|---|---|
| `AVALON_REF` / `AVALON_COMMIT` | tested commit in `upstream-commit.txt` | set a branch or another full commit to override it (see below) |
| `AVALON_BACKEND` | `auto` | `rocm` (AMD) or `cuda` (NVIDIA) |
| `AVALON_ROCM_VERSION` | `7.2.4` | the ROCm release (7.x; upstream tests 7.2.4) |
| `AVALON_GPU_TARGET` | `auto` | `gfx1100`, `gfx1101` or `gfx1102`; `auto` reads the card's PCI ID |
| `AVALON_CUDA_VERSION` | `12.9` | the CUDA toolkit (12.4 or newer; RTX 50 needs 12.8 or newer) |
| `AVALON_CUDA_ARCH` | `auto` | the compute capability as a number (`86`, `89`, `120`); `auto` reads GPU 0 |
| `AVALON_PORT` | `8080` | the API port |
| `AVALON_CONTEXT` | `65536` | the context (`-c`), 4096-262144; `auto` is 262144 with 19 GB of VRAM or more, else 65536 |
| `AVALON_MTP` | `true` | MTP speculative decoding with the 1.4 GB draft head; `false` skips its download |
| `AVALON_MODEL_NAME` | `qwen3.8-flash-next-avalon` | the model id the API lists (`--alias`) |
| `AVALON_READY_TIMEOUT` | `1800` | seconds to wait for the model to load |

Host-side settings (`CORES=8`, `MEMORY_MB=65536`, `ROOTFS_GB=160`,
`GPU_DEVICES`, `GPU_GID=44`, `BRIDGE`, `VLAN_TAG`, `NAMESERVER`,
`SSH_PUBLIC_KEY`, ...) work as for the other GPU targets; `--help` lists them.

## Connect the router

```bash
pct exec 283 -- cat /etc/avalon-target/api-key
manage-model-servers set-avalon-token --apply
manage-model-servers add avalon://192.0.2.83 --tier xlarge --apply
```

`set-avalon-token` prompts for the key. Avalon serves llama.cpp's API:
`/health` is public and says only `{"status":"ok"}`, so the manager identifies
the server from `/v1/models` (`"owned_by": "llamacpp"` and an id containing
`avalon`), which needs the key once it is set. Adding it as `avalon://...`
always works. The router, monitor and LiteLLM use the key from `secrets.env`.
The router sizes the default id as 125B (`[model_sizes]` in `router.ini`; add a
line there if you set another `AVALON_MODEL_NAME`).

Logs: `pct exec 283 -- journalctl -u avalon -f`. The CT's Proxmox firewall flag
is enabled; configure the host's actual firewall rules so only the router and
intended clients reach the API port.

## Where things are

| Path | |
|---|---|
| `/opt/avalon` | the checkout and `build/bin/llama-server` (read-only for the service) |
| `/opt/rocm-7.2.4` | ROCm (AMD), from `repo.radeon.com`, pinned to that release |
| `/var/lib/avalon/models` | the 33 shards, `MTP/` (the draft head) and `moe-cache-ranking.bin` |
| `/etc/avalon/api-key` | the server's copy of the key (root-owned, readable by the `avalon` group only) |
| `/etc/avalon-target/` | root-only records: the key, settings, verified weights; `avalon.env` (llama-server's arguments, no key) |

The key reaches llama-server through `--api-key-file`; it is never on a
command line, in the unit or in its environment file.

## Weights

`avalon-weights.txt` lists every file with its size and SHA-256 at one pinned
revision of the Hugging Face repository
(`372fe3a4e572c5ba75a90e579de0695633d083a8`), so a URL always names the same
object:

- Before downloading, the installer asks Hugging Face for each missing file's
  size and SHA-256 and refuses one that differs from the list, then checks the
  free disk space against what is missing.
- Each file is downloaded beside its place, verified, and moved in.
  Interrupted downloads resume on the next run; a corrupt file is deleted.
- Verified files are recorded (`/etc/avalon-target/verified-weights`), so a
  rerun neither hashes ~90 GiB again nor needs the network for them.

To move to a newer upload, review it and replace the rows (and the revision in
each URL) in `avalon-weights.txt`. Files of the old upload stay on disk until
you delete them.

## Avalon versions

Avalon changes many times a day. By default every run fetches the tested
commit in `upstream-commit.txt` (currently
`7fc482745eabd54b7a779ed54296c8a2d253c76f`), the commit
`test-pinned-upstream.py` and CI's `avalon-upstream` job check. Set
`AVALON_REF=main` on each run to follow the branch tip or `AVALON_COMMIT` to
use another full commit. The installer checks the checkout for the files,
CMake options and llama-server flags it uses before building, and a failed
upgrade rolls back.

Move `upstream-commit.txt` deliberately, after that check passes against the
new commit (see [Local checks](#local-checks)). The commit is not part of the
saved settings, so the next rerun of an existing install moves to the new pin.

## Upgrade

Every rerun of the installer, with or without `--upgrade`, keeps the
installation's settings from `/etc/avalon-target/installed-env`. Non-empty
environment settings override the corresponding saved values; a new
`AVALON_CUDA_VERSION` without `AVALON_NVCC` takes that release's default nvcc,
and a new `AVALON_BACKEND` detects its GPU target again and sets the context to `auto` unless `AVALON_CONTEXT` is given. Only a
fresh install uses the defaults. A fresh install records the settings it runs
with in `/etc/avalon-target/pending-env` before its first change, so an install
that stops part-way resumes with them. An existing checkout or unit with no
readable record requires every setting explicitly.

Copy the current files into the CT, then rerun:

```bash
for f in install-target.sh rocm-toolkit.sh cuda-toolkit.sh avalon.service avalon-weights.txt upstream-commit.txt; do
    pct push 283 targets/avalon/$f /root/avalon-target-deploy/$f
done
pct exec 283 -- bash /root/avalon-target-deploy/install-target.sh --upgrade
```

A rerun fetches the selected commit and verifies (or finishes downloading) the
weights **while the service keeps running**; if either fails, nothing is
stopped or changed. When the commit, settings, unit and weights are unchanged
and the server answers, it does nothing. Otherwise it stops the service and
snapshots the runnable checkout (with its build), the unit, its environment
and the key file into the root-only `/var/lib/avalon-target/`; then it checks
out the commit, rebuilds `llama-server` and restarts. If any step fails, it
restores the previous commit and that snapshot at their original paths,
without building or downloading anything, and health-checks the previous
service. The snapshot is deleted after a successful upgrade or rollback and
kept only when the rollback fails too.
When the rollback fails too, a `rollback-failed` file is left in `/var/lib/avalon-target/`
and every later run stops there, changing nothing, so the last good runtime is
not overwritten: inspect or restore the snapshot, then delete that file and rerun.

ROCm releases replace each other in place (one repository per release), so a
new `AVALON_ROCM_VERSION` cannot be rolled back to the old one by the snapshot;
change it on its own, not together with a new commit.

## Local checks

```bash
bash targets/avalon/test-install.sh         # helpers, plus stubbed end-to-end runs as root
bash targets/avalon/test-provision.sh       # dry-run plans, validation, host GPU detection
bash targets/avalon/test-rocm-toolkit.sh    # the ROCm repository table and key check
bash targets/avalon/test-cuda-toolkit.sh    # the CUDA repository table
git init /tmp/avalon-source-check
git -C /tmp/avalon-source-check fetch --depth 1 \
    https://github.com/freriadoc/Avalon.git "$(cat targets/avalon/upstream-commit.txt)"
git -C /tmp/avalon-source-check checkout -q FETCH_HEAD
python3 targets/avalon/test-pinned-upstream.py /tmp/avalon-source-check
```

`tests/run-tests.sh` runs the first four. `test-pinned-upstream.py` needs the
network and runs as CI's separate `avalon-upstream` job: it checks the pinned
checkout with the installer's own `validate_checkout`, compares the arguments
the unit passes with upstream's `avalon-server` launcher, and checks the API
behaviour the readiness probe, the router and the manager rely on. None of
these build Avalon, download the model or need a GPU.

## Not tested

Nothing here has run on real hardware: ROCm 7.2.4 user space in an
unprivileged CT on the PVE kernel's `amdgpu` (with only `/dev/kfd` and one
render node), the HIP and CUDA builds of the pinned commit, the load time
against `AVALON_READY_TIMEOUT`, and Avalon's expert cache under the CT's
`lxc.prlimit.memlock: unlimited`.
