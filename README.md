# Proxmox Packer Ansible CloudInit Templates - Proxmox P.A.C.T.
<img src="Images/Logo.jpg" alt="Application Logo" width="200"/>

P.A.C.T. stands for Packer Ansible CloudInit Templates. P.A.C.T. creates a series of Linux VM Templates on your Proxmox instance from a variety of distros and versions. These templates will be preconfigured for CloudInit making it so that things like resizing the filesystem or forgetting your password can easily be handled from the Proxmox web interface. We will also preinstall the QEMU-GUEST-AGENT service so that the VMs interact with Proxmox without having the "Could not get a Lock" issue. These templates can also leverage both Packer and Ansible to generalize and update the images. You can also pipe in your own Ansible/Packer playbooks to customize your images

Disclaimer! AI Tools were used to generate some of the functionality in these tools, though the core scripts are refinements on earlier scripts I personally wrote.

[![Support](https://img.shields.io/badge/Support-Buy_Me_A_Coffee-yellow?style=for-the-badge&logo=buy%20me%20a%20coffee&color=FFDD00)](https://www.buymeacoffee.com/ColtonDx)

## How it Works

### SSH Mode (Default)
1. **On your management machine**: 
   - Reads input from: CLI arguments, interactive mode, environment variables, or an answerfile
   - Connects to Proxmox via SSH using password or key-based authentication
   - Uploads `proxmox.sh` script with CLI parameters (`--vmid-base`, `--proxmox-storage`, `--build`)
   - Executes proxmox.sh remotely to build the base templates
   - Executed the default or custom Packer/Ansible customization if the flags are set
   **On Proxmox**:
   - Downloads cloud images for each enabled distros from public repos
   - Customizes VMs with virt-customize (qemu-guest-agent, CloudInit, etc.)
   - Converts VMs to templates
   - Cleans up temporary resources

3. **Standalone Mode (Direct on Proxmox)**
- Copy the Repo directly to your Proxmox host
- Execute locally without SSH: `./build.sh --local`
- Runs the same template creation process without the SSH connections
- NOTE: Running --local with Packer/Ansiblr customizations will install those prerequisites on your Proxmox host which is not recommended

### Post-Template Customization (Optional)
After base templates are created (regardless of whether SSH or Ansible mode was used), Packer can optionally customize templates:

1. **Packer customization**:
   - `build.sh` with `--run-packer` flag runs universal.pkr.hcl (or custom packerfile with `--custom-packerfile`) against created templates
    - Uses Ansible provisioning internally via `image_customizations.yml` (or custom playbook with `--custom-ansible-playbook`)
   - All distributions will run the same packerfile so make sure to include checks for distribution in your customizations
   - Requires Proxmox API Token for authentication

## Repository Structure

- **Scripts/**
  - **build.sh**: Central orchestration script supporting interactive and CLI modes:
  - **proxmox.sh**: Executed on Proxmox host to create base templates. Accepts CLI parameters:
  - **test.sh**: Pre-release end-to-end test. Builds templates in an isolated 88xxx VMID range using both of build.sh's configuration methods, boots each image to prove it works, then deletes everything. See [Pre-Release Testing](#pre-release-testing).

- **Packer/**
  - **Templates/**: 
    - **universal.pkr.hcl**: Universal template supporting all supported distros. Uses `distro` variable to configure behavior for: debian11, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604, fedora43, fedora44

- **Ansible/**
  - **Playbooks/**: 
    - **image_customizations.yml**: Default Ansible playbook for post-creation template customization (detects OS family for package manager compatibility). This playbook is used by Packer when running with `--run-packer` flag unless overridden with `--custom-ansible-playbook`
  - **Variables/**: 
    - **vars.yml**: Variables for Ansible playbooks including template creation flags (Create_Debian11, Create_Ubuntu2404, etc.) and Proxmox connection details

## Getting Started

### Prerequisites

1. **Proxmox Setup**:
   - An SSH user with access to a Proxmox Node (either password or pubkey auth)
   - For Packer deployments:
   - An API Token for a user with VM Admin access (for Packer customization phase)

2. **Management Machine Requirements**:
   - Linux shell for installing requirements (SSHPass, Ansible, Packer, wget)
   - For SSH mode: sshpass (auto-installed by build.sh if using password auth) or SSH private key
   - For Packer mode: Packer (auto-installed by build.sh if using --run-packer flag)

### Quick Setup

**One-liner** (clone and launch interactive mode in a single command):

```bash
git clone https://github.com/ColtonDx/Proxmox-P.A.C.T..git && cd Proxmox-P.A.C.T. && bash Scripts/build.sh --interactive
```

Non-interactive variant (pass your own settings):

```bash
git clone https://github.com/ColtonDx/Proxmox-P.A.C.T..git && cd Proxmox-P.A.C.T. && \
  bash Scripts/build.sh --proxmox-host=pve.local --proxmox-ssh-user=root \
    --proxmox-ssh-password="your_password" --proxmox-storage=local-lvm
```

Or step by step:

1. **Clone the Repository**

   ```bash
   git clone https://github.com/ColtonDx/Proxmox-P.A.C.T..git
   cd Proxmox-P.A.C.T.
   chmod +x ./Scripts/build.sh
   ```

2. **Run the Script**

   You can run the script from any Linux machine, including the Proxmox host itself. The script handles both remote (SSH) and local execution automatically.

   **The Easiest Way - Interactive Mode** (Recommended):
   ```bash
   ./Scripts/build.sh --interactive
   ```

   This will guide you through all configuration options interactively.

3. **Or: Run with CLI Arguments**

   Specify all settings as command-line arguments:

   ```bash
   ./Scripts/build.sh \
     --proxmox-host=pve.local \
     --proxmox-ssh-user=root \
     --proxmox-ssh-password="your_password" \
     --proxmox-storage=local-lvm
   ```

### Interactive Mode Guide

The **Interactive Mode** (`./Scripts/build.sh --interactive`) is the easiest way to get started. It will prompt you for the following in order:

#### 1. Which templates do you want to generate?
Choose which Linux distributions to create templates for. Options include:
- `all` - Create templates for all supported distros
- `debian` - All Debian versions (11, 12, 13)
- `ubuntu` - All Ubuntu versions (22.04, 24.04, 26.04)
- `fedora` - All Fedora versions (43, 44)
- Individual names: `debian11`, `debian12`, `debian13`, `ubuntu2204`, `ubuntu2404`, `ubuntu2604`, `fedora43`, `fedora44`

Example: `debian12,ubuntu2404,fedora43` to create only Debian 12, Ubuntu 24.04, and Fedora 43 templates

#### 2. Do you want to customize the templates with Packer?
Choose whether to run the Packer customization phase after creating base templates:
- `Y` - Run Packer to further customize templates with additional packages, configurations, etc.
- `N` - Create base templates only (faster, basic Cloud-Init setup)

#### 3. Base VMID
Enter the starting VMID number for your templates (default: 800). The script will automatically assign sequential IDs based on distro offsets:
- Debian 11-13: base+1, base+2, base+3
- Ubuntu 22.04/24.04/26.04: base+11, base+12, base+14
If Packer is enabled, customized versions will use base+100 offset (e.g., 901, 902, 903 for Debian with Packer).

#### 4. Is the Proxmox server remote?
Choose how the script will connect to Proxmox:
- `Y` - Connect via SSH (default, works from any machine)
- `N` - Run locally on the Proxmox host itself (no SSH needed)

If you answer **Yes** (remote), you'll be asked for:
- **Proxmox Hostname or IP Address** - DNS name or IP of your Proxmox node
- **SSH Username** - SSH user on Proxmox (usually `root`)
- **SSH Privatekey Path** - Path to your SSH private key file, or leave blank to use password authentication
- **SSH Password** - Only prompted if you didn't specify a private key path

#### 5. Storage pool
Enter the Proxmox storage pool where templates will be stored (default: `local-lvm`). This is asked regardless of whether Proxmox is local or remote.

#### 6. VMID Preview and Rebuild Confirmation
The script displays all VMIDs that will be created:
- **Base templates** with asterisk (`*`) are temporary VMs created during the provisioning process
- **Packer customized** templates (without asterisk) are the final persistent templates
- You'll be asked if you want to delete existing VMs at these IDs before building (rebuild mode)

#### 7. Packer Configuration (if Packer was enabled)
If you chose to use Packer, you'll be prompted for:
- **Proxmox API Token ID** - Format: `username@realm!token_name` (e.g., `packer@pam!packer`)
- **Proxmox API Token Secret** - The secret generated in Proxmox for the token
- **Proxmox Host Node** - Which Proxmox node to use (default: `pve`)

### CLI/Command-Line Argument Mode

For automation, scripts, or CI/CD pipelines, specify all options as command-line arguments:

```bash
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" \
  --proxmox-storage=local-lvm \
  --run-packer=true
```

**Available CLI Arguments**:
- `--interactive` - Prompt user for all settings interactively
- `--run-packer=true` - Enable Packer customization phase
- `--rebuild-templates` - Delete existing VMs before building (destructive)
- `--proxmox-host=HOSTNAME` - Proxmox hostname or IP address (default: pve.local)
- `--proxmox-ssh-user=USERNAME` - SSH username for Proxmox (default: root)
- `--proxmox-ssh-password=PASS` - SSH password for Proxmox authentication
- `--ssh-private-key-path=PATH` - Path to SSH private key for authentication
- `--proxmox-storage=POOL` - Proxmox storage pool name (default: local-lvm)
- `--local` - Run directly on Proxmox host (no SSH needed)
- `--build-distros=LIST` - Comma-separated list of distros to build (e.g., debian12,ubuntu2404, all, debian, ubuntu)
- `--custom-packerfile=PATH_OR_URL` - Path or URL to custom Packer template file (used with --run-packer)
- `--custom-ansible-playbook=PATH_OR_URL` - Path or URL to custom Ansible playbook for template customization (default: ./Ansible/Playbooks/image_customizations.yml)
- `--custom-ansible-varfile=PATH_OR_URL` - Path or URL to custom Ansible variables file (default: ./Ansible/Variables/vars.yml)
- `--packer-token-id=TOKEN` - Proxmox API Token ID for Packer (required with --run-packer, or prompted in interactive mode)
- `--packer-token-secret=SECRET` - Proxmox API Token Secret for Packer (required with --run-packer, or prompted in interactive mode)

**Examples**:

```bash
# Remote Proxmox with SSH password, no Packer
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password"

# Remote Proxmox with SSH key and Packer
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --ssh-private-key-path=/home/user/.ssh/id_rsa \
  --run-packer=true

# Local Proxmox execution with Packer
./Scripts/build.sh \
  --local \
  --proxmox-storage=local-lvm \
  --run-packer=true

# Build specific templates only
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" \
  --build-distros=debian12,ubuntu2404

# Build all Debian templates
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" \
  --build-distros=debian

# With Packer customization
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" \
  --run-packer=true

# With custom Packer template (local path)
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" \
  --run-packer=true \
  --custom-packerfile=/path/to/custom.pkr.hcl

# With custom Packer template (URL)
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" \
  --run-packer=true \
  --custom-packerfile=https://example.com/custom.pkr.hcl

# With custom Ansible playbook (local path or URL)
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" \
  --run-packer=true \
  --custom-ansible-playbook=/path/to/custom_playbook.yml \
  --custom-ansible-varfile=https://example.com/vars.yml

# With Packer API tokens provided via CLI (fully automated, no interactive prompts)
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" \
  --run-packer=true \
  --packer-token-id="user@pam!token_id" \
  --packer-token-secret="your-secret-token"

# With all options specified
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --ssh-private-key-path=/home/user/.ssh/id_rsa \
  --proxmox-storage=local-lvm \
  --build-distros=all \
  --run-packer=true \
  --packer-token-id="user@pam!token_id" \
  --packer-token-secret="your-secret-token" \
  --rebuild-templates
```

## Usage Examples

### build.sh Script

The `build.sh` script is your main entry point and supports two primary modes:

#### Interactive Mode (Recommended)

**Simplest approach** - Just run and answer prompts. Note: `--interactive` **cannot be mixed** with other arguments:
```bash
./Scripts/build.sh --interactive
```

You'll be guided through:
1. Which templates to create
2. Whether to use Packer customization
3. Base VMID
4. Whether Proxmox is remote or local
5. SSH/authentication settings (if remote)
6. Storage pool
7. Rebuild confirmation with full VMID preview
8. Packer configuration (if enabled)

Note: Temporary build VMs are automatically cleaned up after template creation.

#### CLI/Command-Line Argument Mode

For automation, scripts, or CI/CD pipelines, specify all options as command-line arguments. **Do not use `--interactive`** with other arguments:

```bash
./Scripts/build.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-user=root \
  --proxmox-ssh-password="password" \
  --proxmox-storage=local-lvm \
  --run-packer=true
```

For repeatable configurations or team environments, use an answerfile (.env.local) to store your settings:

1. **Copy the sample answerfile**:
   ```bash
   cp .env.local.sample .env.local
   ```

2. **Edit `.env.local` with your settings**:
   ```bash
   nano .env.local
   ```

   Key parameters:
   - `PROXMOX_HOST` - Proxmox hostname or IP
   - `PROXMOX_TARGET_NODE` - Node name (usually "pve")
   - `PROXMOX_SSH_USER` - SSH username (usually "root")
   - `PROXMOX_SSH_PASSWORD` - SSH password (or leave empty to use key)
   - `SSH_PRIVATE_KEY_PATH` - Path to SSH key file (optional, instead of password)
   - `PROXMOX_STORAGE` - Storage pool name
   - `VMID_BASE` - Starting VMID
   - `BUILD_DISTROS` - Which distros ("all", "debian", "ubuntu", "fedora", or comma-separated names)
   - `RUN_PACKER` - Enable Packer customization (true/false)
   - `PACKER_TOKEN_ID` - Proxmox API Token ID (if using Packer)
   - `PACKER_TOKEN_SECRET` - Proxmox API Token Secret (if using Packer)
   - Plus many more customization options (see `.env.local.sample` for full list)

3. **Run the script normally** - it will automatically load `.env.local`:
   ```bash
   ./Scripts/build.sh
   ```

   **Benefits of answerfile mode**:
   - Pre-configured settings ready to use
   - No interactive prompts needed
   - Easy to version control (with secrets protected)
   - Perfect for CI/CD pipelines or team environments
   - CLI arguments can still override answerfile values if needed

**Example `.env.local` file**:
```bash
# Copy this file to .env.local and customize for your environment
PROXMOX_HOST="pve.local"
PROXMOX_TARGET_NODE="pve"
PROXMOX_SSH_USER="root"
PROXMOX_SSH_PASSWORD="your_password_here"
SSH_PRIVATE_KEY_PATH=""
PROXMOX_STORAGE="local-lvm"
VMID_BASE=800
RUN_PACKER=true
PACKER_TOKEN_ID="packer@pam!packer_token"
PACKER_TOKEN_SECRET="your_token_secret"
BUILD_DISTROS="all"
REBUILD_TEMPLATES=false
```

**Examples**:

```bash
# Remote Proxmox with SSH password, no Packer

The `proxmox.sh` script creates base templates. It's normally executed automatically by `build.sh`, but can be run directly:

**Remotely via SSH** (from build.sh):
```bash
./proxmox.sh --vmid-base=800 --proxmox-storage=local-lvm --build=debian12,ubuntu2404
```

**Locally on Proxmox host**:
```bash
# On your management machine:
scp proxmox.sh root@pve.local:/root/

# Then SSH into Proxmox and run:
ssh root@pve.local
./proxmox.sh --vmid-base=800 --proxmox-storage=local-lvm --build=debian12,ubuntu2404
```

**proxmox.sh CLI Options**:
- `--vmid-base=NUM` - Starting VMID (default: 800)
- `--proxmox-storage=NAME` - Storage pool name (default: local-lvm)
- `--build=LIST` - Comma-separated distro names (default: all)
  - Individual: `debian11`, `debian12`, `debian13`, `ubuntu2204`, `ubuntu2404`, `ubuntu2604`, `fedora43`, `fedora44`
  - Groups: `debian` (all Debian), `ubuntu` (all Ubuntu)
  - Example: `--build=debian12,ubuntu2404,fedora43`
- `--rebuild-templates` - Delete existing VMs at target VMIDs before building
  - Without this flag (default): Existing VMs are preserved
  - With this flag: Old VMs are destroyed before creating new ones

**Example**:
```bash
./proxmox.sh --vmid-base=800 --proxmox-storage=local-lvm --build=debian12,ubuntu2404 --rebuild
```

### Distro Information

VM template VMIDs follow this numbering scheme (with default nVMID=800):

| Distro | Base VMID |
|--------|-----------|
| Debian 11 | 801 |
| Debian 12 | 802 |
| Debian 13 | 803 |
| Ubuntu 2204 | 811 |
| Ubuntu 2404 | 812 |
| Ubuntu 2604 | 814 |
| Fedora 43 | 823 |
| Fedora 44 | 824 |

If using Packer customization, customized VMs get base VMID + 100 (e.g., Debian 12 → 902).

## Supported Distros

- Debian 11
- Debian 12
- Debian 13
- Ubuntu 22.04
- Ubuntu 24.04
- Ubuntu 26.04
- Fedora 43
- Fedora 44

## Pre-Release Testing

`Scripts/test.sh` validates that the whole pipeline still works before you cut a
release. It runs against a real Proxmox host and:

1. Builds the selected templates with **build.sh in variable (CLI argument) mode**, verifies each template was created, **boots it**, then deletes it.
2. Repeats the build with **build.sh in answerfile mode**, verifies, boots, and deletes.

All test resources use an isolated **88xxx VMID range** (default base `88000`) so
they never collide with your production templates, and they are destroyed when the
run finishes (even on failure).

### How boot validation works

build.sh produces *templates*, which are never powered on. To catch images that
build but fail to boot, the test full-clones each finished template to a temporary
VM, starts it, and waits for the **QEMU guest agent** to answer (`qm agent <id>
ping`). The agent only responds once the OS has fully booted, so a successful ping
is concrete proof the image boots. The temporary clone is then destroyed.

### Requirements

- SSH (or `--local`) access to a Proxmox host where `qm` is available.
- `sshpass` on the machine running the test when using password authentication.
- Templates already ship with `qemu-guest-agent` (created by `proxmox.sh`), which the boot check relies on.

### Usage

```bash
# Test a single distro in both modes (recommended first run)
./Scripts/test.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-password=secret \
  --proxmox-storage=local-lvm \
  --build-distros=debian12

# Full pre-release run across all distros, including Packer-customized templates
./Scripts/test.sh \
  --proxmox-host=pve.local \
  --proxmox-ssh-password=secret \
  --proxmox-storage=local-lvm \
  --build-distros=all \
  --run-packer \
  --packer-token-id="user@pam!packer" \
  --packer-token-secret="your_api_token_secret"
```

Connection settings can also come from `.env.local` or `PACT_*` environment
variables (same names build.sh uses); CLI arguments take precedence. Useful flags:
`--mode=variable|answerfile|both`, `--vmid-base=NUM`, `--boot-timeout=SEC`, and
`--keep` (leave resources in place for debugging). The script exits non-zero if any
template fails to build or boot, so it can gate a release.

### Continuous Integration

Static checks that don't need a Proxmox host run automatically in GitHub Actions
(`.github/workflows/ci.yml`) on every push, pull request, and `v*` tag:

- **ShellCheck** on `Scripts/*.sh` (the scripts are clean under ShellCheck's default rules)
- **Packer** `fmt -check`, `init`, and `validate` for every distro (the distro list is read from `proxmox.sh`, so new distros are covered automatically)
- **yamllint** + **`ansible-playbook --syntax-check`** on the Ansible files (config in `.yamllint`)

These catch broken scripts, malformed Packer/Ansible changes, and a distro added
to one place but not another, before a release. The end-to-end build + boot test
(`Scripts/test.sh`) is not part of CI because it requires a live Proxmox host;
run it manually as the final pre-release gate.

You can reproduce the CI checks locally:

```bash
shellcheck Scripts/*.sh
packer fmt -check Packer/Templates/universal.pkr.hcl
yamllint Ansible/
ansible-playbook --syntax-check -i localhost, Ansible/Playbooks/image_customizations.yml
```

## Links

- [Packer Documentation](https://www.packer.io/docs)
- [Ansible Documentation](https://docs.ansible.com/)
- [Packer Proxmox-Clone](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/clone)
