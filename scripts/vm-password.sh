#!/usr/bin/env bash
# The shared login password of a Windows VM, in Secrets Manager compute-factory/vm/<name> as
# {"username", "password", "requestId"}. The IDP shows it to the owning team and uses it for browser
# RDP, only while requestId matches the incarnation it authorized (a reused name gets a new secret).
#   ensure <vars-file>: create it for this incarnation (or keep it), write {cf_admin_password} to the file
#   delete: remove it if it belongs to this incarnation
set -euo pipefail
umask 077
action=${1:?ensure or delete}
[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || exit 1
: "${REQUEST_ID:?}"
secret="compute-factory/vm/$NAME"
owned=false
if described=$(aws secretsmanager describe-secret --secret-id "$secret" --output json 2>&1); then
  if jq -e '.DeletedDate == null' <<< "$described" >/dev/null; then
    # The tag decides ownership here; the value's requestId binds the password for the IDP.
    owned=$(jq -r --arg request "$REQUEST_ID" '[.Tags[]? | select(.Key == "cf:request-id")][0].Value == $request' <<< "$described")
    exists=true
  else
    exists=deleted
  fi
elif [[ "$described" == *ResourceNotFoundException* ]]; then
  exists=false
else
  echo "Cannot read $secret: $described" >&2
  exit 1
fi
case "$action" in
  ensure)
    out=${2:?vars file}
    if [[ "$exists" == true && "$owned" == true ]]; then
      value=$(aws secretsmanager get-secret-value --secret-id "$secret" --query SecretString --output text)
    else
      password=$(aws secretsmanager get-random-password --password-length 24 --require-each-included-type \
        --exclude-characters "\"'\`\\\$%&;<>|^/" --query RandomPassword --output text)
      value=$(jq -cn --arg user "${SSH_USER:?}" --arg password "$password" --arg request "$REQUEST_ID" \
        '{username: $user, password: $password, requestId: $request}')
      tags=("Key=cf:poc,Value=true" "Key=cf:vm,Value=$NAME" "Key=cf:request-id,Value=$REQUEST_ID")
      case "$exists" in
        # A leftover of an earlier VM with the same name: replace it for this incarnation.
        true)
          aws secretsmanager put-secret-value --secret-id "$secret" --secret-string "$value" >/dev/null
          aws secretsmanager tag-resource --secret-id "$secret" --tags "${tags[@]}"
          ;;
        deleted)
          aws secretsmanager restore-secret --secret-id "$secret" >/dev/null
          aws secretsmanager put-secret-value --secret-id "$secret" --secret-string "$value" >/dev/null
          aws secretsmanager tag-resource --secret-id "$secret" --tags "${tags[@]}"
          ;;
        false)
          aws secretsmanager create-secret --name "$secret" --description "Compute Factory VM $NAME login (POC)" \
            --secret-string "$value" --tags "${tags[@]}" >/dev/null
          ;;
      esac
    fi
    password=$(jq -er '.password' <<< "$value")
    [[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::add-mask::$password"
    jq -n --arg password "$password" '{cf_admin_password: $password}' > "$out"
    ;;
  delete)
    if [[ "$exists" == true && "$owned" == true ]]; then
      aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery >/dev/null
      echo "Deleted $secret"
    fi
    ;;
  *) echo 'Unknown action' >&2; exit 1 ;;
esac
