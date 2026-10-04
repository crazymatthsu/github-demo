# DL-46 — The on-prem host root is `/apps/<user>`: `/apps/<user>/versions/<project>/<version>/` and `current`

| | |
|---|---|
| Status | Accepted (v1.10, 2026-10-04); amends DL-41 decision 2 (the root) and DL-35 (the forced command's paths) |
| Date | 2026-10-04 |
| Blocking for demo skeleton | no — the demo monorepo keeps its in-place `/opt/platform` bundle until its scripts are ported (D12 §8) |
| Demo | `github-cicd-simple-apps`: `pool-deploy.sh` (versioned sync, activation after health, rollback), `run-compose.sh activate`, config-lint check 11, `workflows-config.yml` (ADR R-0006 there) |

## Context

DL-41 fixed the versioned per-project layout — `<root>/<project>/<YYYYMMDD-HHMMSS>/` with a `current` symlink, rollback
by pointing `current` back — and left the root to the inventory: `root`, defaulting to `~/versions`, relative to the
home of the deploy user. The platform owner's convention for a Linux deployment host is fixed and absolute: every
deployment lives under `/apps/<user>/`, the deploy user's directory, as `/apps/<user>/versions/<project>/<version>/`,
and `/apps/<user>/versions/<project>/current` is the live one. A root that can be set per inventory invites a different
layout per flow; a home-relative one depends on how each box was provisioned.

## Decision

1. **The root is `/apps/<user>`**, `<user>` the flow's deploy user (`pool.user` / `hosts.user`, default `deploy`, DL-35):
   `/apps/<user>/versions/<project>/<version>/` holds one deployed bundle of the project (DL-41 decision 2), never
   changed afterwards; `/apps/<user>/versions/<project>/current` is a symlink to the live version, switched atomically
   (a new link renamed over the old one); `/apps/<user>/shared/<project>/{logs,data}` holds what survives a version
   change. `<project>` is `platform.yml`'s (D12). The directory is also the deploy user's home on the boxes, so `~`
   and `/apps/<user>` coincide, but every path the pipeline uses is absolute.
2. **No `root` in the inventory.** `pool.root` / `hosts.root` are gone; config-lint rejects them with a pointer. The
   inventory keeps `user` and `keep` (the versions kept per box, default 5, at least 2; never fewer than `current`
   and the version it replaced).
3. **A box serves one `<env>/<flow>`** (DL-41 decision 1), so its `current` is one cluster's; config-lint rejects a box
   listed by two flows, whatever the user.
4. **Boxes are provisioned** with `/apps/<user>/versions/<project>/` and `/apps/<user>/shared/<project>/`, owned by the
   deploy user. The forced command (DL-35) allows `run-compose.sh` with `pull`, `start`, `stop`, `health`, `status`,
   `record-tag` and `activate` under `/apps/<user>/versions/<project>/<version|current>/scripts/`, and `rsync --server`
   confined to `/apps/<user>/versions/<project>/<version>/`.

## Alternatives considered

- Home-relative `~/versions` (DL-41 as written): right only where the home is `/apps/<user>`; a box provisioned
  otherwise silently gets another layout.
- A configurable `root` with `/apps/<user>` as the default: the override is the thing to avoid — one layout on every box
  of the estate.
- `/apps/<project>/` without the user level: a per-project user and a shared deploy user would collide, and the owner's
  convention is per user.

## Consequences

- D5 §6.5 check 11 and §6.6 (no `root`), D6 (path resolution and its traceability table), D9 (the compose adapter and
  its traceability table), D12 §8 and TODO.md §5.12 / §6 / §10 are revised; DL-35 and DL-41 carry a note.
- `github-cicd-simple-apps` implements DL-41 decisions 2, 3 and 5 on this root (R-0006): every deploy is synced as a
  new version directory, `record-tag` writes the tag into it before anything starts, `pull` → `start` → `health` run
  from it, `run-compose.sh activate` switches `current` on every box only after every instance passed, any failure
  sends every started instance back to `current`, `pool-deploy.sh rollback` flips `current` back; config-lint check 11
  follows; the Deployment payload carries the version directory. Declared placement (DL-41 decision 4) and the short
  form of the wrapper (decision 6) stay for later.
- The demo monorepo's own scripts keep the in-place `/opt/platform` bundle until ported (D12 §8), as they keep the env
  and platform layers.

## References

- TODO.md §5.12, §6 (DL-46), §10 (v1.10)
- D5 §6.5, §6.6; D6 §6.2; D9 §6.4, §6.9; D12 §8; DL-35, DL-39, DL-41
