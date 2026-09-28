# config/ — the configuration tree (D5)

`config/<env>/<flow>/<AppName>/{app-common,<AppInstance>}/` plus the optional layers
`config/_common/<AppName>/` (every env) and `config/<env>/_common/` (every app of one env), and in `*-dev` envs one
deploy-dev inventory per flow, `config/<env>/<flow>/workflows-config.yml`, with the boxes' host keys in
`config/<env>/known_hosts`. The directory path is the identity tuple; `run-compose.sh` mounts the layers read-only
under `/config/<layer>/` and the jar's import list applies them lowest precedence first: platform, env, app-common,
instance (D5 §6.1).

| File | Holds | Never |
|---|---|---|
| `application.yml` | endpoints, topics, table names, poll intervals, log levels | secrets (D2 §6.4) |
| `<AppInstance>/compose.env` | `IMAGE_REPO`, `IMAGE_TAG`, identity, `JAVA_OPTS`, `TZ`, `LOG_LEVEL_ROOT`, `*_HOST_PORT`, `LOGS_DIR`, `DATA_DIR`, `MEM_LIMIT` | `SPRING_*`, `LOGGING_*`, `MANAGEMENT_*`, `CONNECTOR_*`, secrets |
| `values.yaml` (Helm, D11 §6.2) | `app-common/`: `resources`, `env: {TZ}`; `<AppInstance>/`: `image.tag` (= `IMAGE_TAG`), `identity` (= the directory path), `env: {APP_ENV, APP_FLOW, APP_NAME, APP_INSTANCE, JAVA_OPTS, LOG_LEVEL_ROOT}` | `IMAGE_*`, `*_HOST_PORT`, `MEM_LIMIT`, `LOGS_DIR`, `DATA_DIR`, `SPRING_*`, `CONNECTOR_*_PASSWORD`, secrets |
| `<flow>/workflows-config.yml` (every flow of a `*-dev` env; D5 §6.6, DL-39) | `env` and `flow` (= the path); `pool: {hosts, user, root}` — the flow's bare-metal boxes, SSH user (default `deploy`) and install root (default `/opt/platform`); `defaults`; `targets`: one entry per instance directory of the flow — `instance: <AppName>/<AppInstance>`, `kind: compose \| helm`, `host` (compose: the box; with a pool optional, one of `pool.hosts`, and written back by deploy-dev), `user`, `cluster`, `namespace` (default: the flow) | secrets; an env-level `config/<env>/workflows-config.yml` (config-lint check 11 rejects it); a box in two flows' pools with the same `root` |
| `known_hosts` (in `config/<env>/`) | the reviewed `ssh-keyscan` lines of every box; the ssh transport of `scripts/pool-deploy.sh` and the pool guard trust no other host key | private keys: the deploy key is the Environment `dev` secret `DEV_DEPLOY_SSH_KEY` |

## Host pools (DL-39)

Every box of a flow's `pool` holds the flow's **host bundle** under `root`, so any instance of the flow can run on
any box, and each instance runs on exactly one.
`scripts/pool-deploy.sh <env> <flow> bundle|plan|sync|discover|deploy|status` (`--help`) builds, syncs and deploys
it; deploy-dev runs `deploy` for every flow with a pool (`.github/README.md`).

```
<root>/.platform-bundle                    manifest, KEY=value lines: BUNDLE_ENV, BUNDLE_FLOW, BUNDLE_GIT_SHA, BUNDLE_TAG,
                                           BUNDLE_CREATED, BUNDLE_FILES, BUNDLE_SHA256, POOL_HOSTS, POOL_USER, POOL_ROOT
<root>/scripts/run-compose.sh, smoke.sh
<root>/deephaven-connectors/<AppName>/     docker/docker-compose.yml, scripts/run-compose.sh, scripts/smoke.sh
<root>/config/_common/<AppName>/           when present
<root>/config/<env>/_common/               when present
<root>/config/<env>/<flow>/                every app, instance and layer of the flow, and workflows-config.yml
<root>/config/<env>/known_hosts            when present: the pool guard pins the other boxes' keys with it
```

- **Placement** is recorded, not fixed: pinned (`host` in `workflows-config.yml`) → discovered (the one box that runs the
  instance, asked through `run-compose.sh ... status --json`) → assigned (the box with the fewest placements, ties
  in pool order). The write-back records the box as `host`; a PR that changes `host` moves the instance
  (`deploy --move` stops it on the old box first). An instance found on two boxes stops the deploy (exit 6).
- **Root**: `run-compose.sh` and the app wrappers take the nearest ancestor holding `.platform-bundle` as their root,
  so `<root>/deephaven-connectors/<AppName>/scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> start`
  works on any box, with no git checkout and no `CONFIG_ROOT`.
- **Pool guard**: on a box whose bundle lists more than one host, `start` and `restart` first run `status --json` on
  every other box over SSH (as `POOL_USER`, under `POOL_ROOT`) and refuse (exit 3) when the instance runs there. A
  box that does not answer only warns (a dead box must not block a failover); `--force` skips the guard,
  `POOL_PEER_CHECK=off` disables it, `POOL_SELF_HOST` names this box when `hostname -f` differs from its entry in
  the pool, and `--dry-run` prints the peer commands.
- **Secrets** never enter the bundle: every box of a pool holds the secret environment of every instance of its
  flow (D2). Two instances on one box need distinct `*_HOST_PORT` values in their `compose.env`.

`./gradlew configLint` checks the tree (D5 §6.5, including `helm lint` / `helm template` per instance when Helm 4 is
installed); `scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> validate` checks one instance;
`scripts/helm-deploy-instance.sh <env> <flow> <AppName> <AppInstance> --tag <tag> --mode template` renders its release.
