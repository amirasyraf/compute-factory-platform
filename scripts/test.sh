#!/usr/bin/env bash
# Offline integration checks: real yq/jq/git, isolated local bare remote, no AWS or mocks.
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
mkdir -p terraform/platforms/aws vms ansible
cp "$root/terraform/platforms/aws/sizes.json" terraform/platforms/aws/
cp "$root/ansible/software-catalog.yml" ansible/
touch vms/.gitkeep
git add .
git commit -m fixture >/dev/null
git push -u origin main >/dev/null
export NAME=test-vm REQUESTER_TEAMS=alpha REQUESTED_BY=tester REQUEST_ID=request-123
export SPEC_JSON='{"type":"vm","owner":"group:default/alpha","compute":{"platform":"aws","os":"ubuntu","size":"S"},"configuration":{"software":[],"adJoin":false},"billing":{"costCenter":"CC-123","projectCode":"P-1"},"cloudTags":{"environment":"test"}}'
export GITHUB_RUN_ID=123 GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=example/platform
export BACKSTAGE_URL='' BACKSTAGE_TOKEN='' GITHUB_OUTPUT="$tmp/outputs"
file="vms/$NAME/catalog-info.yaml"
validate() {
  local params='{}'
  if (( $# > 1 )); then params=$2; fi
  : > "$GITHUB_OUTPUT"
  STAGE="$1" RUN_KEY="42.$1.1" PARAMS_JSON="$params" bash scripts/validate.sh
}
reject() { if "$@"; then echo "Unexpected success: $*" >&2; exit 1; fi; }
entity() { yq -o=json '.' "$file"; }
register_params=$(jq -cn --argjson spec "$SPEC_JSON" '{spec:$spec}')
validate register "$register_params"
grep -qx noop=false "$GITHUB_OUTPUT"
reject env REQUESTER_TEAMS=bravo STAGE=register RUN_KEY=42.register.1 PARAMS_JSON="$register_params" bash scripts/validate.sh
reject env NAME=../../escape STAGE=register RUN_KEY=42.register.1 PARAMS_JSON="$register_params" bash scripts/validate.sh
reject env REQUEST_ID=bad:id STAGE=register RUN_KEY=42.register.1 PARAMS_JSON="$register_params" bash scripts/validate.sh
reject env STAGE=register RUN_KEY=42.access.1 PARAMS_JSON="$register_params" bash scripts/validate.sh
reject validate register '{"spec":{}}'
reject validate provision '{"unexpected":true}'
reject validate finalize '{"outcome":"running"}'
reject validate destroy '{"demoGeneration":"not-a-uuid"}'
bash scripts/inventory.sh register
test -f vms/.gitkeep
test ! -f "vms/$NAME/request.yaml"
entity | jq -e '.metadata.annotations as $a | $a["cf/request-id"]=="request-123" and $a["cf/status"]=="provisioning" and $a["cf/requested-by"]=="tester" and (["cf/stages","cf/processes","cf/provision-run-id","cf/software"] | all(. as $k | $a | has($k) | not))'
original=$(entity | jq -c .)
validate register "$register_params"
grep -qx noop=true "$GITHUB_OUTPUT"
GITHUB_RUN_ID=999 bash scripts/inventory.sh register
[[ "$(entity | jq -c .)" == "$original" ]]
reject env REQUEST_ID=different STAGE=register RUN_KEY=42.register.1 PARAMS_JSON="$register_params" bash scripts/validate.sh
reject env REQUEST_ID=different bash scripts/inventory.sh register
reject env REQUEST_ID=different STAGE=provision RUN_KEY=42.provision.1 bash scripts/validate.sh
REQUEST_ID=different validate finalize '{"outcome":"failed"}'
grep -qx noop=true "$GITHUB_OUTPUT"
REQUEST_ID=different OUTCOME=failed bash scripts/inventory.sh finalize
[[ "$(entity | jq -c .)" == "$original" ]]

# Real concurrent inventory commit exercises pull/rebase and unrelated autostash preservation.
git clone "$tmp/remote.git" "$tmp/other" >/dev/null
git -C "$tmp/other" config user.name other
git -C "$tmp/other" config user.email other@example.invalid
mkdir "$tmp/other/vms/other-vm"
touch "$tmp/other/vms/other-vm/catalog-info.yaml"
git -C "$tmp/other" add .
git -C "$tmp/other" commit -m 'another VM' >/dev/null
git -C "$tmp/other" push >/dev/null
printf '# unrelated local edit\n' >> ansible/software-catalog.yml
STATUS=frying bash scripts/inventory.sh update
test -f vms/other-vm/catalog-info.yaml
grep -q '# unrelated local edit' ansible/software-catalog.yml
compute_s='{"platform":"aws","os":"ubuntu","size":"S"}'
configure_params() { jq -cn --argjson compute "$1" --argjson software "$2" --argjson ad "$3" '{compute:$compute,configuration:{software:$software,adJoin:$ad}}'; }
reject env REQUESTER_TEAMS=bravo STAGE=configure RUN_KEY=42.configure.1 PARAMS_JSON="$(configure_params "$compute_s" '["git"]' false)" bash scripts/validate.sh
validate configure "$(configure_params "$compute_s" '["htop","nginx"]' false)"
configured=$(sed -n 's/^spec_json=//p' "$GITHUB_OUTPUT")
SPEC_JSON="$configured" bash scripts/inventory.sh configure
# Modify replaces the software list (unchecked software is removed) and may change size.
validate configure "$(configure_params '{"platform":"aws","os":"ubuntu","instanceType":"t3.medium"}' '["htop","git"]' true)"
configured=$(sed -n 's/^spec_json=//p' "$GITHUB_OUTPUT")
SPEC_JSON="$configured" bash scripts/inventory.sh configure
reject validate configure "$(configure_params "$compute_s" '["unknown"]' false)"
reject validate configure "$(configure_params '{"platform":"aws","os":"windows","size":"S"}' '[]' false)"
reject validate configure '{"software":["git"]}'
entity | jq -e '.spec.configuration=={software:["htop","git"],adJoin:true} and .spec.compute=={platform:"aws",os:"ubuntu",instanceType:"t3.medium"} and .spec.billing.costCenter=="CC-123"'
before_spec=$(entity | jq -c .spec)
PUBLIC_IP=192.0.2.10 SSH_USER=ubuntu INSTANCE_ID=i-test INSTANCE_TYPE=t3.small bash scripts/inventory.sh outputs
REQUESTED_BY=operator validate baseline
sed -n 's/^vars_json=//p' "$GITHUB_OUTPUT" | jq -e '.cf_requested_by=="tester" and .cf_software==["htop","git"] and .cf_software_remove==[] and .cf_ad_join==true and .cf_team=="alpha"'
grep -qx host=192.0.2.10 "$GITHUB_OUTPUT"
validate software '{"remove":["nginx","git"]}'
sed -n 's/^vars_json=//p' "$GITHUB_OUTPUT" | jq -e '.cf_software_remove==["nginx"]'
reject validate software '{"remove":["unknown"]}'
reject validate baseline '{"remove":["nginx"]}'
reject validate stop
PUBLIC_IP=192.0.2.10 SSH_USER=ubuntu INSTANCE_ID=i-0123456789abcdef0 INSTANCE_TYPE=t3.medium bash scripts/inventory.sh outputs
validate stop
grep -qx instance_id=i-0123456789abcdef0 "$GITHUB_OUTPUT"
validate os-update
grep -qx host=192.0.2.10 "$GITHUB_OUTPUT"
PUBLIC_IP='' bash scripts/inventory.sh address
entity | jq -e '.metadata.annotations["cf/public-ip"]==""'
reject validate reboot
reject env PUBLIC_IP=not-an-ip bash scripts/inventory.sh address
PUBLIC_IP=192.0.2.11 bash scripts/inventory.sh address
validate reboot
grep -qx host=192.0.2.11 "$GITHUB_OUTPUT"
# Execute pinned code from a checkout with no VM inventory, reading/writing a separate
# current checkout. A destroy queued before registration must not become a false no-op.
(
  cd "$root"
  : > "$GITHUB_OUTPUT"
  INVENTORY_ROOT="$tmp/work" STAGE=destroy RUN_KEY=42.destroy.1 PARAMS_JSON='{}' bash scripts/validate.sh
  grep -qx noop=false "$GITHUB_OUTPUT"
  INVENTORY_ROOT="$tmp/work" STATUS=frying bash scripts/inventory.sh update
)
OUTCOME=ready bash scripts/inventory.sh finalize
entity | jq -e '.metadata.annotations["cf/status"]=="ready" and (.metadata.annotations["cf/ready-at"]|test("^[0-9]{4}-")) and (.metadata.annotations|has("cf/failed-at")|not)'
# Seed distinguishable old times to prove first-time semantics without sleeping.
yq -i '.metadata.annotations."cf/ready-at" = "2000-01-01T00:00:00Z"' "$file"
OUTCOME=ready bash scripts/inventory.sh finalize
OUTCOME=failed bash scripts/inventory.sh finalize
entity | jq -e '.metadata.annotations["cf/status"]=="failed" and (.metadata.annotations["cf/failed-at"]|test("^[0-9]{4}-"))'
yq -i '.metadata.annotations."cf/failed-at" = "2001-01-01T00:00:00Z"' "$file"
GITHUB_RUN_ID=456 OUTCOME=failed bash scripts/inventory.sh finalize
OUTCOME=ready bash scripts/inventory.sh finalize
entity | jq -e '.metadata.annotations as $a | $a["cf/ready-at"]=="2000-01-01T00:00:00Z" and $a["cf/failed-at"]=="2001-01-01T00:00:00Z" and $a["cf/requested-by"]=="tester" and $a["cf/request-id"]=="request-123" and (["cf/stages","cf/processes","cf/provision-run-id"] | all(. as $k | $a | has($k) | not))'
[[ "$(entity | jq -c .spec)" == "$before_spec" ]]
bash scripts/demo-guard.sh
tail -1 "$GITHUB_OUTPUT" | grep -qx proceed=true
DEMO_GENERATION=stale EXPECTED_REQUEST_ID=different bash scripts/demo-guard.sh
tail -1 "$GITHUB_OUTPUT" | grep -qx proceed=false
REQUEST_ID=different validate destroy '{"demoGeneration":"12345678-1234-1234-1234-123456789abc"}'
grep -qx noop=true "$GITHUB_OUTPUT"
bash scripts/inventory.sh delete
test ! -d "vms/$NAME"
validate destroy
grep -qx noop=true "$GITHUB_OUTPUT"
validate finalize '{"outcome":"failed"}'
grep -qx noop=true "$GITHUB_OUTPUT"
bash scripts/terraform.sh destroy
bash scripts/inventory.sh delete
OUTCOME=failed bash scripts/inventory.sh finalize
DEMO_GENERATION=stale EXPECTED_REQUEST_ID=request-123 bash scripts/demo-guard.sh
tail -1 "$GITHUB_OUTPUT" | grep -qx proceed=false
test -f vms/.gitkeep
test -f vms/other-vm/catalog-info.yaml

# Keep the existing spec-boundary integration checks, without adding a test framework.
advanced='{"type":"vm","owner":"group:default/alpha","compute":{"platform":"aws","os":"ubuntu","instanceType":"m7i.large"}}'
python3 scripts/spec.py <<< "$advanced" | jq -e '.compute.instanceType=="m7i.large" and (.compute|has("size")|not)'
reject python3 scripts/spec.py <<< '{"type":"vm","owner":"group:default/alpha","compute":{"platform":"aws","os":"ubuntu","size":"S"},"cloudTags":{"Cost_Center":"x"}}'
for bad in '"size":"S","instanceType":"t3.small"' '"size":"XL"' '"instanceType":"mac2.metal"' '"instanceType":"m7i large"'; do
  reject python3 scripts/spec.py <<< "{\"type\":\"vm\",\"owner\":\"group:default/alpha\",\"compute\":{\"platform\":\"aws\",\"os\":\"ubuntu\",$bad}}"
done
python3 scripts/spec.py <<< '{"type":"vm","owner":"group:default/alpha","compute":{"platform":"aws","os":"ubuntu","size":"XS"}}' | jq -e '.compute.size=="XS"'
echo 'Offline workflow-helper integration checks passed'
