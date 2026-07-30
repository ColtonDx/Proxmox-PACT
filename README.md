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
| `--customize-cloudinit` | Bake a default username/password/SSH key into the templates |
| `--dry-run` | Print the plan and exit — no host or credentials needed |

Full flag list and answerfile settings: **[CLI Reference](../../wiki/CLI-Reference)**.

## Cloud-Init customization

By default, templates ship with an empty Cloud-Init drive — you set the username,
password, and SSH keys per-VM from the Proxmox UI when you clone one. If you'd rather
bake defaults into the templates themselves, pass `--customize-cloudinit` plus any of:

| Flag | Answerfile var | Meaning |
|------|----------------|---------|
| `--cloudinit-user=USER` | `CLOUDINIT_USER` | Default Cloud-Init username |
| `--cloudinit-password=PASS` | `CLOUDINIT_PASSWORD` | Default password — **stored in plaintext** in each VM's Proxmox config (`qm config`); prefer SSH keys |
| `--cloudinit-ssh-keys=KEY` | `CLOUDINIT_SSH_KEYS` | A literal SSH public key to inject |
| `--cloudinit-ssh-key-file=PATH` | `CLOUDINIT_SSH_KEY_FILE` | Path to a file of SSH public keys (one per line); mutually exclusive with the literal form |

At least one value is required when `--customize-cloudinit` is set. You can also omit
the values and answer prompts instead — `--interactive` mode asks for them, and running
without enough values on a terminal (e.g. `--customize-cloudinit` alone) prompts for
them too. These settings are global for a given run (the same values apply to every
distro you build) and can be combined with any of the standard config methods: CLI
flags, `PACT_CUSTOMIZE_CLOUDINIT` / `PACT_CLOUDINIT_*` env vars, or the `.env.local`
answerfile.

### Don't have an SSH key yet?

When prompted for the SSH key, the first option generates one for you:

```
  SSH public key for the Cloud-Init user:
    1) Generate a new key pair for me
    2) Read one from a file (use this for multiple keys)
    3) Paste a single key
    4) Skip - don't set an SSH key
```

Option 1 creates an ed25519 pair (default `~/.ssh/pact-<timestamp>`, no passphrase, so
first login is unattended) and injects the public half into every template it builds. It
will not overwrite an existing file. You can also ask for a **PuTTY `.ppk`** for
PuTTY/WinSCP on Windows — needs `puttygen` (`putty-tools`), which it offers to install,
and produces a PPK v3 file readable by PuTTY 0.75 and newer.

When the build finishes, the key paths are printed last, along with the exact `ssh -i`
command to log in. You can optionally have the private key itself printed to the
terminal — handy when you're building on a remote box, but it does leave the key in your
scrollback, so it's off by default.

## Examples

Copy-paste configs, one-liners, answerfiles, and a sample playbook live in
**[`examples/`](examples/)**:

- [One-liners](examples/oneliners.md) · [Command recipes](examples/commands.md)
- [Answerfiles](examples/answerfiles/) — copy one to `.env.local` and run
- [Custom playbook + vars](examples/playbooks/)

## Supported distros

| Distro | Base VMID | Distro | Base VMID |
|--------|----------:|--------|----------:|
| Debian 12 | 802 | Ubuntu 26.04 | 814 |
| Debian 13 | 803 | Fedora 43 | 823 |
| Ubuntu 22.04 | 811 | Fedora 44 | 824 |
| Ubuntu 24.04 | 812 | | |

VMIDs are `base + offset` (default base `800`). With Packer, customized
templates get `base + 100 + offset` (e.g. Debian 12 → 902).

> Debian 11 was removed ahead of its end of life on 31 August 2026. VMID 801 is
> now unused; every other VMID is unchanged, so existing templates keep their IDs.
> If you have `debian11` in an answerfile or `--build-distros`, drop it — the
> build will otherwise stop with an unknown-distro error.

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
