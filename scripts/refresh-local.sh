#!/usr/bin/env bash

set -euo pipefail
umask 077

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_dir="$repo_root/.git/profile-refresh.lock"
sub2api_url="${SUB2API_URL:-http://localhost:8080}"
sub2api_container="${SUB2API_CONTAINER:-sub2api-app}"

log() {
  printf '[profile-refresh] %s\n' "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing required command: $1"
    exit 1
  fi
}

docker_env_value() {
  local key="$1"
  local line

  while IFS= read -r line; do
    case "$line" in
      "$key="*)
        printf '%s' "${line#*=}"
        return 0
        ;;
    esac
  done

  return 1
}

for command_name in curl docker git jq node tokscale; do
  require_command "$command_name"
done

if ! mkdir "$lock_dir" 2>/dev/null; then
  log "Another refresh is already running."
  exit 0
fi

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir" "$lock_dir"
}
trap cleanup EXIT

cd "$repo_root"

if [[ -n "$(git status --porcelain)" ]]; then
  log "Repository has local changes; refresh skipped."
  exit 1
fi

log "Updating the local checkout."
git pull --ff-only origin main

container_env="$(docker inspect "$sub2api_container" --format '{{range .Config.Env}}{{println .}}{{end}}')"
admin_email="${SUB2API_ADMIN_EMAIL:-$(docker_env_value ADMIN_EMAIL <<<"$container_env")}"
admin_password="${SUB2API_ADMIN_PASSWORD:-$(docker_env_value ADMIN_PASSWORD <<<"$container_env")}"

login_payload="$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')"
login_payload_path="$work_dir/login-payload.json"
login_response="$work_dir/login.json"
auth_header_path="$work_dir/auth-header"
snapshot_path="$work_dir/ops-snapshot.json"

printf '%s' "$login_payload" >"$login_payload_path"

log "Reading the sanitized 24-hour Sub2API aggregate."
curl --fail-with-body --silent --show-error \
  --connect-timeout 5 --max-time 30 \
  -H 'Content-Type: application/json' \
  --data-binary @"$login_payload_path" \
  "$sub2api_url/api/v1/auth/login" >"$login_response"

access_token="$(jq -er '.data.access_token' "$login_response")"
printf 'Authorization: Bearer %s\n' "$access_token" >"$auth_header_path"
unset access_token admin_email admin_password container_env login_payload

curl --fail-with-body --silent --show-error \
  --connect-timeout 5 --max-time 30 \
  -H @"$auth_header_path" \
  "$sub2api_url/api/v1/admin/ops/dashboard/snapshot-v2?time_range=24h" >"$snapshot_path"

jq -e '.code == 0 and (.data.overview | type == "object")' "$snapshot_path" >/dev/null

log "Submitting the current Tokscale snapshot."
tokscale_submitted=false
for attempt in 1 2 3; do
  if tokscale autosubmit run; then
    tokscale_submitted=true
    break
  fi

  log "Tokscale submission attempt $attempt failed."
  [[ "$attempt" -eq 3 ]] || sleep 5
done

if [[ "$tokscale_submitted" != true ]]; then
  log "Tokscale submission remains stale; continuing with local aggregates."
fi

log "Refreshing usage and operations sections."
readme_updated=false
for attempt in 1 2 3; do
  if node scripts/update-readme.mjs --ops-snapshot "$snapshot_path"; then
    readme_updated=true
    break
  fi

  log "README generation attempt $attempt failed."
  [[ "$attempt" -eq 3 ]] || sleep 5
done

if [[ "$readme_updated" != true ]]; then
  log "README generation failed after 3 attempts."
  exit 1
fi

changed_files="$(git status --porcelain)"
if [[ -z "$changed_files" ]]; then
  log "README is already current."
  exit 0
fi

if [[ "$(git diff --name-only)" != "README.md" ]]; then
  log "Unexpected files changed; refresh aborted."
  exit 1
fi

git add README.md
git commit -m "Refresh profile usage and ops"
git pull --rebase origin main
git push origin HEAD:main
log "Profile refresh pushed successfully."
