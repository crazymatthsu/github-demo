# DL-41 — Versioned per-project bundles on dedicated boxes (host pools v2)

| | |
|---|---|
| Status | Accepted (v1.5, 2026-10-03); supersedes DL-39 decisions 2 and 3 (bundle layout, recorded placement); decision 2's layout amended by DL-44 (v1.8): `config/<env>/<flow>/_common/` instead of `config/<env>/_common/`; and by DL-45 (v1.9): no `config/_common/` in the bundle; the root fixed by DL-46 (v1.10): `/apps/<user>/versions/<project>/`, no `root` in the inventory |
| Date | 2026-10-03 |
| Blocking for demo skeleton | no — follow-up to v1.4; the `local` transport proves it until the boxes exist |
| Demo | `scripts/pool-deploy.sh` v2 (bundle per project, deploy, rollback, status), `run-compose.sh activate` and the manifest-defaulted short form, `workflows-config.yml` v2 in `config/us-dev/<flow>/` |

## Context

DL-39 (v1.3) syncs one flow bundle **in place** on every box (`rsync --delete` into `/opt/platform`) and lets
`host` be optional: the deployer discovers or assigns the box and the write-back records it. v1.4 added
`record-tag`, which wrote the deployed tag into the box's `compose.env` — a file the next sync overwrites
with the tree's. With DL-40 there is no write-back, so a discovered placement would never reach git, and
the tree's `compose.env` now says `main`, so "restart without the override" would pull the build that just
failed health. Rolling back a release that also changed configuration needed git in every case.

The platform owner's on-prem convention settles the layout: `~/versions/<project>/<version>/` under the
deploy user's home with a `current` symlink, rollback by pointing `current` at the previous directory; a
box serves exactly one `<env>/<flow>`; deploys are never partial ("deploy all" — git versus hosts must stay
legible); every instance's box is written in the inventory; the deploy user is configurable there.

## Decision

1. **Dedicated boxes.** A box serves exactly one `<env>/<flow>`; both projects (`deephaven-connectors`,
   `deephaven-server`) may live on it. A host appears in exactly one inventory of the whole tree.
2. **Versioned per-project bundles.** On every box, `<root>/<project>/<YYYYMMDD-HHMMSS>/` holds the bundle:
   `.platform-bundle` (project, env, flow, config git SHA, image tag, created, sha256, hosts), `docker/<AppName>/`
   compose templates, `scripts/` (`run-compose.sh`, `smoke.sh`), and `config/` mirroring the repository's paths
   (`_common/<AppName>/`, `<env>/_common/`, `<env>/<flow>/**`) so `git show <sha>:config/…` and `diff -r` need
   no translation. `current` is a symlink to the live version, switched by an atomic rename (`ln -s … tmp && mv -T`).
   `<root>/../shared/<project>/{logs,data}/` holds everything that must survive a version change (`LOGS_DIR`,
   `DATA_DIR`). `keep` versions are retained (default 5), never the one `current` points to or a running
   container uses. `root` defaults to `~/versions`, relative to the home of `hosts.user`; `~/…` is accepted
   and every ssh / rsync / forced-command path stays home-relative, so changing the user is one inventory
   line plus the boxes' `authorized_keys`.
3. **Deploy all, atomically, per (project, env, flow).** The bundle is built from the tree and rsynced to a
   **new** version directory on every box of `hosts.list` (`--link-dest=../current`: unchanged files cost
   nothing), verified by checksum; the literal tag is recorded into that directory's `compose.env`
   (`record-tag`, v1.4 — no longer overwritten by any sync); images are pulled; every instance of the project
   in the flow is started from the new directory on its declared box (a copy found running on another box of
   the flow is stopped first); `health` runs on all of them; only then `activate` flips `current` on every
   box, and old versions are pruned. Any failure: every instance already started goes back to `current`
   (old image **and** old config) and `current` never moves. No partial deploys, no "skip unchanged": a
   deploy restarts every instance of the project in the flow.
4. **Declared placement.** `instances: {<AppName>/<AppInstance>: <host>}` names every instance directory of
   the flow and is required; `hosts.list` names every box that receives each version (a standby box is
   simply listed). Discovery, assignment, `--move` and the placement write-back are removed. Moving an
   instance is a one-line pull request. A Helm instance names a `cluster` instead of a box.
5. **Rollback** is a dispatch with the inputs project, env, flow: every box flips `current` to the previous
   version and the instances restart from it. The restore-to-revision pull request (DL-40) follows when the
   tree should change too. No `.state/` last-good record: the version directory is the record.
6. **The wrapper on a box.** The manifest states project, env and flow; `run-compose.sh` refuses any other
   `<env> <flow>` there (exit 3, as the env allow-list) — the wrong environment cannot be started by typo —
   and accepts the short form `run-compose.sh <AppName> <AppInstance> <command>` with env and flow from the
   manifest. The long form stays and is required in a checkout (no manifest). The single-run guard shrinks
   to a safety net: refuse `start` when the instance runs on another box of the flow; an unreachable peer
   warns.
7. **Forced command (DL-35).** The deploy user's command allows `run-compose.sh` with `pull`, `start`, `stop`,
   `health`, `status [--json]`, `record-tag` and `activate`, and `rsync --server` confined to
   `<root>/<project>/<version>/`.
8. **Manual, nightly and on-merge deploys**: DL-40 item 4 (`deploy.on-merge`, `deploy.schedule`, dispatch
   inputs project / env / flow).

## Alternatives considered

- In-place sync (v1.3): rollback of configuration needs git on every path; the box's `compose.env` is
  overwritten by each sync.
- A `.state/` last-good record next to an in-place bundle: a second source of truth on the box, and still no
  config rollback.
- One version directory per flow instead of per project: one flip for both projects, but rolling back a
  connector release would also roll back the Deephaven server.
- Keeping discovery with declared `host` as a hint: without the write-back a discovered placement never
  reaches git — the confusion the owner wants gone.
- Partial or idempotent deploys (skip unchanged instances): legible only with per-instance records; rejected
  for simplicity.
- Date-only version names (`YYYYMMDD`): collide on the second deploy of the day; hotfix days have several.

## Consequences

- `pool-deploy.sh`: `bundle` per project, `deploy` (sync → record-tag → pull → start → health → activate →
  prune, with the rollback-on-failure above), `rollback`, `status` (`current` per project per box);
  `plan`, `discover` and `--move` go. `run-compose.sh`: `activate`, the manifest-defaulted short form and the
  env/flow refusal; the hard-coded flow list (`cash deriv swap`) becomes data — a flow is a directory under
  `config/<env>/` with a valid name. config-lint check 11 validates the v2 schema (D5 §6.6).
- Boxes: `~/versions/` and `~/shared/` provisioned for the deploy user; `authorized_keys` forced command
  updated; secrets per box unchanged (DL-39 decision 5).
- `workflows-config.yml` loses `pool`, `defaults` and `targets` and gains `hosts`, `deploy`, `instances`
  (DL-40); every instance directory of the flow must be listed.
- The Deployment payload names the version directory and the config git SHA per instance (DL-40).
- The `local` transport keeps proving bundle, sync and activation on the runner until the boxes exist
  (DL-35); the `ssh` transport is unchanged apart from the paths.
- To revise with the implementation: D6 §6.1 / §6.2 / §6.5, DL-35 (note), DL-10 (note), the
  `gha-config-deploy` skill (`deploy-inventory.md` §3–§7, templates).

## References

- TODO.md §5.12, §6 (DL-41), §8, §10 (v1.5)
- D5 §6.6; D6 §6.1, §6.2, §6.5; D9 §6.4, §6.9; DL-35, DL-39, DL-40
