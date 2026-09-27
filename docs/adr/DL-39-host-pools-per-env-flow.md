# DL-39 — Host pools per env/flow for the bare-metal compose targets

| | |
|---|---|
| Status | Accepted (v1.3, 2026-09-27) |
| Date | 2026-09-27 |
| Blocking for demo skeleton | no (follow-up to demo step 2) |
| Demo | `pool` in `config/us-dev/cash/workflows-config.yml`; `scripts/pool-deploy.sh`; the runner plays every box until the dev boxes exist (DL-35) |

## Context

Demo step 1 records one compose host per AppInstance in `workflows-config.yml`. The platform owner asked for the
bare-metal boxes to be organised per `<env>/<flow>` instead: a list of hosts for `us-dev/cash`, every box
of that list holding the configuration of every instance of the flow, so that any `AppName/AppInstance`
of the flow can run on any box (failover, rebalancing, maintenance), not only on the one box named for
it. Kubernetes gives this for free (the namespace is the flow, the nodes are the pool, the scheduler
places the single replica, the ConfigMap reaches every node — D11); the on-prem compose boxes need an
explicit design. DL-10 had closed "config sync to target VMs" as superseded by GitOps to clusters; this
decision reopens it for the compose path only.

## Decision

1. **One inventory per flow, with its pool.** The inventory moves into the flow directory:
   `config/<env>/<flow>/workflows-config.yml` (the env-level file is retired), so each flow team owns its hosts
   through CODEOWNERS on `config/<env>/<flow>/**`. The file may declare `pool` with `hosts` (the boxes),
   `user` (SSH user, default `deploy`) and `root` (install root, default `/opt/platform`); its targets
   are `<AppName>/<AppInstance>` relative to the flow. A compose target then needs no `host`; a `host` it
   does carry must be one of the pool's boxes. config-lint check 11 enforces all of it (D5 §6.6).
2. **The whole flow on every box.** On every deploy the job builds one **host bundle** per flow — the
   compose runtime (`scripts/run-compose.sh`, `scripts/smoke.sh`, each app's compose template and
   wrappers) plus `config/_common/`, `config/<env>/_common/`, `config/<env>/<flow>/**` (every app,
   instance and layer), `workflows-config.yml` and `config/<env>/known_hosts` when present, with a `.platform-bundle`
   manifest (`BUNDLE_SHA256` over the sorted file hashes) — and syncs it to every box of the pool
   (`rsync --delete`, the box's `.state/` kept, over the DL-35 SSH channel; each copy verified by a second
   checksum dry run). `run-compose.sh` resolves its root
   from the bundle marker, so `run-compose.sh <env> <flow> <app> <inst> start` works on any box.
3. **Placement is recorded, not fixed.** Each instance runs on exactly one box. `scripts/pool-deploy.sh`
   resolves the box as pinned (`host` in `workflows-config.yml`) → discovered (the one box where it already runs,
   asked through `run-compose.sh status --json`) → assigned (the pool box with the fewest placements,
   deterministic). The write-back records the chosen box as `host` next to the deployed tag, so git shows
   where every instance runs and moving one is a PR that changes `host`. An instance found on two boxes,
   or on a box other than its pin, stops the deploy (exit 6) unless `--move` is given.
4. **Single-run rule on the boxes.** `run-compose.sh start` / `restart` on a pooled box asks the other
   boxes of the pool (`status --json` over the same forced-command SSH channel) and refuses to start an
   instance that already runs elsewhere (exit 3; `--force` overrides; an unreachable peer only warns, so
   a dead box does not block failover).
5. **Secrets stay off the bundle.** Every box of a pool must hold the secret environment of every
   instance of its flow, provisioned per box outside git (D2); later a Vault agent (DL-11 / DL-12).

## Alternatives considered

- One host per instance, pool only for config distribution: least machinery, but a dead box means a PR
  to move each of its instances before anything can restart.
- Deploy-time scheduling (least loaded box, hashing): rebuilds a scheduler on top of compose, conflicts
  with stable per-box ports and log paths, and the Kubernetes path already provides it.
- Git checkout or pull agent on every box: no push credentials in CI, but no synchronous result, a daemon
  per box, and a second mechanism next to the DL-35 channel that already reaches the boxes.

## Consequences

- Each flow's `workflows-config.yml` keeps one entry per instance (the deployment record and write-back anchor);
  only `host` becomes optional for pooled flows. `deploy-dev` merges the flows' files, prefixing the flow.
- The DL-35 transport now carries the bundle sync as well as the three commands; the forced command on
  the boxes must allow `run-compose.sh` with `pull`, `start`, `stop`, `health` and `status` for the deploy
  user, and the same user is used box-to-box for the single-run rule.
- Two instances on one box need distinct published ports (`*_HOST_PORT` in `compose.env`, D5 §6.3).
- The demo has no boxes: `deploy-dev` runs `pool-deploy.sh` with the `local` transport (one directory per
  box on the runner, `validate` and `start --dry-run` per placement) and switches to `ssh` when the
  Environment `dev` holds `DEV_DEPLOY_SSH_KEY` and `config/<env>/known_hosts` exists.
- qa and prod are untouched: pools are read by `deploy-dev` for `*-dev` envs only; production stays on
  Kubernetes (DL-02).

## References

- TODO.md §4, §5.12, §6 (DL-39), §8
- D5 §6.6, D6 §6.2 / §6.5, D9 §6.4–§6.6, D2 §8, DL-10, DL-35
