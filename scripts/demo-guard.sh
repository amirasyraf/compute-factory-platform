#!/usr/bin/env bash
set -euo pipefail
# Called after validation and again immediately before destructive work.
# Manual destroy remains unchanged. Automatic cleanup must be current and generation-bound.
proceed=true
if [[ -n "${DEMO_GENERATION:-}" ]]; then
  file="${INVENTORY_ROOT:-.}/vms/${NAME:?}/catalog-info.yaml"
  [[ "$NAME" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || exit 1
  proceed=false
  if [[ -f "$file" ]]; then
    current=$(yq -r '.metadata.annotations."cf/request-id"' "$file")
    if [[ -n "${EXPECTED_REQUEST_ID:-}" && "$current" == "$EXPECTED_REQUEST_ID" ]]; then
      # Fail closed on API/auth/network errors; never silently permit destruction.
      result=$(curl --fail --silent --show-error --max-time 20 --get \
        -H "Authorization: Bearer ${BACKSTAGE_TOKEN:?}" \
        --data-urlencode "generation=$DEMO_GENERATION" \
        --data-urlencode "request_id=$EXPECTED_REQUEST_ID" \
        "${BACKSTAGE_URL:?}/api/vms/cleanup-check/$NAME")
      jq -se 'length == 1 and (.[0] | type == "object" and (.destroy | type == "boolean"))' <<< "$result" >/dev/null
      if jq -e '.destroy == true' <<< "$result" >/dev/null; then proceed=true; fi
    fi
  fi
  [[ "$proceed" == true ]] || echo 'Automatic cleanup skipped: mode/VM generation is no longer eligible'
fi
echo "proceed=$proceed" >> "${GITHUB_OUTPUT:?}"
