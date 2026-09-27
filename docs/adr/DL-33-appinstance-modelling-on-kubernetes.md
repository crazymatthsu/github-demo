# DL-33 — AppInstance modelling on Kubernetes

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes (demo step 2) |

## Context

One AppName serves many AppInstances that differ only in configuration. On Kubernetes an instance could
be its own Helm release, one of N Deployments inside a single release per app, or a StatefulSet replica.
Most connectors are single-consumer pipelines where two active consumers would duplicate output.

## Decision

One Application / Helm release per AppInstance, generated from the config tree, one Deployment named
`<app>-<instance>`, `replicas: 1` for now (decided v0.7). Values are layered chart defaults →
`app-common` → instance; `targets.yml` (demo) or an ApplicationSet (EKS) enumerates the instances.

## Alternatives considered

- One release with N Deployments: fewer releases, but one upgrade touches every instance and a failed
  `--rollback-on-failure` (`--atomic`) upgrade rolls all of them back.
- StatefulSet with one replica per instance: stable identities, but instances are not ordinal peers and
  cannot differ in configuration.

## Consequences

- Blast radius of a deploy or config change is one pipeline (D6, D9).
- `strategy: Recreate` by default; a PDB only when `replicas > 1`; leader election or partitioned
  consumers are later options per source type (D6).
- Release count equals instance count; the config-lint job renders each one (D11).

## References

- TODO.md §2.2, §2.4, §5.6, §5.7, §6 (DL-33)
- D11 (`docs/11-kubernetes-packaging-and-gitops.md`), D6 (`docs/06-runtime-operations.md`)
