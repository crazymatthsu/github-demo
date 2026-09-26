# DL-34 — Registry for EKS

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |
| Phase | deferred to Phase 3 (brief v1.1) — not needed for the demo skeleton |

## Context

EKS nodes must pull the promoted images. They can pull from JFrog directly (`imagePullSecrets`, egress
to Artifactory) or from an in-region ECR mirror replicated from JFrog (IAM node auth, faster pulls).
Whether JFrog is reachable from the nodes and whether Graviton (arm64) nodes are used are §8 questions.

## Decision

Proposed: ECR mirror replicated from JFrog if pulls must be in-region or JFrog is unreachable from the
nodes; JFrog direct with `imagePullSecrets` otherwise. The image reference in `values.yaml` stays
digest-based so both registries serve the same content.

## Alternatives considered

- JFrog direct: one registry and one promotion path, but egress and pull latency depend on the network
  path.
- ECR mirror: in-region and IAM-authenticated, but replication is another moving part and promotion
  must be mirrored.

## Consequences

- The chart's `image.repository` is an env-level value (D11).
- Trusted-registry admission policy allows both hosts (D6).
- CI stays amd64 (SQL Server test image); a multi-arch decision follows the node architecture answer.

## References

- TODO.md §5.3, §8, §6 (DL-34)
- D3 (`docs/03-docker-images.md`), D11 (`docs/11-kubernetes-packaging-and-gitops.md`)
