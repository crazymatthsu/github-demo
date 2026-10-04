# DL-45 — The platform layer `config/_common/<AppName>/` is removed

| | |
|---|---|
| Status | Accepted (v1.9, 2026-10-04); amends DL-07 (layer 2), DL-41 decision 2 (bundle layout), DL-42 §2 (layout) and DL-44 (layer count) |
| Date | 2026-10-04 |
| Blocking for demo skeleton | no — the demo monorepo keeps `config/_common/source-database/` until its scripts are ported (D12 §8) |
| Demo | `github-cicd-simple-apps`: `config/_common/` deleted; the jar import list, `run-compose.sh`, `stack.sh`, `pool-deploy.sh`, `helm-deploy-instance.sh`, the charts and config-lint no longer know the layer (ADR R-0005 there) |

## Context

DL-07 kept an optional platform layer `config/_common/<AppName>/application.yml`, mounted at `/config/platform/`
below every other file layer, for settings "the same in every env" (poll intervals, metric names). D5 §4.2
recorded its cost when it was chosen: a wrong edit hits prod and dev alike, so the directory had to be
CODEOWNERS-guarded. The platform owner judges that cost too high: the blast radius of one mistake at the top of the
tree is every environment at once, a review guard only slows such a mistake down, and the one file the layer holds
in the demo (a poll interval) is a default the jar could carry. Since DL-44 the operating model is "one business
flow in one env is one cluster, and nothing is shared above it"; a layer shared across envs contradicts it.

## Decision

1. **The platform layer is removed from the contract.** `config/` holds env directories and a README, nothing
   else; config-lint check 1 rejects `config/_common/` with a pointer. The mount `/config/platform/`, the compose
   variable `PLATFORM_DIR`, the Helm values `appConfig.platform` / `appFiles.platform` (ConfigMap keys
   `platform.*`) and the import `optional:file:/config/platform/application.yml` go with it.
2. **"Same in every env" is a jar default.** A value that must hold everywhere belongs in layer 1
   (`src/main/resources/application.yml`), versioned and tested with the code and rolled out by a release through
   dev, qa and prod in turn — the promotion path is the guard. A value shared by the apps of one cluster belongs in
   the cluster layer `config/<env>/<flow>/_common/` (DL-44).
3. **Three file layers remain** — cluster, app-common, instance — and six layers in all (D5 §6.1: jar defaults,
   cluster, app-common, instance, secrets, environment variables); precedence is unchanged. The host bundle (DL-41)
   carries no `config/_common/`.

## Alternatives considered

- Keep the layer behind a CODEOWNERS rule (the D5 §4.2 position): review lowers the chance of a bad edit, not its
  reach once merged; every env still changes in one commit, with no promotion step between them.
- Keep the layer but let config-lint require every key of it to be overridden in each cluster layer: a layer
  that is empty by construction.
- Freeze the layer read-only and let only releases change it: that is what the jar defaults already are.

## Consequences

- D5 §4.2, §6.1 (table renumbered, import list), §6.5 check 7 and Figure 1, the D2 Vault path table and figure,
  the D6 mount table, the D9 Helm adapter and rollback rows, the D11 values table and lint flags, D12 §6.2 / §6.3
  / §8 and TODO.md §5.6 are revised.
- `github-cicd-simple-apps` implements it (R-0005): `config/_common/source-database/` is deleted (its poll interval
  demonstrated precedence; the jar default stands), and the rendered-config test proves
  jar < cluster < app-common < instance < secrets.
- The demo monorepo's own tree and scripts, and the `gha-config-deploy` skill's `_common/__APP__/` example, keep the
  layer until they are ported (D12 §8), as they keep the env layer (DL-44).
- Rolling a shared value back for one env (D5, D9) is no longer a case: nothing shared crosses an env boundary.

## References

- TODO.md §5.6, §6 (DL-45), §10 (v1.9)
- D2 (Vault path table, Figure 1); D5 §4.2, §6.1, §6.5, §7.1; D6 §6.7; D9 (Helm adapter, rollback); D11 §6.3,
  §8.3; D12 §6.2, §6.3, §8; DL-07, DL-41, DL-42, DL-44
