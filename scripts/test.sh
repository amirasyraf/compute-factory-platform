#!/usr/bin/env bash
# Offline integration checks: real yq/jq/git, isolated local bare remote, no AWS calls.
set -euo pipefail
root=$(pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cf-platform-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
git init --bare --initial-branch=main "$tmp/remote.git" >/dev/null
mkdir "$tmp/work"
cd "$tmp/work"
git init --initial-branch=main >/dev/null
git config user.name test
git config user.email test@example.invalid
git remote add origin "$tmp/remote.git"
cp -R "$root/scripts" scripts
mkdir -p vms ansible
touch vms/.gitkeep
printf 'git: {linux: git}\nhtop: {linux: htop}\nnginx: {linux: nginx}\ndocker: {linux: docker.io}\n' > ansible/software-catalog.yml
git add .
git commit -m fixture >/dev/null
git push -u origin main >/dev/null
export NAME=test-vm REQUESTER_TEAMS=group:default/alpha REQUESTED_BY=tester
export SPEC_JSON='{"type":"vm","owner":"group:default/alpha","compute":{"platform":"aws","os":"ubuntu","size":"S"},"configuration":{"software":[],"adJoin":false},"billing":{"costCenter":"CC-123","projectCode":"P-1"},"cloudTags":{"environment":"test"}}'
export GITHUB_RUN_ID=123 GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=example/platform
export BACKSTAGE_URL='' BACKSTAGE_TOKEN=''
export GITHUB_OUTPUT="$tmp/outputs"
bash scripts/validate.sh provision
grep -q '^team=alpha$' "$GITHUB_OUTPUT"
export TEAM=alpha
REQUESTER_TEAMS=group:default/platform-admins bash scripts/team-guard.sh
if REQUESTER_TEAMS=bravo bash scripts/team-guard.sh; then echo 'Guard allowed other team' >&2; exit 1; fi
bad_spec=$(jq '.configuration.software=["not-allowed"]' <<< "$SPEC_JSON")
if SPEC_JSON="$bad_spec" bash scripts/validate.sh provision; then echo 'Unknown software allowed' >&2; exit 1; fi
if NAME=../../escape bash scripts/validate.sh provision; then echo 'Invalid name allowed' >&2; exit 1; fi
bash scripts/inventory.sh register
test -f vms/.gitkeep
test ! -f "vms/$NAME/request.yaml"
yq -o=json '.' "vms/$NAME/catalog-info.yaml" | jq -e '.spec.owner=="group:default/alpha" and .spec.configuration.software==[] and .spec.configuration.adJoin==false and .metadata.annotations["cf/requested-by"]=="tester" and (.metadata.annotations|has("cf/software")|not)'
yq -r '.metadata.annotations."cf/stages"' "vms/$NAME/catalog-info.yaml" | jq -e 'keys_unsorted==["provision","baseline","software","ad-join","access"]'
yq -r '.metadata.annotations."cf/processes"' "vms/$NAME/catalog-info.yaml" | jq -e 'keys_unsorted==["validate","register","provision","fry-baseline","fry-software","fry-ad-join","fry-access","finalize","on-failure"]'
if bash scripts/validate.sh provision; then echo 'Duplicate VM allowed' >&2; exit 1; fi

# Simulate an unrelated VM commit after this runner's checkout, exercising pull/rebase.
git clone "$tmp/remote.git" "$tmp/other" >/dev/null
git -C "$tmp/other" config user.name other
git -C "$tmp/other" config user.email other@example.invalid
mkdir "$tmp/other/vms/other-vm"
touch "$tmp/other/vms/other-vm/catalog-info.yaml"
git -C "$tmp/other" add .
git -C "$tmp/other" commit -m 'another VM' >/dev/null
git -C "$tmp/other" push >/dev/null
# Inventory rebasing must preserve, rather than depend on, unrelated dirty files.
printf '# unrelated local edit\n' >> ansible/software-catalog.yml
# Mock only the Terraform boundary, leaving real inventory/Git operations in place.
# A runner must not modify tracked lockfiles before the inventory rebase.
# Exported for the child shell running scripts/terraform.sh.
# shellcheck disable=SC2329
terraform() {
  case "$2" in
    init) [[ " $* " == *" -lockfile=readonly "* ]] ;;
    apply)
      local arg
      for arg in "$@"; do
        if [[ "$arg" == -var-file=* ]]; then cp "${arg#-var-file=}" "$CAPTURED_VARS"; fi
      done
      [[ -f "$CAPTURED_VARS" ]]
      ;;
    output)
      case "$4" in
        public_ip) printf 192.0.2.10 ;;
        ssh_user) printf ubuntu ;;
        instance_id) printf i-test ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}
export -f terraform
export AWS_REGION=ap-southeast-2 TF_STATE_BUCKET=test-bucket
export CAPTURED_VARS="$tmp/applied.json"
# Deliberately change the tracked entity and inject conflicting legacy environment values.
# Terraform must consume the entity, not the original dispatch or legacy annotations.
yq -i '.spec.compute.size = "M"' "vms/$NAME/catalog-info.yaml"
SIZE=L TEAM=bravo SOFTWARE=nginx AD_JOIN=true bash scripts/terraform.sh apply
jq -e '.size=="M" and .team=="alpha" and .requested_by=="tester" and .cloud_tags=={"environment":"test","billing:cost-center":"CC-123","billing:project-code":"P-1"}' "$CAPTURED_VARS"
unset -f terraform
yq -r '.metadata.annotations."cf/stages"' "vms/$NAME/catalog-info.yaml" | jq -e '.["software"]=="skipped" and .["ad-join"]=="skipped"'
yq -r '.metadata.annotations."cf/processes"' "vms/$NAME/catalog-info.yaml" | jq -e '.["fry-software"]=="skipped" and .["fry-ad-join"]=="skipped"'
test -f vms/other-vm/catalog-info.yaml
grep -q '# unrelated local edit' ansible/software-catalog.yml
STAGE=baseline STAGE_STATUS=running bash scripts/inventory.sh update
bash scripts/inventory.sh failure
yq -o=json '.' "vms/$NAME/catalog-info.yaml" | jq -e '.metadata.annotations as $a | $a["cf/status"]=="failed" and ($a["cf/stages"]|fromjson|.baseline)=="failed" and ($a["cf/processes"]|fromjson|."fry-baseline")=="failed" and ($a["cf/processes"]|fromjson|."on-failure")=="success"'
if REQUESTER_TEAMS=bravo bash scripts/validate.sh existing; then echo 'Existing VM guard bypassed' >&2; exit 1; fi
SOFTWARE_INPUT='["htop"]' STAGE=software bash scripts/validate.sh existing
grep -q '^host=192.0.2.10$' "$GITHUB_OUTPUT"
configured=$(grep '^spec_json=' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-)
SPEC_JSON="$configured" bash scripts/inventory.sh configure
yq -o=json '.spec' "vms/$NAME/catalog-info.yaml" | jq -e '.configuration.software==["htop"] and .compute.size=="M" and .billing.costCenter=="CC-123"'
STAGE=ad-join bash scripts/validate.sh existing
configured=$(grep '^spec_json=' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-)
SPEC_JSON="$configured" bash scripts/inventory.sh configure
yq -o=json '.spec' "vms/$NAME/catalog-info.yaml" | jq -e '.configuration.adJoin==true and .configuration.software==["htop"]'
before=$(yq -o=json '.spec' "vms/$NAME/catalog-info.yaml" | jq -c .)
STATUS=ready STAGE=baseline STAGE_STATUS=success bash scripts/inventory.sh update
STATUS=ready STAGE=software bash scripts/inventory.sh update
yq -r '.metadata.annotations."cf/stages"' "vms/$NAME/catalog-info.yaml" | jq -e '.software=="skipped" and .baseline=="success"'
yq -r '.metadata.annotations."cf/processes"' "vms/$NAME/catalog-info.yaml" | jq -e '.finalize=="success" and ."on-failure"=="skipped"'
GITHUB_RUN_ID=456 STAGE=software STAGE_STATUS=success bash scripts/inventory.sh update
yq -o=json '.' "vms/$NAME/catalog-info.yaml" | jq -e '.metadata.annotations["cf/run-id"]=="456"'
after=$(yq -o=json '.spec' "vms/$NAME/catalog-info.yaml" | jq -c .)
[[ "$before" == "$after" ]] || { echo 'Status update mutated desired configuration' >&2; exit 1; }
bash scripts/inventory.sh delete
test ! -d "vms/$NAME"
test -f vms/.gitkeep
test -f vms/other-vm/catalog-info.yaml
echo 'Offline workflow-helper integration tests passed'
