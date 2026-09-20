#!/usr/bin/env bash
# Zealse Connect deploy relay — runs ON the Hostinger server (triggered via
# account cron). GitHub Actions was failing at runner allocation (account
# minutes), and the sandbox cannot reach srv1826-files, so this script closes
# the gap: it downloads deploy archives from the public artifact repo, pushes
# them into the target site's file storage over TUS, and triggers the
# platform's own Node.js build pipeline (the same flow an API deploy uses).
#
# Env (set by the cron command, never stored in the repo):
#   RELAY_TOKEN  Hostinger developer API token (Bearer)
#   RELAY_TASKS  space-separated tasks: domain:archive:mode[:entry]
#                mode = nodejs | static; entry = entry_file for nodejs mode
#
# All output lands in the cron output log.
set -uo pipefail

API="https://developers.hostinger.com/api/hosting/v1"
RAW_BASE="https://raw.githubusercontent.com/navidRashik/zealse-deploy-artifacts/main"
WORK="/tmp/zealse-relay"
USERNAME="u646404230"

log() { echo "[relay $(date -u +%H:%M:%S)] $*"; }

mkdir -p "$WORK"

tus_upload() {
  # $1 = domain, $2 = local file, $3 = remote filename (inside public_html)
  local domain="$1" file="$2" remote="$3"
  local size
  size=$(stat -c%s "$file")
  log "generating upload URL for $domain"
  local gen
  gen=$(curl -sS --max-time 60 -X POST "$API/files/upload-urls" \
    -H "Authorization: Bearer $RELAY_TOKEN" -H "Content-Type: application/json" \
    -d "{\"username\":\"$USERNAME\",\"domain\":\"$domain\"}")
  local url auth rest
  url=$(echo "$gen" | python3 -c "import sys,json;print(json.load(sys.stdin).get('url',''))" 2>/dev/null)
  auth=$(echo "$gen" | python3 -c "import sys,json;print(json.load(sys.stdin).get('auth_key',''))" 2>/dev/null)
  rest=$(echo "$gen" | python3 -c "import sys,json;print(json.load(sys.stdin).get('rest_auth_key',''))" 2>/dev/null)
  if [ -z "$url" ] || [ -z "$auth" ]; then
    log "ERROR: upload-url generation failed: $gen"
    return 1
  fi
  log "tus create $remote ($size bytes)"
  local create_code
  create_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 60 -X POST "$url/$remote?override=true" \
    -H "X-Auth: $auth" -H "X-Auth-Rest: $rest" -H "Tus-Resumable: 1.0.0" \
    -H "Upload-Length: $size" -H "Upload-Offset: 0")
  if [ "$create_code" != "201" ]; then
    log "ERROR: tus create returned $create_code"
    return 1
  fi
  log "tus upload $remote"
  local patch_offset
  patch_offset=$(curl -s -i --max-time 300 -X PATCH "$url/$remote?override=true" \
    -H "X-Auth: $auth" -H "X-Auth-Rest: $rest" -H "Tus-Resumable: 1.0.0" \
    -H "Content-Type: application/offset+octet-stream" -H "Upload-Offset: 0" \
    --data-binary "@$file" | grep -i "^upload-offset:" | tr -d "\r" | cut -d" " -f2)
  if [ "$patch_offset" != "$size" ]; then
    log "ERROR: tus upload incomplete (offset=$patch_offset expected=$size)"
    return 1
  fi
  log "tus upload complete ($remote)"
  return 0
}

nodejs_deploy() {
  # $1 = domain, $2 = archive filename in public_html, $3 = entry_file
  local domain="$1" archive="$2" entry="$3"
  local payload
  payload=$(cat <<JSON
{"node_version":20,"app_type":"other","root_directory":null,"output_directory":null,
 "build_script":"build","entry_file":"$entry","package_manager":null,
 "source_type":"archive","source_options":{"archive_path":"$archive"}}
JSON
  )
  log "starting nodejs build on $domain (entry=$entry)"
  local resp
  resp=$(curl -sS --max-time 120 -X POST "$API/accounts/$USERNAME/websites/$domain/nodejs/builds" \
    -H "Authorization: Bearer $RELAY_TOKEN" -H "Content-Type: application/json" \
    -d "$(echo "$payload" | tr -d "\n")")
  log "build response: $resp"
}

static_deploy() {
  # $1 = domain, $2 = archive filename in public_html
  local domain="$1" archive="$2"
  log "starting static deploy on $domain ($archive)"
  local resp
  resp=$(curl -sS --max-time 120 -X POST "$API/accounts/$USERNAME/websites/$domain/deploy" \
    -H "Authorization: Bearer $RELAY_TOKEN" -H "Content-Type: application/json" \
    -d "{\"archive_path\":\"$archive\"}")
  log "static deploy response: $resp"
}

fetch_archive() {
  # $1 = archive name
  local name="$1"
  log "downloading $name from artifact repo"
  curl -sSL --max-time 240 -o "$WORK/$name" "$RAW_BASE/$name" || { log "ERROR: download failed"; return 1; }
  local size
  size=$(stat -c%s "$WORK/$name")
  if [ "$size" -lt 10000 ]; then log "ERROR: $name too small ($size)"; return 1; fi
  log "downloaded $name ($size bytes)"
  return 0
}

log "relay started; tasks: ${RELAY_TASKS:-none}"

for task in ${RELAY_TASKS:-}; do
  IFS=":" read -r domain archive mode entry <<< "$task"
  log "=== task: $domain / $archive / $mode / ${entry:-} ==="
  if ! fetch_archive "$archive"; then continue; fi
  if tus_upload "$domain" "$WORK/$archive" "$archive"; then
    case "$mode" in
      nodejs) nodejs_deploy "$domain" "$archive" "$entry" ;;
      static) static_deploy "$domain" "$archive" ;;
      *) log "ERROR: unknown mode $mode" ;;
    esac
  fi
done

log "relay finished"
