# Kind tier: design details

Read this when you build or debug the Helm deployment test: `kind.sh`, `helm-release.sh`,
`smoke-diff.sh`, `_kind-deploy.yml`, Helm 4 flags, `helm test` hooks, image loading and teardown.

Contents

1. What the tier proves
2. Layout
3. Cluster name, kubeconfig and labels
4. Tools and pins
5. Images: digest in, tag on the node
6. One release per instance
7. helm-release.sh: one flag list, the first-install rule, Helm 4
8. helm test hooks
9. Smoke diff
10. Diagnostics
11. Teardown layers and the leak check
12. Timeouts and measured timings
13. Laptop flow
14. Variants

## 1. What the tier proves

A throwaway kind cluster inside the job: the chart renders and installs with every instance's values,
the pods pass the restricted Pod Security Standard, probes turn ready, the chart's own `helm test`
passes, and two instances of one chart really differ. It is a deployment test of the chart and the
values tree, not an integration test: integration tests stay on compose, and the releases must become
ready without their real dependencies (readiness must not require a database).

Put it in its own job: a kind node next to a compose stack does not fit a standard runner.

## 2. Layout

```
test-infra/kind/
  kind.sh          up | load | diagnostics | down | leak-check (assets/scripts/kind.sh)
  cluster.yaml     one control-plane node, no port mappings, no node image
  versions.env     KIND_VERSION, KUBECTL_VERSION, HELM_VERSION, KUBECONFORM_VERSION
  .state/          kubeconfigs written by up (git-ignored, mode 600)
scripts/ci/helm-release.sh   one release: lint | template | deploy
scripts/ci/smoke-diff.sh     two releases answer differently
<instances-dir>/_common/values.yaml, <instances-dir>/<instance>/values.yaml   one release per instance
```

## 3. Cluster name, kubeconfig and labels

- Name: `KIND_CLUSTER_NAME`, set by the job to `ci-<run_id>-<attempt>` (`local-kind` on a laptop). At most
  50 characters of `a-z 0-9 . -`: the node hostname `<cluster>-control-plane` must stay within 64.
- Kubeconfig: `.state/<cluster>.kubeconfig`, passed to every `kind create/delete --kubeconfig` and
  `kubectl --kubeconfig`, so `~/.kube/config` is never touched and a laptop's own contexts survive.
- `up` appends `KIND_CLUSTER_NAME` and `KUBECONFIG` to `$GITHUB_ENV` before creating the cluster: a
  teardown after a half-finished `up` targets the right cluster, and later steps need no setup.
- kind labels every node container `io.x-k8s.kind.cluster=<cluster>` (verified with kind v0.33.0); that is
  the label `down` prunes by and `leak-check` looks for. `up` also labels the Kubernetes nodes
  `<prefix>.run` / `<prefix>.attempt` for traceability.
- An existing cluster of the same name is reused (`up` twice on a laptop is harmless).
- `up` waits for `deployment/coredns`: `--wait` covers the control plane only, and `helm test` needs
  service DNS.

## 4. Tools and pins

`setup-kube-tools` installs the pins of `versions.env` from the official URLs and checks each download
against the SHA-256 file its project publishes. The runner image's own kind, kubectl and helm are other
versions and are shadowed on PATH, not used. kubectl stays within one minor of the node's Kubernetes,
which the kind release decides (its binary pins the default node image by digest). `kind.sh` warns when
the local kind differs from the pin. If the CI build image ships the same tools, keep one set of pins
(gha-build-images checks them).

## 5. Images: digest in, tag on the node

The build hands over `<repo>:<tag>@sha256:<digest>`. The chart renders `<image.repository>:<image.tag>`
with `pullPolicy: IfNotPresent`, and a kind node has no registry credentials. So `kind.sh load --tag <tag>
<ref>`:

1. pulls `<repo>@sha256:<digest>` when the engine does not have it (by digest, never by tag);
2. tags that image ID `<repo>:<tag>` (by ID: the content the digest names, whatever else carries the tag
   locally);
3. runs `kind load docker-image <repo>:<tag>` (Podman: `podman save` + `kind load image-archive`,
   because `kind load docker-image` always calls `docker`);
4. writes the loaded names to `$GITHUB_OUTPUT` as `loaded`.

Every release is then deployed with `--set-string image.tag=<tag>` and `image.repository=<repo>`: the
name the chart renders is exactly the loaded image, which is exactly the tested digest, and the node never
pulls. `helm-release.sh --loaded-images "<loaded>"` renders each release first and fails before
installing when any container (init containers and test hooks included) would run an image that is not
on the node. Without that check a wrong tag shows up as `ImagePullBackOff` after the full Helm timeout.
Load every image a release runs, e.g. the image a test hook uses, or use the app's own image there.

The alternative, `image.digest` rendered as `repo@sha256:...`, does not work with kind's by-name loading;
keep digests for real clusters (gha-versioning-release, gha-config-deploy).

## 6. One release per instance

`_kind-deploy.yml` makes one release per sub-directory of `instances-dir` that holds a `values.yaml`
(`_common/values.yaml`, when present, is applied first; `_*` and `.*` directories are skipped). Release
name `<prefix>-<instance>`, at most 53 characters (Helm's limit), all in one namespace. One release per
instance means one failure is confined to one release, `helm history` is per instance, and the smoke
diff can compare instances. Every instance is attempted; the step fails afterwards if any failed, and the
job summary lists each release's result.

## 7. helm-release.sh: one flag list, the first-install rule, Helm 4

The flag list is identical in `lint`, `template` and `deploy` mode, so what a lint job checks is what the
deploy installs: `-f <values>...` in order, `--set-string <tag key>=<tag>`, then the given `--set-string` /
`--set-file` pairs. `--set-string`, because `--set` turns an integer-looking tag (`1`, `20260929`) into a
number that a string schema rejects (checked with Helm 4.3.0; `1.10` and `1.4.0` stay strings).

Deploy mode:

1. namespace: created when missing, labelled `pod-security.kubernetes.io/enforce=restricted`,
   `enforce-version=latest`, `warn` and `audit` (`--pss none` leaves it alone);
2. `helm lint`, then the render check (`--loaded-images`);
3. `helm history`: a release with a deployed (or superseded) revision is upgraded with
   `--rollback-on-failure`; a **first install** runs without it. Helm uninstalls a failed first install
   when the flag is set, taking the failed pods, their logs and events with it, so it stays for the
   diagnostics (`helm uninstall` removes it; the kind cluster goes anyway);
4. `helm upgrade --install --create-namespace ... --wait --timeout 5m`;
5. `kubectl rollout status` of every Deployment / StatefulSet / DaemonSet labelled
   `app.kubernetes.io/instance=<release>` (charts from `helm create` set it), redundant with `--wait` but
   explicit in the log;
6. `helm test <release> --logs --timeout 5m`;
7. when rollout status or helm test fails after an upgrade: diagnostics to stderr, `helm rollback
   <release> --wait`, exit 1. The last stdout line on success is `deployed <release> <namespace> <tag>`.

Helm 4 facts the script relies on (checked against Helm 4.3.0's help):

| Helm 4 | Consequence |
|---|---|
| `--rollback-on-failure` replaces `--atomic` (kept as a deprecated alias) | the script uses the new flag on v4 and `--atomic` on v3 |
| `--rollback-on-failure` defaults `--wait` to the `watcher` strategy | - |
| without `--wait` the strategy is `hookOnly`: resources are not waited for | always pass `--wait` explicitly |
| `helm list` lists every status by default and has no `--all` | diagnostics use `--deployed --failed --pending --uninstalling`, which Helm 3 has too |
| `helm test --logs` prints the logs of test **pods** only | a Job hook needs `helm.sh/hook-output-log-policy` (section 8) |

## 8. helm test hooks

A `helm create` chart ships `templates/tests/test-connection.yaml` (a busybox pod): replace it with a Job
that checks the release end to end through its Service, using the app's own image (already on the node).
This template was linted, rendered and validated with kubeconform (Helm 4.3.0) in a `helm create api`
chart; rename `api.` to your chart's helper prefix:

```yaml
{{- /* templates/tests/smoke-test.yaml: `helm test <release>` runs this Job in the cluster after each deploy. */}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "api.fullname" . | trunc 52 | trimSuffix "-" }}-smoke-test
  labels:
    {{- include "api.labels" . | nindent 4 }}
    app.kubernetes.io/component: smoke-test
  annotations:
    helm.sh/hook: test
    # Replace the previous run's Job; keep a failed one for the diagnostics.
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
    # Helm 4: `helm test --logs` prints Pod hooks only; this prints the Job's output too.
    helm.sh/hook-output-log-policy: hook-succeeded,hook-failed
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 180
  template:
    metadata:
      labels:
        # Deliberately NOT the Service's selector labels: a running test pod must never receive traffic.
        app.kubernetes.io/instance: {{ .Release.Name }}
        app.kubernetes.io/component: smoke-test
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
        - name: smoke-test
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: ["sh", "-c"]
          args:
            - |
              set -eu
              url="http://{{ include "api.fullname" . }}:{{ .Values.service.port }}"
              curl -fsS --max-time 5 --retry 10 --retry-delay 3 --retry-connrefused "$url/health" \
                || { echo "FAIL $url/health"; exit 1; }
              echo "OK $url/health"
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 128Mi }
```

Check what identifies the instance, not only liveness: the reference's Job asserted readiness `UP` and
that `/actuator/info` reported exactly the instance identity the values set. `podSecurityContext` and
`securityContext` must satisfy `restricted` (`runAsNonRoot`, a numeric `runAsUser` when the image's user
is a name, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`),
or the namespace label rejects the pods. On Argo CD the same Job can double as a PostSync hook.

## 9. Smoke diff

`smoke-diff.sh -n <ns> <release-a> <release-b> -- <probe...>` runs the probe with `kubectl exec
deploy/<release>` in both releases (no port-forward, nothing published), prints a unified diff and passes
when both answered and the answers differ. It proves each release got its own values, which `helm test`
per release cannot. Choose a probe whose answer is deterministic per instance: an endpoint reporting the
instance identity and its effective (masked) configuration. Drop volatile fields with `--jq` (e.g.
`--jq '{identity, config}'`) or `--ignore <regex>`: a probe that only differs by uptime or pod name proves
nothing. The image must ship the probe binary (curl, wget) because `kubectl exec` runs it in the app
container. `_kind-deploy.yml` compares the first release with every other one; with a single instance it
warns and skips.

## 10. Diagnostics

`kind.sh diagnostics <dir>` (on failure, before teardown) writes: `node-containers.txt`, `nodes.txt`
(get + describe), `get-all.txt` (`get all,events -A -o wide`), `events.txt` (sorted by time), a
`describe-<ns>.<pod>.txt` for every pod that is not ready, `logs-<ns>.<pod>.log` (all containers, and
`.previous.log` after a restart) for every pod outside `kube-system` / `local-path-storage` and every
unhealthy one, `helm-list.txt`, a `helm-<ns>.<release>.txt` with history and status per release, and
`kind-export/` (kind export logs: node journal, kubelet, containerd). It never fails, and writes
`cluster-missing.txt` when there is no cluster. `helm-release.sh` also prints status, pods, describe, logs
and the last events of a failing release to stderr, so the job log alone usually explains it.

## 11. Teardown layers and the leak check

| Layer | Mechanism |
|---|---|
| `always()` `kind.sh down` | `kind delete cluster --kubeconfig <file>` (idempotent), then `docker rm -f -v` / `volume rm` / `network rm` of anything labelled `io.x-k8s.kind.cluster=<cluster>`, then the kubeconfig. In CI also the shared `kind` bridge network once no kind node is left: kind creates it without a cluster label and never deletes it. Exit 0 only when nothing is left. Works with only the engine when kind itself is missing |
| unique name | `ci-<run_id>-<attempt>`; the node's anonymous `/var` volume goes with `rm -v` |
| `always()` `kind.sh leak-check` | fails when `kind get clusters` still lists the cluster, when any container, volume or network carries the label, or in CI when the idle `kind` network remains; writes the job summary |
| ephemeral runner | the VM, and every pulled image, is discarded after the job |

## 12. Timeouts and measured timings

| Setting | Default |
|---|---|
| `KIND_WAIT` (control plane and coredns) | 120s |
| Helm `--timeout` and rollout status, per release | 5m (`timeout` input) |
| test hook `activeDeadlineSeconds` | 180 |
| job `timeout-minutes` | 25 |

Measured on ubuntu-latest in the reference (2026-09), one chart, two releases: tools 6 s (three checksum-verified
downloads), `kind up` 43 s, `load` 13 s, lint + render check + upgrade --install + rollout +
helm test for both releases 22 s, smoke diff under 1 s, `down` 2 s, `leak-check` under 1 s: about 90 s
for the whole job.

## 13. Laptop flow

```bash
test-infra/kind/kind.sh up                                   # cluster local-kind
export KUBECONFIG=$PWD/test-infra/kind/.state/local-kind.kubeconfig
docker build -t ghcr.io/<org>/api:local services/api         # or your build tool's image task
test-infra/kind/kind.sh load ghcr.io/<org>/api:local
for dir in deploy/dev/api/*/; do
  instance=$(basename "$dir"); [[ $instance == _* ]] && continue
  scripts/ci/helm-release.sh "api-$instance" --chart services/api/helm/api --namespace apps --tag local \
    -f deploy/dev/api/_common/values.yaml -f "${dir}values.yaml" --set-string image.repository=ghcr.io/<org>/api
done
scripts/ci/smoke-diff.sh -n apps api-eu-1 api-us-1 -- curl -fsS localhost:8080/info
test-infra/kind/kind.sh down && test-infra/kind/kind.sh leak-check
```

`helm-release.sh --dry-run` prints the commands; `--mode template --render-out <file>` renders without a
cluster (feed it to kubeconform for schema checks).

## 14. Variants

- **Podman**: `KIND_EXPERIMENTAL_PROVIDER=podman` (the default when docker is missing); `load` goes
  through an image archive. Not exercised in the reference's CI.
- **Real clusters later**: an ephemeral namespace `ci-<run_id>` on a dev cluster (OIDC to the cloud,
  RBAC limited to `ci-*` namespaces, `always()` namespace delete, and a TTL janitor as the backstop) tests
  the real platform; keep kind for pull requests. Deploying to long-lived clusters belongs to
  gha-config-deploy, whose deployer can call `helm-release.sh` so both share one flag list.
- **More than one chart**: call `_kind-deploy.yml` once per chart (one cluster each), or extend the
  instance listing with a chart per instance.
