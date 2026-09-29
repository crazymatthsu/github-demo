# Compose tier: design details

Read this when you build or debug the docker compose tier: `stack.sh`, the compose files, the test-runner
container, diagnostics, the leak check, timeouts, parallel jobs and reruns. The SKILL.md body has the rules;
this file has the mechanics behind them.

Contents

1. Layout and file roles
2. Names and labels
3. What `stack.sh up` does, step by step
4. The test-runner container
5. Images, digests and versions.env
6. Test-only secrets
7. Health checks and timeouts
8. Diagnostics bundle
9. Teardown layers and what the leak check looks for
10. Parallel jobs, reruns and shared engines
11. Laptop parity
12. Build-tool variants
13. Seeding test data
14. Resource budget and measured timings

## 1. Layout and file roles

```
test-infra/compose/
  stack.sh              up | status | diagnostics | down | leak-check (assets/scripts/stack.sh)
  base.yml              first file of every stack: run labels on the default network
  <stack>.yml           one dependency each (postgres.yml is the example): service <stack>, health check,
                        labelled named volumes, no ports
  <stack>.local.yml     ports on 127.0.0.1 for laptops only (added by `up --local`)
  test-runner.yml       the test process as a compose service (profile `tools`)
  stacks.yml            project id -> [stack, ...], one flow-style line per project
  versions.env          image references, tag + digest, one line each
  .state/               written by up: one <project>.env per stack (git-ignored, mode 600)
<project>/compose.test.yml   the app under test (image: ${APP_IMAGE}), passed as --file
```

`base.yml` must come first: compose resolves relative paths in every merged file against the directory of
the first file (the project directory). A relative bind mount in the app's compose file therefore points
into `test-infra/compose/`, not next to the app. Mount repository paths as `${TEST_WORKSPACE}/...`.

## 2. Names and labels

| Resource | Name | Labels |
|---|---|---|
| compose project | `COMPOSE_PROJECT_NAME`; in CI the job sets `ci-<run_id>-<attempt>`, on a laptop `local-<project slug>` | - |
| network | `<project>_default` | run labels (base.yml) + `com.docker.compose.project` |
| containers | `<project>-<service>-<n>` | run labels + compose's project / service labels |
| named volumes | `<project>_<volume>` | run labels (each volume declares them) + compose's project label |
| `compose run` containers | `<project>-test-runner-run-<id>` | the test-runner's labels + project label |

Run labels are `<prefix>.run=<run_id>` and `<prefix>.attempt=<attempt>` from an `x-ci-labels` anchor that
every file repeats (anchors do not cross files). The prefix is `com.example.ci` in the templates and
`CI_LABEL_PREFIX` in stack.sh; use your reverse domain in both. On a laptop the run label is `local`.

The project name is set by the job, not computed by `up`: a teardown step that runs after `up` failed
half-way (or never ran) must still know what to remove. `stack.sh` validates it (lower-case letters,
digits, `-`, `_`, starting with a letter or digit): the names compose accepts.

## 3. What `stack.sh up` does, step by step

1. Resolve the stacks: `--project <id>` looks up `stacks.yml`; `--stack <name>` adds more. A project with
   no line is a usage error (exit 2): an undeclared project never runs its ITs against nothing.
2. Merge the files in this order: `base.yml`, `<stack>.yml`..., `test-runner.yml`, every `--file` (the
   app), then in CI a generated override `ports: !reset []` for `--app-service` (Docker Compose 2.24+),
   or with `--local` the `<stack>.local.yml` files.
3. Generate the secrets named in `x-stack-secrets` lines (section 6) and the runner variables
   (`TEST_RUNNER_UID/GID`, `TEST_WORKSPACE`, `TEST_CACHE_DIR`, created by the caller so the engine does not
   create it as root).
4. Record everything in `.state/<project>.env` and, in CI, append it to `$GITHUB_ENV` (secrets masked
   with `::add-mask::` first). Later steps then run plain `docker compose ...` with the same
   `COMPOSE_FILE`, `COMPOSE_ENV_FILES` and interpolation values.
5. `pull --quiet --include-deps <stacks>`: only the dependencies. The image under test may exist only
   locally on a laptop, and `up` pulls a missing digest anyway.
6. `up --wait --wait-timeout 180 <stacks>`: the dependencies, healthy.
7. `STACK_SEED_CMD`, if set (section 13).
8. `up --wait --wait-timeout 180 --quiet-pull`: everything else, i.e. the app under test, which also
   declares `depends_on: {<stack>: {condition: service_healthy}}`.

A failed up prints `compose ps -a`, the interleaved log tail and then the last 40 lines of each container
that is not running or is unhealthy. The last part was added after a real failure: the interleaved tail
was dominated by a chatty server while the failing broker's own error sat far above it.

## 4. The test-runner container

The tests run as `docker compose run --rm test-runner <command>` on the stack network:

- **No published ports.** Tests reach `postgres:5432` and `app:8080` by service name and container
  port. Nothing binds a host port, so two jobs, two stacks or a developer's own database never clash.
- **Same image as the build.** `TEST_RUNNER_IMAGE` is the CI build image (gha-build-images), so the tests
  run with the toolchain the build used and a laptop can run the same container.
- **The runner's UID/GID** (`user: ${TEST_RUNNER_UID}:${TEST_RUNNER_GID}`, 1001 on GitHub-hosted runners):
  reports and build outputs written into the bind-mounted workspace stay owned by the runner user, so
  later steps (summary, upload, cache save) can read and delete them.
- **`profiles: [tools]`** keeps `up --wait` from starting it; `compose run` still starts a service of an
  inactive profile when it is named explicitly.
- **`HOME=/tmp`**: an arbitrary UID has no home directory in the image.
- **Cache**: the host cache restored by the workflow is bind-mounted at `/cache` read-write (section 12).
  Only the build job saves the cache (`cache-read-only: true` here), so parallel IT jobs never race to
  write it.
- **`init: true`** reaps the test JVM's / node's children and forwards the cancel signal.

The alternative, running the tests in the job container joined to the stack network (`docker network
connect`), needs host-path translation for bind mounts; the runner service avoids it because compose
runs on the host.

## 5. Images, digests and versions.env

- Dependencies: `<registry>/<repo>:<tag>@sha256:<digest>` in `versions.env`, one line each. When both are
  present, Docker and Podman pull by digest; the tag only documents the version. Fully qualified
  registries: Podman resolves short names through registries.conf and may refuse them.
- The image under test: `APP_IMAGE`, the digest the build job pushed in this run
  (`fromJSON(inputs.images)[inputs.project]`), checked for `@sha256:` before anything starts. Never a
  moving tag: a concurrent run could move it between build and test.
- The environment beats `--env-file`: a system-level test can swap one dependency for an image built in
  the same run (the reference swapped an upstream server image for its own build of it at system level) by
  setting that variable, without editing versions.env.
- Enterprise registries: point the lines at the mirror (JFrog remote, ECR pull-through cache) and keep
  the digest; the digest is the same content whatever the registry.
- Comments in versions.env stay on lines of their own: compose reads it as an env file.

## 6. Test-only secrets

A stack file lists the variables it needs generated:

```yaml
x-stack-secrets: [DB_PASSWORD]
```

`stack.sh up` keeps a value already in the environment, else reuses the one recorded in the state file
(a re-run of `up` against a running database must not change its password), else generates
`Aa1-<32 hex>` (upper, lower, digit, symbol: passes common password policies). In CI the value is masked
before it is written to `$GITHUB_ENV`. Nothing secret is committed; the state file is mode 600 and
git-ignored. `down` re-reads the compose files, so it fills any missing secret with a dummy value first.

## 7. Health checks and timeouts

| Layer | Default | Rule |
|---|---|---|
| service health check | `start_period` + `retries` x `interval` | must fit inside the wait timeout, or `up` gives up before compose calls the service unhealthy |
| `up --wait-timeout` | 180 s (`STACK_WAIT_TIMEOUT`) | per phase (dependencies, then the app); raise it for slow images under emulation |
| `down --timeout` | 20 s (`STACK_DOWN_TIMEOUT`) | the stop grace period: services that ignore SIGTERM use all of it |
| job `timeout-minutes` | 30 (input) | a hung service cannot hold a runner; the job is cancelled and its `always()` steps still run |

Probe the way the tests connect: over TCP for a database (the Postgres image's init phase runs a
temporary server on the Unix socket only), a gRPC or HTTP health endpoint for servers. The probe binary
must exist in the image: check with `docker run --rm --entrypoint sh <image> -c 'command -v curl'`; images
without one can fall back to bash's `/dev/tcp` (`bash -c 'exec 3<>/dev/tcp/127.0.0.1/<port>'`).

## 8. Diagnostics bundle

`stack.sh diagnostics <dir>` runs before teardown (`if: failure()`), never fails, and writes:

| File | Content |
|---|---|
| `compose-ps.txt` | `compose ps -a` plus the engine's view by label (containers compose no longer knows) |
| `<service>.log` | `docker logs --timestamps` of every labelled container, one-off runner containers included |
| `state-<service>.json` | `.State`: status, exit code, `OOMKilled`, error, and the health probe's last outputs |
| `stats.txt` | `docker stats --no-stream`: memory against `mem_limit` |

The workflow uploads it with the JUnit results only on failure (`it-diagnostics-<run>-<attempt>-<slug>`,
7 days on PRs, 14 on main). It holds container logs: keep secrets out of them, as everywhere.

## 9. Teardown layers and what the leak check looks for

| Layer | Covers | Gap it leaves |
|---|---|---|
| `always()` `stack.sh down`: `compose down -v --remove-orphans --timeout 20` | success, failure, cancel, timeout | the files must still parse; a crashed runner |
| prune by label: `docker rm -f -v`, `volume rm -f`, `network rm` of everything labelled | what compose lost track of: one-off `run` containers, resources of an up that died half-way | unlabelled resources |
| labels + unique name per run and attempt | exact targeting; parallel jobs and reruns never meet | nothing labelled means nothing found |
| ephemeral runner (GitHub-hosted VM, ephemeral self-hosted) | everything on the machine | persistent self-hosted runners |
| `always()` `stack.sh leak-check` | makes any gap visible: exit 1 and a job-summary table | - |

The leak check lists containers (any state), volumes and networks carrying the project label, plus in CI
(`STACK_SCOPE=run`) the run label, which also catches anything else the run labelled on that machine. A
failing engine query is an error, never "nothing found". `--warn-only` reports without failing, for the
first weeks of a new stack. `down` itself exits 1 when anything is left, so a failed teardown is visible
even without the leak check.

What it cannot see, and how the templates avoid it:

- **Anonymous volumes.** An image that declares `VOLUME /data` gets an engine-created volume with no run
  or project label. Mount a named, labelled volume on every declared path
  (`docker image inspect -f '{{json .Config.Volumes}}' <image>` lists them); `rm -v` also removes the
  anonymous volumes of the containers it deletes. A tmpfs is not a safe replacement: it is root-owned, and
  a non-root image failed to initialise its data directory on it in the reference.
- **`docker run` without labels** in a workflow step: always go through compose, or add the labels.

## 10. Parallel jobs, reruns and shared engines

- Matrix jobs on GitHub-hosted runners each get their own VM, so `ci-<run_id>-<attempt>` is unique per
  machine; the attempt number keeps a rerun's resources apart from the first attempt's.
- Runners that share one engine (persistent self-hosted, several runner processes on one host) would give
  every matrix job of a run the same name. Pass `name-suffix` (e.g. `-${{ strategy.job-index }}` from the
  caller) to `_integration-test.yml`: the stack name becomes unique and `STACK_SCOPE=project` stops a job
  from pruning its siblings' stacks by the shared run label.
- One stack per job: tests inside a suite share it and isolate by data (a per-run table or schema prefix),
  not by restarting containers.

## 11. Laptop parity

```bash
test-infra/compose/stack.sh up --project services/api --local      # ports on 127.0.0.1, state recorded
( set -a; . test-infra/compose/.state/local-services-api.env; set +a
  docker compose run --rm test-runner ./gradlew :services:api:integrationTest )   # the exact CI shape
test-infra/compose/stack.sh down                                    # finds the only state file
```

- `--local` publishes each stack's `<stack>.local.yml` ports on 127.0.0.1 (above 1024, fine for rootless
  Podman) and keeps the app's own ports, so a test on the host JVM or an IDE can connect.
- Build tools can call the same script: a Gradle `Exec` task, an npm script or a Makefile target, with
  the teardown in a `finally` / `finalizedBy`.
- Podman: `COMPOSE_BIN="podman compose"` (the default when `docker` is missing), with the docker-compose
  provider: `--wait` and `COMPOSE_ENV_FILES` are compose v2 features. SELinux hosts add `:z` to read-only
  bind mounts.
- Apple silicon runs amd64-only images under emulation: raise `STACK_WAIT_TIMEOUT` (300 s).

## 12. Build-tool variants

| Tool | `__TEST_COMMAND__` (runs in /workspace) | `TEST_CACHE_DIR` (mounted at /cache) | Runner env |
|---|---|---|---|
| Gradle | `./gradlew "${PROJECT}:integrationTest" --no-daemon` | `~/.gradle` (setup-gradle, read-only) | `GRADLE_USER_HOME=/cache` |
| Maven | `mvn -B -ntp -pl "$PROJECT" verify -Pintegration-tests` | `~/.m2/repository` (actions/cache/restore) | `MAVEN_OPTS=-Dmaven.repo.local=/cache` |
| npm / pnpm | `pnpm --filter "./$PROJECT" run test:integration` | `~/.npm` / the pnpm store | `npm_config_cache=/cache` / `npm_config_store_dir=/cache` |
| Go | `go test -tags=integration "./$PROJECT/..."` | `~/go/pkg/mod` | `GOMODCACHE=/cache` (the build cache stays under HOME=/tmp) |
| Python | `python -m pytest "$PROJECT/tests/integration" --junitxml=...` | `~/.cache/pip` | `PIP_CACHE_DIR=/cache` |

JUnit XML: Gradle and Maven write `TEST-*.xml` (junit-summary.sh's default); jest needs jest-junit, Go
needs gotestsum, pytest `--junitxml`: then set `JUNIT_GLOB='*.xml'` on the summary step.

## 13. Seeding test data

In order of preference:

1. **From the tests.** The reference's integration test applied its case's schema and rows over JDBC
   before polling for the result, so the data lives with the test that needs it.
2. **`STACK_SEED_CMD`** for data the app needs at startup: it runs after the dependencies are healthy and
   before the app starts, with `COMPOSE_*` exported, e.g.
   `STACK_SEED_CMD='docker compose exec -T postgres psql -U test -d test -f /seed/init.sql'` (mount
   `/seed` read-only in the stack file).
3. An image's own init hook (`/docker-entrypoint-initdb.d` for Postgres) when the data is static.

Isolate by data, not by container: a per-run prefix (the reference used `it_<sha7>_` for table names) lets
the classes of a suite share one stack.

## 14. Resource budget and measured timings

The reference was sized for a 2 vCPU / 7 GB GitHub-hosted runner (check the current specification: it
differs between public and private repositories). Give every service a `mem_limit`, sum them with the
runner OS (~1 GB) and measure with `stats.txt` on the first real runs. If a stack does not fit: shrink
heaps first, then split suites into separate jobs, then a larger runner class.

Measured on ubuntu-latest in the reference (2026-09), stacks of a database, a data server and the app:

| Step | Duration |
|---|---|
| `stack.sh up` (pull, dependencies healthy, app healthy) | 36-52 s |
| tests in the runner container | 40-51 s |
| `stack.sh down` | 1-21 s (21 s when a service used the whole stop grace period) |
| `stack.sh leak-check` | under 1 s |
| self-cancelled drill: cancel request to teardown start | 15 s |
