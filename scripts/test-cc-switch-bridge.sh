#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

source_db="$test_root/cc-switch's.db"
bridge_db="$test_root/sqlite.db"

sqlite3 "$source_db" <<'SQL'
CREATE TABLE usage_daily_rollups (
  date TEXT NOT NULL,
  app_type TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  model TEXT NOT NULL,
  request_count INTEGER NOT NULL,
  success_count INTEGER NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  cache_read_tokens INTEGER NOT NULL,
  cache_creation_tokens INTEGER NOT NULL,
  total_cost_usd TEXT NOT NULL,
  avg_latency_ms INTEGER NOT NULL
);
CREATE TABLE proxy_request_logs (
  request_id TEXT PRIMARY KEY,
  app_type TEXT NOT NULL,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  cache_read_tokens INTEGER NOT NULL,
  cache_creation_tokens INTEGER NOT NULL,
  total_cost_usd TEXT NOT NULL,
  status_code INTEGER NOT NULL,
  session_id TEXT,
  created_at INTEGER NOT NULL
);
INSERT INTO usage_daily_rollups VALUES
  ('2026-08-01', 'codex', 'provider-a', 'gpt-5.6-sol', 2, 2, 5, 3, 4, 2, '1.25', 10),
  ('2026-08-01', 'claude', 'provider-b', 'Claude-Haiku-4-5-20251001', 1, 1, 7, 1, 0, 0, '0', 10);
INSERT INTO proxy_request_logs VALUES
  ('new-success', 'codex', 'gpt-5.6-luna', 11, 2, 3, 4, '0.75', 200, 'session-a', strftime('%s', '2026-08-02 12:00:00')),
  ('old-success', 'codex', 'gpt-5.5', 100, 0, 0, 0, '10', 200, 'session-b', strftime('%s', '2026-08-01 13:00:00')),
  ('new-failure', 'codex', 'gpt-5.6-luna', 100, 0, 0, 0, '10', 500, 'session-c', strftime('%s', '2026-08-02 13:00:00'));
SQL

CC_SWITCH_DB="$source_db" TOKSCALE_BRIDGE_DB="$bridge_db" "$repo_root/scripts/build-cc-switch-bridge.sh"
CC_SWITCH_DB="$source_db" "$repo_root/scripts/build-cc-switch-usage-snapshot.sh" "$test_root/usage.json" >/dev/null
CC_SWITCH_DB="$source_db" "$repo_root/scripts/build-cc-switch-tokscale-snapshot.sh" "$test_root/tokscale.json" >/dev/null

[[ "$(sqlite3 "$bridge_db" 'SELECT COUNT(*) FROM messages;')" -eq 4 ]]
[[ "$(sqlite3 "$bridge_db" 'SELECT COUNT(DISTINCT model) FROM messages;')" -eq 3 ]]
[[ "$(sqlite3 "$bridge_db" 'SELECT SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens) FROM messages;')" -eq 42 ]]
[[ "$(sqlite3 "$bridge_db" "SELECT printf('%.2f', SUM(CASE WHEN cost > 0.000000001 THEN cost ELSE 0 END)) FROM messages;")" == '2.00' ]]
[[ "$(sqlite3 "$bridge_db" "SELECT COUNT(*) FROM messages WHERE model = 'cc-switch-rollup' OR model LIKE 'model: % (cc-switch)';")" -eq 0 ]]
[[ "$(sqlite3 "$bridge_db" "SELECT COUNT(*) FROM messages WHERE model = 'gpt-5.6-sol';")" -eq 2 ]]
[[ "$(jq -r '.windows[] | select(.label == "All time") | .tokens' "$test_root/usage.json")" -eq 42 ]]
[[ "$(jq -r '.windows[] | select(.label == "All time") | .cost' "$test_root/usage.json")" == '2' ]]
[[ "$(jq -r '.models | length' "$test_root/usage.json")" -eq 3 ]]
[[ "$(jq -r '.models[0].model' "$test_root/usage.json")" == 'gpt-5.6-luna' ]]
[[ "$(jq -r '.summary.totalTokens' "$test_root/tokscale.json")" -eq 42 ]]
[[ "$(jq -r '.summary.totalCost' "$test_root/tokscale.json")" == '2' ]]
[[ "$(jq -r '.summary.clients | join(",")' "$test_root/tokscale.json")" == 'claude,codex' ]]
[[ "$(jq -r '.summary.models | index("claude-haiku-4-5") != null' "$test_root/tokscale.json")" == 'true' ]]
[[ "$(jq -r '.summary.models | index("claude-haiku-4-5-20251001") == null' "$test_root/tokscale.json")" == 'true' ]]
[[ "$(jq -r '[.contributions[].clients[] | select(.client == "codex" and .modelId == "gpt-5.6-sol")] | length' "$test_root/tokscale.json")" -eq 1 ]]
[[ "$(jq -r '[.contributions[].clients[] | select(.client == "synthetic")] | length' "$test_root/tokscale.json")" -eq 0 ]]

sqlite3 "$source_db" "UPDATE usage_daily_rollups SET model = 'gpt-5.6-sol-updated' WHERE model = 'gpt-5.6-sol';"
CC_SWITCH_DB="$source_db" TOKSCALE_BRIDGE_DB="$bridge_db" "$repo_root/scripts/build-cc-switch-bridge.sh" >/dev/null

[[ -f "${bridge_db}.previous" ]]
[[ "$(sqlite3 "${bridge_db}.previous" "SELECT COUNT(*) FROM messages WHERE model = 'gpt-5.6-sol';")" -eq 2 ]]
[[ "$(sqlite3 "$bridge_db" "SELECT COUNT(*) FROM messages WHERE model = 'gpt-5.6-sol-updated';")" -eq 2 ]]

printf 'cc-switch bridge tests passed\n'
