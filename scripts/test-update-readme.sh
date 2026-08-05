#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/repo/scripts"
cp "$repo_root/README.md" "$test_root/repo/README.md"
cp "$repo_root/scripts/update-readme.mjs" "$test_root/repo/scripts/update-readme.mjs"

cat >"$test_root/ops.json" <<'JSON'
{
  "code": 0,
  "data": {
    "generated_at": "2026-08-03T06:42:48Z",
    "overview": {
      "start_time": "2026-08-02T06:42:48Z",
      "end_time": "2026-08-03T06:42:48Z",
      "request_count_total": 1234,
      "token_consumed": 9876543,
      "sla": 0.9987,
      "tps": {"avg": 456.78},
      "duration": {"p50_ms": 3210}
    }
  }
}
JSON

cat >"$test_root/usage.json" <<'JSON'
{
  "windows": [
    {"label": "Today", "tokens": 1900, "cost": 12.34, "messages": 50},
    {"label": "Last 7 days", "tokens": 2900, "cost": 22.34, "messages": 60},
    {"label": "Last 30 days", "tokens": 3900, "cost": 32.34, "messages": 70},
    {"label": "All time", "tokens": 4900, "cost": 42.34, "messages": 80}
  ],
  "models": [
    {"app": "codex", "model": "gpt-5.6-sol", "tokens": 3000, "cost": 30.25, "messages": 30},
    {"app": "claude", "model": "qwen3.7-plus", "tokens": 1900, "cost": 12.09, "messages": 20}
  ]
}
JSON

node "$test_root/repo/scripts/update-readme.mjs" --ops-snapshot "$test_root/ops.json" --usage-snapshot "$test_root/usage.json"
node "$test_root/repo/scripts/update-readme.mjs" --ops-snapshot "$test_root/ops.json" --usage-snapshot "$test_root/usage.json"

grep -F '| Window | Tokens | Cost | Requests |' "$test_root/repo/README.md" >/dev/null
grep -F '| Today | 1,900 | $12.34 | 50 |' "$test_root/repo/README.md" >/dev/null
grep -F '| codex | gpt-5.6-sol | 3,000 | $30.25 | 30 |' "$test_root/repo/README.md" >/dev/null
grep -F '| claude | qwen3.7-plus | 1,900 | $12.09 | 20 |' "$test_root/repo/README.md" >/dev/null
! grep -F 'cc-switch-rollup' "$test_root/repo/README.md" >/dev/null
grep -F '| Last 24 hours | 1,234 | 9,876,543 | 99.87% | 456.8 | 3,210 ms |' "$test_root/repo/README.md" >/dev/null
[[ "$(grep -c '<!-- sub2api-ops:start -->' "$test_root/repo/README.md")" -eq 1 ]]
[[ "$(grep -c '<!-- sub2api-ops:end -->' "$test_root/repo/README.md")" -eq 1 ]]
[[ "$(grep -c '^### Top Models$' "$test_root/repo/README.md")" -eq 1 ]]

jq '.windows |= reverse' "$test_root/usage.json" >"$test_root/bad-usage.json"
if node "$test_root/repo/scripts/update-readme.mjs" --usage-snapshot "$test_root/bad-usage.json" 2>/dev/null; then
  printf 'update-readme accepted invalid usage windows\n' >&2
  exit 1
fi

node "$test_root/repo/scripts/update-readme.mjs" --heartbeat-only

printf 'update-readme tests passed\n'
