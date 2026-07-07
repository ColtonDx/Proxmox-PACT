# Command recipes

Ready-to-adapt `build.sh` invocations for common configurations. Swap in your
own host, user, credentials, and storage pool. See the
[CLI reference](../README.md#command-structure) for every flag.

## Connect and authenticate

```bash
# Remote Proxmox, SSH password, base templates only
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password"

# Remote Proxmox, SSH private key
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --ssh-private-key-path=/home/you/.ssh/id_ed25519

# Local run, directly on the Proxmox host (no SSH)
./Scripts/build.sh --local --proxmox-storage=local-lvm
```

## Choose which distros to build

```bash
# Just two specific distros
./Scripts/build.sh --proxmox-host=pve.local --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" --build-distros=debian12,ubuntu2404

# A whole family (all Debian versions)
./Scripts/build.sh --proxmox-host=pve.local --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" --build-distros=debian

# Everything
./Scripts/build.sh --proxmox-host=pve.local --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" --build-distros=all
```

Valid values: `all`, a family (`debian`, `ubuntu`, `fedora`), or a
comma-separated list of `debian11 debian12 debian13 ubuntu2204 ubuntu2404
ubuntu2604 fedora43 fedora44`.

## Packer customization

```bash
# Default customization (installs common packages via the bundled playbook)
./Scripts/build.sh --proxmox-host=pve.local --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" --run-packer \
  --packer-token-id="packer@pam!packer" \
  --packer-token-secret="your-api-token-secret"

# Custom Ansible playbook + vars (local path or URL)
./Scripts/build.sh --proxmox-host=pve.local --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" --run-packer \
  --packer-token-id="packer@pam!packer" \
  --packer-token-secret="your-api-token-secret" \
  --custom-ansible-playbook=./examples/playbooks/custom-playbook.yml \
  --custom-ansible-varfile=./examples/playbooks/custom-vars.yml

# Custom Packer template from a URL
./Scripts/build.sh --proxmox-host=pve.local --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" --run-packer \
  --packer-token-id="packer@pam!packer" \
  --packer-token-secret="your-api-token-secret" \
  --custom-packerfile=https://example.com/custom.pkr.hcl
```

## Rebuild / preview

```bash
# Destroy the target VMIDs first, then rebuild (destructive)
./Scripts/build.sh --proxmox-host=pve.local --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" --build-distros=all --rebuild-templates

# Dry run: print the plan (targets + VMIDs) and exit, no host or creds needed
./Scripts/build.sh --build-distros=all --run-packer --dry-run
```

## Answerfile mode

Store settings once and just run the script. See
[`answerfiles/`](answerfiles/) for ready-made examples.

```bash
cp examples/answerfiles/remote-ssh-password.env .env.local
# edit .env.local, then:
./Scripts/build.sh
```
