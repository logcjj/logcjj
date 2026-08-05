#!/usr/bin/env bash

set -euo pipefail
umask 077

cc_switch_db="${CC_SWITCH_DB:-$HOME/.cc-switch/cc-switch.db}"
bridge_db="${TOKSCALE_BRIDGE_DB:-$HOME/.local/share/octofriend/sqlite.db}"
previous_db="${bridge_db}.previous"
bridge_dir="$(dirname "$bridge_db")"
temp_db=""

cleanup() {
  [[ -z "$temp_db" ]] || rm -f "$temp_db"
}
trap cleanup EXIT

for command_name in sqlite3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done

if [[ ! -f "$cc_switch_db" ]]; then
  printf 'cc-switch database not found: %s\n' "$cc_switch_db" >&2
  exit 1
fi

mkdir -p "$bridge_dir"
temp_db="$(mktemp "$bridge_dir/.sqlite.db.XXXXXX")"
cc_switch_db_sql=${cc_switch_db//\'/\'\'}

sqlite3 -bail "$temp_db" <<SQL
ATTACH DATABASE '$cc_switch_db_sql' AS cc;

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  cache_read_tokens INTEGER NOT NULL,
  cache_write_tokens INTEGER NOT NULL,
  reasoning_tokens INTEGER NOT NULL,
  cost REAL NOT NULL,
  timestamp REAL NOT NULL,
  session_id TEXT NOT NULL,
  provider TEXT NOT NULL
);

WITH RECURSIVE expanded(
  date,
  app_type,
  provider_id,
  model,
  n,
  request_count,
  input_tokens,
  output_tokens,
  cache_read_tokens,
  cache_creation_tokens,
  total_cost_usd
) AS (
  SELECT
    date,
    app_type,
    provider_id,
    model,
    1,
    request_count,
    input_tokens,
    output_tokens,
    cache_read_tokens,
    cache_creation_tokens,
    CAST(total_cost_usd AS REAL)
  FROM cc.usage_daily_rollups
  WHERE request_count > 0

  UNION ALL

  SELECT
    date,
    app_type,
    provider_id,
    model,
    n + 1,
    request_count,
    input_tokens,
    output_tokens,
    cache_read_tokens,
    cache_creation_tokens,
    total_cost_usd
  FROM expanded
  WHERE n < request_count
)
INSERT INTO messages
SELECT
  'cc-rollup-' || date || '-' || hex(app_type) || '-' || hex(provider_id) || '-' || hex(model) || '-' || n,
  'model: ' || COALESCE(NULLIF(model, ''), 'unknown') || ' (cc-switch)',
  (input_tokens / request_count) + CASE WHEN n <= (input_tokens % request_count) THEN 1 ELSE 0 END,
  (output_tokens / request_count) + CASE WHEN n <= (output_tokens % request_count) THEN 1 ELSE 0 END,
  (cache_read_tokens / request_count) + CASE WHEN n <= (cache_read_tokens % request_count) THEN 1 ELSE 0 END,
  (cache_creation_tokens / request_count) + CASE WHEN n <= (cache_creation_tokens % request_count) THEN 1 ELSE 0 END,
  0,
  CASE
    WHEN total_cost_usd > 0 THEN total_cost_usd / request_count
    ELSE 0.000000001
  END,
  strftime('%s', date || ' 12:00:00'),
  'cc-switch-' || date || '-' || app_type,
  app_type
FROM expanded;

WITH cutoff AS (
  SELECT MAX(date) AS date FROM cc.usage_daily_rollups
)
INSERT INTO messages
SELECT
  'cc-log-' || request_id,
  'model: ' || COALESCE(NULLIF(model, ''), 'unknown') || ' (cc-switch)',
  input_tokens,
  output_tokens,
  cache_read_tokens,
  cache_creation_tokens,
  0,
  CASE
    WHEN CAST(total_cost_usd AS REAL) > 0 THEN CAST(total_cost_usd AS REAL)
    ELSE 0.000000001
  END,
  CASE WHEN created_at > 100000000000 THEN created_at / 1000 ELSE created_at END,
  COALESCE(session_id, 'cc-switch-' || date(CASE WHEN created_at > 100000000000 THEN created_at / 1000 ELSE created_at END, 'unixepoch', 'localtime') || '-' || app_type),
  app_type
FROM cc.proxy_request_logs, cutoff
WHERE status_code BETWEEN 200 AND 299
  AND date(CASE WHEN created_at > 100000000000 THEN created_at / 1000 ELSE created_at END, 'unixepoch', 'localtime') > COALESCE(cutoff.date, '0001-01-01');

CREATE INDEX messages_timestamp ON messages(timestamp);
CREATE INDEX messages_model ON messages(model);
SQL

integrity="$(sqlite3 "$temp_db" 'PRAGMA integrity_check;')"
if [[ "$integrity" != "ok" ]]; then
  printf 'Bridge integrity check failed: %s\n' "$integrity" >&2
  exit 1
fi

source_totals="$(sqlite3 -separator '|' "$cc_switch_db" "
WITH cutoff AS (SELECT MAX(date) AS date FROM usage_daily_rollups), combined AS (
  SELECT
    SUM(request_count) AS requests,
    SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens) AS tokens,
    SUM(CAST(total_cost_usd AS REAL)) AS cost
  FROM usage_daily_rollups
  UNION ALL
  SELECT
    COUNT(*),
    SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens),
    SUM(CAST(total_cost_usd AS REAL))
  FROM proxy_request_logs, cutoff
  WHERE status_code BETWEEN 200 AND 299
    AND date(CASE WHEN created_at > 100000000000 THEN created_at / 1000 ELSE created_at END, 'unixepoch', 'localtime') > COALESCE(cutoff.date, '0001-01-01')
)
SELECT SUM(requests), SUM(tokens), printf('%.8f', SUM(cost)) FROM combined;")"

bridge_totals="$(sqlite3 -separator '|' "$temp_db" "
SELECT
  COUNT(*),
  SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens + reasoning_tokens),
  printf('%.8f', SUM(CASE WHEN cost > 0.000000001 THEN cost ELSE 0 END))
FROM messages;")"

if [[ "$source_totals" != "$bridge_totals" ]]; then
  printf 'Bridge totals do not match cc-switch.\nsource=%s\nbridge=%s\n' "$source_totals" "$bridge_totals" >&2
  exit 1
fi

if sqlite3 "$temp_db" "SELECT COUNT(*) FROM messages WHERE model = 'cc-switch-rollup' OR model NOT LIKE 'model: % (cc-switch)';" | grep -qv '^0$'; then
  printf 'Bridge contains an invalid model label.\n' >&2
  exit 1
fi

if [[ -f "$bridge_db" ]]; then
  cp -p "$bridge_db" "${previous_db}.tmp"
  mv "${previous_db}.tmp" "$previous_db"
fi

mv "$temp_db" "$bridge_db"

model_count="$(sqlite3 "$bridge_db" 'SELECT COUNT(DISTINCT model) FROM messages;')"
printf 'cc-switch bridge ready: %s rows, %s models, %s tokens, %s cost\n' \
  "${bridge_totals%%|*}" \
  "$model_count" \
  "$(cut -d'|' -f2 <<<"$bridge_totals")" \
  "$(cut -d'|' -f3 <<<"$bridge_totals")"
