#!/usr/bin/env bash
set -euo pipefail

image=${1:?Usage: container-lifecycle.sh IMAGE}
scratch=$(mktemp -d)
volume=$(docker volume create)
container=
cleanup() {
  if [[ -n "$container" ]]; then docker rm -f "$container" >/dev/null; fi
  docker volume rm "$volume" >/dev/null
  rm -rf "$scratch"
}
trap cleanup EXIT

start_vault() {
  container=$(docker run -d --mount "type=volume,source=$volume,target=/vault" \
    -p 127.0.0.1::8743 "$image")
  local address
  address=$(docker port "$container" 8743/tcp)
  base="http://$address"
  curl -fsS --retry 15 --retry-delay 1 --retry-all-errors --max-time 3 \
    "$base/health" > "$scratch/health.json"
}

owner_request() {
  curl -fsS --max-time 10 -H "Authorization: Bearer $owner" \
    -H 'Content-Type: application/json' -b "$scratch/cookie" -c "$scratch/cookie" "$@"
}

start_vault
jq -e '.initialized == false and .unlocked == false' "$scratch/health.json" >/dev/null
owner=$(docker exec "$container" context-vault token owner)
touch "$scratch/cookie"
password='{"password":"Synthetic CI lifecycle passphrase"}'
owner_request -d "$password" "$base/api/setup" | jq -e '.unlocked' >/dev/null
fixture='{"kind":"profile","label":"Container fixture","value":"synthetic vault lifecycle record"}'
id=$(owner_request -d "$fixture" "$base/api/items" | jq -er '.id')
# The volume holds ciphertext even before the originally unlocked process exits.
docker exec "$container" python -c 'from pathlib import Path
p = Path("/vault/vault.cvault").read_bytes()
assert p and b"synthetic vault lifecycle record" not in p and b"Container fixture" not in p'

docker rm -f "$container" >/dev/null
container=
start_vault
jq -e '.initialized == true and .unlocked == false' "$scratch/health.json" >/dev/null
# Try the original owner token and the original cookie before unlocking again.
status=$(curl -sS --max-time 5 -o "$scratch/locked.json" -w '%{http_code}' \
  -H "Authorization: Bearer $owner" -b "$scratch/cookie" "$base/api/items/$id")
[[ "$status" == 423 ]]
jq -e '.error == "Vault locked" and (has("value") | not)' "$scratch/locked.json" >/dev/null
owner_request -d "$password" "$base/api/unlock" | jq -e '.unlocked' >/dev/null
owner_request "$base/api/items/$id" | jq -e --arg id "$id" \
  '.id == $id and .label == "Container fixture" and .value == "synthetic vault lifecycle record"' >/dev/null
echo "Container replacement, locked access, and owner recovery passed."
