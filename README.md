# Compute Factory platform

POC AWS VM stage executor, with Git as inventory and Ansible configuration.
The binding cross-repository interfaces are in `../compute-factory/CONTRACTS.md`.

## Lifecycle

The IDP `vms` backend owns stage ordering, automatic retries/backoff, manual retry/skip,
and run state in its database. GitHub Actions **executes exactly one stage per dispatch**
through `.github/workflows/stage.yml`. There is no supported direct lifecycle pipeline.

Provision runs execute register → provision → baseline → optional software → optional mock
AD join → access → finalize. Refry runs configure the desired state (software/AD only), execute
one fry stage, then finalize. Destroy runs remove infrastructure/state/inventory; only their
failure path finalizes. The IDP handles inapplicable-stage skips, not GitHub Actions.
Transient failures do not mark the VM failed: only the orchestrator's terminal `finalize`
with `outcome: failed` writes that status. Failed VMs remain for diagnosis.

Each dispatch supplies `stage`, `name`, `request_id`, `run_key`, `requested_by`,
`requester_teams` and optional `params_json` (object, at most 40 KiB). The run title is
`stage <stage> <name> by <requested_by> [<run_key>]`; the suffix is dispatch recovery identity.
`run_key` is `<positive run id>.<stage>.<positive attempt>`, `request_id` is a stable incarnation
matching `^[a-zA-Z0-9_-]{1,100}$`, and names match `^[a-z][a-z0-9-]{2,20}$`.

One 20-minute job checks out executor code at the dispatched commit (`github.sha`), then
`Load current inventory` checks out current `main` separately under `.current-inventory`.
Workflow concurrency opens before either checkout, so a queued destroy sees registration
committed while it was waiting, not the dispatch-time snapshot. `INVENTORY_ROOT` points all
inventory reads/writes/Git commits at that separate checkout (default `.` for local scripts).
Terraform, Ansible, validators and helpers still execute from the pinned executor checkout.
Inventory retrieval failures are transient and never misclassified as validation failures.
The `Validate inputs` step
does all local input/spec/identity/team checks before mutations. Failure there is permanent;
tool setup, OIDC, cleanup-check HTTP, AWS, SSH and Git writes happen later and are retryable.
Concurrency `vm-<name>` serializes all attempts for a VM. Distinct VMs run concurrently.
The workflow has only `contents: write` and `id-token: write` permissions.

| Stage | `params_json` | Effect |
|---|---|---|
| register | `{"spec": <Resource spec>}` | Create inventory with `provisioning`; same incarnation is a no-op, another is rejected |
| provision | `{}` | Mark provisioning, adopt/apply Terraform, record outputs, mark frying |
| baseline/software/ad-join/access | `{}` | Mark frying, sign an ephemeral SSH cert, run the corresponding playbook |
| configure | `{"software":["git"]}` **or** `{"adJoin":true}` | Persist software union or enable AD join, without VM contact |
| destroy | `{}` or `{"demoGeneration":"<uuid>"}` | Check cleanup eligibility if automatic, mark destroying, destroy, delete state and inventory |
| finalize | `{"outcome":"ready"}` or `{"outcome":"failed"}` | Write status and first-only readiness/failure timestamp |

Missing inventory makes destroy/finalize successful no-ops. Finalize for another incarnation,
or automatic cleanup for an outdated incarnation, also does nothing. Other stages reject a
missing/mismatched incarnation. Guards use persisted `spec.owner` (desired owner for register).
`requester_teams` contains comma-separated bare group names; `platform-admins` passes all guards.
Register retry checks both desired and existing owner. No side effects run for a validated no-op.

Every inventory write commits to `main`, retries pull/rebase/push eight times with jitter and
`--autostash`, then best-effort refreshes `resource:default/<name>` in Backstage (10-second
HTTP timeout). Register/delete also refresh `location:default/cf-vms`. `vms/.gitkeep` remains.
Git tracks coarse `cf/status`, connection/instance outputs and request provenance only;
per-stage attempts and errors live in the IDP database, never inventory annotations.
`cf/ready-at` and `cf/failed-at` record their first occurrence and are never reset by refry.

## Templates and progress

`vm-request` has one step, `cf:vm:dispatch`, which submits `{name, specJson}` to
`/api/vms/requests`; authenticated identity, teams and the task ID are derived server-side.
Admission reserves quota and creates the run idempotently by task ID. The run's first stage, the
mock ServiceNow request, runs inside the IDP (not in this repo); its fake RITM number is shown on
the run page, not stored in VM inventory or passed to workflows. The IDP then takes the browser to
the run page; the task also links **Follow provisioning** (`runUrl`) and **Open VM in catalog**.

`vm-refry` and `vm-destroy` each have one `cf:vm:run` step. The action reads the chosen VM with
initiating-user credentials and derives identity/teams server-side. Their **Follow run** link
uses `runUrl`. Both actions return `{runId, runUrl}`. Live progress, retry and skip are on
`/vms/runs/<id>` and the VM entity page, not streamed into the Scaffolder task. The request team
picker remains `MyGroupsPicker`; refry/destroy retain team-filtered Resource/VM EntityPickers.

## Configuration and trust

`catalog-info.yaml` is the only per-VM desired state; no `request.yaml` or duplicate desired
annotations. A normalized spec looks like:

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

`scripts/spec.py` validates/normalizes types, supported fields and bounds with the Python standard
library. Only AWS/Ubuntu and catalog software `[git, htop, nginx, docker]` are supported. Compute
has exactly one of `size` (XS/S/M/L from `terraform/platforms/aws/sizes.json`) or `instanceType`
(e.g. `m7i.large`, no `mac*`). Terraform checks x86_64 support and default-subnet AZ availability.
The IDP Advanced picker reads the same map and live AWS offerings. Recorded `cf/instance-type`
is the launched type, not a re-evaluation of a mutable size map.

Configuration defaults to no software/no AD join; billing/tags default to empty objects. Software
refry is additive and never uninstalls. Status writes never alter desired spec or original
`cf/requested-by`/`cf/requested-at`/`cf/request-id`. Ansible `cf_requested_by` and AWS requester
tags come from original persisted provenance, not whoever dispatched the current attempt.

Billing accepts only nonempty `costCenter`/`projectCode` (up to 256 chars), projected as
`cost_center`/`project_code` AWS tags. Both are required by the form/IDP for new requests but
optional in `spec.py` for older specs. These are self-reported, not billing authorization.
Custom tags: at most 40 entries, keys 1–128 chars, string values 0–256 chars. Controls, unknown
spec section fields and reserved tag keys/prefixes (`Name`, `cost_center`, `project_code`,
`cf:`, `aws:`, `billing:`, case-insensitive) are rejected. Never store secrets in specs or tags.

Backstage stores custom spec fields but does not itself enforce this workflow schema. Git edits
do not trigger reconciliation or Terraform. Future enterprise sections need explicit validators
and consumers. Legacy inventory is not migrated; coordinated cut-over starts with empty inventory.

Repository variables: `AWS_ROLE_ARN`, `AWS_REGION` (`ap-southeast-2`), `TF_STATE_BUCKET`
(`cf-tfstate-134584031874-apse2`), `BACKSTAGE_URL`. Secret: `BACKSTAGE_TOKEN`, subject
`compute-factory-workflows`, restricted to catalog and the `vms` read-only cleanup check.
Missing Backstage config skips refresh but automatic cleanup fails closed.
The IDP must register the optional `cf-vms` glob Location and enable orphan deletion.
Repo writers and dispatch-token holders can impersonate identity inputs: trusted POC admins only.

## Terraform retry safety

S3 state is `vms/aws/<name>/terraform.tfstate`, with native `use_lockfile=true`. The script uses
`init -lockfile=readonly` so provider checksum files do not dirty inventory rebases. All resources
carry `cf:poc=true`, `cf:vm`, `cf:team`, and (when nonempty) `cf:request-id` tags.

Before either apply or destroy, recover any **untracked** instance/security group with matching
`cf:vm`, `cf:request-id` and `cf:poc=true` into Terraform state. Instance lookup includes pending,
running, stopping and stopped states. Zero matches permits creation (apply); one is imported;
multiple matches fail for operator recovery rather than guessing. Security-group adoption also
recovers an interrupted apply before instance creation. This does not adopt another incarnation.

Instances ignore AMI and computed subnet changes after creation: a newer bake or reordering/default
subnet availability must not replace an existing VM on retry. Imported SGs ignore `name_prefix`.
Provision creates a saved plan and rejects any delete/replacement action before applying it, so
other unexpected immutable-property drift requires operator recovery rather than recreation.
Do not use direct Git edits for resize/network changes; this POC has no reconciliation flow.

The script lists the exact `.tflock` object and reads its `Created`/`ID`. A lock older than
1,200 seconds (the workflow job timeout) is logged and removed via `terraform force-unlock`;
a younger lock fails safely for retry. Auth/network/malformed-lock errors fail, never bypass locking.
This relies on the shared per-VM concurrency group: external Terraform operators must not run
against an active VM stage or rely on locks beyond that window. Local teardown freezes workflows
first. Untracked-resource discovery, import and stale-lock recovery are script behavior, not
properties of invoking the module directly.

Terraform receives private temporary vars and plan files, removed on exit. Only `name` is required
by the module; `terraform destroy -var name=<name>` remains valid for `./poc down`. Stage destruction
uses the full persisted vars, deletes the state object only after successful destroy, then removes
inventory. Missing state after partial destruction is recovered by the same adoption path.
AWS access is OIDC only. Requirements: default VPC/subnets, a golden AMI tagged `cf:managed=true`
and `cf:os=ubuntu`, and Secrets Manager `compute-factory/ssh-ca`. SSH ingress is public for this POC.

## SSH and demo cleanup

Each fry attempt signs a throwaway key with principal `cf-automation`, key ID `gha-<run-id>`,
validity one hour. The CA private-key file is deleted immediately after signing; ephemeral keys,
certs and vars are removed by an always-run step. No EC2 key pairs or per-VM user keys are stored.
The playbook CLI/variable contract is in `ansible/README.md` and the shared contract §6.3.

Automatic destroy's `demoGeneration` checks
`GET $BACKSTAGE_URL/api/vms/cleanup-check/<name>?generation=…&request_id=…` after validation
and again after tool setup immediately before destructive work. Ineligible returns a successful
no-op; HTTP/auth/network or malformed responses fail closed and remain retryable. Manual destroy
uses `{}` and never contacts this endpoint. Demo expiry is a trigger time, not a termination SLA.

Trusted manual dispatch can execute **one** stage and is not tracked by the orchestrator:

```bash
gh workflow run stage.yml -R amirasyraf/compute-factory-platform \
  -f stage=baseline -f name=demo-1 -f request_id='persisted-request-id' \
  -f run_key=42.baseline.1 -f requested_by=amirasyraf -f requester_teams=alpha \
  -f 'params_json={}'
```

Do not dispatch this during coordinated cut-over until the matching IDP is deployed. Do not run
teardown against unrelated resources; shared infra and golden images belong to sibling repos.

## Extending and checking

New platforms need the same variables (`name`, `os`, `size`, `instance_type`, `team`,
`requested_by`, `request_id`, `cloud_tags`), outputs (`public_ip`, `ssh_user`, `instance_id`,
`instance_type`), validator/identity/adoption rules and OIDC setup. New OSes need a golden image,
SSH-user mapping, Ansible OS-family tasks and software checks. New stages require contract and
orchestrator stage-list changes as well as playbooks, workflow allowlists and template enums.

Tool versions are pinned in `mise.toml`. Offline verification (no new unit-test framework):

```bash
mise exec -- terraform -chdir=terraform/platforms/aws fmt -check
mise exec -- terraform -chdir=terraform/platforms/aws init -backend=false -lockfile=readonly
mise exec -- terraform -chdir=terraform/platforms/aws validate
mise exec -- actionlint
mise exec -- shellcheck scripts/*.sh
for script in scripts/*.sh; do bash -n "$script"; done
mise exec -- bash scripts/test.sh
```

`scripts/test.sh` uses real jq/yq/Git and an isolated local bare remote to exercise validation,
inventory idempotency, config unions, provenance, first-time timestamps, missing-inventory
no-ops and separate current-inventory reads/writes from pinned executor code. It does not
invoke AWS/Terraform or prove live recovery behavior. Live stage/SSH/adoption
verification belongs to the coordinated IDP cut-over; local checks do not claim that evidence.
