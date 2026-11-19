# Fry stages

From the repository root, install `pip install -r requirements-ansible.txt` and
`ansible-galaxy collection install -r ansible/requirements.yml` (`ansible.windows`,
pinned). To reproduce one stage on an authorized disposable VM, set `stage` to `baseline`,
`software`, `ad-join`, or `access` and use:

```sh
ansible-playbook -i "$host," -u "$ssh_user" --private-key "$key" \
  --ssh-common-args "-o CertificateFile=$key-cert.pub -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30" \
  "ansible/fry/$stage.yml" -e "@ansible/connection/$family.yml" -e @vars.json -e @secret.json
```

`$family` is the OS family from the platform's `platform.json` (`linux` or `windows`). The
connection file supplies what must be known before facts are gathered: `ansible_become: true`
(sudo) on Linux; `ansible_shell_type: powershell` on Windows, where the login user is already a
local administrator and the few tasks that need SYSTEM set `become` (`runas`) themselves. Plays do
not set `become`.

`vars.json` always includes `cf_vm_name`, `cf_team` (bare group name),
`cf_requested_by` (the original persisted `cf/requested-by`, not the stage dispatcher),
`cf_platform`, `cf_os`, `cf_software` (a JSON list of desired packages),
`cf_software_remove` (catalog packages deselected by Modify; never one still desired),
`cf_ad_join` (desired mock AD membership) and `cf_ad_domain`. `secret.json` is `{}` except for the
Windows `access` stage, where it is `{"cf_admin_password": …}` from `scripts/vm-password.sh`.
Playbooks resolve roles relative to their own directory. The SSH CLI arguments
above supply host-key settings; no Ansible configuration file is required.

`software-catalog.json` is the allowlist: `{<id>: {label, linux, windows}}`, each OS-family column
holding that family's package ID or `null` (not offered). `spec.py`, `validate.sh`, these roles and
the IDP's software picker read it; unknown or OS-unavailable selections fail before installation.
The software stage installs `cf_software` and removes `cf_software_remove`: on Linux with `apt`
(`state: absent`: data and configuration files are kept), on Windows with winget through the
`Microsoft.WinGet.Client` PowerShell module as SYSTEM in the baked PowerShell 7 (`pwsh.exe`), machine-wide and silent (the winget CLI is not
supported as SYSTEM and is unreliable over SSH). The module is installed for all users by the bake.

AD join only records mock metadata and banners: it does not join a domain; with
`cf_ad_join: false` it removes them again. Access replaces the entire principals file of the login user
(`/etc/ssh/auth_principals/<ansible_user>`, Windows `C:\ProgramData\ssh\auth_principals\<user>`),
removing any former owning team's access. On Linux it turns off `authorized_keys` logins
(`AuthorizedKeysFile none`), so only CA certificates work; Azure's required launch-time admin key
stops working there. The Windows image already has `AuthorizedKeysFile none`, and Windows access sets
the login user's password to the team's shared one (`cf_admin_password`), replacing the launch
password. Windows marks this shared POC password as non-expiring. `$ssh_user` is the OS login user
from the platform's `platform.json` (`ubuntu`;
`Administrator` on AWS Windows, `cfadmin` on Azure Windows, where Azure forbids `Administrator`).
Baseline owns a marked block in the Linux banners (Windows: the whole
`C:\ProgramData\ComputeFactory\banner.txt`, the image's SSH banner), preserving the mock AD join line
when stages are re-run independently. On Windows it also sets the computer name (the VM name cut
to 15 characters, rebooting once), UTC and allows Remote Desktop logins (reached only through SSH).

`maintain/os-update.yml` (stage `os-update`) is maintenance, not a fry stage: on Linux it runs a full
`apt` upgrade and reboots only when `/var/run/reboot-required` exists; on Windows it installs updates
of every category with `win_updates`, rebooting as needed (the stage job allows 40 minutes). It does
not change `cf/status`.

The IDP orchestrator dispatches `stage.yml` once per stage attempt. Its single playbook
execution step reads the host, SSH user and variables from committed inventory,
marks the coarse status `frying` for fry stages (not OS updates), and uses a final cleanup step to
remove ephemeral credentials.
Retries, optional-stage decisions and final failure/ready status belong to the IDP,
not these playbooks.
