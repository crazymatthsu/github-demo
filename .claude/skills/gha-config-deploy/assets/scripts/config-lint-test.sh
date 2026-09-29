#!/usr/bin/env bash
# config-lint-test.sh — plain-bash test of config_lint.py on fixture trees built here, never copied from a live
# config/: one good tree that passes, then broken variants for every rule family of checks 1 to 6 and 9 to 12,
# the repository config (allow-lists, runtimes helm only / compose only / per env, app_config false, inventory
# '', checks.skip, allow-lists for variables and keys), the renderings through stubs (a Helm adapter, kubeconform
# and docker that record their arguments; no helm, cluster or daemon), the report, usage and exit codes. The
# whole suite runs once per YAML reader: PyYAML when importable, and mikefarah yq v4 with PyYAML blocked.
# Part of the gha-config-deploy skill.
#
# Usage: config-lint-test.sh [--help] [<path to config_lint.py>]
#   Default: config_lint.py next to this file, else ../ci/config_lint.py (scripts in scripts/ci/, their tests in
#   scripts/test/, where the lint job runs scripts/test/*-test.sh).
#   Needs python3 (3.8+) and PyYAML or mikefarah yq v4 (as `yq`, or YQ=<path>); each reader found runs the suite.
# Exit codes: 0 every case passed · 1 a case failed · 2 usage · 5 a tool is missing
set -euo pipefail

case "${1:-}" in
  -h | --help)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 0
    ;;
esac
[ $# -le 1 ] || { echo "usage: $0 [<path to config_lint.py>]" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
if [ $# -eq 1 ]; then
  SUT=$1
elif [ -f "$HERE/config_lint.py" ]; then
  SUT=$HERE/config_lint.py
else
  SUT=$HERE/../ci/config_lint.py
fi
[ -f "$SUT" ] || { echo "config-lint-test: $SUT not found (pass its path)" >&2; exit 2; }
SUT=$(cd "$(dirname "$SUT")" && pwd)/$(basename "$SUT")
EXAMPLE=$HERE/../config-lint.example.yml # in the skill's layout only
command -v python3 >/dev/null 2>&1 || { echo "config-lint-test: python3 is needed" >&2; exit 5; }
YQ_BIN=${YQ:-yq}
READERS=()
if python3 -c 'import yaml' 2>/dev/null; then READERS+=(PyYAML); fi
if "$YQ_BIN" --version 2>/dev/null | grep -q mikefarah; then READERS+=(yq); fi
[ "${#READERS[@]}" -gt 0 ] || { echo "config-lint-test: needs PyYAML or mikefarah yq v4 (YQ)" >&2; exit 5; }
# The cases set what they test: CI=true (set on every CI runner) turns missing tools into errors.
unset CI STUB_EXIT STUB_FAIL_INSTANCE STUB_FAIL_MODE STUB_KC_INVALID || true

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P) # the linter resolves its root: compare like with like (macOS /tmp is a link)
T=$WORK/repo # the fixture repository; not a git repository, --root points at it
D1=sha256:$(printf 'a%.0s' $(seq 64))
mkdir -p "$WORK/stubs" "$WORK/bin" "$WORK/no-pyyaml"
echo 'raise ImportError("PyYAML blocked by config-lint-test.sh")' >"$WORK/no-pyyaml/yaml.py"
export STUB_LOG_DIR=$WORK DOCKER_BIN=$WORK/bin/docker KUBECONFORM_BIN=$WORK/bin/kubeconform

# --- stubs: they record their arguments under $WORK and answer like the real tools -------------------------------
cat >"$WORK/stubs/helm-deploy-instance.sh" <<'STUB'
#!/usr/bin/env bash
# helm-deploy-instance.sh <env> <flow> <app> <instance> --mode lint|template [--render-out <file>], stubbed
printf 'adapter %s chart=%s config=%s\n' "$*" "${HELM_CHART_DIR:-}" "${HELM_CONFIG_DIR:-}" >>"$STUB_LOG_DIR/adapter.log"
instance=$4 mode='' out=''
shift 4
while [ $# -gt 0 ]; do
  case $1 in --mode) mode=$2; shift ;; --render-out) out=$2; shift ;; esac
  shift
done
if [ -n "${STUB_EXIT:-}" ]; then echo "helm-release: error: helm not found (helm)" >&2; exit "$STUB_EXIT"; fi
if [ "$instance" = "${STUB_FAIL_INSTANCE:-}" ] && [ "$mode" = "${STUB_FAIL_MODE:-lint}" ]; then
  echo "helm-release: helm $mode (stub)" >&2
  echo "Error: execution error at (api/templates/deployment.yaml:3:4): identity.instance must equal env.APP_INSTANCE" >&2
  echo "helm-release: error: helm $mode failed" >&2
  exit 1
fi
if [ "$mode" = template ]; then
  mkdir -p "$(dirname "$out")"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n' "$instance" >"$out"
fi
STUB
cat >"$WORK/bin/kubeconform" <<'STUB'
#!/usr/bin/env bash
# kubeconform -output json, stubbed: every file is valid but one whose path contains $STUB_KC_INVALID
printf 'kubeconform %s\n' "$*" >>"$STUB_LOG_DIR/kubeconform.log"
files=0 invalid=''
for arg in "$@"; do
  case $arg in *.yaml) files=$((files + 1)) ;; esac
  case $arg in *"${STUB_KC_INVALID:-no invalid file}"*) invalid=$arg ;; esac
done
if [ -n "$invalid" ]; then
  printf '{"resources": [{"filename": "%s", "kind": "Deployment", "name": "api-refunds", ' "$invalid"
  printf '"status": "statusInvalid", "msg": "problem validating schema", "validationErrors": '
  printf '[{"path": "/spec/replicas", "msg": "got string, want null or integer"}]}], '
  printf '"summary": {"valid": %d, "invalid": 1, "errors": 0, "skipped": 0}}\n' "$((files - 1))"
  exit 1
fi
printf '{"resources": [], "summary": {"valid": %d, "invalid": 0, "errors": 0, "skipped": 0}}\n' "$files"
STUB
cat >"$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
# docker compose, stubbed; runs with the linter's reduced environment, so it finds its files next to itself
dir=$(cd "$(dirname "$0")/.." && pwd)
if [ "$1 $2" = "compose version" ]; then echo "Docker Compose version v2.99.9-stub"; exit 0; fi
printf 'docker %s SPRING_DATASOURCE_PASSWORD=%s CONFIG_DIR=%s IMAGE_TAG=%s\n' "$*" \
  "${SPRING_DATASOURCE_PASSWORD:-unset}" "${CONFIG_DIR:-unset}" "${IMAGE_TAG:-unset}" >>"$dir/docker.log"
if [ -f "$dir/docker.fail" ] && [ "$3" = "$(cat "$dir/docker.fail")" ]; then
  echo "error while interpolating services.api.image: required variable IMAGE_REPO is missing a value" >&2
  exit 15
fi
STUB
chmod +x "$WORK/stubs/helm-deploy-instance.sh" "$WORK/bin/kubeconform" "$WORK/bin/docker"

# --- fixtures ---------------------------------------------------------------------------------------------------
put() { # put <file> <line>...: the file's content, under $T
  local file=$T/$1
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" >"$file"
}
append() { # append <file> <line>...
  local file=$T/$1
  shift
  printf '%s\n' "$@" >>"$file"
}
edit() { # edit <file> <sed script>: in place, without sed -i (GNU and BSD differ)
  sed "$2" "$T/$1" >"$T/$1.new"
  mv "$T/$1.new" "$T/$1"
}
config() { append .github/config-lint.yml "$@"; } # config <line>...: more keys of the linter's config
values() {                                           # values <env> <instance> <tag> [<digest>]
  put "config/$1/payments/api/$2/values.yaml" "image:" "  tag: \"$3\"" ${4:+"  digest: $4"} \
    "identity:" "  env: $1" "  flow: payments" "  app: api" "  instance: $2" \
    "env:" "  APP_ENV: $1" "  APP_FLOW: payments" "  APP_NAME: api" "  APP_INSTANCE: $2" \
    "  JAVA_OPTS: \"-XX:MaxRAMPercentage=75\""
}
instance() { # instance <env> <instance> <tag> <host port> [<digest>]: application.yml, values.yaml, compose.env
  put "config/$1/payments/api/$2/application.yml" "app:" "  source:" "    table: public.$2"
  values "$1" "$2" "$3" "${5:-}"
  put "config/$1/payments/api/$2/compose.env" "# compose variables of $1/payments/api/$2" \
    "IMAGE_REPO=ghcr.io/acme" "IMAGE_TAG=$3" "APP_ENV=$1" "APP_FLOW=payments" "APP_NAME=api" "APP_INSTANCE=$2" \
    "JAVA_OPTS=\"-XX:MaxRAMPercentage=75\" # quoted, then a comment: compose reads the value only" "TZ=UTC" \
    "HTTP_HOST_PORT=$4" "MEM_LIMIT=1g"
}
inventory() { # inventory <kind of ledger> [pool|nopool]: config/dev/payments/workflows-config.yml
  put config/dev/payments/workflows-config.yml "env: dev" "flow: payments"
  if [ "${2:-pool}" = pool ]; then
    append config/dev/payments/workflows-config.yml "pool:" "  hosts:" "    - box-1.example.com" \
      "    - box-2.example.com" "  user: deploy" "  root: /opt/platform"
  fi
  append config/dev/payments/workflows-config.yml "defaults:" "  kind: helm" "  cluster: dev-cluster" \
    "  namespace: payments" "targets:" "  - instance: api/ledger" "    kind: $1" "  - instance: api/refunds"
}
fixture() { # the good tree: dev (inventory with a pool; ledger on compose, refunds on helm) and prod (pinned)
  rm -rf "$T"
  put .github/config-lint.yml "# the linter's config for this fixture" "envs: [local, dev, prod]" "flows: [payments]" \
    "compose_file: deploy/compose/{app}/docker-compose.yml" "helm_deploy_script: stubs/helm-deploy-instance.sh"
  put deploy/helm/api/Chart.yaml "apiVersion: v2" "name: api" "version: 0.1.0"
  put deploy/compose/api/docker-compose.yml "services:" "  api:" "    image: \${IMAGE_REPO}/api:\${IMAGE_TAG}" \
    "    environment:" "      SPRING_DATASOURCE_PASSWORD: \${SPRING_DATASOURCE_PASSWORD:?set it in the shell}" \
    "    volumes:" "      - \${CONFIG_DIR:?}:/config/instance:ro"
  mkdir -p "$T/stubs"
  cp "$WORK/stubs/helm-deploy-instance.sh" "$T/stubs/"
  put config/README.md "# config" "The deployment record: one directory per instance."
  put config/_common/api/application.yml "app:" "  source:" "    poll-interval: 15s"
  put config/dev/_common/application.yml "logging:" "  format: json"
  put config/dev/known_hosts "# ssh-keyscan -t ed25519 box-1.example.com box-2.example.com" \
    "box-1.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample" \
    "box-2.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExamplf"
  inventory compose
  local env
  for env in dev prod; do
    put "config/$env/payments/api/app-common/application.yml" "app:" "  sink:" "    topic: payments.$env"
    put "config/$env/payments/api/app-common/values.yaml" "resources:" "  limits:" "    memory: 1Gi" "env:" "  TZ: UTC"
  done
  instance dev ledger 0.2.0-rc.1 18081
  instance dev refunds 0.2.0-rc.1 18082
  instance prod ledger 1.4.2 18081 "$D1"
  instance prod refunds "" 18082 # never deployed to prod yet: a WARN
}

# --- harness ----------------------------------------------------------------------------------------------------
FAILED=0 PASSED=0 RC=0 READER=''
pass() { PASSED=$((PASSED + 1)); printf 'ok   [%s] %s\n' "$READER" "$1"; }
fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL [%s] %s: %s\n' "$READER" "$1" "$2"
  sed 's/^/     | /' "$WORK/out"
}
lint() { # lint [<option>...]: the linter on $T; RC and $WORK/out
  RC=0
  rm -f "$WORK/adapter.log" "$WORK/kubeconform.log" "$WORK/docker.log"
  touch "$WORK/adapter.log" "$WORK/kubeconform.log" "$WORK/docker.log"
  python3 "$SUT" --root "$T" --report build/config-lint.txt "$@" >"$WORK/out" 2>&1 || RC=$?
}
expect() { # expect <case> <exit code> [[!]<text>...]: the exit code, and each text in the output (!: absent)
  local name=$1 want=$2 text
  shift 2
  if [ "$RC" -ne "$want" ]; then fail "$name" "exit $RC, expected $want"; return 0; fi
  for text in "$@"; do
    case $text in
      '!'*) if grep -qF -- "${text#!}" "$WORK/out"; then fail "$name" "unexpected: ${text#!}"; return 0; fi ;;
      *) if ! grep -qF -- "$text" "$WORK/out"; then fail "$name" "missing: $text"; return 0; fi ;;
    esac
  done
  pass "$name"
}
logged() { # logged <case> <log> <text>...: every text in $WORK/<log>.log
  local name=$1 log=$WORK/$2.log text
  shift 2
  for text in "$@"; do
    if ! grep -qF -- "$text" "$log"; then fail "$name" "${log##*/} lacks: $text ($(cat "$log"))"; return 0; fi
  done
  pass "$name"
}

# --- the cases ----------------------------------------------------------------------------------------------------
suite() {
  local p=config/dev/payments/api # most cases break a dev instance
  local q=config/prod/payments/api

  # the good tree, rendered through the stubs
  fixture
  lint
  expect good-tree 0 '!ERROR' '!WARN check 4' "(YAML read with $READER)" \
    "WARN check 10  $q/refunds/values.yaml: prod records no release yet" \
    "TODO check 7  config: " "TODO check 8  config: " "TODO check 13  config: " \
    "INFO check 12  build/rendered: kubeconform: 4 valid, 0 invalid"
  logged renders-helm-through-the-adapter adapter \
    "adapter dev payments api refunds --mode lint chart=deploy/helm/{app} config=config" \
    "adapter prod payments api ledger --mode template --render-out $T/build/rendered/prod/payments/api/ledger.yaml"
  logged renders-kubeconform kubeconform "-strict -summary -output json" "$T/build/rendered/dev/payments/api/refunds.yaml"
  logged renders-compose-with-placeholders docker \
    "compose -p lint-dev-payments-api-ledger --env-file $T/$p/ledger/compose.env -f $T/deploy/compose/api/docker-compose.yml config --quiet SPRING_DATASOURCE_PASSWORD=lint-placeholder CONFIG_DIR=$T/$p/ledger"
  if cmp -s "$WORK/out" "$T/build/config-lint.txt"; then pass report-holds-the-output
  else fail report-holds-the-output "$(diff "$WORK/out" "$T/build/config-lint.txt" || true)"; fi
  if awk '/ check / { sub(/:$/, "", $4); print $4 }' "$WORK/out" | LC_ALL=C sort -c 2>/dev/null; then pass sorted-by-path
  else fail sorted-by-path "the findings are not sorted by path"; fi
  IMAGE_TAG=from-the-shell lint
  logged compose-ignores-the-shell docker "IMAGE_TAG=unset"

  # check 1: naming
  fixture
  mkdir -p "$T/config/staging" "$T/config/dev/Payments" "$T/$q/2" "$T/$q/ledger-db-to-the-central-warehouse-01"
  put config/notes.txt "stray"
  lint
  expect naming 1 "ERROR check 1  config/staging: env 'staging' is not allow-listed (envs: local, dev, prod)" \
    "ERROR check 1  config/dev/Payments: flow 'Payments' is not a lower-case kebab token" \
    "ERROR check 1  $q/2: instance '2' is a bare number" \
    "ERROR check 1  $q/ledger-db-to-the-central-warehouse-01: instance 'ledger-db-to-the-central-warehouse-01' is longer than 32" \
    "ERROR check 1  config/notes.txt: unexpected file at the top of the tree"

  # check 2: apps match deployables
  fixture
  put "config/prod/payments/web/app-common/application.yml" "app: {}"
  put deploy/helm/worker/Chart.yaml "apiVersion: v2" "name: worker" "version: 0.1.0"
  put config/_common/ghost/application.yml "app: {}"
  config "complete_envs: [prod]"
  lint --no-render
  expect deployables 1 "ERROR check 2  config/prod/payments/web: no chart for app 'web': deploy/helm/web/Chart.yaml" \
    "ERROR check 2  config/prod/payments/web: no compose file for app 'web': deploy/compose/web/docker-compose.yml" \
    "ERROR check 2  config/prod: app 'worker' has no directory in prod (complete_envs)" \
    "ERROR check 2  config/_common/ghost: a platform layer for 'ghost', which no env configures" \
    "WARN check 3  config/prod/payments/web: no instance"
  fixture
  config "apps: [worker]"
  lint --no-render
  expect apps-allow-list 1 "ERROR check 2  config/dev/payments/api: 'api' is not a deployable app (apps: worker)"

  # check 3: required, forbidden and misnamed files
  fixture
  rm "$T/$p/ledger/application.yml" "$T/$q/refunds/values.yaml" "$T/$p/refunds/compose.env"
  cp "$T/$p/ledger/compose.env" "$T/$p/app-common/compose.env"
  put "$p/ledger/.env" "DEBUG=1"
  put "$p/ledger/extra/logback.xml" "<configuration/>"
  mv "$T/$q/ledger/application.yml" "$T/$q/ledger/application.yaml"
  put config/dev/payments/notes.txt "stray"
  put config/dev/_common/values.yaml "replicas: 2"
  lint --no-render
  expect files 1 "ERROR check 3  $p/ledger: application.yml is missing" \
    "ERROR check 3  $q/refunds: values.yaml is missing" "ERROR check 3  $p/refunds: compose.env is missing" \
    "ERROR check 3  $p/app-common/compose.env: it belongs to an instance" \
    "ERROR check 3  $p/ledger/.env: no .env files" "ERROR check 3  $p/ledger/extra: layers are flat" \
    "ERROR check 3  $q/ledger/application.yaml: never read: name it application.yml" \
    "ERROR check 3  config/dev/payments/notes.txt: unexpected file" \
    "ERROR check 3  config/dev/_common/values.yaml: values.yaml belongs to app-common or an instance"
  fixture
  rm "$T/config/dev/payments/workflows-config.yml"
  put "$p/ledger/values.yaml" "image: [unclosed"
  lint --no-render
  expect files-yaml-and-inventory 1 "ERROR check 3  $p/ledger/values.yaml: does not parse" \
    "ERROR check 3  config/dev/payments: dev flow without workflows-config.yml"

  # check 4: identity
  fixture
  edit "$p/ledger/compose.env" 's/^APP_INSTANCE=ledger$/APP_INSTANCE=refunds/'
  edit "$p/refunds/values.yaml" 's/^  flow: payments$/  flow: orders/; /APP_FLOW/d'
  edit "$q/ledger/values.yaml" 's/^  tag: "1.4.2"$/  tag: "1.4.3"/'
  append "$q/app-common/values.yaml" "image:" "  tag: \"1.0.0\"" "identity:" "  env: prod"
  append "$p/ledger/values.yaml" "  SPRING_PROFILES_ACTIVE: cloud" "  IMAGE_TAG: \"1.0.0\""
  lint --no-render
  expect identity 1 "ERROR check 4  $p/ledger/compose.env: APP_INSTANCE is 'refunds', the path says 'ledger'" \
    "ERROR check 4  $p/refunds/values.yaml: identity.flow is 'orders', the path says 'payments'" \
    "ERROR check 4  $p/refunds/values.yaml: env.APP_FLOW is missing, the path says 'payments'" \
    "ERROR check 4  $q/ledger/values.yaml: image.tag is '1.4.3' but compose.env has IMAGE_TAG=1.4.2" \
    "ERROR check 4  $q/app-common/values.yaml: image.tag belongs to the instance" \
    "ERROR check 4  $q/app-common/values.yaml: identity belongs to the instance" \
    "ERROR check 4  $p/ledger/values.yaml: env.SPRING_PROFILES_ACTIVE: application config belongs in the YAML" \
    "ERROR check 4  $p/ledger/values.yaml: env.IMAGE_TAG: a compose knob"
  fixture
  edit "$p/ledger/compose.env" 's/^JAVA_OPTS=.*/JAVA_OPTS=-Xmx1g/'
  lint --no-render
  expect identity-renderings-disagree 0 "WARN check 4  $p/ledger/values.yaml: env.JAVA_OPTS is '-XX:MaxRAMPercentage=75' but compose.env has '-Xmx1g'"
  fixture
  put "$p/refunds/values.yaml" "image:" "  tag: \"0.2.0-rc.1\"" "identity: {env: dev, flow: payments, app: api, instance: refunds}" \
    "env:" "  - name: APP_ENV" "    value: dev"
  lint --no-render
  expect identity-env-list 1 "ERROR check 4  $p/refunds/values.yaml: env must be a map"

  # check 5: compose.env
  fixture
  # ledger: lines 1-11 from the fixture, minus IMAGE_REPO (line 2), then 11-17 appended here
  append "$p/ledger/compose.env" "SPRING_DATASOURCE_URL=jdbc:postgresql://db:5432/ledger" "FOO=1" "PROJECT=x" \
    "DB_PASSWORD=\${DB_PASSWORD}" "TZ=Europe/Paris" "export BAR=1" "ADMIN_HOST_PORT=80"
  edit "$p/ledger/compose.env" '/^IMAGE_REPO=/d'
  edit "$p/refunds/compose.env" 's/^HTTP_HOST_PORT=.*/HTTP_HOST_PORT=18081/'
  lint --no-render
  expect compose-env 1 "ERROR check 5  $p/ledger/compose.env: SPRING_DATASOURCE_URL: application config belongs" \
    "ERROR check 5  $p/ledger/compose.env: FOO: not allow-listed (compose_env_allow)" \
    "ERROR check 5  $p/ledger/compose.env: PROJECT: the compose wrapper sets it" \
    "ERROR check 5  $p/ledger/compose.env: DB_PASSWORD: looks like a secret" \
    "ERROR check 5  $p/ledger/compose.env: line 15: TZ is defined twice" \
    "ERROR check 5  $p/ledger/compose.env: line 16: not KEY=VALUE" \
    "ERROR check 5  $p/ledger/compose.env: ADMIN_HOST_PORT=80: a host port is a number in 1024-65535" \
    "ERROR check 5  $p/ledger/compose.env: IMAGE_REPO is missing" \
    "WARN check 5  $p/refunds/compose.env: HTTP_HOST_PORT=18081 is published by HTTP_HOST_PORT of $p/ledger/compose.env" \
    "!ERROR check 5  $p/refunds/compose.env"
  fixture
  append "$p/ledger/compose.env" "FEATURE_LEDGER_V2=true"
  config "compose_env_allow: ['FEATURE_*']"
  lint --no-render
  expect compose-env-allow-pattern 0 '!ERROR'

  # check 6: compose renders
  fixture
  echo lint-dev-payments-api-refunds >"$WORK/docker.fail"
  lint
  rm -f "$WORK/docker.fail"
  expect compose-render-fails 1 "ERROR check 6  $p/refunds/compose.env: docker compose config failed: error while interpolating" \
    "!ERROR check 6  $p/ledger"
  DOCKER_BIN=$WORK/no/docker lint
  expect compose-docker-missing-on-a-laptop 0 "WARN check 6  config: docker compose not found"
  CI=true DOCKER_BIN=$WORK/no/docker lint
  expect compose-docker-missing-in-ci 1 "ERROR check 6  config: docker compose not found"
  edit .github/config-lint.yml '/^compose_file:/d'
  lint
  expect compose-file-unset 0 "TODO check 6  config: compose renderings not checked: set compose_file"

  # check 9: secrets (built by concatenation, so that no scanner flags this file)
  fixture
  append "$p/ledger/application.yml" "  aws-key-id: AKIA""ABCDEFGHIJKLMNOP" "  db:" "    password: hunter""22" \
    "    url: postgres://app:s3cr""et@db:5432/ledger" "  oauth:" "    client-secret: \${OAUTH_CLIENT_SECRET}" \
    "  github: ghp_$(printf 'x%.0s' $(seq 36))" "  mssql: jdbc:sqlserver://db:1433;databaseName=x;password=abc"
  put "$p/ledger/client.pem" "-----BEGIN RSA ""PRIVATE KEY-----" "MIIEexample" "-----END RSA PRIVATE KEY-----"
  printf '\377\376\000binary' >"$T/$p/ledger/keystore.jks"
  lint --no-render # application.yml: lines 1-3 from the fixture, 4-11 appended here
  expect secrets 1 "ERROR check 9  $p/ledger/application.yml: line 4: looks like an AWS access key id" \
    "ERROR check 9  $p/ledger/application.yml: line 6: looks like a literal password" \
    "ERROR check 9  $p/ledger/application.yml: line 7: looks like credentials in a URL" \
    "ERROR check 9  $p/ledger/application.yml: line 10: looks like a GitHub token" \
    "ERROR check 9  $p/ledger/application.yml: line 11: looks like a password in a JDBC URL" \
    "ERROR check 9  $p/ledger/application.yml: key app.db.password names a secret" \
    "ERROR check 9  $p/ledger/application.yml: key app.oauth.client-secret names a secret" \
    "ERROR check 9  $p/ledger/client.pem: line 1: looks like a PEM private key" \
    "ERROR check 9  $p/ledger/keystore.jks: not UTF-8 text" \
    "!hunter22" "!s3cret"
  fixture
  append "$p/ledger/application.yml" "  cache:" "    token: warm-up" "  auth:" "    token-endpoint: https://id.example.com/token"
  lint --no-render
  expect secrets-key-rule 1 "ERROR check 9  $p/ledger/application.yml: key app.cache.token names a secret" \
    "!app.auth.token-endpoint"
  config "secret_keys_allow: [app.cache.token]"
  lint --no-render
  expect secrets-keys-allow 0 '!ERROR'

  # check 10: tag policy
  fixture
  values prod ledger latest "$D1"
  values prod refunds 1.4.2
  edit "$q/refunds/compose.env" 's/^IMAGE_TAG=.*/IMAGE_TAG=1.4.2/'
  edit "$q/ledger/compose.env" 's/^IMAGE_TAG=.*/IMAGE_TAG=1.4/'
  edit "$p/ledger/values.yaml" 's/^  tag: .*/  tag: 1.10/'
  values dev refunds "bad tag!" "sha256:abc"
  lint --no-render
  expect tags 1 "ERROR check 10  $q/ledger/values.yaml: prod pins a release X.Y.Z, not 'latest'" \
    "ERROR check 10  $q/refunds/values.yaml: prod pins the digest main tested next to 1.4.2" \
    "ERROR check 10  $q/ledger/compose.env: prod pins a release X.Y.Z, not '1.4'" \
    "ERROR check 10  $p/ledger/values.yaml: image.tag must be a quoted string, got 1.1" \
    "ERROR check 10  $p/refunds/values.yaml: image.digest must be sha256:<64 hex>, got 'sha256:abc'"
  fixture
  values dev refunds "bad tag!"
  edit "$p/ledger/values.yaml" '/^image:/d; /^  tag:/d'
  lint --no-render
  expect tags-invalid-and-missing 1 "ERROR check 10  $p/refunds/values.yaml: image.tag 'bad tag!' is not a valid image tag" \
    "ERROR check 10  $p/ledger/values.yaml: image.tag is missing"
  fixture
  values dev ledger main
  edit "$p/ledger/compose.env" 's/^IMAGE_TAG=.*/IMAGE_TAG=main/'
  edit "$q/ledger/compose.env" "s/^IMAGE_TAG=.*/IMAGE_TAG=1.4.2@$D1/"
  lint --no-render
  expect tags-floating-in-dev-and-compose-digest 0 '!ERROR'

  # check 11: the deploy inventory
  fixture
  put "$p/fees/application.yml" "app: {}"
  values dev fees 0.2.0-rc.1
  put "$p/fees/compose.env" "IMAGE_REPO=ghcr.io/acme" "IMAGE_TAG=0.2.0-rc.1" "APP_ENV=dev" "APP_FLOW=payments" \
    "APP_NAME=api" "APP_INSTANCE=fees" "JAVA_OPTS=-XX:MaxRAMPercentage=75" "HTTP_HOST_PORT=18083"
  put config/dev/payments/workflows-config.yml "env: dev" "flow: orders" "hosts: []" \
    "pool:" "  hosts: [box-1.example.com, box-2.example.com]" "  root: /opt/../etc" "defaults:" "  kind: helm" \
    "targets:" "  - instance: api/ledger" "    kind: compose" "    host: box-9.example.com" "  - instance: api/refunds" \
    "  - instance: api/gone" "  - instance: api/ledger" "    kind: compose" "    host: Box_1"
  put config/dev/workflows-config.yml "env: dev"
  append config/dev/known_hosts "not a keyscan line"
  put config/prod/payments/workflows-config.yml "env: prod" "flow: payments"
  lint --no-render
  expect inventory 1 "ERROR check 11  config/dev/payments/workflows-config.yml: instance api/fees has 0 targets, not one: deploy-dev would skip it" \
    "ERROR check 11  config/dev/payments/workflows-config.yml: targets[2]: payments/api/gone has no directory" \
    "ERROR check 11  config/dev/payments/workflows-config.yml: flow is 'orders', the path says 'payments'" \
    "ERROR check 11  config/dev/payments/workflows-config.yml: targets[1]: a helm target needs a cluster" \
    "ERROR check 11  config/dev/payments/workflows-config.yml: targets[0]: host box-9.example.com is not one of pool.hosts" \
    "ERROR check 11  config/dev/payments/workflows-config.yml: targets[3]: host 'Box_1' is not a lower-case DNS name" \
    "ERROR check 11  config/dev/payments/workflows-config.yml: instance api/ledger has 2 targets, not one" \
    "ERROR check 11  config/dev/payments/workflows-config.yml: unknown key 'hosts'" \
    "ERROR check 11  config/dev/payments/workflows-config.yml: pool.root '/opt/../etc' must be an absolute path" \
    "ERROR check 11  config/dev/workflows-config.yml: the inventory is per flow" \
    "ERROR check 11  config/dev/known_hosts: line 4: not an ssh-keyscan line" \
    "WARN check 11  config/prod/payments/workflows-config.yml: prod is not a dev env"

  # check 12: helm renders through the adapter, then kubeconform
  fixture
  STUB_FAIL_INSTANCE=refunds lint
  expect helm-lint-fails 1 "ERROR check 12  $p/refunds: helm lint failed: Error: execution error at (api/templates/deployment.yaml:3:4)" \
    "!ERROR check 12  $p/ledger"
  STUB_FAIL_INSTANCE=ledger STUB_FAIL_MODE=template lint
  expect helm-template-fails 1 "ERROR check 12  $q/ledger: helm template failed: Error: execution error"
  STUB_KC_INVALID=dev/payments/api/refunds.yaml lint
  expect kubeconform-invalid 1 "ERROR check 12  $p/refunds: kubeconform: Deployment api-refunds: /spec/replicas: got string, want null or integer"
  KUBECONFORM_BIN=$WORK/no/kubeconform lint
  expect kubeconform-missing-on-a-laptop 0 "WARN check 12  config: kubeconform not found"
  CI=true KUBECONFORM_BIN=$WORK/no/kubeconform lint
  expect kubeconform-missing-in-ci 1 "ERROR check 12  config: kubeconform not found"
  STUB_EXIT=5 lint
  expect helm-missing-on-a-laptop 0 "WARN check 12  config: the Helm adapter cannot run: helm-release: error: helm not found"
  CI=true STUB_EXIT=5 lint
  expect helm-missing-in-ci 1 "ERROR check 12  config: the Helm adapter cannot run"
  lint --no-render
  expect no-render 0 "INFO check 12  config: skipped (--no-render)" "INFO check 6  config: skipped (--no-render)"
  if [ -s "$WORK/adapter.log" ] || [ -s "$WORK/docker.log" ]; then fail no-render-runs-nothing "a renderer ran"
  else pass no-render-runs-nothing; fi
  edit .github/config-lint.yml 's#^helm_deploy_script: .*#helm_deploy_script: scripts/ci/nope.sh#'
  lint
  expect helm-adapter-missing 1 "ERROR check 12  scripts/ci/nope.sh: the Helm adapter is missing (helm_deploy_script)"

  # deployment shapes (the config file)
  fixture
  rm "$T/.github/config-lint.yml"
  mkdir -p "$T/config/staging"
  lint --no-render
  expect no-config-file 0 "WARN check 1  .github/config-lint.yml: not found: the defaults apply" "!env 'staging'" \
    "TODO check 6  config: compose renderings not checked"

  fixture # Helm only: no compose.env anywhere, every target helm, no pool
  config "runtimes: [helm]"
  find "$T/config" -name compose.env -exec rm {} +
  inventory helm nopool
  lint
  expect helm-only 0 '!ERROR' "INFO check 5  config: not applicable: compose is not in runtimes" \
    "INFO check 6  config: not applicable: compose is not in runtimes"
  put "$p/ledger/compose.env" "IMAGE_REPO=ghcr.io/acme"
  inventory compose nopool
  lint --no-render
  expect helm-only-strays 1 "ERROR check 3  $p/ledger/compose.env: compose does not run dev (runtimes)" \
    "ERROR check 11  config/dev/payments/workflows-config.yml: targets[0]: kind 'compose' is not a runtime of dev"

  fixture # compose only: no values.yaml anywhere, every target compose on the pool
  config "runtimes: [compose]"
  find "$T/config" -name values.yaml -exec rm {} +
  put config/dev/payments/workflows-config.yml "env: dev" "flow: payments" "pool:" "  hosts: [box-1.example.com]" \
    "targets:" "  - instance: api/ledger" "  - instance: api/refunds"
  lint
  expect compose-only 0 '!ERROR' "INFO check 12  config: not applicable: helm is not in runtimes"
  if [ -s "$WORK/adapter.log" ]; then fail compose-only-no-helm "the Helm adapter ran"; else pass compose-only-no-helm; fi
  values dev ledger 0.2.0-rc.1
  lint --no-render
  expect compose-only-strays 1 "ERROR check 3  $p/ledger/values.yaml: helm does not run dev (runtimes)"

  fixture # compose for laptops and dev only, Helm everywhere
  config "runtimes: {helm: '.*', compose: '^(local|dev)\$'}"
  rm "$T/$q/ledger/compose.env"
  lint --no-render
  expect runtimes-per-env 1 "ERROR check 3  $q/refunds/compose.env: compose does not run prod (runtimes)" \
    "!ERROR check 3  $q/ledger"

  fixture # apps that read no config file: variables are their configuration
  config "app_config: false"
  find "$T/config" -name application.yml -exec rm {} +
  append "$p/ledger/values.yaml" "  DATABASE_HOST: db.internal"
  append "$p/ledger/compose.env" "DATABASE_HOST=db.internal"
  edit "$q/ledger/values.yaml" '/APP_/d'
  lint --no-render
  expect app-config-false 0 '!ERROR' "INFO check 7  config: not applicable: the apps read no config files"
  edit "$p/refunds/values.yaml" 's/^  APP_FLOW: payments$/  APP_FLOW: orders/'
  lint --no-render
  expect app-config-false-identity-still-checked 1 "ERROR check 4  $p/refunds/values.yaml: env.APP_FLOW is 'orders'"

  fixture # GitOps: no dev inventory
  config "inventory: ''"
  rm "$T/config/dev/payments/workflows-config.yml"
  lint --no-render
  expect gitops-no-inventory 0 '!ERROR' "INFO check 11  config: not applicable: no dev inventory"

  fixture # skipped checks say so; YAML that does not parse is reported anyway
  config "checks: {skip: [3, 9, 13]}"
  append "$p/ledger/application.yml" "  aws-key-id: AKIA""ABCDEFGHIJKLMNOP"
  rm "$T/$p/refunds/application.yml"
  put "$p/ledger/extra.yml" "a: [unclosed"
  lint --no-render
  expect checks-skip 1 "INFO check 9  config: skipped (checks.skip in .github/config-lint.yml)" \
    "INFO check 13  config: skipped (checks.skip" "!TODO check 13" "!ERROR check 9" "!application.yml is missing" \
    "ERROR check 3  $p/ledger/extra.yml: does not parse"

  fixture # tag_var names the tag variable of compose.env (WRITE_BACK_TAG_VAR, SET_IMAGE_TAG_VAR)
  config "tag_var: API_TAG" "values_env_allow: [OTEL_SERVICE_NAME]"
  for env_file in "$T"/config/*/payments/api/*/compose.env; do
    edit "${env_file#"$T/"}" 's/^IMAGE_TAG=/API_TAG=/'
  done
  append "$p/ledger/values.yaml" "  OTEL_SERVICE_NAME: api-ledger"
  lint --no-render
  expect tag-var-and-values-env-allow 0 '!ERROR'

  fixture # a finding is one line, whatever a value holds: YAML decodes \n in a double-quoted string
  values dev ledger '0.2.0\n::warning::forged'
  lint --no-render
  if [ "$RC" -eq 1 ] && grep -qF "image.tag is '0.2.0\n::warning::forged' but" "$WORK/out" && ! grep -q '^::' "$WORK/out"
  then pass one-line-per-finding
  else fail one-line-per-finding "exit $RC, the tag is not shown escaped, or a line starts with ::"; fi

  if [ -f "$EXAMPLE" ]; then # the skill's documented example config (absent once copied into a repository)
    fixture
    cp "$EXAMPLE" "$T/.github/config-lint.yml"
    lint --no-render
    expect example-config 0 '!ERROR' "TODO check 6  config: compose renderings not checked: set compose_file"
  fi

  # usage
  fixture
  config "foo: 1"
  lint --no-render
  expect config-unknown-key 2 "unknown key 'foo'"
  fixture
  config "app_config: 'no'"
  lint --no-render
  expect config-wrong-type 2 "app_config must be true or false"
  fixture
  config "dev_env_pattern: '('"
  lint --no-render
  expect config-bad-regex 2 "dev_env_pattern: '(' is not a regex"
  fixture
  config "checks: {skip: [14]}"
  lint --no-render
  expect config-bad-skip 2 "checks must be {skip: [check numbers 1 to 13]}"
  fixture
  config "wrapper_vars: {CONFIG_DIR: '{instance_dir}'}"
  lint --no-render
  expect config-bad-wrapper-var 2 "wrapper_vars: '{instance_dir}' uses 'instance_dir'"
  lint --config nope.yml
  expect config-named-but-missing 2 "nope.yml not found"
  fixture
  config "config_dir: nope"
  lint
  expect no-config-tree 2 "does not exist"
  lint --bogus
  expect unknown-option 2 "unrecognized arguments: --bogus"
  lint --help
  expect help 0 "Usage: config_lint.py" "Exit codes:"
}

for READER in "${READERS[@]}"; do
  if [ "$READER" = yq ]; then # PyYAML blocked: the linter must read every file through yq
    export PYTHONPATH=$WORK/no-pyyaml${PYTHONPATH:+:$PYTHONPATH} YQ=$YQ_BIN
  else # yq unreachable: the linter must read every file through PyYAML
    export YQ=$WORK/no/yq
  fi
  suite
done

echo "config-lint-test: $PASSED passed, $FAILED failed (readers: ${READERS[*]})"
[ "$FAILED" -eq 0 ]
