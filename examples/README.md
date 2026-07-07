# Examples

Copy-paste configurations, commands, and files for Proxmox-PACT. Start here, then
adapt to your environment.

| File | What it covers |
|------|----------------|
| [`oneliners.md`](oneliners.md) | Zero-clone bootstrap, clone-and-run, dry-run |
| [`commands.md`](commands.md) | `build.sh` recipes for different configs (auth, distros, Packer, rebuild) |
| [`answerfiles/`](answerfiles/) | Ready-made `.env` files — copy one to `.env.local` |
| [`playbooks/`](playbooks/) | A sample custom Ansible playbook + its variables |

## Answerfiles

Each `.env` under [`answerfiles/`](answerfiles/) is a complete configuration.
Copy one to the repo root as `.env.local`, edit the values, and run
`./Scripts/build.sh` (it loads `.env.local` automatically).

| File | Scenario |
|------|----------|
| [`remote-ssh-password.env`](answerfiles/remote-ssh-password.env) | Remote Proxmox over SSH, password auth |
| [`remote-ssh-key.env`](answerfiles/remote-ssh-key.env) | Remote Proxmox over SSH, private key |
| [`local-on-proxmox.env`](answerfiles/local-on-proxmox.env) | Running directly on the Proxmox host |
| [`packer-full.env`](answerfiles/packer-full.env) | Full run with Packer + a custom playbook |

> `.env.local` is git-ignored because it can hold passwords and API tokens. The
> examples here use placeholders only — never commit real secrets.

## Playbooks

[`playbooks/custom-playbook.yml`](playbooks/custom-playbook.yml) and
[`playbooks/custom-vars.yml`](playbooks/custom-vars.yml) show how to customize
images during the Packer phase (create a user, install an SSH key, add packages,
set a MOTD). Use them with:

```bash
./Scripts/build.sh --proxmox-host=pve.local --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" --run-packer \
  --packer-token-id="packer@pam!packer" --packer-token-secret="secret" \
  --custom-ansible-playbook=./examples/playbooks/custom-playbook.yml \
  --custom-ansible-varfile=./examples/playbooks/custom-vars.yml
```

Both `--custom-ansible-playbook` and `--custom-ansible-varfile` also accept an
`https://` URL, so you can host your customizations anywhere.
