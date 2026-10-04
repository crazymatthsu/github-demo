# DL-44 — The cluster layer `config/<env>/<flow>/_common/` replaces the env-wide layer

| | |
|---|---|
| Status | Accepted (v1.8, 2026-10-04); amends DL-07 (layer 3), DL-41 decision 2 (bundle layout) and DL-42 §2 (layout) |
| Date | 2026-10-04 |
| Blocking for demo skeleton | no — the demo monorepo keeps `config/us-dev/_common/` until its scripts are ported (D12 §8) |
| Demo | `github-cicd-simple-apps`: `config/us-dev/cash/_common/application.yml` → `/config/flow/`; `FLOW_COMMON_DIR`; `appConfig.flow` (ADR R-0004 there) |

## Context

DL-07 fixed four file layers with layer 3 env-wide: `config/<env>/_common/application.yml`, mounted at
`/config/env/`, for the log-shipping endpoint, the region TZ and the Vault address. The platform owner's
operating model has no sharing at the env level: one business flow in one env — `<env>/<flow>` — is one business
cluster, with its own boxes (DL-41: a box serves exactly one `<env>/<flow>`), its own inventory (DL-39) and its
own shared endpoints (one AMPS per flow). The values the env-wide layer was meant to hold are set per cluster
anyway, and a layer nobody owns invites drift. D5 §4.2 had considered `config/<env>/<flow>/_common/` and set it
aside only to stay within the budget of four file layers.

## Decision

1. **Layer 3 is the cluster layer**: `config/<env>/<flow>/_common/application.yml` (and the other files of that
   directory), mounted at `/config/flow/` — compose `FLOW_COMMON_DIR`; Helm `appConfig.flow` / `appFiles.flow`
   with ConfigMap keys `flow.*` — shared by every app of the cluster. `config/<env>/_common/` is gone; config-lint
   check 1 rejects it with a pointer. The layer count stays at four: platform (`config/_common/<AppName>/`),
   cluster, app-common, instance; precedence is unchanged.
2. **The host bundle** (DL-41) carries `config/<env>/<flow>/_common/` with the flow; under `config/<env>/` only the
   flows and `known_hosts` remain.
3. **Shared secrets follow the same rule**: the Vault path of a cluster's shared secrets is `<env>/<flow>/_common`
   (D2; the chart's ExternalSecret), beside `<env>/<flow>/<app>/<instance>`.

## Alternatives considered

- Keep the env-wide layer and add the flow layer: five file layers (the D5 §4.2 budget), and nothing left to put
  in the env layer once the clusters own their endpoints.
- Keep the env-wide layer only (status quo): a value shared by the apps of one cluster is duplicated in every
  `app-common/`.
- Mount the layer at `/config/cluster/`: `cluster` is already the Kubernetes cluster field of a Helm target in
  the inventory; `flow` names the directory level the layer maps to.

## Consequences

- D5 §4.2, §6.1 (table, import list, Figure 1), the D6 mount table, the D11 values table and D12 §6.2 / §8 are
  revised; the `gha-config-deploy` skill's `__DEV_ENV__/_common/` example moves under the flow with the
  platform-ci extraction.
- `github-cicd-simple-apps` implements it (R-0004): the jar import list and its rendered-config test, the compose
  templates, `run-compose.sh`, `stack.sh`, `pool-deploy.sh` and its test, `helm-deploy-instance.sh`, the charts
  (schema, ConfigMap, helpers, ExternalSecret), config-lint and `_deploy-dev.yml`.
- The demo monorepo's own tree and scripts keep the env layer until they are ported (D12 §8).

## References

- TODO.md §5.6, §6 (DL-44), §10 (v1.8)
- D5 §4.2, §6.1; D6 §6.7; D11 §6.3; D12 §6.2, §8; DL-07, DL-39, DL-41, DL-42
