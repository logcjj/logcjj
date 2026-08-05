#!/usr/bin/env bash

set -euo pipefail
umask 077

if [[ "$#" -ne 1 ]]; then
  printf 'Usage: %s OUTPUT_PATH\n' "$0" >&2
  exit 1
fi

cc_switch_db="${CC_SWITCH_DB:-$HOME/.cc-switch/cc-switch.db}"
output_path="$1"
output_dir="$(dirname "$output_path")"
temp_path=""

cleanup() {
  [[ -z "$temp_path" ]] || rm -f "$temp_path"
}
trap cleanup EXIT

for command_name in jq sqlite3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done

if [[ ! -f "$cc_switch_db" ]]; then
  printf 'cc-switch database not found: %s\n' "$cc_switch_db" >&2
  exit 1
fi

mkdir -p "$output_dir"
temp_path="$(mktemp "$output_dir/.usage-snapshot.XXXXXX")"

sqlite3 -bail -json "$cc_switch_db" "
WITH cutoff AS (
  SELECT COALESCE(MAX(date), '0001-01-01') AS date FROM usage_daily_rollups
), daily AS (
  SELECT
    date,
    request_count AS messages,
    input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens AS tokens,
    CAST(total_cost_usd AS REAL) AS cost
  FROM usage_daily_rollups

  UNION ALL

  SELECT
    date(CASE WHEN created_at > 100000000000 THEN created_at / 1000 ELSE created_at END, 'unixepoch', 'localtime'),
    1,
    input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens,
    CAST(total_cost_usd AS REAL)
  FROM proxy_request_logs, cutoff
  WHERE status_code BETWEEN 200 AND 299
    AND date(CASE WHEN created_at > 100000000000 THEN created_at / 1000 ELSE created_at END, 'unixepoch', 'localtime') > cutoff.date
), windows AS (
  SELECT 1 AS position, 'Today' AS label, COALESCE(SUM(tokens), 0) AS tokens, COALESCE(SUM(cost), 0) AS cost, COALESCE(SUM(messages), 0) AS messages FROM daily WHERE date = date('now', 'localtime')
  UNION ALL SELECT 2, 'Last 7 days', COALESCE(SUM(tokens), 0), COALESCE(SUM(cost), 0), COALESCE(SUM(messages), 0) FROM daily WHERE date >= date('now', 'localtime', '-6 days')
  UNION ALL SELECT 3, 'Last 30 days', COALESCE(SUM(tokens), 0), COALESCE(SUM(cost), 0), COALESCE(SUM(messages), 0) FROM daily WHERE date >= date('now', 'localtime', '-29 days')
  UNION ALL SELECT 4, 'All time', COALESCE(SUM(tokens), 0), COALESCE(SUM(cost), 0), COALESCE(SUM(messages), 0) FROM daily
), models AS (
  SELECT app_type AS app, model, SUM(request_count) AS messages, SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens) AS tokens, SUM(CAST(total_cost_usd AS REAL)) AS cost
  FROM usage_daily_rollups
  GROUP BY app_type, model

  UNION ALL

  SELECT app_type, model, COUNT(*), SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), SUM(CAST(total_cost_usd AS REAL))
  FROM proxy_request_logs, cutoff
  WHERE status_code BETWEEN 200 AND 299
    AND date(CASE WHEN created_at > 100000000000 THEN created_at / 1000 ELSE created_at END, 'unixepoch', 'localtime') > cutoff.date
  GROUP BY app_type, model
)
SELECT json_object(
  'windows', json((SELECT json_group_array(json_object('label', label, 'tokens', tokens, 'cost', cost, 'messages', messages)) FROM (SELECT * FROM windows ORDER BY position))),
  'models', json((SELECT json_group_array(json_object('app', app, 'model', model, 'tokens', tokens, 'cost', cost, 'messages', messages)) FROM (SELECT app, model, SUM(tokens) AS tokens, SUM(cost) AS cost, SUM(messages) AS messages FROM models GROUP BY app, model ORDER BY tokens DESC LIMIT 8)))
) AS snapshot;
" | jq -er '.[0].snapshot | fromjson' >"$temp_path"

jq -e '.windows | length == 4' "$temp_path" >/dev/null
jq -e '.models | length > 0 and all(.model != "cc-switch-rollup")' "$temp_path" >/dev/null

mv "$temp_path" "$output_path"
printf 'cc-switch usage snapshot ready: %s\n' "$output_path"
