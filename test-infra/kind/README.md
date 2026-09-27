# test-infra/kind

The Kubernetes test tier of demo step 2 (D10 §5.9, D11 §6.4, DL-32). A throwaway
[kind](https://kind.sigs.k8s.io/) cluster runs one Helm release per AppInstance, waits for readiness,
runs `helm test` and a smoke comparison of two instances, and is then deleted. It is a deployment test
of the chart and the config tree, not an integration test. The apps become ready without a reachable
database or Deephaven, because readiness is `readinessState` plus the connector indicator. The same
cluster type is the `deploy-dev` target `cluster: kind-ci` (`config/us-dev/cash/targets.yml`, one inventory per flow) until a dev
cluster exists.

```
test-infra/kind/
├── versions.env   pinned kind, kubectl, helm, kubeconform (equal to the ci-build image pins)
├── cluster.yaml   one control-plane node, no port mappings, no node image (kind's default)
├── kind.sh        up | load | diagnostics | down | leak-check
└── .state/        kubeconfigs written by `up` (git-ignored)
```

## Tools and node image

| Tool | Pin (`versions.env`) | Notes |
|---|---|---|
| kind | `v0.33.0` | default node image `kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5` (Kubernetes 1.37.0), pinned by digest inside the kind binary; `KIND_NODE_IMAGE` overrides it |
| kubectl | `v1.37.1` | within one minor of the node |
| helm | `v4.3.0` | Helm 4: `--rollback-on-failure` replaces `--atomic` and implies `--wait` (watcher); the deploy script refuses Helm 3 |
| kubeconform | `v0.8.0` | schema check of the rendered releases (config-lint check 12) |

In CI, `.github/actions/setup-kube-tools` installs exactly these from the official download URLs. Each
download is checked against the SHA-256 file that its project publishes next to it, as in
`docker/base/ci-build/Dockerfile`. On a laptop, install them yourself. `kind.sh` warns when your kind
differs from the pin, because another kind brings another Kubernetes version.

## `kind.sh`

```
kind.sh up                                  create the cluster (cluster.yaml, --wait 120s), label the nodes, wait for DNS
kind.sh load [--tag <tag>] <image-ref>...   put images on the nodes as <repo>:<tag>
kind.sh diagnostics <dir>                   nodes, get all,events, describe + logs of failing pods, helm history/status, kind export logs
kind.sh down                                kind delete cluster, prune by label, remove the kubeconfig; exit 0 only when nothing is left
kind.sh leak-check [--warn-only]            exit 1 if anything of the cluster remains
```

Every command takes `--name <cluster>`. The cluster is `KIND_CLUSTER_NAME`. Its default is
`ci-<run_id>-<attempt>` in CI (from `CI_RUN_ID` / `CI_RUN_ATTEMPT`, which default to `GITHUB_RUN_ID` /
`GITHUB_RUN_ATTEMPT`) and `local-kind` elsewhere. `deploy-dev` uses `deploy-<run_id>-<attempt>`. A name
has at most 50 characters from `a-z 0-9 . -`, which are kind's limits.

Exit codes, as in `test-infra/compose/stack.sh`: `0` success, `1` kind, kubectl or engine failure, or
a leak, `2` usage, `5` no container engine, kind or kubectl, or an unreachable engine. `kind.sh --help`
lists everything.

| Variable | Default | Effect |
|---|---|---|
| `KIND_CLUSTER_NAME` | see above | cluster name (kind itself also reads it) |
| `KIND_NODE_IMAGE` | kind's default for the pin | node image for `up` |
| `KIND_WAIT` | `120s` | how long `up` waits for the control plane and for `coredns` |
| `KIND_STATE_DIR` | `test-infra/kind/.state` | where `up` writes `<cluster>.kubeconfig` (mode 600) |
| `KIND_EXPERIMENTAL_PROVIDER` | `docker` when installed, else `podman` | kind's engine; `load` then uses `podman save` + `kind load image-archive`, because `kind load docker-image` always calls `docker` |

What `up` does:

1. Creates the cluster from `cluster.yaml`. The kubeconfig is written to
   `.state/<cluster>.kubeconfig`, never to `~/.kube/config`. In CI, `KIND_CLUSTER_NAME` and `KUBECONFIG`
   are appended to `$GITHUB_ENV` before the cluster is created. Later steps, including teardown after a
   half-finished `up`, therefore always target the same cluster.
2. Labels every node `com.example.ci.run=<run>` and `com.example.ci.attempt=<attempt>`.
3. Waits for `deployment/coredns`, because the smoke test needs service DNS.

An existing cluster of the same name is reused, so running `up` twice on a laptop is harmless.

### Images: digest in, `<repo>:<tag>` on the node

The build hands over each image pinned by digest (`images` output:
`ghcr.io/crazymatthsu/deephaven-connectors/source-database:<tag>@sha256:<digest>`). The chart renders
`<image.repository>:<image.tag>` with `pullPolicy: IfNotPresent`, and a kind node cannot pull a private
GHCR image. `kind.sh load` therefore works as follows:

1. It pulls `<repo>@sha256:<digest>` when the engine does not have it yet.
2. It tags that image ID `<repo>:<tag>`. The tag comes from `--tag`, else from the reference.
3. It runs `kind load docker-image <repo>:<tag>`.

Every release is then deployed with `--tag <tag>`. The name the chart renders is exactly the loaded
image, which is exactly the tested digest, and the node never pulls. The `helm-deploy-instance` action
renders each release before deploying it. It fails fast when any container would run an image that
`load` did not put on the node, such as a chart `image.repository` that differs from the built image's
repository. In CI, `load` writes the loaded names to `$GITHUB_OUTPUT` as `loaded`, and the
`kind-cluster` action returns them. The alternative, `--set image.digest`, was not chosen: kind loads
images by name, and the deploy script's interface is `--tag`.

### Teardown and leak check (DL-27)

| Layer | Mechanism |
|---|---|
| `always()` step | `kind.sh down`: `kind delete cluster`, then `docker rm -f -v` of any container, and removal of any volume or network, still carrying `io.x-k8s.kind.cluster=<cluster>` (verified label in kind v0.33.0). It also removes the kubeconfig. In CI it removes the shared `kind` bridge network too, once no kind node is left: kind creates that network without a cluster label and never deletes it. |
| Unique name | `ci-<run_id>-<attempt>` / `deploy-<run_id>-<attempt>`. The node containers carry the cluster label and the node's anonymous `/var` volume goes with `rm -v`. |
| Leak check | `always()` step after `down`. It fails when `kind get clusters` still lists the cluster, when a container, volume or network carries the label, or, in CI, when the idle `kind` network is still there. It writes the result to the job summary. |
| Timeouts | `kind-deploy` has `timeout-minutes: 25`, and the `always()` steps still run after the timeout. |
| Ephemeral runner | The GitHub-hosted VM is discarded after the job, together with any pulled image. |

## In CI

| Job | Where | What |
|---|---|---|
| `kind-deploy` | `.github/workflows/_kind-deploy.yml`, called by `pr.yml` (PR and merge queue, when `detect-affected` reports `deploy-test`) and `main.yml` (after `publish`, before `deploy-dev`) | `ci-<run>-<attempt>`: one release per instance directory of `config/us-dev/*/source-database/`, then `scripts/helm-smoke-diff.sh` across the two releases |
| `deploy-dev` | `.github/workflows/_deploy-dev.yml` (Helm adapter) | `deploy-<run>-<attempt>` for every `kind: helm` target with `cluster: kind-ci`, followed by the tag write-back |

Both jobs run the same sequence:

1. `registry-login`, `setup-kube-tools`.
2. The `kind-cluster` action: `up`, then `load` with the digest reference and `--tag`.
3. The `helm-deploy-instance` action, which wraps `scripts/helm-deploy-instance.sh`: namespace with
   the PSS `restricted` labels, the `<release>-secrets` Secret, `helm lint`, `helm upgrade --install
   --rollback-on-failure --wait --timeout 5m`, `rollout status` and `helm test`.
4. `diagnostics` into `build/kind-logs` and an upload when something failed.
5. `down` and `leak-check` in `always()` steps.

## Local flow

Requirements: Docker (or Podman, see above), plus kind, kubectl and helm at the pins above.

```bash
# 1. cluster local-kind; kubeconfig in test-infra/kind/.state/
test-infra/kind/kind.sh up
export KUBECONFIG=$PWD/test-infra/kind/.state/local-kind.kubeconfig

# 2. the app image, built locally as ghcr.io/crazymatthsu/deephaven-connectors/source-database:local
./gradlew :deephaven-connectors:source-database:buildImage
test-infra/kind/kind.sh load ghcr.io/crazymatthsu/deephaven-connectors/source-database:local

# 3. both local instances (namespace = flow = cash), deployed with the tag that was loaded
for instance in trades-db-to-amps positions-db-to-deephaven; do
  scripts/helm-deploy-instance.sh local cash source-database "$instance" --tag local
done
kubectl -n cash get deploy,pods

# 4. smoke comparison: the two instances differ in identity and effective configuration
scripts/helm-smoke-diff.sh -n cash source-database-trades-db-to-amps source-database-positions-db-to-deephaven

# 5. delete everything and prove it
test-infra/kind/kind.sh down
test-infra/kind/kind.sh leak-check
```

`scripts/helm-deploy-instance.sh --help` lists the deploy options. For example, `--dry-run` prints
the commands without running them, and `--mode template` renders a release without a cluster.
`kind.sh diagnostics build/kind-logs` collects the bundle that CI uploads.

## What only CI proves

`kind.sh` is tested against a stub engine: argument validation, exit codes, the commands it issues,
CI exports, pruning and leak reporting. Only a real runner can show the rest:

- the cluster starts within `--wait 120s` on a GitHub-hosted runner
- `kind load docker-image` imports the pulled image into the node's containerd
- both releases roll out, and `helm test` and the smoke diff pass
- `down` and `leak-check` leave nothing behind on passing, failing and cancelled runs
- the Podman path works, since Podman has not been run here
