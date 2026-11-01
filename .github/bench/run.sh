#!/usr/bin/env bash
# One comparison on one runner: each database with the base branch's code, then with the PR's, so the numbers can be set side by side.
#   run.sh <folder> <pr number> <head sha> <results json>
# ci/bench.conf in the folder says what to run, ci/compose.yml starts the databases.
set -uo pipefail
FOLDER=$1; PR=$2; HEAD_SHA=$3; OUT=$(realpath -m "$4"); LOGS=${OUT%.json}.log
mkdir -p "$(dirname "$OUT")"; : > "$LOGS"
ROOT=$PWD; WORK=$(mktemp -d); K6_IMAGE=grafana/k6:2.3.0
git worktree add -q "$WORK/base" HEAD^1
ROWS="$WORK/rows.jsonl"; : > "$ROWS"

row() { python3 .github/bench/row.py "$@" >> "$ROWS"; }

one() {  # <database> <base|pr> <folder of that version>
  local db=$1 version=$2 dir=$3 summary="$WORK/$db-$version/summary.json" status=0 pid
  mkdir -p "$(dirname "$summary")"; chmod 777 "$(dirname "$summary")"
  (
    source "$dir/ci/bench.conf"
    dsn_var="DSN_$db"; export DB_KIND=$db DB_DSN=${!dsn_var} ADDR=127.0.0.1:8000
    docker compose -f "$dir/ci/compose.yml" up -d --wait "$db" || exit 10
    (cd "$dir/app" && go build -o "$WORK/app-$version") || exit 11
    "$WORK/app-$version" seed $SEED || exit 12
    "$WORK/app-$version" & pid=$!
    for _ in $(seq 30); do curl -fs http://127.0.0.1:8000/healthz >/dev/null && break; sleep 1; done
    docker run --rm --network host -v "$dir:/src:ro" -v "$(dirname "$summary"):/out" "$K6_IMAGE" run --quiet --no-usage-report \
      --summary-export /out/summary.json -e BASE_URL=http://127.0.0.1:8000 $K6_ENV "/src/$K6_SCRIPT"
    k6=$?
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    exit $k6
  ) >> "$LOGS" 2>&1
  status=$?
  docker compose -f "$dir/ci/compose.yml" down -v --timeout 5 >> "$LOGS" 2>&1
  row "$db" "$version" "$summary" "$status"
}

source "$FOLDER/ci/bench.conf"
for db in $DBS; do
  [ -f "$WORK/base/$FOLDER/ci/bench.conf" ] && one "$db" base "$WORK/base/$FOLDER"
  one "$db" pr "$ROOT/$FOLDER"
done

k6_changed=false
[ -f "$WORK/base/$FOLDER/$K6_SCRIPT" ] && ! cmp -s "$WORK/base/$FOLDER/$K6_SCRIPT" "$FOLDER/$K6_SCRIPT" && k6_changed=true
python3 - "$FOLDER" "$PR" "$HEAD_SHA" "$k6_changed" "$ROWS" > "$OUT" <<'PY'
import json, sys
folder, pr, sha, changed, rows = sys.argv[1:]
print(json.dumps({'folder': folder, 'pr': int(pr), 'head_sha': sha, 'k6_changed': changed == 'true', 'rows': [json.loads(l) for l in open(rows)]}))
PY
git worktree remove --force "$WORK/base"
