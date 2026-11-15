# Compute Factory platform

POC VM provisioning on AWS, with Git as inventory and isolated Ansible fry jobs.
The binding cross-repository interfaces are in the sibling `compute-factory/CONTRACTS.md`.

## Lifecycle

`provision.yml`: validate → register → Terraform → baseline → optional software → optional
mock AD join → access → ready. Every inventory transition is committed to `main`; running
stages are marked failed if a job fails. Failed VMs remain available for diagnosis.

`fry.yml` re-runs one fry stage using the host and SSH user in the VM entity. It does not
rewrite the original request. Software installs are additive; an empty selection installs nothing.
`destroy.yml` checks ownership, marks destroying, destroys the VM, deletes its S3 state object,
then removes `vms/<name>/`. The VM catalog entity is subsequently orphaned and deleted.

All three entry points share concurrency group `vm-<name>`, so operations on the same VM
are serialized. Distinct VMs can run concurrently. Inventory commits retry pull/rebase/push
five times, using rebase autostash to preserve unrelated working-tree changes. Backstage refresh
is best-effort and bounded to ten seconds per entity.
`vms/.gitkeep` is permanent; each registered VM has `request.yaml` and `catalog-info.yaml`.

## Configuration and trust

Repository variables: `AWS_ROLE_ARN`, `AWS_REGION` (`ap-southeast-2`), `TF_STATE_BUCKET`
(`cf-tfstate-134584031874-apse2`), `BACKSTAGE_URL`. Secret: `BACKSTAGE_TOKEN` (catalog-only
external access). Missing Backstage configuration skips refresh without affecting provisioning.
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

```bash
gh workflow run provision.yml -R amirasyraf/compute-factory-platform \
  -f name=demo-1 -f team=alpha -f platform=aws -f os=ubuntu -f size=S \
  -f software=git,nginx -f ad_join=true -f requested_by=amirasyraf -f requester_teams=alpha

gh workflow run fry.yml -R amirasyraf/compute-factory-platform \
  -f name=demo-1 -f stage=software -f software=htop \
  -f requested_by=amirasyraf -f requester_teams=alpha

gh workflow run destroy.yml -R amirasyraf/compute-factory-platform \
  -f name=demo-1 -f requested_by=amirasyraf -f requester_teams=alpha
```

Run `gh run watch <id> --exit-status` in background mode when operating through an agent.
Do not run teardown against unrelated resources. Shared infra and golden-image lifecycle
belong to `compute-factory` / `compute-factory-builder`, not this repository.

## Extending the POC

- **Platform:** add `terraform/platforms/<platform>/` with the same variables (`name`, `os`,
  `size`, `team`, `requested_by`) and outputs (`public_ip`, `ssh_user`, `instance_id`), plus
  a platform size map. Only `name` is required, so lifecycle teardown can destroy with just
  `-var name=<name>`. Add the platform's OIDC authentication, validation and template enum.
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
