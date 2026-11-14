# Fry stages

From the repository root, install `pip install -r requirements-ansible.txt`,
then run each of `baseline`, `software`, `ad-join`, and `access` as follows:

```sh
ansible-playbook -i "$host," -u ubuntu --private-key "$key" \
  --ssh-common-args "-o CertificateFile=$key-cert.pub -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
  ansible/fry/baseline.yml -e @vars.json
```

`vars.json` always includes `cf_vm_name`, `cf_team` (bare group name),
`cf_requested_by`, `cf_platform`, `cf_os`, `cf_software` (a JSON list), and
`cf_ad_domain`. There are no collection or extra environment requirements.
Playbooks resolve roles relative to their own directory. The SSH CLI arguments
above supply host-key settings; no Ansible configuration file is required.

The software catalog is the allowlist; unknown or OS-unavailable selections fail
before installation. AD join only records mock metadata and banners: it does not
join a domain. Access replaces the entire principals file, removing any former
owning team's access. Baseline owns a marked block in the banners, preserving
the mock AD join line when stages are re-run independently. Windows tasks fail
explicitly until implemented.
