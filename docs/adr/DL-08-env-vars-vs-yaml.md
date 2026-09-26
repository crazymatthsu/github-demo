# DL-08 — Env vars vs YAML

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

Two instances of the same AppName differ in source and target hosts, ports, topics and subscriptions.
The brief asks whether such values belong in environment variables that parameterise `application.yml`
or in override YAML, and forbids defining the same key in both places.

## Decision

Proposed: environment variables only for knobs that are per host or per instance **and** also consumed
by compose or the pod spec (image tag, published ports, memory, volume paths, instance identity, Vault
role, log level); YAML for structured application configuration (endpoint lists, topics, subscriptions,
mappings). Source and target `host:port` live in the instance `application.yml`; `${VAR}` placeholders
are allowed only for the few values shared with compose.

## Alternatives considered

- Everything through environment variables: compose-friendly, but lists and mappings become unreadable
  and untyped.
- Everything in YAML: clean, but the image tag, ports and memory must still be visible to compose and
  Helm.

## Consequences

- `compose.env` stays small and is mirrored one-to-one into container `env` in the instance
  `values.yaml` (D11).
- config-lint rejects a key defined both as an env var and in YAML (D5).
- The worked example (two `source-database` instances with different SQL Server hosts and AMPS topics)
  is part of D5 and the demo config tree.

## References

- TODO.md §5.6, §6 (DL-08)
- D5 (`docs/05-configuration-management.md`)
