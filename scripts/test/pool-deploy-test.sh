#!/usr/bin/env bash
# pool-deploy-test.sh — script tests of the host pools (DL-39; D6 §6.8): scripts/pool-deploy.sh, the .platform-bundle
# root, the pool guard and record-tag of scripts/run-compose.sh, and the placement write-back
# (scripts/ci/set-target-host.sh, scripts/ci/write-back-tag.sh). Plain bash: stub ssh and rsync (POOL_SSH /
# POOL_RSYNC) and a stub docker and curl (PATH) record their arguments and answer from STUB_* variables, so nothing
# reaches a host, a registry or an engine.
#
# Usage: scripts/test/pool-deploy-test.sh [<case>...]     every case by default; the pr.yml lint job runs it.
# Needs bash 4+, mikefarah yq v4, jq, rsync and git; a docker compose CLI is optional (validate skips its lint).
# Exit codes: 0 every case passed · 1 a case failed · 2 usage or a missing tool.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO POOL_DEPLOY="$REPO/scripts/pool-deploy.sh"
readonly H1=dev-cash-01.us-dev.example.com H2=dev-cash-02.us-dev.example.com
readonly TRADES=cash/source-database/trades-db-to-amps POSITIONS=cash/source-database/positions-db-to-deephaven
# The command a box runs, as pool-deploy.sh and the pool guard address it.
readonly BOX_RC=/opt/platform/deephaven-connectors/source-database/scripts/run-compose.sh
readonly CASES="bundle plan_assigns plan_pinned discovered two_boxes move sync_local dry_run health_fails
    record_tag record_after_health known_hosts refusals guard ssh_deploy local_execute write_back"

for tool in yq jq rsync git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "pool-deploy-test: $tool is needed" >&2; exit 2; }
done
yq --version 2>/dev/null | grep -q mikefarah || { echo "pool-deploy-test: mikefarah yq v4 is needed" >&2; exit 2; }
if command -v sha256sum >/dev/null 2>&1; then SHA256=(sha256sum); else SHA256=(shasum -a 256); fi
# Only what each case sets: nothing from the caller's shell steers the scripts under test.
unset CONFIG_ROOT POOL_TRANSPORT POOL_LOCAL_ROOT POOL_LOCAL_EXECUTE POOL_SSH POOL_RSYNC POOL_SSH_OPTS POOL_PEER_CHECK \
    POOL_SELF_HOST IMAGE_TAG IMAGE_REPO APP_IMAGE WRITE_BACK_PLACEMENTS STUB_RUNNING STUB_FAIL STUB_UNREACHABLE \
    STUB_RSYNC_CHANGES STUB_RSYNC_FAIL STUB_HEALTHY STUB_INSTANCE

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pool-deploy-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
readonly WORK STUB="$WORK/stub" DOCKER_BIN="$WORK/docker-bin"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STUB" "$DOCKER_BIN"

cat >"$STUB/ssh" <<'EOF'
#!/usr/bin/env bash
# Stub ssh: logs "ssh <args>"; answers run-compose.sh ... status --json with running true for the
# "<host>:<AppInstance>" pairs in STUB_RUNNING; fails the "<host>:<command>" pairs in STUB_FAIL; plays dead
# (exit 255, as ssh does) for the hosts in STUB_UNREACHABLE.
printf 'ssh %s\n' "$*" >>"$STUB_LOG"
target="" remote=""
while [ $# -gt 0 ]; do
    if [ "$1" = -- ]; then remote="$2"; break; fi
    target="$1"
    shift
done
host="${target#*@}"
case " ${STUB_UNREACHABLE:-} " in *" $host "*) echo "ssh: connect to host $host port 22: Connection timed out" >&2; exit 255 ;; esac
read -r -a words <<<"$remote"
[[ ${words[0]:-} != IMAGE_TAG=* ]] || words=("${words[@]:1}")
inst="${words[4]:-}" cmd="${words[5]:-}"
case " ${STUB_FAIL:-} " in *" $host:$cmd "*) echo "stub: $cmd of $inst failed on $host" >&2; exit 1 ;; esac
if [ "$cmd" = status ]; then
    running=false
    case " ${STUB_RUNNING:-} " in *" $host:$inst "*) running=true ;; esac
    echo "NAME    IMAGE    SERVICE    STATUS"
    printf '{"project":"us-dev-cash-source-database-%s","running":%s,"desired":"ghcr.io/o/r/source-database:1","runningImage":"","runningId":"","desiredId":"","drift":"false"}\n' "$inst" "$running"
    [ "$running" = true ] || exit 1
fi
exit 0
EOF
cat >"$STUB/rsync" <<'EOF'
#!/usr/bin/env bash
# Stub rsync (ssh transport): logs "rsync <args>"; a --dry-run pass (the verification) prints STUB_RSYNC_CHANGES;
# the transfer to the host in STUB_RSYNC_FAIL fails as a dead box would.
printf 'rsync %s\n' "$*" >>"$STUB_LOG"
dest="${!#}"
case " $* " in *" --dry-run "*) printf '%b' "${STUB_RSYNC_CHANGES:-}"; exit 0 ;; esac
if [ -n "${STUB_RSYNC_FAIL:-}" ] && [[ $dest == *"@$STUB_RSYNC_FAIL:"* ]]; then
    echo "rsync: connection unexpectedly closed" >&2
    exit 12
fi
exit 0
EOF
cat >"$DOCKER_BIN/docker" <<'EOF'
#!/usr/bin/env bash
# Stub docker for run-compose.sh start: a compose CLI and a daemon that accept everything. With STUB_HEALTHY
# set, `compose ... ps -q` names a container, so health goes on to ask the actuator (the stub curl).
printf 'docker %s\n' "$*" >>"$STUB_LOG"
if [ "${1:-}" = compose ] && [ "${2:-}" = version ]; then echo "Docker Compose version v2.99.0-stub"; fi
if [ -n "${STUB_HEALTHY:-}" ] && [ "${1:-}" = compose ] && [[ " $* " == *" ps -q "* ]]; then echo 0123456789ab; fi
exit 0
EOF
cat >"$DOCKER_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl for run-compose.sh health and smoke.sh: with STUB_HEALTHY set, the actuator of a ready instance
# (readiness UP, the identity of STUB_INSTANCE, default trades-db-to-amps); otherwise nothing listens.
printf 'curl %s\n' "$*" >>"$STUB_LOG"
[ -n "${STUB_HEALTHY:-}" ] || { echo "curl: (7) Failed to connect" >&2; exit 7; }
case "${!#}" in
    */actuator/health/readiness) echo '{"status":"UP"}' ;;
    */actuator/info)
        printf '{"connector":{"env":"us-dev","flow":"cash","app":"source-database","instance":"%s"}}\n' \
            "${STUB_INSTANCE:-trades-db-to-amps}" ;;
    *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
EOF
chmod +x "$STUB/ssh" "$STUB/rsync" "$DOCKER_BIN/docker" "$DOCKER_BIN/curl"

# --- helpers ----------------------------------------------------------------------------------------------

CASE_FAILED=0 RC=0 OUT="" ERR=""
fail() {
    printf '    %s\n' "$*"
    CASE_FAILED=1
}
# run <command...>: stdout in OUT, stderr in ERR, exit code in RC.
run() {
    RC=0
    "$@" >"$WORK/stdout" 2>"$WORK/stderr" || RC=$?
    OUT="$(cat "$WORK/stdout")" ERR="$(cat "$WORK/stderr")"
}
expect_rc() { [ "$RC" -eq "$1" ] || fail "exit $RC, expected $1; stderr: $(tail -n 4 <<<"$ERR" | tr '\n' ' ')"; }
expect_in() { [[ $2 == *"$1"* ]] || fail "missing '$1' in: $(head -c 700 <<<"$2")"; }
expect_not_in() { [[ $2 != *"$1"* ]] || fail "unexpected '$1' in: $(head -c 700 <<<"$2")"; }
expect_json() { # <json> <jq filter> <expected>
    local actual
    actual="$(jq -r "$2" <<<"$1" 2>&1)" || actual="(jq failed: $actual)"
    [ "$actual" = "$3" ] || fail "jq '$2' is '$actual', expected '$3'"
}
line_of() { grep -nF -- "$1" "$2" | head -n 1 | cut -d : -f 1; }
in_dir() { # <dir> <command...>: the command, run from <dir>
    local dir="$1"
    shift
    (cd "$dir" && "$@")
}
# copy_config <dest>: a copy of config/ without the placements deploy-dev records (the `host` of every target
# of a pooled flow), so each case starts from an unplaced inventory whatever main's write-back last recorded.
# Flows without a pool keep their hosts: there a compose target needs one.
copy_config() {
    local f
    cp -R "$REPO/config" "$1"
    for f in "$1"/*/*/workflows-config.yml; do
        [ -f "$f" ] || continue
        yq -i 'with(select(.pool != null); del(.targets[].host))' "$f"
    done
}
# fixture <name> [yq expression for us-dev/cash/workflows-config.yml]: a copy of config/, printed as a CONFIG_ROOT.
fixture() {
    mkdir -p "$WORK/$1"
    copy_config "$WORK/$1/config"
    [ -z "${2:-}" ] || yq -i "$2" "$WORK/$1/config/us-dev/cash/workflows-config.yml"
    printf '%s' "$WORK/$1/config"
}
known_hosts() { # the reviewed host keys the ssh transport requires (a test key, public)
    printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n' "$H1" "$H2" >"$1/us-dev/known_hosts"
}
bundle() { # <config root> <out>: a verified bundle of us-dev/cash
    CONFIG_ROOT="$1" "$POOL_DEPLOY" us-dev cash bundle --out "$2" --tag t1 >/dev/null 2>"$WORK/bundle.err" ||
        { fail "bundle failed: $(tail -n 3 "$WORK/bundle.err")"; return 1; }
}

# --- cases (DL-39 contract §4) ------------------------------------------------------------------------------

case_bundle() { # the layout and marker for us-dev/cash; every instance validates from the bundle alone
    local b="$WORK/bundle/out" m f n sha checkout inst
    run "$POOL_DEPLOY" us-dev cash bundle --out "$b" --tag t1
    expect_rc 0
    m="$b/.platform-bundle"
    for f in .platform-bundle scripts/run-compose.sh scripts/smoke.sh deephaven-connectors/source-database/docker/docker-compose.yml \
        deephaven-connectors/source-database/scripts/run-compose.sh deephaven-connectors/source-database/scripts/smoke.sh \
        config/_common/source-database/application.yml config/us-dev/_common/application.yml config/us-dev/cash/workflows-config.yml \
        config/us-dev/cash/source-database/app-common/application.yml config/us-dev/cash/source-database/trades-db-to-amps/compose.env \
        config/us-dev/cash/source-database/positions-db-to-deephaven/application.yml; do
        [ -f "$b/$f" ] || fail "the bundle lacks $f"
    done
    for f in config/us-dev/workflows-config.yml config/local deephaven-connectors/source-amps deephaven-connectors/source-kafka \
        deephaven-connectors/source-database/src deephaven-connectors/source-database/build scripts/ci scripts/test .git; do
        [ ! -e "$b/$f" ] || fail "the bundle holds $f"
    done
    [ -x "$b/deephaven-connectors/source-database/scripts/run-compose.sh" ] || fail "the wrapper is not executable"
    [ "$OUT" = "$(cat "$m")" ] || fail "bundle does not print its manifest"
    # Shell-sourceable, so a box needs no yq.
    (
        set +u
        # shellcheck disable=SC1090 # the manifest under test
        . "$m"
        [ "$BUNDLE_ENV/$BUNDLE_FLOW/$BUNDLE_TAG" = us-dev/cash/t1 ] && [ "$POOL_HOSTS" = "$H1 $H2" ] &&
            [ "$POOL_USER" = deploy ] && [ "$POOL_ROOT" = /opt/platform ]
    ) || fail "the marker does not source to us-dev/cash/t1 and the pool: $(tr '\n' ' ' <"$m")"
    grep -Eq '^BUNDLE_CREATED=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$m" || fail "BUNDLE_CREATED is not UTC"
    grep -Eq '^BUNDLE_GIT_SHA=([0-9a-f]{40}(-dirty)?|unknown)$' "$m" || fail "BUNDLE_GIT_SHA is malformed"
    n="$(cd "$b" && find . -type f ! -path ./.platform-bundle | wc -l | tr -d ' ')"
    grep -qx "BUNDLE_FILES=$n" "$m" || fail "BUNDLE_FILES is not $n"
    # The documented recipe: sha256 of the sorted "<sha256>  <path>" lines of every other file.
    sha="$(cd "$b" && find . -type f ! -path ./.platform-bundle -print0 | LC_ALL=C sort -z | xargs -0 "${SHA256[@]}" |
        sed 's|  \./|  |' | "${SHA256[@]}" | cut -d ' ' -f 1)"
    grep -qx "BUNDLE_SHA256=$sha" "$m" || fail "BUNDLE_SHA256 is not the recipe's $sha"
    # Any instance of the flow can run on any box: both validate from the bundle, outside any checkout.
    for inst in trades-db-to-amps positions-db-to-deephaven; do
        run in_dir / env -u GITHUB_RUN_ID SPRING_DATASOURCE_USERNAME=u SPRING_DATASOURCE_PASSWORD=p \
            "$b/deephaven-connectors/source-database/scripts/run-compose.sh" us-dev cash source-database "$inst" validate
        expect_rc 0
    done
    # The marker wins over an enclosing git checkout.
    checkout="$WORK/bundle/checkout"
    mkdir -p "$checkout"
    git -C "$checkout" init -q
    cp -R "$b" "$checkout/platform"
    run "$checkout/platform/deephaven-connectors/source-database/scripts/run-compose.sh" us-dev cash source-database trades-db-to-amps printenv
    expect_rc 0
    expect_in "REPO_ROOT=$checkout/platform"$'\n' "$OUT"
    expect_in "CONFIG_ROOT=$checkout/platform/config"$'\n' "$OUT"
    # A second build replaces a previous bundle; a directory that is not one is refused.
    run "$POOL_DEPLOY" us-dev cash bundle --out "$b"
    expect_rc 0
    grep -qx 'BUNDLE_TAG=' "$m" || fail "a bundle without --tag has an empty BUNDLE_TAG"
    run "$POOL_DEPLOY" us-dev cash bundle --out "$checkout"
    expect_rc 2
}

case_plan_assigns() { # two unplaced instances spread over the two boxes, the same way every time
    local cfg first
    cfg="$(fixture plan-assigns '.targets[].kind = "compose"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --json --transport dry-run
    expect_rc 0
    first="$OUT"
    expect_json "$OUT" '[.placements[] | "\(.instance)@\(.host)=\(.how)"] | join(" ")' "$TRADES@$H1=assigned $POSITIONS@$H2=assigned"
    expect_json "$OUT" '"\(.pool.hosts | join(" "))|\(.pool.user)|\(.pool.root)"' "$H1 $H2|deploy|/opt/platform"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --json --transport dry-run
    [ "$OUT" = "$first" ] || fail "a second plan differs from the first"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --transport dry-run
    expect_rc 0
    expect_in "$TRADES" "$OUT"
    expect_in "assigned" "$OUT"
}

case_plan_pinned() { # a pinned host is kept, and counted before the assignments
    local cfg
    cfg="$(fixture plan-pinned '.targets[].kind = "compose" | (.targets[] | select(.instance == "source-database/positions-db-to-deephaven")).host = "'"$H1"'"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --json --transport dry-run
    expect_rc 0
    expect_json "$OUT" '[.placements[] | "\(.instance)@\(.host)=\(.how)"] | join(" ")' "$TRADES@$H2=assigned $POSITIONS@$H1=pinned"
}

case_discovered() { # a box that already runs the instance keeps it
    local cfg log="$WORK/discovered.log"
    cfg="$(fixture discovered)"
    known_hosts "$cfg"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash plan --json --transport ssh
    expect_rc 0
    expect_json "$OUT" '.placements[0] | "\(.instance) \(.host) \(.how)"' "$TRADES $H2 discovered"
    expect_in "deploy@$H1 -- $BOX_RC us-dev cash source-database trades-db-to-amps status --json" "$(cat "$log")"
    expect_in "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$cfg/us-dev/known_hosts deploy@$H2 --" "$(cat "$log")"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash discover --json --transport ssh
    expect_rc 0
    expect_json "$OUT" '.[0] | "\(.instance) \(.running | join(","))"' "$TRADES $H2"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash status --json --transport ssh
    expect_rc 0
    expect_json "$OUT" '[.[] | "\(.host)=\(.status.running)"] | join(" ")' "$H1=false $H2=true"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_UNREACHABLE="$H1" \
        "$POOL_DEPLOY" us-dev cash status --transport ssh
    expect_rc 1
    expect_in "unreachable" "$OUT"
}

case_two_boxes() { # an instance running on two boxes stops everything (6), before any change
    local cfg log="$WORK/two-boxes.log"
    cfg="$(fixture two-boxes)"
    known_hosts "$cfg"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H1:trades-db-to-amps $H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash plan --transport ssh
    expect_rc 6
    expect_in "running on more than one box: $H1 $H2" "$ERR"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H1:trades-db-to-amps $H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash discover --transport ssh
    expect_rc 6
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" \
        STUB_RUNNING="$H1:trades-db-to-amps $H2:trades-db-to-amps" "$POOL_DEPLOY" us-dev cash deploy --tag t1 --transport ssh
    expect_rc 6
    expect_not_in "deployed" "$OUT"
    expect_not_in " pull" "$(cat "$log")"
}

case_move() { # pinned to box 1 but running on box 2: 6, or with --move stop there, then deploy on box 1
    local cfg log="$WORK/move.log" stop pull
    cfg="$(fixture move '(.targets[] | select(.instance == "source-database/trades-db-to-amps")).host = "'"$H1"'"')"
    known_hosts "$cfg"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --transport ssh
    expect_rc 6
    expect_in "pinned to $H1 but running on $H2" "$ERR"
    expect_not_in " stop" "$(cat "$log")"
    : >"$log"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --transport ssh --move
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the one deployed line"
    stop="$(line_of "deploy@$H2 -- $BOX_RC us-dev cash source-database trades-db-to-amps stop" "$log")"
    pull="$(line_of "deploy@$H1 -- IMAGE_TAG=t1 $BOX_RC us-dev cash source-database trades-db-to-amps pull" "$log")"
    if [ -z "$stop" ] || [ -z "$pull" ] || [ "$stop" -ge "$pull" ]; then fail "expected stop on $H2 before pull on $H1: $(cat "$log")"; fi
}

case_sync_local() { # the local transport: every box gets the same complete tree; .state/ stays, stale files go
    local cfg b="$WORK/sync-local/bundle" boxes="$WORK/sync-local/boxes" one two
    cfg="$(fixture sync-local)"
    bundle "$cfg" "$b" || return 0
    one="$boxes/$H1/opt/platform" two="$boxes/$H2/opt/platform"
    mkdir -p "$one/.state"
    echo keep >"$one/.state/keep"
    echo stale >"$one/stale.txt"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash sync --bundle "$b" --transport local --local-root "$boxes"
    expect_rc 0
    diff -r -x .state "$one" "$two" >/dev/null || fail "the two boxes differ: $(diff -r -x .state "$one" "$two" | head -n 5)"
    diff -r -x .state "$b" "$one" >/dev/null || fail "box 1 differs from the bundle"
    [ -f "$one/.state/keep" ] || fail "sync removed the box's .state/"
    [ ! -e "$one/stale.txt" ] || fail "sync kept a file the bundle does not have"
    expect_in "synced and verified" "$ERR"
    # A changed bundle is refused rather than synced.
    echo tampered >>"$b/config/us-dev/cash/workflows-config.yml"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash sync --bundle "$b" --transport local --local-root "$boxes"
    expect_rc 4
    expect_in "changed since it was built" "$ERR"
}

case_dry_run() { # dry-run prints the sync, pull / start / health and record-tag on every box, with IMAGE_TAG; deploys nothing
    local cfg cmd
    cfg="$(fixture dry-run)"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash deploy --tag t1 --dry-run
    expect_rc 0
    [ -z "$OUT" ] || fail "a dry run reports '$OUT' on stdout"
    expect_in "rsync -az --delete --exclude .state/ -e 'ssh -o BatchMode=yes" "$ERR"
    for cmd in pull start health record-tag; do
        expect_in "deploy@$H1 -- 'IMAGE_TAG=t1 $BOX_RC us-dev cash source-database trades-db-to-amps $cmd'" "$ERR"
    done
    expect_in "deploy@$H2 -- 'IMAGE_TAG=t1 $BOX_RC us-dev cash source-database trades-db-to-amps record-tag'" "$ERR"
    expect_not_in "deploy@$H2 -- 'IMAGE_TAG=t1 $BOX_RC us-dev cash source-database trades-db-to-amps start'" "$ERR"
    expect_in "known_hosts is missing: the ssh transport would refuse" "$ERR"
}

case_health_fails() { # a failed health check starts the previous tag again: no override, exit 1, no deployed line
    local cfg log="$WORK/health-fails.log" last
    cfg="$(fixture health-fails)"
    known_hosts "$cfg"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_FAIL="$H1:health" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --transport ssh --report "$WORK/health-fails.json"
    expect_rc 1
    expect_not_in "deployed" "$OUT"
    expect_in "deploy@$H1 -- IMAGE_TAG=t1 $BOX_RC us-dev cash source-database trades-db-to-amps health" "$(cat "$log")"
    # compose.env keeps the previous tag on every box: nothing is recorded after a failed health.
    expect_not_in "record-tag" "$(cat "$log")"
    last="$(grep '^ssh ' "$log" | tail -n 1)"
    [[ $last == *"deploy@$H1 -- $BOX_RC us-dev cash source-database trades-db-to-amps start" ]] ||
        fail "the last command is not start without the override: $last"
    expect_json "$(cat "$WORK/health-fails.json")" '.placements[0].result' "failed: health (previous tag started again)"
}

case_record_tag() { # run-compose.sh record-tag: IMAGE_TAG into a host bundle's compose.env only, in place, idempotent
    local cfg b="$WORK/record-tag/bundle" rc env before first mode inside
    cfg="$(fixture record-tag)"
    bundle "$cfg" "$b" || return 0
    rc="$b/deephaven-connectors/source-database/scripts/run-compose.sh"
    env="$b/config/us-dev/cash/source-database/trades-db-to-amps/compose.env"
    # The box's copy gets a commented-out IMAGE_TAG and a second IMAGE_TAG line (compose reads the last one,
    # run-compose.sh the first), and mode 640.
    { echo "# IMAGE_TAG=commented-out"; cat "$env"; echo "IMAGE_TAG=duplicate"; } >"$WORK/record-tag.env"
    cat "$WORK/record-tag.env" >"$env"
    chmod 640 "$env"
    before="$WORK/record-tag.before"
    cp "$env" "$before"
    first="$(grep -n '^IMAGE_TAG=' "$before" | head -n 1)"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t2 "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 0
    [ "$(grep -n '^IMAGE_TAG=' "$env")" = "${first%%:*}:IMAGE_TAG=t2" ] ||
        fail "expected one IMAGE_TAG line, t2, where the first was (line ${first%%:*}): $(grep -n IMAGE_TAG "$env" | tr '\n' ' ')"
    [ "$(grep -v '^IMAGE_TAG=' "$env")" = "$(grep -v '^IMAGE_TAG=' "$before")" ] || fail "another line of compose.env changed"
    mode="$(stat -c %a "$env" 2>/dev/null || stat -f %Lp "$env")"
    [ "$mode" = 640 ] || fail "compose.env lost its mode: $mode"
    [ -z "$(find "$(dirname "$env")" -name '.compose.env.*')" ] || fail "a temporary file was left behind"
    expect_in "IMAGE_TAG=t2 recorded in config/us-dev/cash/source-database/trades-db-to-amps/compose.env (was ${first#*:IMAGE_TAG=})" "$ERR"
    expect_in 'cmd=record-tag opts="" result=0 override=IMAGE_TAG' "$ERR"
    # Idempotent; --dry-run only says what it would write.
    cp "$env" "$before"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t2 "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 0
    expect_in "already records IMAGE_TAG=t2" "$ERR"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t3 "$rc" us-dev cash source-database trades-db-to-amps record-tag --dry-run
    expect_rc 0
    expect_in "write         IMAGE_TAG=t3 into config/us-dev/cash/source-database/trades-db-to-amps/compose.env (now t2)" "$OUT"
    # Refused: no tag; a value that is not a tag (a second line would add a variable); an IMAGE_REPO override.
    run in_dir / env -u GITHUB_RUN_ID "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 2
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG="t3"$'\n'"JAVA_OPTS=-Dinjected" "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 2
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG="t3"$'\n'"JAVA_OPTS=-Dinjected" "$rc" us-dev cash source-database trades-db-to-amps printenv
    expect_rc 2
    expect_in "is not a valid override" "$ERR"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t3 IMAGE_REPO=ghcr.io/other/repo "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 2
    expect_in "records IMAGE_TAG only" "$ERR"
    cmp -s "$env" "$before" || fail "a dry run or a refused record-tag changed compose.env: $(diff "$before" "$env" | tr '\n' ' ')"
    # Never outside the bundle: a CONFIG_ROOT elsewhere, or a checkout (there compose.env changes through git).
    cp "$cfg/us-dev/cash/source-database/trades-db-to-amps/compose.env" "$WORK/record-tag.cfg"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t3 CONFIG_ROOT="$cfg" "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 3
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t3 CONFIG_ROOT="$b/../../record-tag/config" "$rc" us-dev cash source-database \
        trades-db-to-amps record-tag
    expect_rc 3
    cmp -s "$cfg/us-dev/cash/source-database/trades-db-to-amps/compose.env" "$WORK/record-tag.cfg" || fail "record-tag wrote outside the bundle"
    inside="$REPO/config/us-dev/cash/source-database/trades-db-to-amps/compose.env"
    cp "$inside" "$WORK/record-tag.repo"
    run env -u GITHUB_RUN_ID IMAGE_TAG=t3 "$REPO/deephaven-connectors/source-database/scripts/run-compose.sh" \
        us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 3
    expect_in "in a checkout compose.env changes through git" "$ERR"
    cmp -s "$inside" "$WORK/record-tag.repo" || fail "record-tag wrote the checkout's compose.env"
    # Without an IMAGE_TAG line the tag is appended.
    grep -v '^IMAGE_TAG=' "$before" >"$env"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t4 "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 0
    [ "$(tail -n 1 "$env")" = IMAGE_TAG=t4 ] || fail "IMAGE_TAG was not appended: $(tail -n 2 "$env" | tr '\n' ' ')"
}

case_record_after_health() { # once health passed, the tag is recorded on every box of the pool; a failed record only warns
    local cfg log="$WORK/record-after-health.log" report="$WORK/record-after-health.json" health record other box
    local b="$WORK/record-after-health/bundle" boxes="$WORK/record-after-health/boxes"
    local env_rel=config/us-dev/cash/source-database/trades-db-to-amps/compose.env
    cfg="$(fixture record-after-health)"
    known_hosts "$cfg"
    # ssh: record-tag on the instance's box once its health passed, then on the other box of the pool.
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --transport ssh --report "$report"
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the one deployed line"
    health="$(line_of "deploy@$H1 -- IMAGE_TAG=t1 $BOX_RC us-dev cash source-database trades-db-to-amps health" "$log")"
    record="$(line_of "deploy@$H1 -- IMAGE_TAG=t1 $BOX_RC us-dev cash source-database trades-db-to-amps record-tag" "$log")"
    other="$(line_of "deploy@$H2 -- IMAGE_TAG=t1 $BOX_RC us-dev cash source-database trades-db-to-amps record-tag" "$log")"
    if [ -z "$health" ] || [ -z "$record" ] || [ -z "$other" ] || [ "$health" -ge "$record" ] || [ "$record" -ge "$other" ]; then
        fail "expected health on $H1, then record-tag on $H1, then on $H2: $(grep -e ' health' -e record-tag "$log" | tr '\n' ' ')"
    fi
    expect_json "$(cat "$report")" '.placements[0] | "\(.result) \([.commands[] | select(test("record-tag.$"))] | length)"' "deployed 2"
    # A box that fails to record the tag: the instance is still deployed (exit 0, its line), and the report says so.
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_FAIL="$H2:record-tag" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --transport ssh --report "$report"
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "a failed record-tag on $H2 cost the deployed line: '$OUT'"
    expect_in "compose.env on $H2 still names the previous tag" "$ERR"
    expect_json "$(cat "$report")" '.placements[0].result' "deployed; IMAGE_TAG not recorded on $H2"
    # The local transport validates: record-tag --dry-run on both box directories, nothing written.
    bundle "$cfg" "$b" || return 0
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash deploy --tag t1 --bundle "$b" --transport local --local-root "$boxes"
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the validated instance"
    [ "$(grep -c "write         IMAGE_TAG=t1 into $env_rel" <<<"$ERR")" -eq 2 ] ||
        fail "expected record-tag --dry-run on both boxes: $(grep 'write  ' <<<"$ERR" | tr '\n' ' ')"
    if grep -qx 'IMAGE_TAG=t1' "$boxes/$H1/opt/platform/$env_rel"; then fail "a validation run recorded the tag"; fi
    # POOL_LOCAL_EXECUTE with a healthy stub engine: every box directory's compose.env names t1, the bundle's does
    # not, and the next sync brings the bundle's back.
    run env PATH="$DOCKER_BIN:$PATH" CONFIG_ROOT="$cfg" STUB_LOG="$log" STUB_HEALTHY=1 POOL_LOCAL_EXECUTE=true \
        SPRING_DATASOURCE_USERNAME=u SPRING_DATASOURCE_PASSWORD=p \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --bundle "$b" --transport local --local-root "$boxes"
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the one deployed line"
    for box in "$H1" "$H2"; do
        grep -qx 'IMAGE_TAG=t1' "$boxes/$box/opt/platform/$env_rel" ||
            fail "$box: compose.env does not record t1: $(grep 'IMAGE_TAG=' "$boxes/$box/opt/platform/$env_rel")"
    done
    if grep -qx 'IMAGE_TAG=t1' "$b/$env_rel"; then fail "record-tag changed the bundle itself"; fi
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash sync --bundle "$b" --transport local --local-root "$boxes"
    expect_rc 0
    for box in "$H1" "$H2"; do
        cmp -s "$b/$env_rel" "$boxes/$box/opt/platform/$env_rel" ||
            fail "$box: the next sync did not bring the bundle's compose.env back"
    done
}

case_known_hosts() { # the ssh transport never runs without the reviewed known_hosts (5)
    local cfg cmd
    cfg="$(fixture known-hosts)"
    for cmd in "deploy --tag t1" "discover" "status" "sync --bundle $WORK/none"; do
        # shellcheck disable=SC2086 # the command and its options, split on purpose
        run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$WORK/known-hosts.log" \
            "$POOL_DEPLOY" us-dev cash $cmd --transport ssh
        expect_rc 5
        expect_in "config/us-dev/known_hosts is missing" "$ERR"
    done
    [ ! -s "$WORK/known-hosts.log" ] || fail "something ran without known_hosts: $(cat "$WORK/known-hosts.log")"
    # plan is a preview: it plans without asking the boxes.
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$WORK/known-hosts.log" "$POOL_DEPLOY" us-dev cash plan --json --transport ssh
    expect_rc 0
    expect_json "$OUT" '.discovery | startswith("skipped")' true
}

case_refusals() { # env, flow, pool and usage rules
    local cfg
    run "$POOL_DEPLOY" us-qa cash plan
    expect_rc 3
    run "$POOL_DEPLOY" us-prod cash deploy --tag t1
    expect_rc 3
    cfg="$(fixture refusals)"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev deriv plan --dry-run
    expect_rc 4
    expect_in "config/us-dev/deriv/workflows-config.yml not found" "$ERR"
    cfg="$(fixture refusals-no-pool 'del(.pool) | .targets[0].host = "dev-compose-01.us-dev.example.com"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --dry-run
    expect_rc 4
    expect_in "no pool in" "$ERR"
    cfg="$(fixture refusals-pin '.targets[0].host = "dev-other-01.us-dev.example.com"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --dry-run
    expect_rc 4
    expect_in "is not a box of the pool" "$ERR"
    cfg="$(fixture refusals-flow '.flow = "deriv"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --dry-run
    expect_rc 4
    run "$POOL_DEPLOY" us-dev cash
    expect_rc 2
    run "$POOL_DEPLOY" us-dev cash deploy
    expect_rc 2
    run "$POOL_DEPLOY" us-dev cash plan --move
    expect_rc 2
    run "$POOL_DEPLOY" us-dev cash plan --out "$WORK/refusals/out"
    expect_rc 2
    expect_in "--out does not apply to plan" "$ERR"
    run "$POOL_DEPLOY" us-dev cash plan --transport ftp
    expect_rc 2
    run "$POOL_DEPLOY" us-dev fx plan
    expect_rc 2
    run "$POOL_DEPLOY" us-dev cash deploy --tag 'bad tag'
    expect_rc 2
    run "$POOL_DEPLOY" --help
    expect_rc 0
    expect_in "pool-deploy.sh <env> <flow> <command>" "$OUT"
}

case_guard() { # run-compose.sh start / restart on a pooled box asks the other boxes first (D6 §6.5)
    local b="$WORK/guard/bundle" log="$WORK/guard.log" rc peer
    bundle "$REPO/config" "$b" || return 0
    rc="$b/deephaven-connectors/source-database/scripts/run-compose.sh"
    peer="deploy@$H2 -- $BOX_RC us-dev cash source-database trades-db-to-amps status --json"
    guard() { # [VAR=value...] -- <run-compose.sh arguments...>
        local envs=()
        while [ "$1" != -- ]; do envs+=("$1"); shift; done
        shift
        : >"$log"
        run env PATH="$DOCKER_BIN:$PATH" POOL_SSH="$STUB/ssh" STUB_LOG="$log" SPRING_DATASOURCE_USERNAME=u \
            SPRING_DATASOURCE_PASSWORD=p ${envs[@]+"${envs[@]}"} "$rc" us-dev cash source-database trades-db-to-amps "$@"
    }
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" -- start
    expect_rc 3
    expect_in "trades-db-to-amps is already running on $H2; stop it there first, or --force" "$ERR"
    expect_in "$peer" "$(cat "$log")"
    expect_not_in "deploy@$H1" "$(cat "$log")"
    expect_not_in " up -d" "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" -- restart
    expect_rc 3
    expect_not_in "docker compose" "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" -- start --force
    expect_rc 0
    expect_not_in "ssh " "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" POOL_PEER_CHECK=off -- start
    expect_rc 0
    expect_not_in "ssh " "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" -- start
    expect_rc 0
    expect_in "$peer" "$(cat "$log")"
    expect_in " up -d --wait" "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" STUB_UNREACHABLE="$H2" -- start
    expect_rc 0
    expect_in "could not ask $H2 whether trades-db-to-amps runs there (exit 255" "$ERR"
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" -- start --dry-run
    expect_rc 0
    expect_in "peer check    $STUB/ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes deploy@$H2 -- '$BOX_RC us-dev cash source-database trades-db-to-amps status --json'" "$OUT"
    expect_not_in "ssh " "$(cat "$log")"
    guard POOL_SELF_HOST=box-elsewhere.example.com -- start
    expect_rc 0
    expect_in "is not one of POOL_HOSTS" "$ERR"
    expect_in "deploy@$H1 --" "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" -- status
    expect_not_in "ssh " "$(cat "$log")"
}

case_ssh_deploy() { # the ssh transport end to end: rsync verified per box, the command shape, the report; a dead box
    local cfg log="$WORK/ssh-deploy.log" report="$WORK/ssh-deploy.json" cmd
    cfg="$(fixture ssh-deploy)"
    known_hosts "$cfg"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --transport ssh --report "$report"
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the one deployed line"
    expect_in "-az --delete --exclude .state/ -e $STUB/ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$cfg/us-dev/known_hosts" "$(cat "$log")"
    expect_in "/ deploy@$H2:/opt/platform/" "$(cat "$log")"
    [ "$(grep -c -- '--dry-run --itemize-changes --checksum' "$log")" -eq 2 ] || fail "not every box was verified"
    for cmd in pull start health; do
        expect_in "deploy@$H1 -- IMAGE_TAG=t1 $BOX_RC us-dev cash source-database trades-db-to-amps $cmd" "$(cat "$log")"
    done
    expect_json "$(cat "$report")" '[.boxes[] | .result] | join(",")' "synced,synced"
    # pull, start, health on the box, then record-tag there and on the other box.
    expect_json "$(cat "$report")" '.placements[0] | "\(.how) \(.result) \(.commands | length)"' "assigned deployed 5"
    # A verification that finds a difference fails the box; with no box left nothing is deployed.
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" \
        STUB_RSYNC_CHANGES='>f..t...... config/us-dev/cash/workflows-config.yml\n' "$POOL_DEPLOY" us-dev cash deploy --tag t1 --transport ssh
    expect_rc 1
    expect_in "the synced tree differs from the bundle" "$ERR"
    expect_not_in "deployed" "$OUT"
    # A dead box does not block the flow: the instance goes to the box that received the bundle (which alone
    # records the tag: the dead box is never asked); still exit 1.
    : >"$log"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_RSYNC_FAIL="$H1" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --transport ssh
    expect_rc 1
    [ "$OUT" = "deployed $TRADES@$H2=t1" ] || fail "stdout is '$OUT', expected the instance on $H2"
    expect_in "not synced: $H1" "$ERR"
    expect_in "deploy@$H2 -- IMAGE_TAG=t1 $BOX_RC us-dev cash source-database trades-db-to-amps record-tag" "$(cat "$log")"
    expect_not_in "deploy@$H1 --" "$(cat "$log")"
}

case_local_execute() { # POOL_LOCAL_EXECUTE=true: the real run-compose.sh commands in the box directories (stub engine)
    local cfg log="$WORK/local-execute.log" boxes="$WORK/local-execute/boxes" starts
    cfg="$(fixture local-execute)"
    run env PATH="$DOCKER_BIN:$PATH" CONFIG_ROOT="$cfg" STUB_LOG="$log" POOL_LOCAL_EXECUTE=true SPRING_DATASOURCE_USERNAME=u \
        SPRING_DATASOURCE_PASSWORD=p "$POOL_DEPLOY" us-dev cash deploy --tag t1 --transport local --local-root "$boxes"
    # The stub engine runs no container, so health fails and the previous tag is started again.
    expect_rc 1
    expect_not_in "deployed" "$OUT"
    expect_in "--env-file $boxes/$H1/opt/platform/config/us-dev/cash/source-database/trades-db-to-amps/compose.env" "$(cat "$log")"
    expect_in " pull" "$(cat "$log")"
    expect_in " up -d --wait" "$(cat "$log")"
    expect_not_in "ssh " "$(cat "$log")"
    starts="$(grep 'cmd=start ' <<<"$ERR" || true)"
    [ "$(grep -c . <<<"$starts")" -eq 2 ] || fail "expected two starts, got: $starts"
    [[ $(head -n 1 <<<"$starts") == *override=IMAGE_TAG* ]] || fail "the first start lacks the override: $starts"
    [[ $(tail -n 1 <<<"$starts") != *override=* ]] || fail "the second start carries the override: $starts"
    expect_not_in "cmd=record-tag" "$ERR"
}

case_write_back() { # the box is recorded as host in the flow's workflows-config.yml, in the tag's commit; idempotent
    local g="$WORK/write-back" count targets
    mkdir -p "$g"
    git init -q --bare "$g/remote.git"
    git -C "$g/remote.git" symbolic-ref HEAD refs/heads/main
    git init -q "$g/work"
    copy_config "$g/work/config"
    git -C "$g/work" checkout -q -b main
    git -C "$g/work" add -A
    git -C "$g/work" -c user.name=test -c user.email=test@example.com commit -q -m fixture
    git -C "$g/work" remote add origin "$g/remote.git"
    git -C "$g/work" push -q origin main 2>/dev/null
    run in_dir "$g/work" env -u GITHUB_RUN_ID WRITE_BACK_PLACEMENTS="$TRADES=$H2 cash/source-database/gone=$H1" \
        "$REPO/scripts/ci/write-back-tag.sh" us-dev 0.1.0-rc.99
    expect_rc 0
    expect_in "cash/source-database/gone was not deployed" "$ERR"
    targets="$(git -C "$g/remote.git" show main:config/us-dev/cash/workflows-config.yml)"
    expect_json "$(yq -o=json '.' <<<"$targets")" '.targets[] | select(.instance == "source-database/trades-db-to-amps") | .host' "$H2"
    [ "$(git -C "$g/remote.git" diff main~1 main -- config/us-dev/cash/workflows-config.yml | grep -c '^[-+] ')" -eq 1 ] ||
        fail "the placement is not a one-line change: $(git -C "$g/remote.git" diff main~1 main -- config/us-dev/cash/workflows-config.yml)"
    expect_in "IMAGE_TAG=0.1.0-rc.99" "$(git -C "$g/remote.git" show main:config/us-dev/cash/source-database/trades-db-to-amps/compose.env)"
    expect_in "chore(config): us-dev deployed 0.1.0-rc.99 [skip ci]" "$(git -C "$g/remote.git" log -1 --format=%B main)"
    expect_in "us-dev/$TRADES on $H2" "$(git -C "$g/remote.git" log -1 --format=%B main)"
    expect_in "github-actions[bot]" "$(git -C "$g/remote.git" log -1 --format=%an main)"
    count="$(git -C "$g/remote.git" rev-list --count main)"
    run in_dir "$g/work" env -u GITHUB_RUN_ID WRITE_BACK_PLACEMENTS="$TRADES=$H2" \
        "$REPO/scripts/ci/write-back-tag.sh" us-dev 0.1.0-rc.99
    expect_rc 0
    expect_in "nothing to write back" "$OUT"
    [ "$(git -C "$g/remote.git" rev-list --count main)" = "$count" ] || fail "an idempotent write-back committed"
    run "$REPO/scripts/ci/set-target-host.sh" "$g/work/config/us-dev/cash/workflows-config.yml" source-database/gone "$H1"
    expect_rc 4
    run "$REPO/scripts/ci/set-target-host.sh" "$g/work/config/us-dev/cash/workflows-config.yml" source-database/trades-db-to-amps dev-other.example.com
    expect_rc 4
    run "$REPO/scripts/ci/set-target-host.sh" "$g/work/config/us-dev/cash/workflows-config.yml" "$TRADES" "$H1"
    expect_rc 2
}

# --- runner -----------------------------------------------------------------------------------------------

selected=("$@")
[ "${#selected[@]}" -gt 0 ] || read -r -a selected <<<"$(tr '\n' ' ' <<<"$CASES")"
passed=0 failed=0
for name in "${selected[@]}"; do
    case " $(tr '\n' ' ' <<<"$CASES") " in *" $name "*) ;; *) echo "pool-deploy-test: unknown case '$name' (cases: $CASES)" >&2; exit 2 ;; esac
    status=0
    ( CASE_FAILED=0; "case_$name"; exit "$CASE_FAILED" ) >"$WORK/case.out" 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        echo "ok - $name"
        passed=$((passed + 1))
    else
        echo "not ok - $name$([ "$status" -eq 1 ] || echo " (aborted with exit $status)")"
        cat "$WORK/case.out"
        failed=$((failed + 1))
    fi
done
echo "pool-deploy-test: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
