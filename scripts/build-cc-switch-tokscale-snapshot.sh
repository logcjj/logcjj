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
temp_path="$(mktemp "$output_dir/.tokscale-snapshot.XXXXXX")"

sqlite3 -bail -json "$cc_switch_db" <<'SQL' \
  | jq -er '.[0].snapshot | fromjson' >"$temp_path"
WITH cutoff AS (
  SELECT COALESCE(MAX(date), '0001-01-01') AS date FROM usage_daily_rollups
), raw AS (
  SELECT
    date,
    lower(app_type) AS app,
    lower(COALESCE(NULLIF(model, ''), 'unknown')) AS model,
    request_count AS messages,
    input_tokens AS input,
    output_tokens AS output,
    cache_read_tokens AS cache_read,
    cache_creation_tokens AS cache_write,
    0 AS reasoning,
    CAST(total_cost_usd AS REAL) AS cost
  FROM usage_daily_rollups

  UNION ALL

  SELECT
    date(CASE WHEN created_at > 100000000000 THEN created_at / 1000 ELSE created_at END, 'unixepoch', 'localtime'),
    lower(app_type),
    lower(COALESCE(NULLIF(model, ''), 'unknown')),
    1,
    input_tokens,
    output_tokens,
    cache_read_tokens,
    cache_creation_tokens,
    0,
    CAST(total_cost_usd AS REAL)
  FROM proxy_request_logs, cutoff
  WHERE status_code BETWEEN 200 AND 299
    AND date(CASE WHEN created_at > 100000000000 THEN created_at / 1000 ELSE created_at END, 'unixepoch', 'localtime') > cutoff.date
), normalized AS (
  SELECT
    date,
    app,
    CASE
      WHEN length(model) > 9
        AND substr(model, -9, 1) = '-'
        AND substr(model, -8) GLOB '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
      THEN substr(model, 1, length(model) - 9)
      ELSE model
    END AS model,
    messages,
    input,
    output,
    cache_read,
    cache_write,
    reasoning,
    cost
  FROM raw
), models AS (
  SELECT
    date,
    app,
    model,
    SUM(messages) AS messages,
    SUM(input) AS input,
    SUM(output) AS output,
    SUM(cache_read) AS cache_read,
    SUM(cache_write) AS cache_write,
    SUM(reasoning) AS reasoning,
    SUM(cost) AS cost
  FROM normalized
  GROUP BY date, app, model
), days AS (
  SELECT
    date,
    SUM(messages) AS messages,
    SUM(input) AS input,
    SUM(output) AS output,
    SUM(cache_read) AS cache_read,
    SUM(cache_write) AS cache_write,
    SUM(reasoning) AS reasoning,
    SUM(cost) AS cost
  FROM models
  GROUP BY date
), stats AS (
  SELECT
    MIN(date) AS first_date,
    MAX(date) AS last_date,
    COUNT(*) AS active_days,
    SUM(input + output + cache_read + cache_write + reasoning) AS tokens,
    SUM(cost) AS cost,
    MAX(cost) AS max_cost
  FROM days
), yearly AS (
  SELECT
    substr(date, 1, 4) AS year,
    MIN(date) AS first_date,
    MAX(date) AS last_date,
    SUM(input + output + cache_read + cache_write + reasoning) AS tokens,
    SUM(cost) AS cost
  FROM days
  GROUP BY substr(date, 1, 4)
)
SELECT json_object(
  'meta', json_object(
    'generatedAt', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    'version', 'cc-switch-1',
    'dateRange', json_object('start', first_date, 'end', last_date)
  ),
  'summary', json_object(
    'totalTokens', tokens,
    'totalCost', cost,
    'totalDays', active_days,
    'activeDays', active_days,
    'averagePerDay', CASE WHEN active_days > 0 THEN cost / active_days ELSE 0 END,
    'maxCostInSingleDay', max_cost,
    'clients', json((SELECT json_group_array(app) FROM (SELECT DISTINCT app FROM models ORDER BY app))),
    'models', json((SELECT json_group_array(model) FROM (SELECT DISTINCT model FROM models ORDER BY model)))
  ),
  'years', json((
    SELECT json_group_array(json_object(
      'year', year,
      'totalTokens', tokens,
      'totalCost', cost,
      'range', json_object('start', first_date, 'end', last_date)
    ))
    FROM (SELECT * FROM yearly ORDER BY year)
  )),
  'contributions', json((
    SELECT json_group_array(json_object(
      'date', date,
      'totals', json_object(
        'tokens', input + output + cache_read + cache_write + reasoning,
        'cost', cost,
        'messages', messages
      ),
      'intensity', 1,
      'tokenBreakdown', json_object(
        'input', input,
        'output', output,
        'cacheRead', cache_read,
        'cacheWrite', cache_write,
        'reasoning', reasoning
      ),
      'clients', json((
        SELECT json_group_array(json_object(
          'client', app,
          'modelId', model,
          'providerId', app,
          'tokens', json_object(
            'input', input,
            'output', output,
            'cacheRead', cache_read,
            'cacheWrite', cache_write,
            'reasoning', reasoning
          ),
          'cost', cost,
          'messages', messages
        ))
        FROM (SELECT * FROM models WHERE models.date = ordered_days.date ORDER BY app, model)
      ))
    ))
    FROM (SELECT * FROM days ORDER BY date) AS ordered_days
  ))
) AS snapshot
FROM stats;
SQL

jq -e '.summary.totalTokens > 0 and (.contributions | length) == .summary.activeDays' "$temp_path" >/dev/null
jq -e '[.contributions[].clients[].client] | all(. == "codex" or . == "claude" or . == "gemini")' "$temp_path" >/dev/null
jq -e '[.contributions[].clients[].client] | index("synthetic") == null' "$temp_path" >/dev/null

mv "$temp_path" "$output_path"
printf 'cc-switch Tokscale snapshot ready: %s tokens; clients: %s\n' \
  "$(jq -r '.summary.totalTokens' "$output_path")" \
  "$(jq -r '.summary.clients | join(", ")' "$output_path")"
