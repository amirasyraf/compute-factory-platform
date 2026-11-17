# Fry stages

From the repository root, install `pip install -r requirements-ansible.txt`,
then run each of `baseline`, `software`, `ad-join`, and `access` as follows:

```sh
ansible-playbook -i "$host," -u ubuntu --private-key "$key" \
  --ssh-common-args "-o CertificateFile=$key-cert.pub -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
  ansible/fry/baseline.yml -e @vars.json
```

`vars.json` always includes `cf_vm_name`, `cf_team` (bare group name),
`cf_requested_by` (the original persisted `cf/requested-by`, not the stage dispatcher),
`cf_platform`, `cf_os`, `cf_software` (a JSON list of desired packages),
`cf_software_remove` (catalog packages deselected by Modify; never one still desired),
`cf_ad_join` (desired mock AD membership) and `cf_ad_domain`. There are no collection or extra environment requirements.
Playbooks resolve roles relative to their own directory. The SSH CLI arguments
above supply host-key settings; no Ansible configuration file is required.

The software catalog is the allowlist; unknown or OS-unavailable selections fail
before installation. The software stage installs `cf_software` and removes
`cf_software_remove` (`apt` `state: absent`: data and configuration files are kept).
AD join only records mock metadata and banners: it does not join a domain; with
`cf_ad_join: false` it removes them again. Access replaces the entire principals file, removing any former
owning team's access. Baseline owns a marked block in the banners, preserving
the mock AD join line when stages are re-run independently. Windows tasks fail
explicitly until implemented.

`maintain/os-update.yml` (stage `os-update`) is maintenance, not a fry stage: it runs a full
`apt` upgrade and reboots only when `/var/run/reboot-required` exists. It does not change
`cf/status`.

The IDP orchestrator dispatches `stage.yml` once per stage attempt. Its single playbook
execution step reads the host, SSH user and variables from committed inventory,
marks the coarse status `frying`, and cleans up ephemeral credentials even on failure.
Retries, optional-stage decisions and final failure/ready status belong to the IDP,
not these playbooks.
