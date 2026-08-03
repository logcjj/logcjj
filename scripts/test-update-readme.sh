#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/repo/scripts" "$test_root/bin"
cp "$repo_root/README.md" "$test_root/repo/README.md"
cp "$repo_root/scripts/update-readme.mjs" "$test_root/repo/scripts/update-readme.mjs"

cat >"$test_root/bin/tokscale" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "totalInput": 1000,
  "totalOutput": 200,
  "totalCacheRead": 300,
  "totalCacheWrite": 400,
  "totalMessages": 50,
  "totalCost": 12.34
}
JSON
EOF
chmod +x "$test_root/bin/tokscale"

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

PATH="$test_root/bin:$PATH" node "$test_root/repo/scripts/update-readme.mjs" --ops-snapshot "$test_root/ops.json"

grep -F '| Today | 1,900 | $12.34 | 50 |' "$test_root/repo/README.md" >/dev/null
grep -F '| Last 24 hours | 1,234 | 9,876,543 | 99.87% | 456.8 | 3,210 ms |' "$test_root/repo/README.md" >/dev/null
[[ "$(grep -c '<!-- sub2api-ops:start -->' "$test_root/repo/README.md")" -eq 1 ]]
[[ "$(grep -c '<!-- sub2api-ops:end -->' "$test_root/repo/README.md")" -eq 1 ]]

printf 'update-readme tests passed\n'
