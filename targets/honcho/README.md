# Honcho AI memory target

[Honcho](https://github.com/plastic-labs/honcho) stores conversations and
derives persistent peer memory. This CPU-only target creates a separate
unprivileged Debian 13 LXC with PostgreSQL/pgvector, the Honcho API and
deriver, and the upstream HTTP MCP server. No GPU is passed through. The
Proxmox firewall allows the router to reach API port 8000 and MCP port 3000;
selected Hermes and OpenClaw CTs can reach the API. Other inbound traffic is
blocked. Honcho uses JWT authentication with two keys in its CT:
`/etc/honcho-target/api-key` is the admin key and never leaves the CT;
`/etc/honcho-target/client-api-key` is scoped to the shared `osr` workspace
and is the only key Open WebUI, Hermes and OpenClaw receive.

The router supplies Honcho's chat model via its OpenAI-compatible `/v1`
endpoint. `HONCHO_MODEL=fast` is the default; it must resolve to a model with
tool calling (the dialectic and dreams call tools) and structured output (the
deriver asks for JSON-schema output). Before changing anything, the install
sends the router one chat request with a tool and a JSON schema; it stops if
the router refuses it or reports that no tool-capable model serves it. If the
model's backend only has JSON mode, set `HONCHO_STRUCTURED_OUTPUT_MODE=json_object`
(upstream's fallback, set for every model config and probed the same way).
`HONCHO_SKIP_CHAT_PROBE=true` skips the probe. Honcho also needs embeddings for
memory writes. Set
`HONCHO_EMBEDDING_MODEL` and `HONCHO_EMBEDDING_DIMENSIONS` to a reachable
OpenAI-compatible embedding model and its vector size. Set
`HONCHO_EMBEDDING_BASE_URL` to that server's `/v1` URL (`http(s)://host[:port]/v1`);
if blank, the target uses the router's `/v1/embeddings` route, which must have
an embedding model mapped in LiteLLM. For example, pull `nomic-embed-text` in an Ollama CT and use
`HONCHO_EMBEDDING_MODEL=nomic-embed-text`, `HONCHO_EMBEDDING_DIMENSIONS=768`,
and `HONCHO_EMBEDDING_BASE_URL=http://<ollama-ip>:11434/v1`. The installer
checks the endpoint and dimensions before it configures Honcho. If the
embedding endpoint differs from the router, it receives a placeholder key;
use an endpoint that accepts unauthenticated local requests. If the
embedding provider needs the OpenAI `dimensions` parameter, set
`HONCHO_EMBEDDING_DIMENSIONS_MODE=auto` or `always`; the default is `never` for
fixed-size local models. Changing vector dimensions after data has been stored
requires a new Honcho database. The target installs the upstream release
`HONCHO_REF=v3.5.0`; set another release tag, a full commit SHA, or `main`.
Its MCP server runs on Bun 1.4.4 from the release zip, checked against a
pinned SHA-256 (the baseline build on CPUs without AVX2). For another Bun set
`HONCHO_BUN_VERSION` with the checksum of the build this CPU takes:
`HONCHO_BUN_SHA256` for `bun-linux-x64.zip`, `HONCHO_BUN_BASELINE_SHA256` for
`bun-linux-x64-baseline.zip` (the error names the one missing). The services
run `uv run --frozen`, so they use exactly the locked dependencies.

## Upgrades, rollback and keys

A reconfigure keeps the PostgreSQL database, JWT secret and both keys. Before
it changes an installed CT, it sets aside the env file, keys, units and Bun
in `/var/lib/honcho-target/rollback/` (root-only), stops the three services,
and dumps the database there (`pg_dump -Fc`; leave room for it). The dump is
taken even when the commit is unchanged because embedding configuration can
change empty vector columns. If any later
step fails, the previous commit, its dependencies, the database (dropped,
recreated and restored from the dump), the env file, keys, units and Bun are
put back and the services started again; the run reports whether the
previous version is healthy. The set-aside copies are deleted after a
successful run or a clean rollback, and kept for inspection otherwise.

### When a rollback does not complete

If the previous version does not come back healthy (or a restore step fails),
the run says so and keeps `/var/lib/honcho-target/rollback/`. The next
reconfigure stops at once, changes nothing and points here, so a second run
cannot overwrite the only copy of the old database. Inside the Honcho CT:

1. Look at `systemctl status honcho-api honcho-deriver honcho-mcp` and
   `journalctl -u honcho-api -u honcho-deriver -u honcho-mcp`. The rollback
   has already put the files back; often the cause is outside Honcho (the
   router, the embedding endpoint, disk space).
2. If the database is not as it was, restore the dump with the services
   stopped:

   ```bash
   systemctl stop honcho-mcp honcho-deriver honcho-api
   runuser -u postgres -- dropdb --if-exists honcho
   runuser -u postgres -- createdb -O honcho honcho
   runuser -u postgres -- pg_restore --exit-on-error -d honcho < /var/lib/honcho-target/rollback/honcho.dump
   systemctl start honcho-api honcho-deriver honcho-mcp
   ```

   `honcho.env`, `jwt-secret`, `api-key`, `client-api-key`, the three units and
   `bun` in the same directory are the copies from before the failed run; they
   belong in `/etc/honcho-target/`, `/etc/systemd/system/` and `/opt/honcho-bun/`.
3. Once Honcho is healthy (`curl -fsS http://127.0.0.1:8000/health` and
   `http://127.0.0.1:3000/health`), remove the directory with
   `rm -r -- /var/lib/honcho-target/rollback` and run the reconfigure again.

The first install migrates with Honcho's default 1536-dimension columns and
then sets them to `HONCHO_EMBEDDING_DIMENSIONS`, as upstream documents. Later
runs migrate with the configured size, so a future migration that touches the
vector columns keeps it. `configure_embeddings.py` refuses to change the size
of columns that already hold vectors; that needs a new database.

`--reconfigure --rotate-keys` replaces the JWT secret, which invalidates every
existing key, and makes a new admin key and `osr` workspace key. The
provisioner verifies Open WebUI admin access first and keeps a separate copy
of the old secret and keys, and of the Open WebUI connection, until MCP
registration succeeds. Hermes and OpenClaw keep failing to reach Honcho until
each is reconfigured with `HONCHO_CT_ID`; the run prints those commands. The
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
  then; reconfigure Hermes and OpenClaw with `HONCHO_CT_ID` if the keys did
  change, and remove both directories.

## Install with the router

Select `honcho` in `ollama-smart-router-install.sh`, before any Hermes or
OpenClaw targets. The installer gives Honcho the router's URL and key, creates
the CT, and registers `http://<honcho-ip>:3000/mcp` as an authenticated
Streamable HTTP tool server in Open WebUI. When Hermes or OpenClaw is also
selected, their native Honcho integrations are installed and use the same
`osr` workspace and `user` peer. Open WebUI's MCP tools are available for an
admin to enable in a chat; the MCP connection does not automatically make
every Open WebUI conversation a Honcho memory session.

The router CT's Proxmox firewall must let the Honcho CT reach the router API.
When `/etc/pve/firewall/<router CT>.fw` exists, the provisioner keeps one rule
there for it (`# osr-honcho-router`, replaced when the Honcho address or
router port changes; every other line stays). Set `HONCHO_ROUTER_FIREWALL=false`
to manage that file yourself. An embedding endpoint other than the router must
be reachable from the Honcho CT too.

The selection menu asks for the embedding model, dimensions and endpoint and
offers `HONCHO_CT_ID`, `HONCHO_IP_CIDR`, `HONCHO_STORAGE`, and
`HONCHO_TEMPLATE` presets. The CT defaults to 4 cores, 8 GiB RAM, and 48 GiB
disk. To override the guest defaults, set any of `HONCHO_MODEL`,
`HONCHO_EMBEDDING_MODEL`, `HONCHO_EMBEDDING_DIMENSIONS`,
`HONCHO_EMBEDDING_BASE_URL`, `HONCHO_REF`, `HONCHO_STRUCTURED_OUTPUT_MODE` and
`HONCHO_SKIP_CHAT_PROBE` before launching the installer.
An Open WebUI admin API key or JWT is required for the MCP registration; a
run without one stops before it creates anything.

## Install or repair separately

On the Proxmox host running the router CT:

```bash
CT_ID=285 ROUTER_CT_ID=280 \
  TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
  STORAGE=local-lvm IP_CIDR=192.168.11.85/24 GATEWAY=192.168.11.1 \
  HONCHO_EMBEDDING_MODEL=nomic-embed-text HONCHO_EMBEDDING_DIMENSIONS=768 \
  HONCHO_EMBEDDING_BASE_URL=http://192.168.11.90:11434/v1 \
  OPENWEBUI_ADMIN_TOKEN=... bash targets/honcho/provision-lxc.sh
```

Use the same variables with `--reconfigure` to repair or update a CT that
this target created; existing agent firewall allowances are preserved unless
`HONCHO_CLIENT_IPS` is explicitly set. `--dry-run` prints its plan. Set `HONCHO_CLIENT_IPS` to
the agent CT addresses (space separated) if adding Hermes or OpenClaw
separately. Then run those provisioners with `HONCHO_URL` and
`HONCHO_CT_ID=285`; they pull the `osr` workspace key without putting it on a
command line. For an external Honcho instance, supply `HONCHO_API_KEY_FILE`
instead. Later `--reconfigure` runs of Hermes or OpenClaw keep the Honcho URL,
key and firewall rule from the last run; set `HONCHO_CT_ID` again to fetch a
new key, or `HONCHO_URL=` (empty) to turn Honcho off for that agent. A Honcho CT
made before the workspace key existed gets it on its next `--reconfigure`; run
that before reconfiguring the agents.

Inside the Honcho CT, inspect `systemctl status honcho-api honcho-deriver
honcho-mcp` or their journals. PostgreSQL data is under the distribution's
usual `/var/lib/postgresql` directory. The API and MCP health checks are
`http://127.0.0.1:8000/health` and `http://127.0.0.1:3000/health`.

Upstream deployment and integration guidance:
[self hosting](https://github.com/plastic-labs/honcho#self-hosting),
[OpenClaw plugin](https://github.com/plastic-labs/openclaw-honcho), and
[MCP server](https://honcho.dev/docs/v3/guides/integrations/mcp).
