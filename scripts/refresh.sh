#!/usr/bin/env bash
set -euo pipefail
[[ -n "${BACKSTAGE_URL:-}" && -n "${BACKSTAGE_TOKEN:-}" ]] || exit 0
for ref in "$@"; do
  curl --fail --silent --show-error --max-time 10 \
    -X POST "${BACKSTAGE_URL%/}/api/catalog/refresh" \
    -H "Authorization: Bearer $BACKSTAGE_TOKEN" -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg ref "$ref" '{entityRef:$ref}')" || true
done
