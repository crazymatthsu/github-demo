# DL-29 — Kubernetes packaging

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes (demo step 2) |

## Context

With production on EKS the config tree must map to Kubernetes objects: a Deployment, Service and
ConfigMap per AppInstance with probes and resources, driven by the `application.yml` layers and per-env
values. Candidates were a Helm chart per app, Kustomize base plus overlays, or Helm rendered through
Kustomize.

## Decision

Helm chart per app under `helm/<AppName>/` (decided v0.7). Values are layered chart defaults →
`app-common/values.yaml` → `<instance>/values.yaml`; the `application.yml` layers are passed as file
values (`--set-file`, or `helm.fileParameters` in Argo CD) and rendered into a ConfigMap mounted under
`/config/...`.

## Alternatives considered

- Kustomize base + overlays: no templating language, but one overlay directory per instance duplicates
  structure and cannot take files from outside the tree as easily.
- Helm + Kustomize post-rendering: maximal flexibility, two tools to learn.

## Consequences

- `helm lint` and `helm template` for every instance run in config-lint (D5, D11).
- The same chart serves `deploy-dev` (`helm upgrade --install --rollback-on-failure --wait`, Helm 4's name for `--atomic`) and Argo CD (D9).
- Chart defaults carry the probes, resources and security context of D6.

## References

- TODO.md §2.2, §2.4, §5.6, §6 (DL-29)
- D11 (`docs/11-kubernetes-packaging-and-gitops.md`)
