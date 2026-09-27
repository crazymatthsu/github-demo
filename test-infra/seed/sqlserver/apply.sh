#!/usr/bin/env bash
# test-infra/seed/sqlserver/apply.sh: apply SQL files inside the test-infra sqlserver container (D8 §6.3).
#
# sqlserver.yml mounts this directory read-only at /seed and test-infra/testdata at /testdata.
#
#   apply.sh
#       Apply the generic helpers /seed/*.sql, in name order, against master. `stack.sh up` runs this.
#   apply.sh --database <db> <file.sql | dir>...
#       Apply case files against <db>. For a directory, schema.sql comes first, then the other *.sql
#       files in name order.
#
# From the host, with the stack up (COMPOSE_* from the state file or $GITHUB_ENV):
#   docker compose exec -T sqlserver bash /seed/apply.sh --database positions \
#     /testdata/source-database/positions-basic/input
set -euo pipefail

SQLCMD=${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}
: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD is not set; run this inside the sqlserver container}"
database=master
files=()

add_path() {
  local path=$1 f
  if [[ -d $path ]]; then
    if [[ -f $path/schema.sql ]]; then files+=("$path/schema.sql"); fi
    for f in "$path"/*.sql; do
      if [[ -f $f && ${f##*/} != schema.sql ]]; then files+=("$f"); fi
    done
  elif [[ -f $path ]]; then
    files+=("$path")
  else
    echo "apply.sh: no such file or directory: $path" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --database)
      [[ $# -ge 2 ]] || { echo "apply.sh: --database needs a name" >&2; exit 2; }
      database=$2
      shift 2
      ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) echo "apply.sh: unknown option $1" >&2; exit 2 ;;
    *) add_path "$1"; shift ;;
  esac
done
if [[ ${#files[@]} -eq 0 ]]; then add_path /seed; fi
[[ ${#files[@]} -gt 0 ]] || { echo "apply.sh: nothing to apply" >&2; exit 2; }

for f in "${files[@]}"; do
  echo "apply.sh: $f -> [$database]"
  # -C trusts the server's self-signed certificate, -b stops on the first error, -I sets
  # QUOTED_IDENTIFIER ON as JDBC does. The password travels in SQLCMDPASSWORD, not on the command line.
  SQLCMDPASSWORD=$MSSQL_SA_PASSWORD "$SQLCMD" -C -S localhost -U sa -d "$database" -b -I -i "$f"
done
