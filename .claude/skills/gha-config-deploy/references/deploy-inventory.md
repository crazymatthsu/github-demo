# The deploy inventory: targets, host pools, transports

Read this when you write or review `config/<env>/<flow>/workflows-config.yml`, a compose, pool or Helm deployer
for `_deploy-dev.yml`, or the SSH set-up of the dev hosts.

## Contents

1. What the inventory is for
2. Schema and resolution
3. Compose targets on a fixed host
4. Host pools: the whole flow on every box
5. Placement: pinned, then discovered, then assigned
6. The single-run guard on the boxes
7. Transports: ssh, local, dry-run
8. SSH with a forced command
9. Helm targets
10. Testing deployers, and retiring the inventory

## 1. What the inventory is for

The tree says what exists; the inventory says how and where each dev instance is deployed: compose on a host
or a Helm release in a cluster. It is one file per env and flow, `config/<env>/<flow>/workflows-config.yml`, so
each flow team owns its hosts through CODEOWNERS on `config/<env>/<flow>/`. It lists every instance of the flow
exactly once (config lint check 11), which makes it the deployment record and the anchor of the write-back (the
box of a pooled instance is recorded there). Only dev envs have inventories: qa and prod are deployed from
reviewed bump PRs by their controller or promotion job, never by `deploy-dev`. There is no env-level file.

## 2. Schema and resolution

```yaml
env: us-dev # must equal the path
flow: payments # must equal the path
pool: # optional: the flow's compose boxes (section 4)
  hosts: [box-1.example.com, box-2.example.com] # non-empty, unique, lower-case DNS names or IPv4
  user: deploy # SSH user on every box (default deploy)
  root: /opt/platform # install root of the flow's bundle on every box (default /opt/platform)
defaults: # any target field
  kind: helm
  cluster: dev-cluster # helm: a kube context in the Environment's kubeconfig
  namespace: payments # helm: default the flow
targets: # one per instance directory of the flow
  - instance: sync-app/ledger-db # <app>/<instance>, relative to the flow
    kind: compose # compose | helm
    host: box-2.example.com # compose: the host; with a pool, the recorded placement (optional)
  - instance: sync-app/refunds-db # inherits kind helm, cluster, namespace
```

| Field | Applies to | Resolution | Rule |
|---|---|---|---|
| `instance` | all | required | `<app>/<instance>` with a directory under the flow |
| `kind` | all | target, else `defaults.kind`, else `compose` | `compose` or `helm` |
| `host` | compose | target, else `defaults.host` | required without a pool; one of `pool.hosts` with a pool |
| `user` | compose without a pool | target, else `defaults.user`, else `deploy` | login name; a pool uses `pool.user` |
| `cluster` | helm | target, else `defaults.cluster` | required |
| `namespace` | helm | target, else `defaults.namespace`, else the flow | DNS label, at most 63 characters |

`_deploy-dev.yml` merges the flows' files into one list with the flow prefixed (`payments/sync-app/ledger-db`),
validates it with the rules above and deploys each kind through its deployer. Keep the file in mikefarah yq's own
layout (one space before a trailing comment; `yq -i . file` once) so that the write-back's yq edit is a one-line
diff.

## 3. Compose targets on a fixed host

The deployer runs, on the target's host, the same compose wrapper laptops and CI use (`<root>` is where the
wrapper and the config live on the host, `/opt/platform` by default):

```
IMAGE_TAG=<tag> <root>/scripts/run-compose.sh <env> <flow> <app> <instance> pull        # a registry failure changes nothing
IMAGE_TAG=<tag> <root>/scripts/run-compose.sh <env> <flow> <app> <instance> start       # up -d --wait: returns when healthy
IMAGE_TAG=<tag> <root>/scripts/run-compose.sh <env> <flow> <app> <instance> health      # readiness endpoint, exit code
IMAGE_TAG=<tag> <root>/scripts/run-compose.sh <env> <flow> <app> <instance> record-tag  # only after health passed
```

The new tag travels as an environment override: the host's `compose.env` still holds the last recorded tag. A
failed `start` or `health` is therefore rolled back by running `start` again without the override (the previous
image is still in the local cache), and the instance counts as failed, so it gets no write-back. Once `health`
passes, `record-tag` makes the host's copy of `compose.env` name the new tag (its `IMAGE_TAG` line rewritten in a
temporary copy that is renamed over it). Without it, a `restart` on the host before the next config sync quietly
runs the previous tag again. The wrapper refuses it in a git checkout, where `compose.env` only changes through
git (a host that pulls a checkout gets the tag with the write-back). A failed record is a warning, not a failed
deploy: the instance runs the new tag and the write-back still commits it. `restart` is `stop` + `start` (compose's own `restart` ignores env and image changes);
`down` never removes volumes unless asked explicitly (`--volumes`, plus `--force` on a dev host). Two instances
on one host need distinct `*_HOST_PORT` values.

The deployer assumes the host already holds the wrapper and the flow's config under a root directory. The simplest
way to get them there is to declare the flow's hosts as a `pool` (section 4), even when every instance stays pinned
to one host: the bundle sync then distributes config the same way everywhere. A minimal deployer that satisfies
the `_deploy-dev.yml` contract:

```bash
#!/usr/bin/env bash
# compose-target.sh <env> <flow> <app> <instance> --tag <tag> --host <host> --user <user>
set -euo pipefail
env=$1 flow=$2 app=$3 inst=$4; shift 4
while [ $# -gt 0 ]; do case $1 in --tag) tag=$2 ;; --host) host=$2 ;; --user) user=$2 ;; esac; shift 2; done
wrapper="${DEPLOY_ROOT:-/opt/platform}/scripts/run-compose.sh"
opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$DEPLOY_KNOWN_HOSTS")
on_host() { ssh "${opts[@]}" "$user@$host" -- "$@" </dev/null; }   # </dev/null: ssh must not eat the caller's input
compose() { local cmd=$1; shift; on_host "$@" "$wrapper" "$env" "$flow" "$app" "$inst" "$cmd"; }
compose pull "IMAGE_TAG=$tag" || exit 1
if compose start "IMAGE_TAG=$tag" && compose health "IMAGE_TAG=$tag"; then
  compose record-tag "IMAGE_TAG=$tag" || echo "warning: compose.env on $host still names the previous tag" >&2
  exit 0
fi
compose start || echo "starting the previous tag failed too" >&2   # compose.env still holds the previous tag
exit 1
```

## 4. Host pools: the whole flow on every box

When a flow runs on several bare-metal or VM boxes, declare them as the flow's `pool`. Every box receives the
flow's whole configuration, so any instance can run on any box (failover, rebalancing, maintenance) and each
instance runs on exactly one.

The **host bundle** is built from the checkout on every deploy and synced to every box under `pool.root`:

```
<root>/.platform-bundle         manifest, KEY=value lines: BUNDLE_ENV, BUNDLE_FLOW, BUNDLE_GIT_SHA, BUNDLE_TAG,
                                BUNDLE_CREATED, BUNDLE_FILES, BUNDLE_SHA256, POOL_HOSTS, POOL_USER, POOL_ROOT
<root>/scripts/run-compose.sh   the compose wrapper (and its helpers)
<root>/<app-dir>/               per app of the flow: docker/docker-compose.yml, scripts/
<root>/config/_common/<app>/    when present
<root>/config/<env>/_common/    when present
<root>/config/<env>/<flow>/     every app, instance and layer of the flow, and workflows-config.yml
<root>/config/<env>/known_hosts when present (the guard of section 6 pins the other boxes with it)
<root>/.state/                  box-local state, never synced or deleted
```

- Validate before syncing: run the wrapper's `validate` for every compose target from inside the built bundle
  (`IMAGE_TAG=<tag>`, placeholder values for the secrets), exactly as a box would run it.
- `BUNDLE_SHA256` is the sha256 of the sorted `<sha256>  <path>` lines of every file but the manifest and
  `.state/`; mark `BUNDLE_GIT_SHA` `-dirty` when a bundled file differs from the commit.
- Sync with `rsync -az --delete --exclude .state/ -e "ssh <opts>" <bundle>/ <user>@<box>:<root>/`: `--delete`
  removes an instance deleted from git; without it the box keeps a stale directory that the guard and the
  operators still see.
- Verify each copy with a second pass that must list nothing:
  `rsync -a --delete --exclude .state/ --dry-run --itemize-changes --checksum --omit-dir-times <bundle>/ <dest>/`.
- A box that fails to sync or verify is dropped for this run: nothing is placed or discovered there, an instance
  pinned to it fails, the rest continue, and the deploy exits non-zero at the end.
- After a passing `health`, run `record-tag` on the instance's box and then on every other box that received the
  bundle: every copy of `compose.env` names what runs, so a failover start on another box does not bring the
  previous tag back. The boxes' trees then differ from the manifest's `BUNDLE_SHA256` until the next sync, which
  replaces them with the new bundle (and verifies against it).
- The wrapper takes the nearest ancestor holding `.platform-bundle` as its root, so
  `<root>/<app-dir>/scripts/run-compose.sh <env> <flow> <app> <instance> start` works on a box with no git checkout.
- Secrets stay out of the bundle: each box holds the secret environment of every instance of its flow.

## 5. Placement: pinned, then discovered, then assigned

For each compose target of a pooled flow, the pool deployer picks one box:

1. **pinned**: the target's `host` in the inventory (set by a human, or recorded by an earlier write-back);
2. **discovered**: the one box that already runs it, asked through `run-compose.sh ... status --json` on every box;
3. **assigned**: the box with the fewest placements so far, ties in pool order (deterministic, so a re-run
   chooses the same box). Pinned and discovered instances count first, so assignments balance around them.

Conflicts stop the deploy with a dedicated exit code (the reference used 6): an instance running on two boxes,
or on a box other than its pin. `deploy --move` resolves the second case by stopping it on the old box first.
The deployer prints `deployed <flow>/<app>/<instance>@<host>=<tag>` per success; the write-back records `<host>`
as the target's `host`, so git always shows where each instance runs and moving one is a reviewed PR that
changes `host`.

A pool tool worth copying has one command per phase, each usable on its own from a laptop:
`bundle --out <dir>` · `plan [--json]` (placements without deploying) · `sync --bundle <dir>` · `discover` ·
`deploy --tag <tag> [--move] [--report <file>]` · `status`. `--report` writes JSON (boxes: files, sha256,
verification; placements: host, how, result, commands) that the job turns into its summary table.

## 6. The single-run guard on the boxes

Placement protects deploys; the guard protects humans. On a box whose manifest lists more than one pool host,
the wrapper's `start` and `restart` first ask every other box (`status --json` over SSH, as `POOL_USER`, under
`POOL_ROOT`, host keys pinned by the bundled `known_hosts`) and refuse (exit 3) when the instance runs there.

- A box that does not answer only warns: a dead box must never block a failover.
- `--force` skips the guard; `POOL_PEER_CHECK=off` disables it; `POOL_SELF_HOST` names this box when its
  `hostname -f` differs from its pool entry; `--dry-run` prints the peer commands.
- It applies only when the bundle's env and flow are the instance's, never in `local`.

## 7. Transports: ssh, local, dry-run

| Transport | What runs | Use |
|---|---|---|
| `ssh` | rsync and the wrapper over `ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=config/<env>/known_hosts`; refuses to start without that file | real boxes |
| `local` | the runner plays every box: one directory per box (`<local-root>/<host><root>/`), `validate`, `start --dry-run` and `record-tag --dry-run` per placement, the ssh commands printed | proving bundle, sync and placement before the boxes exist |
| `dry-run` | prints every rsync and ssh command, runs nothing, reports nothing as deployed | reviewing a change to the tool |

Let tests swap the binaries (`POOL_SSH`, `POOL_RSYNC` environment variables) instead of editing the tool. The
reference's deploy job ran the `local` transport until its boxes existed and wrote back the placements it
validated, to exercise the whole loop; with real boxes, treat `local` and `dry-run` as validation only and never
record their result as a deployment.

## 8. SSH with a forced command

The deploy key lives in the GitHub Environment `dev` (`DEV_DEPLOY_SSH_KEY`), is loaded into an `ssh-agent` for
one step and is never written to the workspace. Host keys are pinned: commit the reviewed `ssh-keyscan` output
as `config/<env>/known_hosts` (compare fingerprints out of band first); never `StrictHostKeyChecking=no`.

On every box, the deploy user's `authorized_keys` entry forces one command, so the key can do nothing else:

```
command="/usr/local/bin/deploy-gate",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA... deploy-dev
```

A sketch of that gate (the reference specified it but never ran it against real boxes; adapt and test it):

```bash
#!/usr/bin/env bash
# /usr/local/bin/deploy-gate: the only commands deploy-dev, the pool tool and the single-run guard send
set -euo pipefail
root=/opt/platform
read -r -a w <<<"${SSH_ORIGINAL_COMMAND:-}"          # split on blanks, never evaluated by a shell
if [[ ${w[0]:-} == rsync ]]; then exec rrsync "$root"; fi    # the bundle sync, confined to the root
if [[ ${w[0]:-} == IMAGE_TAG=* ]]; then                      # the tag of pull, start, health and record-tag
  [[ ${w[0]#IMAGE_TAG=} =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || exit 2
  export IMAGE_TAG="${w[0]#IMAGE_TAG=}"
  w=("${w[@]:1}")
fi
[[ ${w[0]:-} == "$root"/*scripts/run-compose.sh && ${w[0]} != *..* ]] || exit 2
for x in "${w[@]:1:4}"; do [[ $x =~ ^[a-z0-9-]+$ ]] || exit 2; done   # env flow app instance
case "${w[*]:5}" in pull | start | stop | health | record-tag | status | "status --json") ;; *) exit 2 ;; esac
exec "${w[@]}"
```

It refuses every option but `status --json`: `start --force` would skip the single-run guard. `rrsync` ships with
rsync and interprets the client's destination inside its directory, so the pool tool then syncs to
`<user>@<box>:` rather than `<user>@<box>:<root>/`; check this with your rsync version. The boxes hold the same
key and `known_hosts` for the guard's box-to-box `status --json`. A host that GitHub-hosted runners cannot reach
gets a self-hosted runner on it instead (the one self-hosted exception): the same commands run locally there, and
only the transport changes.

## 9. Helm targets

`cluster` names a kube context of the kubeconfig the Environment holds (`DEV_KUBECONFIG`), or of the one a cloud
OIDC login writes (then the caller also grants `id-token: write`). One script builds the Helm flag list for lint,
template and deploy, so config lint (check 12) renders exactly what the deploy installs:

```
-f config/<env>/<flow>/<app>/app-common/values.yaml -f config/<env>/<flow>/<app>/<instance>/values.yaml
--set-string image.tag=<tag>
--set-file appConfig.common=.../app-common/application.yml --set-file appConfig.instance=.../<instance>/application.yml
--set-file appConfig.platform=config/_common/<app>/application.yml   (when present; likewise appConfig.env)
```

Deploy, per instance, release `<app>-<instance>` in namespace `<ns>`:

1. create the namespace when missing, label it for the `restricted` Pod Security Standard;
2. ensure `Secret <app>-<instance>-secrets` exists (created from the secret store; see config-tree.md);
3. `helm lint`, then `helm upgrade --install <release> <chart> -n <ns> --create-namespace <flags>
   --rollback-on-failure --wait --timeout 5m --kube-context <cluster>` (Helm 4; Helm 3 calls it `--atomic`);
   on a first install leave `--rollback-on-failure` out: Helm would uninstall the failed release together with
   the pods and events the diagnosis needs;
4. `kubectl rollout status deployment/<release>` and `helm test <release> --logs` (give the test pod
   `helm.sh/hook-output-log-policy: hook-succeeded,hook-failed` so its log is printed); when either fails after
   an upgrade, `helm rollback <release> --wait` and exit non-zero;
5. print `deployed <flow>/<app>/<instance>=<tag>` on stdout, everything else on stderr; exit codes 0 ok,
   1 helm/kubectl failure, 2 usage, 3 refused (deploy of a qa or prod env: lint and template accept every env),
   4 config tree, 5 tool missing or not Helm 4.

Until a dev cluster exists, the reference deployed its helm targets into a throwaway kind cluster created in the
job (`cluster: kind-ci`), which proves chart and values on every merge but deploys nothing durable (see
gha-ephemeral-test-envs for the kind lifecycle).

## 10. Testing deployers, and retiring the inventory

- Test the pool tool and the wrapper in plain bash with stub `ssh`, `rsync` and `docker` on `PATH` that record
  their arguments: bundle content and manifest, pinned / discovered / assigned, two boxes running one instance
  (conflict), `--move`, identical trees per box, dry-run command lines, a failed health that restarts the previous
  tag without the override and records nothing, `record-tag` on every box after a passing health (a failed record
  only warning), the guard refusing and warning.
- Build test fixtures from a copy of the tree with the recorded `host` fields removed: after the first write-back
  the live inventory carries placements, and tests that copied it started from pinned instances.
- With a GitOps controller (promotion.md), an ApplicationSet with a git directory generator over
  `config/<env>/*/*/*` (excluding `app-common` and `_common`) enumerates the instances, and the helm part of the
  inventory retires; compose pools keep theirs.
