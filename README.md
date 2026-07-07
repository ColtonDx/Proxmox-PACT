# Proxmox-PACT — Packer Ansible CloudInit Templates

<img src="Images/Logo.jpg" alt="Application Logo" width="200"/>

Proxmox-PACT builds a set of ready-to-use Linux VM templates on your Proxmox
instance from a range of distros and versions. Every template is preconfigured
for **Cloud-Init** (resize disks, set users/passwords, inject SSH keys from the
Proxmox UI) and ships with **qemu-guest-agent** so Proxmox can talk to the VM
cleanly. Optionally, **Packer + Ansible** generalize and customize the images —
and you can supply your own playbooks to make them yours.

> Disclaimer: AI tools helped generate some functionality; the core scripts are
> refinements of earlier scripts I wrote.

[![Support](https://img.shields.io/badge/Support-Buy_Me_A_Coffee-yellow?style=for-the-badge&logo=buy%20me%20a%20coffee&color=FFDD00)](https://www.buymeacoffee.com/ColtonDx)

## Quick start

**Zero-clone** — fetches what it needs and prompts you:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ColtonDx/Proxmox-PACT/main/Scripts/build.sh)
```

**Or clone and run interactive mode:**

```bash
git clone https://github.com/ColtonDx/Proxmox-PACT.git && cd Proxmox-PACT
./Scripts/build.sh --interactive
```

Use `bash <(curl …)`, not `curl … | bash`, so the prompts work. You can run from
any Linux machine or directly on the Proxmox host — SSH vs. local is handled
automatically.

## How it works

1. **`build.sh`** (your machine or the Proxmox host) collects settings from CLI
   flags, interactive prompts, `PACT_*` env vars, or an answerfile.
2. It runs **`proxmox.sh`** on the Proxmox host (over SSH, or locally with
   `--local`) to download cloud images and turn them into Cloud-Init templates.
3. Optionally, with **`--run-packer`**, Packer + Ansible customize each template,
   producing a second set at VMID + 100.

## Command structure

```bash
./Scripts/build.sh [connection] [what-to-build] [packer] [options]
```

| Common flag | Meaning |
|-------------|---------|
| `--interactive` | Prompt for everything (can't be mixed with other flags) |
| `--local` | Run on the Proxmox host, no SSH |
| `--proxmox-host=HOST` | Proxmox hostname or IP (default `pve.local`) |
| `--proxmox-ssh-user=USER` | SSH user (default `root`) |
| `--proxmox-ssh-password=PASS` / `--ssh-private-key-path=PATH` | Auth |
| `--proxmox-storage=POOL` | Storage pool (default `local-lvm`) |
| `--build-distros=LIST` | `all`, a family (`debian`/`ubuntu`/`fedora`), or names |
| `--run-packer` | Enable Packer customization (needs API token flags) |
| `--dry-run` | Print the plan and exit — no host or credentials needed |

Full flag list and answerfile settings: **[CLI Reference](../../wiki/CLI-Reference)**.

## Examples

Copy-paste configs, one-liners, answerfiles, and a sample playbook live in
**[`examples/`](examples/)**:

- [One-liners](examples/oneliners.md) · [Command recipes](examples/commands.md)
- [Answerfiles](examples/answerfiles/) — copy one to `.env.local` and run
- [Custom playbook + vars](examples/playbooks/)

## Supported distros

| Distro | Base VMID | Distro | Base VMID |
|--------|----------:|--------|----------:|
| Debian 11 | 801 | Ubuntu 24.04 | 812 |
| Debian 12 | 802 | Ubuntu 26.04 | 814 |
| Debian 13 | 803 | Fedora 43 | 823 |
| Ubuntu 22.04 | 811 | Fedora 44 | 824 |

VMIDs are `base + offset` (default base `800`). With Packer, customized
templates get `base + 100 + offset` (e.g. Debian 12 → 902).

## Testing

`Scripts/test.sh` builds every selected image in an isolated 88xxx VMID range,
boots each one to prove it works, then deletes everything — the pre-release gate.
Static checks (ShellCheck, Packer validate, yamllint, Ansible syntax) run in CI
on every push. See **[Testing and CI](../../wiki/Testing-and-CI)**.

## Documentation

- **[`examples/`](examples/)** — copy-paste configurations and commands
- **[Wiki](../../wiki)** — interactive-mode walkthrough, full CLI/answerfile
  reference, `proxmox.sh` usage, testing details

## Links

- [Packer Documentation](https://www.packer.io/docs)
- [Ansible Documentation](https://docs.ansible.com/)
- [Packer Proxmox Clone builder](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/clone)
