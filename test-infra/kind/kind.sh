#!/usr/bin/env bash
# test-infra/kind/kind.sh: lifecycle of the throwaway kind cluster that the Helm deployment test runs in
# (D10 §5.9, §6.4; D11 §6.4; DL-27, DL-32).
#
# One script, three callers: the kind-deploy job and the deploy-dev Helm adapter (through the kind-cluster
# composite action) and a laptop (README.md), so all of them run the same commands. It mirrors
# test-infra/compose/stack.sh: the same exit codes, teardown in `down`, and `leak-check` as the proof that
# nothing is left. Portable to bash 3.2 (macOS). Run `kind.sh --help` for the interface.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: test-infra/kind/kind.sh <command> [--name <cluster>] [options]

Commands
  up
      Create the cluster from test-infra/kind/cluster.yaml (kind create cluster --wait 120s) with its
      kubeconfig in test-infra/kind/.state/<cluster>.kubeconfig, label every node com.example.ci.run=<run>
      and com.example.ci.attempt=<attempt>, and wait for cluster DNS. In CI it appends KIND_CLUSTER_NAME and
      KUBECONFIG to $GITHUB_ENV first, so later steps find the cluster even when up fails half-way.
      An existing cluster of the same name is reused.
  load [--tag <tag>] <image-ref>...
      Put images on the cluster's nodes: kind load docker-image (Podman: save + kind load image-archive).
      <image-ref> is <repo>:<tag>, <repo>@sha256:<digest> or <repo>:<tag>@sha256:<digest> (the form of the
      build's `images` output). A digest reference is pulled by digest when missing and tagged <repo>:<tag>
      locally, the tag coming from --tag, else from the reference; any other reference is pulled when
      missing (and retagged when --tag differs). The chart renders <image.repository>:<image.tag> with
      pullPolicy IfNotPresent, so deploy with --tag <tag> and the node never pulls. In CI the loaded names
      are written to $GITHUB_OUTPUT as `loaded`.
  diagnostics <dir>
      Write the nodes, kubectl get all,events -A, a describe of every pod that is not ready, pod logs
      (current and previous), helm list -A, helm history and status of every release, and kind export
      logs into <dir>. Never fails because the cluster is broken or gone.
  down
      kind delete cluster, then remove every container, volume and network still carrying
      io.x-k8s.kind.cluster=<cluster>, and the kubeconfig. In CI also the shared `kind` network once no
      kind node is left (the runner is ephemeral). Exit 0 only when nothing is left.
  leak-check [--warn-only]
      Exit 1 when the cluster, or any container, volume or network carrying io.x-k8s.kind.cluster=<cluster>
      remains (in CI also an idle `kind` network); --warn-only reports and exits 0. Writes a summary to
      $GITHUB_STEP_SUMMARY in CI.

  --name <cluster> overrides KIND_CLUSTER_NAME for any command.

Environment
  KIND_CLUSTER_NAME      default ci-<CI_RUN_ID>-<CI_RUN_ATTEMPT> in CI, local-kind elsewhere
                         (a-z, 0-9, '.', '-', at most 50 characters: kind's limits)
  CI_RUN_ID, CI_RUN_ATTEMPT  run labels (default GITHUB_RUN_ID / GITHUB_RUN_ATTEMPT, else local / 0)
  KIND_NODE_IMAGE        node image for up (default: kind's own for the pinned KIND_VERSION, versions.env)
  KIND_WAIT              how long up waits for the control plane and for cluster DNS (default 120s)
  KIND_STATE_DIR         where up writes kubeconfigs (default test-infra/kind/.state)
  KIND_EXPERIMENTAL_PROVIDER  docker (default when installed) or podman (default when docker is absent)

Exit codes
  0 success   1 kind, kubectl or engine failure, or a leak found   2 usage
  5 no container engine, kind or kubectl, or the engine is not reachable
EOF
}

KIND_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$KIND_DIR/../.." && pwd -P)
STATE_DIR=${KIND_STATE_DIR:-$KIND_DIR/.state}
CLUSTER_CONFIG=$KIND_DIR/cluster.yaml
VERSIONS_ENV=$KIND_DIR/versions.env
LABEL_CLUSTER=io.x-k8s.kind.cluster # set by kind on every node container (verified in kind v0.33.0)
LABEL_RUN=com.example.ci.run
LABEL_ATTEMPT=com.example.ci.attempt
NAME_MAX=50 # kind: the node hostname <cluster>-control-plane must stay within 64 characters
WAIT=${KIND_WAIT:-120s}

ENGINE=
CLUSTER=
KUBECONFIG_FILE=
LEFTOVERS=
REF_REPO=
REF_TAG=
REF_DIGEST=

log()  { printf '[kind] %s\n' "$*"; }
warn() { printf '[kind] warning: %s\n' "$*" >&2; }
die() {
  local code=$1
  shift
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then printf '::error title=kind.sh::%s\n' "$*" >&2; fi
  printf '[kind] error: %s\n' "$*" >&2
  exit "$code"
}
usage_error() {
  printf '[kind] error: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}
rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }
with_timeout() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"; else "$@"; fi
}
has_tool() { command -v "$1" >/dev/null 2>&1; }

# The pin of a tool in versions.env (KIND_VERSION, ...), for messages.
pinned_version() {
  local value
  value=$(sed -n "s/^$1=\\([^[:space:]#]*\\).*/\\1/p" "$VERSIONS_ENV" 2>/dev/null | tail -n 1)
  printf '%s' "${value:-(see test-infra/kind/versions.env)}"
}

# --- arguments ---------------------------------------------------------------------------------------

init_run_identity() {
  CI_RUN_ID=${CI_RUN_ID:-${GITHUB_RUN_ID:-local}}
  CI_RUN_ATTEMPT=${CI_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-0}}
  # Both become Kubernetes label values on the nodes.
  local re='^[A-Za-z0-9]([A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$'
  [[ $CI_RUN_ID =~ $re && $CI_RUN_ATTEMPT =~ $re ]] \
    || usage_error "CI_RUN_ID / CI_RUN_ATTEMPT must be Kubernetes label values (got '$CI_RUN_ID' / '$CI_RUN_ATTEMPT')"
  export CI_RUN_ID CI_RUN_ATTEMPT
}

in_ci() { [[ $CI_RUN_ID != local ]]; }

# D10 §6.1: ci-<run_id>-<attempt> in CI, local-kind on a laptop; KIND_CLUSTER_NAME (or --name) wins.
resolve_cluster() {
  if [[ -n ${KIND_CLUSTER_NAME:-} ]]; then
    CLUSTER=$KIND_CLUSTER_NAME
  elif in_ci; then
    CLUSTER=ci-$CI_RUN_ID-$CI_RUN_ATTEMPT
  else
    CLUSTER=local-kind
  fi
  local re='^[a-z0-9][a-z0-9.-]*$'
  [[ $CLUSTER =~ $re ]] \
    || usage_error "'$CLUSTER' is not a valid kind cluster name (lower-case letters, digits, '.' and '-', starting with a letter or digit)"
  [[ ${#CLUSTER} -le $NAME_MAX ]] || usage_error "cluster name '$CLUSTER' is longer than $NAME_MAX characters (kind's limit)"
  KUBECONFIG_FILE=$STATE_DIR/$CLUSTER.kubeconfig
}

validate_wait() {
  local re='^([0-9]+(ms|s|m|h))+$'
  [[ $WAIT =~ $re ]] || usage_error "KIND_WAIT '$WAIT' is not a duration such as 120s or 2m"
}

validate_tag() {
  local re='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
  [[ $1 =~ $re ]] || usage_error "$2: '$1' is not a valid image tag"
}

# Splits <repo>[:<tag>][@sha256:<digest>] into REF_REPO, REF_TAG, REF_DIGEST (a ':' after the last '/'
# is a tag; one before it is a registry port).
split_ref() {
  local name=$1 last
  REF_DIGEST=''
  if [[ $name == *@* ]]; then
    REF_DIGEST=${name#*@}
    name=${name%%@*}
  fi
  last=${name##*/}
  if [[ $last == *:* ]]; then
    REF_TAG=${last##*:}
    REF_REPO=${name%:*}
  else
    REF_TAG=''
    REF_REPO=$name
  fi
}

validate_ref() {
  local ref=$1 repo_re='^[a-z0-9]([a-z0-9._/:-]*[a-z0-9])?$' digest_re='^sha256:[0-9a-f]{64}$'
  [[ $ref != *[[:space:]]* && -n $ref ]] || usage_error "load: empty or blank image reference"
  split_ref "$ref"
  [[ $REF_REPO =~ $repo_re && $REF_REPO != *//* ]] || usage_error "load: '$ref' does not name an image repository"
  [[ -z $REF_DIGEST || $REF_DIGEST =~ $digest_re ]] || usage_error "load: '$ref' has a malformed digest (expected @sha256:<64 hex>)"
  if [[ -n $REF_TAG ]]; then validate_tag "$REF_TAG" "load: the tag of '$ref'"; fi
  [[ -n $REF_TAG || -n $REF_DIGEST ]] || usage_error "load: '$ref' has neither a tag nor a digest"
}

# --- engine and tools --------------------------------------------------------------------------------

detect_engine() {
  local provider=${KIND_EXPERIMENTAL_PROVIDER:-}
  if [[ -n $provider ]]; then
    case $provider in
      docker | podman) ENGINE=$provider ;;
      *) die 5 "KIND_EXPERIMENTAL_PROVIDER='$provider' is not supported here (docker or podman)." ;;
    esac
  elif has_tool docker; then
    ENGINE=docker
  elif has_tool podman; then
    ENGINE=podman
    export KIND_EXPERIMENTAL_PROVIDER=podman
  else
    die 5 "no container engine found: kind needs Docker, or Podman with KIND_EXPERIMENTAL_PROVIDER=podman."
  fi
  has_tool "$ENGINE" || die 5 "container engine '$ENGINE' (KIND_EXPERIMENTAL_PROVIDER) is not on PATH."
  with_timeout 30 "$ENGINE" info >/dev/null 2>&1 \
    || die 5 "cannot reach the $ENGINE engine ('$ENGINE info' failed). Start Docker, or for Podman run 'podman machine start'."
}

require_tool() {
  local tool=$1 key
  has_tool "$tool" && return 0
  key=$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')_VERSION
  die 5 "'$tool' is not on PATH. Install $tool $(pinned_version "$key") (test-infra/kind/versions.env; in CI .github/actions/setup-kube-tools does it)."
}

# The deployment test is proven with the pinned kind and its default node image; another kind works
# but brings another Kubernetes version.
check_kind_version() {
  local have want
  want=$(pinned_version KIND_VERSION)
  have=$(kind version 2>/dev/null | awk '{ print $2; exit }') || have=''
  if [[ -n $have && $have != "$want" ]]; then
    warn "kind $have found; this repository pins $want (test-infra/kind/versions.env), whose default node image CI uses"
  fi
}

cluster_exists() {
  local name
  while IFS= read -r name; do
    if [[ $name == "$CLUSTER" ]]; then return 0; fi
  done < <(kind get clusters 2>/dev/null || true)
  return 1
}

kctl() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }

export_github_env() {
  [[ -n ${GITHUB_ENV:-} ]] || return 0
  printf 'KIND_CLUSTER_NAME=%s\nKUBECONFIG=%s\n' "$CLUSTER" "$KUBECONFIG_FILE" >>"$GITHUB_ENV"
}

write_output() {
  [[ -n ${GITHUB_OUTPUT:-} ]] || return 0
  printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
}

# --- leftovers ---------------------------------------------------------------------------------------

kind_network() { printf '%s' "${KIND_EXPERIMENTAL_DOCKER_NETWORK:-kind}"; }

# In CI the shared bridge network is ours alone (ephemeral runner, one cluster per job); kind leaves it
# behind because it carries no cluster label. Idle = no kind node container of any cluster is left.
idle_kind_network() {
  local nodes
  nodes=$("$ENGINE" ps -aq --filter "label=$LABEL_CLUSTER" 2>/dev/null) || return 1
  [[ -z $nodes ]] || return 1
  "$ENGINE" network inspect "$(kind_network)" >/dev/null 2>&1
}

prune_by_label() {
  local filter="label=$LABEL_CLUSTER=$CLUSTER" ids
  ids=$("$ENGINE" ps -aq --filter "$filter" 2>/dev/null || true)
  if [[ -n $ids ]]; then
    log "removing node containers with $filter"
    # shellcheck disable=SC2086 # one argument per id
    "$ENGINE" rm -f -v $ids >/dev/null || warn "could not remove every container with $filter"
  fi
  ids=$("$ENGINE" volume ls -q --filter "$filter" 2>/dev/null || true)
  if [[ -n $ids ]]; then
    log "removing volumes with $filter"
    # shellcheck disable=SC2086
    "$ENGINE" volume rm -f $ids >/dev/null || warn "could not remove every volume with $filter"
  fi
  ids=$("$ENGINE" network ls -q --filter "$filter" 2>/dev/null || true)
  if [[ -n $ids ]]; then
    log "removing networks with $filter"
    # shellcheck disable=SC2086
    "$ENGINE" network rm $ids >/dev/null || warn "could not remove every network with $filter"
  fi
}

# Sets LEFTOVERS to one line per resource of this cluster that still exists: "<kind> <id or name> [details]".
# A failing engine query is an error, never "nothing found".
collect_leftovers() {
  local filter="label=$LABEL_CLUSTER=$CLUSTER" out lines=''
  if has_tool kind && cluster_exists; then lines+="cluster $CLUSTER"$'\n'; fi
  out=$("$ENGINE" ps -a --filter "$filter" --format 'container {{.ID}} {{.Names}} ({{.Status}})') \
    || die 1 "cannot list containers ('$ENGINE ps' failed)"
  if [[ -n $out ]]; then lines+=$out$'\n'; fi
  out=$("$ENGINE" volume ls --filter "$filter" --format 'volume {{.Name}}') \
    || die 1 "cannot list volumes ('$ENGINE volume ls' failed)"
  if [[ -n $out ]]; then lines+=$out$'\n'; fi
  out=$("$ENGINE" network ls --filter "$filter" --format 'network {{.ID}} {{.Name}}') \
    || die 1 "cannot list networks ('$ENGINE network ls' failed)"
  if [[ -n $out ]]; then lines+=$out$'\n'; fi
  if in_ci && idle_kind_network; then lines+="network $(kind_network) (shared kind network, idle)"$'\n'; fi
  LEFTOVERS=$(printf '%s' "$lines" | sed '/^$/d' | sort -u)
}

# --- commands ----------------------------------------------------------------------------------------

cmd_up() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --name)
        [[ $# -ge 2 ]] || usage_error "up: --name needs a cluster name"
        KIND_CLUSTER_NAME=$2
        shift 2
        ;;
      --name=*) KIND_CLUSTER_NAME=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "up: unknown argument '$1'" ;;
    esac
  done
  init_run_identity
  resolve_cluster
  validate_wait
  [[ -f $CLUSTER_CONFIG ]] || die 1 "up: $(rel "$CLUSTER_CONFIG") is missing"
  detect_engine
  require_tool kind
  require_tool kubectl
  check_kind_version

  (umask 077 && mkdir -p "$STATE_DIR")
  export KUBECONFIG=$KUBECONFIG_FILE
  export_github_env
  if cluster_exists; then
    log "up: cluster $CLUSTER exists; reusing it"
    (umask 077 && kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG_FILE") \
      || die 1 "up: kind export kubeconfig failed for $CLUSTER"
  else
    local args=(create cluster --name "$CLUSTER" --config "$CLUSTER_CONFIG" --wait "$WAIT" --kubeconfig "$KUBECONFIG_FILE")
    local node_image='the default of this kind release'
    if [[ -n ${KIND_NODE_IMAGE:-} ]]; then
      args+=(--image "$KIND_NODE_IMAGE")
      node_image=$KIND_NODE_IMAGE
    fi
    log "up: creating cluster $CLUSTER ($(rel "$CLUSTER_CONFIG"), node image: $node_image, --wait $WAIT)"
    (umask 077 && kind "${args[@]}") \
      || die 1 "up: kind create cluster failed for $CLUSTER (tear down with: test-infra/kind/kind.sh down)"
  fi
  chmod 600 "$KUBECONFIG_FILE" 2>/dev/null || true

  kctl label nodes --all --overwrite "$LABEL_RUN=$CI_RUN_ID" "$LABEL_ATTEMPT=$CI_RUN_ATTEMPT" >/dev/null \
    || die 1 "up: labelling the nodes of $CLUSTER failed"
  # --wait covers the control plane; the smoke test also needs service DNS.
  kctl -n kube-system rollout status deployment/coredns --timeout="$WAIT" >/dev/null \
    || die 1 "up: cluster DNS (deployment coredns) of $CLUSTER did not become ready within $WAIT"
  kctl get nodes -o wide || true

  log "up: cluster $CLUSTER is ready (context kind-$CLUSTER)"
  log "  kubeconfig: $(rel "$KUBECONFIG_FILE")   export KUBECONFIG=$KUBECONFIG_FILE"
}

cmd_load() {
  local tag='' refs=() ref
  while [[ $# -gt 0 ]]; do
    case $1 in
      --name)
        [[ $# -ge 2 ]] || usage_error "load: --name needs a cluster name"
        KIND_CLUSTER_NAME=$2
        shift 2
        ;;
      --name=*) KIND_CLUSTER_NAME=${1#*=}; shift ;;
      --tag)
        [[ $# -ge 2 ]] || usage_error "load: --tag needs a tag"
        tag=$2
        shift 2
        ;;
      --tag=*) tag=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) usage_error "load: unknown option '$1'" ;;
      *) refs+=("$1"); shift ;;
    esac
  done
  [[ ${#refs[@]} -gt 0 ]] || usage_error "load: at least one image reference is required"
  if [[ -n $tag ]]; then validate_tag "$tag" "load: --tag"; fi
  for ref in "${refs[@]}"; do
    validate_ref "$ref"
    if [[ -z $REF_TAG && -z $tag ]]; then
      usage_error "load: '$ref' has a digest but no tag; pass --tag <tag> (the chart renders <image.repository>:<image.tag>)"
    fi
  done
  init_run_identity
  resolve_cluster
  detect_engine
  require_tool kind
  cluster_exists || die 1 "load: there is no kind cluster named $CLUSTER (run test-infra/kind/kind.sh up first)"

  local names=() source target id
  for ref in "${refs[@]}"; do
    split_ref "$ref"
    target=$REF_REPO:${tag:-$REF_TAG}
    if [[ -n $REF_DIGEST ]]; then source=$REF_REPO@$REF_DIGEST; else source=$REF_REPO:$REF_TAG; fi
    if ! "$ENGINE" image inspect "$source" >/dev/null 2>&1; then
      log "load: pulling $source"
      "$ENGINE" pull --quiet "$source" >/dev/null \
        || die 1 "load: pulling $source failed (is the registry login done, and does the image exist?)"
    fi
    if [[ $source != "$target" ]]; then
      # By image ID: the content the digest names, whatever else carries the tag locally.
      id=$("$ENGINE" image inspect --format '{{.Id}}' "$source") || die 1 "load: cannot inspect $source"
      "$ENGINE" tag "$id" "$target" || die 1 "load: tagging $source as $target failed"
    fi
    log "load: $target <- $source"
    names+=("$target")
  done

  if [[ $ENGINE == docker ]]; then
    kind load docker-image --name "$CLUSTER" "${names[@]}" || die 1 "load: kind load docker-image failed"
  else
    # kind load docker-image shells out to `docker`; an archive works with any engine.
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/kind-load.XXXXXX")
    if ! "$ENGINE" save -o "$tmp/images.tar" "${names[@]}"; then
      rm -rf "$tmp"
      die 1 "load: $ENGINE save failed"
    fi
    if ! kind load image-archive --name "$CLUSTER" "$tmp/images.tar"; then
      rm -rf "$tmp"
      die 1 "load: kind load image-archive failed"
    fi
    rm -rf "$tmp"
  fi
  write_output loaded "${names[*]}"
  log "load: on every node of $CLUSTER: ${names[*]}"
}

cmd_diagnostics() {
  local dir=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --name)
        [[ $# -ge 2 ]] || usage_error "diagnostics: --name needs a cluster name"
        KIND_CLUSTER_NAME=$2
        shift 2
        ;;
      --name=*) KIND_CLUSTER_NAME=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) usage_error "diagnostics: unknown option '$1'" ;;
      *)
        [[ -z $dir ]] || usage_error "diagnostics: exactly one directory expected"
        dir=$1
        shift
        ;;
    esac
  done
  [[ -n $dir ]] || usage_error "diagnostics: <dir> is required"
  init_run_identity
  resolve_cluster
  detect_engine
  require_tool kubectl
  mkdir -p "$dir"
  log "diagnostics for kind cluster $CLUSTER into $dir"

  "$ENGINE" ps -a --filter "label=$LABEL_CLUSTER=$CLUSTER" >"$dir/node-containers.txt" 2>&1 || true
  if has_tool kind; then
    if ! cluster_exists; then
      printf 'There is no kind cluster named %s.\n' "$CLUSTER" >"$dir/cluster-missing.txt"
      log "diagnostics: no cluster named $CLUSTER; wrote $(cd "$dir" && printf '%s ' *)"
      return 0
    fi
    # The kubeconfig may be gone (a laptop); kind can always write it again.
    if [[ ! -s $KUBECONFIG_FILE ]]; then
      (umask 077 && mkdir -p "$STATE_DIR" && kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG_FILE") >/dev/null 2>&1 || true
    fi
  fi
  local kd=(kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=30s)

  { "${kd[@]}" get nodes -o wide; echo; "${kd[@]}" describe nodes; } >"$dir/nodes.txt" 2>&1 || true
  "${kd[@]}" get all,events -A -o wide >"$dir/get-all.txt" 2>&1 || true
  "${kd[@]}" get events -A --sort-by=.lastTimestamp >"$dir/events.txt" 2>&1 || true

  # Every pod that is not ready: describe. Pods outside the kind system namespaces, and every unhealthy
  # pod: logs of all containers, plus the previous instance after a restart.
  local ns pod phase ready file unhealthy
  while read -r ns pod phase ready; do
    [[ -n ${pod:-} ]] || continue
    file=$ns.$pod
    unhealthy=false
    if [[ $phase != Succeeded ]] && [[ $phase != Running || $ready == *false* || $ready == '<none>' ]]; then
      unhealthy=true
      "${kd[@]}" -n "$ns" describe pod "$pod" >"$dir/describe-$file.txt" 2>&1 || true
    fi
    if $unhealthy || [[ $ns != kube-system && $ns != local-path-storage ]]; then
      "${kd[@]}" -n "$ns" logs "$pod" --all-containers --timestamps --prefix >"$dir/logs-$file.log" 2>&1 || true
      if ! "${kd[@]}" -n "$ns" logs "$pod" --all-containers --timestamps --prefix --previous \
        >"$dir/logs-$file.previous.log" 2>/dev/null; then
        rm -f "$dir/logs-$file.previous.log"
      fi
    fi
  done < <("${kd[@]}" get pods -A --no-headers \
    -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready' \
    2>/dev/null || true)

  if has_tool helm; then
    # Helm 4 has no --all; these flags list every release that is not superseded (Helm 3 has them too).
    local states=(--deployed --failed --pending --uninstalling) release rns
    helm list -A "${states[@]}" --kubeconfig "$KUBECONFIG_FILE" >"$dir/helm-list.txt" 2>&1 || true
    while read -r release rns _; do
      [[ -n ${rns:-} ]] || continue
      {
        printf '# helm history %s -n %s\n' "$release" "$rns"
        helm history "$release" -n "$rns" --kubeconfig "$KUBECONFIG_FILE" 2>&1 || true
        printf '\n# helm status %s -n %s\n' "$release" "$rns"
        helm status "$release" -n "$rns" --kubeconfig "$KUBECONFIG_FILE" 2>&1 || true
      } >"$dir/helm-$rns.$release.txt"
    done < <(helm list -A "${states[@]}" --no-headers --kubeconfig "$KUBECONFIG_FILE" 2>/dev/null || true)
  else
    printf 'helm is not on PATH\n' >"$dir/helm-list.txt"
  fi
  if has_tool kind; then
    # Node journal, kubelet, containerd and container logs.
    with_timeout 120 kind export logs "$dir/kind-export" --name "$CLUSTER" >/dev/null 2>&1 \
      || warn "kind export logs failed; the kubectl view above is all there is"
  fi
  log "diagnostics: wrote $(cd "$dir" && printf '%s ' *)"
}

cmd_down() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --name)
        [[ $# -ge 2 ]] || usage_error "down: --name needs a cluster name"
        KIND_CLUSTER_NAME=$2
        shift 2
        ;;
      --name=*) KIND_CLUSTER_NAME=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "down: unknown argument '$1'" ;;
    esac
  done
  init_run_identity
  resolve_cluster
  detect_engine

  if has_tool kind; then
    log "down: kind delete cluster --name $CLUSTER"
    # Idempotent: a cluster that is already gone is a success. The kubeconfig given is the only file
    # kind edits (never ~/.kube/config).
    with_timeout 300 kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG_FILE" \
      || warn "kind delete cluster failed; removing what carries $LABEL_CLUSTER=$CLUSTER instead"
  else
    warn "kind is not on PATH; removing what carries $LABEL_CLUSTER=$CLUSTER with $ENGINE"
  fi
  prune_by_label
  if in_ci && idle_kind_network; then
    if "$ENGINE" network rm "$(kind_network)" >/dev/null 2>&1; then
      log "down: removed the idle shared network '$(kind_network)'"
    else
      warn "could not remove the shared network '$(kind_network)'"
    fi
  fi
  rm -f "$KUBECONFIG_FILE" "$KUBECONFIG_FILE.lock"

  collect_leftovers
  if [[ -n $LEFTOVERS ]]; then
    printf '%s\n' "$LEFTOVERS" >&2
    die 1 "down: resources of kind cluster $CLUSTER remain"
  fi
  log "down: nothing of kind cluster $CLUSTER remains"
}

cmd_leak_check() {
  local warn_only=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --warn-only) warn_only=true; shift ;;
      --name)
        [[ $# -ge 2 ]] || usage_error "leak-check: --name needs a cluster name"
        KIND_CLUSTER_NAME=$2
        shift 2
        ;;
      --name=*) KIND_CLUSTER_NAME=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "leak-check: unknown argument '$1'" ;;
    esac
  done
  init_run_identity
  resolve_cluster
  detect_engine

  local what="kind cluster $CLUSTER ($LABEL_CLUSTER=$CLUSTER)"
  collect_leftovers
  if [[ -z $LEFTOVERS ]]; then
    log "leak-check: nothing of $what remains"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
      # shellcheck disable=SC2016 # Markdown backticks
      printf '### Leak check (kind): clean\n\nNo cluster, container, volume or network of `%s` remains.\n' "$CLUSTER" >>"$GITHUB_STEP_SUMMARY"
    fi
    return 0
  fi
  local count
  count=$(printf '%s\n' "$LEFTOVERS" | wc -l | tr -d ' ')
  printf '[kind] leak-check: %s resource(s) of %s remain:\n' "$count" "$what" >&2
  printf '%s\n' "$LEFTOVERS" | sed 's/^/  /' >&2
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
      # shellcheck disable=SC2016 # Markdown backticks
      printf '### Leak check (kind): %s resource(s) left\n\nCluster `%s`\n\n| Kind | Resource |\n|---|---|\n' "$count" "$CLUSTER"
      # shellcheck disable=SC2016
      printf '%s\n' "$LEFTOVERS" | sed -E 's/^([a-z]+) (.*)$/| \1 | `\2` |/'
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  if $warn_only; then
    if [[ ${GITHUB_ACTIONS:-} == true ]]; then printf '::warning title=leak-check::%s resource(s) of %s remain\n' "$count" "$what"; fi
    log "leak-check: --warn-only, not failing"
    return 0
  fi
  die 1 "leak-check: $count resource(s) of $what remain"
}

main() {
  [[ $# -gt 0 ]] || usage_error "missing command"
  local command=$1
  shift
  case $command in
    up) cmd_up "$@" ;;
    load) cmd_load "$@" ;;
    diagnostics) cmd_diagnostics "$@" ;;
    down) cmd_down "$@" ;;
    leak-check) cmd_leak_check "$@" ;;
    -h | --help | help) usage ;;
    *) usage_error "unknown command '$command'" ;;
  esac
}

main "$@"
