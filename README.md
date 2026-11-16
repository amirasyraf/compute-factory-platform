# Compute Factory platform

POC VM provisioning on AWS, with Git as inventory and isolated Ansible fry jobs.
The binding cross-repository interfaces are in the sibling `compute-factory/CONTRACTS.md`.

## Lifecycle

`provision.yml`: validate → register → Terraform → baseline → optional software → optional
mock AD join → access → ready. Every inventory transition is committed to `main`; the catalog entity
records both the five user-facing `cf/stages` and the complete nine-job `cf/processes` graph. Running
processes are marked failed if a job fails. Failed VMs remain available for diagnosis.

`fry.yml` re-runs one fry stage using the host and SSH user in the VM entity. Before applying,
software refry saves the selected list in `spec.configuration.software`; AD refry sets
`spec.configuration.adJoin=true`. Other desired settings and original requester provenance are
preserved. Software installs are additive: removing an entry from desired software does not uninstall it.
`destroy.yml` checks ownership, marks destroying, destroys the VM, deletes its S3 state object,
then removes `vms/<name>/`. The VM catalog entity is subsequently orphaned and deleted.

All three entry points share concurrency group `vm-<name>`, so operations on the same VM
are serialized. Distinct VMs can run concurrently. Inventory commits retry pull/rebase/push
five times, using rebase autostash to preserve unrelated working-tree changes. Backstage refresh
is best-effort and bounded to ten seconds per entity.
`vms/.gitkeep` is permanent; each registered VM has only `catalog-info.yaml`. The portal
request task and VM page both read this catalog projection, while the request, refry and destroy tasks
stream their GitHub Actions jobs and steps directly. Users can see validation, registration, Terraform,
every fry job, finalization, deletion and failure handling without repository access.

## Configuration and trust

### One desired-configuration source

Before dispatch, the VM request template runs `cf:servicenow:create` in the IDP backend. It POSTs
VM name/team/compute and authenticated requester/task identity to the IDP's mock ServiceNow REST
endpoint, which returns HTTP 201 and a fake `RITM…` number. This is a stateless integration demo, not
a real ServiceNow ticket or approval gate. Failure stops dispatch; the number appears in task logs
and successful task output only, not VM inventory or GHA inputs. Refry/destroy and direct workflow
dispatch are unchanged. The matching backend action must be available before using this template.

The request template uses `cf:vm:dispatch` to reserve quota in the IDP before dispatching
`name`, `spec_json`, `requested_by`, `requester_teams` and the stable `request_id` (task ID).
`spec_json` is a JSON Resource spec; identity/group claims remain server-supplied authorization
context, not user-editable desired state. Validation normalizes the owner to `group:default/<team>`
and commits the spec in `vms/<name>/catalog-info.yaml`. There is no separate `request.yaml`, and no
duplicated desired `cf/platform`, `cf/os`, `cf/size`, `cf/team` or `cf/software` annotations.

```yaml
spec:
  type: vm
  owner: group:default/alpha
  lifecycle: poc
  compute: {platform: aws, os: ubuntu, size: S}
  configuration: {software: [git, nginx], adJoin: false}
  billing: {costCenter: CC-1234, projectCode: PROJ-5678}
  cloudTags: {environment: test}
```

Terraform reads this persisted spec and generates a private, temporary `.tfvars.json` file, deleted on
exit. Downstream Ansible inputs and optional-job decisions also derive from the entity after
provisioning, not the initial dispatch environment. Existing-operation guards derive the team from
`spec.owner`. Annotations contain observed state (status, stages, IP, instance ID, current run) and
request provenance (`cf/requested-by`, `cf/requested-at`). Status writes do not change desired spec.

`scripts/spec.py` validates types and supported fields at workflow boundaries (Python 3 standard
library). It rejects unsupported compute/software, unknown section fields, malformed owner refs,
string booleans, duplicate software, control characters, more than 40 custom tags, and reserved tag
keys (`Name`, `cf:`, `aws:`, `billing:`; case-insensitive). Custom tag keys are 1–128 characters;
values are strings up to 256 characters. Optional billing keys are `costCenter` and `projectCode`,
nonempty strings up to 256 characters, mapped to AWS `billing:cost-center`/`billing:project-code`
tags. These are self-reported metadata, not validated organizational billing authorization.
Mandatory POC/ownership tags remain platform-controlled. No secrets belong in catalog specs or tags.
Optional configuration defaults to no software/no AD join; billing and tags default to empty objects.

This is an extensible, explicitly validated contract, not a catch-all for arbitrary unvalidated input.
Add future enterprise sections with validators, consumers and documentation. Backstage stores custom
spec fields but does not itself enforce this custom workflow schema. No Git push reconciliation is
introduced: editing the file alone neither triggers Terraform nor changes the running VM. A future
update/reconcile workflow is separate work. Legacy inventory is not migrated; rollout starts from an
empty VM inventory after the requested VM teardown.

Repository variables: `AWS_ROLE_ARN`, `AWS_REGION` (`ap-southeast-2`), `TF_STATE_BUCKET`
(`cf-tfstate-134584031874-apse2`), `BACKSTAGE_URL`. Secret: `BACKSTAGE_TOKEN` (catalog plus the
read-only demo cleanup check; subject `compute-factory-workflows`). Missing Backstage configuration
skips catalog refresh without affecting provisioning; automatic demo destruction fails closed.
AWS access always uses OIDC, never static keys. Terraform uses partial S3 backend configuration
and native lockfiles, with state `vms/aws/<name>/terraform.tfstate`.
Provider checksums cover macOS arm64 and Linux amd64; workflow init uses
`-lockfile=readonly` so initialization cannot dirty tracked files before inventory rebasing.

Requirements: default VPC/subnets, golden AMI tagged `cf:managed=true` and `cf:os=ubuntu`,
and Secrets Manager `compute-factory/ssh-ca`. All created resources are tagged `cf:poc=true`.
The SG exposes SSH publicly for this POC. There are no EC2 key pairs. Each fry job signs an
ephemeral key for `cf-automation` with a one-hour certificate, then immediately deletes the
CA private-key file. Runner identities and temporary variables are removed even on failure.

Teams and requester membership accept bare names or catalog refs (`group:default/alpha`).
The workflow normalizes both, checks membership, and lets `platform-admins` manage any VM.
Backstage supplies requester identity and groups server-side, not as editable form fields.
Anyone with repository write or dispatch-token access can impersonate these inputs; that is
the explicit POC trust boundary. Do not grant that access to ordinary portal users.

Backstage templates use stock `MyGroupsPicker` for the user's own groups (including sole-group
auto-selection), and VM `EntityPicker` plus `catalog:fetch` with initiator credentials. The
browser run link uses dispatch output `workflowRunHtmlUrl`. Verify these fields, permission
filtering, checkbox rendering, boolean-to-string serialization and catalog discovery when the
IDP is live. The IDP must enable orphan deletion and register the `cf-vms` Location glob.

## Manual dispatch

### Automatic demo cleanup

The IDP's admin-toggleable demo policy is defined in `compute-factory/CONTRACTS.md` §8.1.
Registration records immutable `cf/request-id` and `cf/provision-run-id`; `cf/ready-at` and
`cf/failed-at` record first readiness/failure and are not reset by refry. Manual provision defaults
the request ID to `manual:<run-id>`. Old inventory without these annotations is handled conservatively
by the controller using its original request timestamp/first observed readiness.

Automatic `destroy.yml` dispatch includes `demo_generation` and `expected_request_id`. The real
guard script checks both VM incarnation and current backend eligibility twice, skipping stale/missing
VMs and refusing deletion on network/auth failures. The second check immediately precedes destructive
inventory/Terraform work, after tool setup. Manual destroy omits these fields and remains unchanged.
Workflows remain serialized per VM. The IDP must be reachable for automatic cleanup; runner queues
and Terraform mean expiry is a trigger time, not a guaranteed completed termination time.

### Trusted operator dispatch

```bash
gh workflow run provision.yml -R amirasyraf/compute-factory-platform \
  -f name=demo-1 \
  -f 'spec_json={"type":"vm","owner":"group:default/alpha","compute":{"platform":"aws","os":"ubuntu","size":"S"},"configuration":{"software":["git","nginx"],"adJoin":false}}' \
  -f requested_by=amirasyraf -f requester_teams=alpha

gh workflow run fry.yml -R amirasyraf/compute-factory-platform \
  -f name=demo-1 -f stage=software -f 'software=["htop"]' \
  -f requested_by=amirasyraf -f requester_teams=alpha

gh workflow run destroy.yml -R amirasyraf/compute-factory-platform \
  -f name=demo-1 -f requested_by=amirasyraf -f requester_teams=alpha
```

Run `gh run watch <id> --exit-status` in background mode when operating through an agent.
Do not run teardown against unrelated resources. Shared infra and golden-image lifecycle
belong to `compute-factory` / `compute-factory-builder`, not this repository.

## Extending the POC

- **Platform:** add `terraform/platforms/<platform>/` with the same variables (`name`, `os`,
  `size`, `team`, `requested_by`, `cloud_tags`) and outputs (`public_ip`, `ssh_user`, `instance_id`,
  `instance_type`), plus a platform size map. For AWS the map is `terraform/platforms/aws/sizes.json`
  (`XS`/`S`/`M`/`L` to `t3.micro`/`small`/`medium`/`large`), read by `scripts/spec.py`, Terraform and the
  IDP request form. A spec carries exactly one of `compute.size` or `compute.instanceType` (an explicit
  EC2 type from the IDP's Advanced picker; Terraform's `instance_type` variable). Terraform checks that
  the type boots x86_64 and launches into a default subnet whose AZ offers it; provisioning records the
  launched type in the `cf/instance-type` annotation. Only `name` is required, so lifecycle teardown can destroy with just
  `-var name=<name>`. Add the platform's OIDC authentication, spec validation and template enum.
- **OS:** bake its golden image with the matching `cf:os` tag, add the SSH-user map entry,
  Ansible OS-family tasks, software compatibility validation and template enum. Ubuntu maps
  to the catalog's `linux` package IDs. Update the registration SSH-user mapping as needed.
- **Fry stage:** add `ansible/fry/<stage>.yml` and its role; add its ordered stage key to
  inventory, validation, the reusable workflow allowlist, the provision job sequence, and
  the refry enum. Pass the same complete `vars_json` contract to every stage.

## Static checks

Tool versions are pinned in `mise.toml`; run `mise install`, then `mise exec --` for these commands.

```bash
terraform -chdir=terraform/platforms/aws fmt -check
terraform -chdir=terraform/platforms/aws init -backend=false
terraform -chdir=terraform/platforms/aws validate
actionlint
shellcheck scripts/*.sh
for script in scripts/*.sh; do bash -n "$script"; done
bash scripts/test.sh
```

Ansible files and `requirements-ansible.txt` are owned by the builder/Ansible agent; workflow
jobs install exactly `pip install -r requirements-ansible.txt` and call its stage playbooks.
