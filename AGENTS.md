# Agent instructions: Vendy platform

- Read `../vendy/AGENTS.md` and `../vendy/CONTRACTS.md` before changing shared schemas or workflow
  inputs. Use `README.md` for human onboarding, `REFERENCE.md` for stage and recovery details, and
  `ansible/README.md` for the playbook contract.
- Preserve the one-stage dispatch contract, run-key suffix, `Validate inputs` failure boundary,
  split executor/inventory checkouts, and per-VM concurrency. The IDP owns run order and retries.
- Keep incarnation and team checks ahead of side effects. Never aim manual Terraform or workflow
  commands at an active VM run or bypass locks and adoption. Don't destroy, stop, or replace a
  user-visible VM without explicit authorization.
- `vms/` is public and workflow-managed. Don't write secrets or sensitive data to inventory, tags,
  outputs, or job logs. Don't use manual inventory edits as a substitute for reconciliation.
- Use `mise exec -- bash scripts/test.sh` and the relevant static checks in `REFERENCE.md`. No added
  unit-test scaffolding. Before dispatching a changed guest step, exercise it on a disposable guest
  that matches the target OS/cloud. Leave existing POC workflows and resources alone for docs checks.
