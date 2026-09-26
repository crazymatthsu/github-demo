# DL-23 — Spring Boot baseline

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

The apps are Spring Boot services on Java 21. Spring Boot 3.x is the widely deployed baseline; 4.x on
Spring Framework 7 brings modularised starters and a newer Jakarta EE baseline. Third-party clients
(Deephaven Java client, AMPS, Kafka, SQL Server JDBC driver) must be verified against the chosen line.

## Decision

Spring Boot 4.1 on Spring Framework 7 with Java 21 (decided v0.8); upgrade policy: track 4.x minors.

## Alternatives considered

- Spring Boot 3.x: more third-party guidance available today, but an earlier end of support and a
  migration later.

## Consequences

- Gradle wrapper at a version supported by the Boot 4.1 Gradle plugin (D1).
- When Spring Cloud Vault arrives, pin the Spring Cloud release train matching Boot 4.1 (D2).
- The skeleton's first build verifies the third-party clients against Boot 4's modularised starters.
- Structured logging and actuator probe support of the 4.x line are relied on in D6.

## References

- TODO.md §2.2, §5.1, §6 (DL-23)
- D1 (`docs/01-repository-and-build.md`)
