# One-liners

Copy-paste starters. Replace `pve.local`, users, and passwords with your own.

## Zero-clone bootstrap (nothing to download first)

`build.sh` fetches everything it needs and prompts you:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ColtonDx/Proxmox-PACT/main/Scripts/build.sh)
```

Use `bash <(curl …)` (process substitution), **not** `curl … | bash` — the
latter breaks the interactive prompts. Run with no arguments and it asks whether
to continue interactively; answer `n` to point it at an answerfile or URL
instead.

## Clone and launch interactive mode

```bash
git clone https://github.com/ColtonDx/Proxmox-PACT.git && cd Proxmox-PACT && bash Scripts/build.sh --interactive
```

## Clone and run non-interactively

```bash
git clone https://github.com/ColtonDx/Proxmox-PACT.git && cd Proxmox-PACT && \
  bash Scripts/build.sh --proxmox-host=pve.local --proxmox-ssh-user=root \
    --proxmox-ssh-password="your_password" --proxmox-storage=local-lvm
```

## Preview only — no host, no credentials

Print the plan (targets + VMIDs) and exit without touching Proxmox:

```bash
./Scripts/build.sh --build-distros=all --run-packer --dry-run
```
