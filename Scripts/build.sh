#!/bin/bash

################################################################################
# Proxmox-PACT Build Script
#
# This script orchestrates the complete build process for creating Proxmox VM
# templates and customizing them with Packer. It supports three configuration modes:
#
#  - Interactive mode: Prompts user for all settings
#  - CLI arguments: Pass settings directly (--proxmox-host=, --build-distros=, etc.)
#  - Answerfile: Load from .env.local configuration file
#
# Multiple template creation methods:
#  * SSH mode (default): SSH to Proxmox and run proxmox.sh to create templates
#  * Local mode (--local): Run directly on Proxmox host without SSH
#
# Optional Packer customization:
#  * --run-packer: Enable Packer customization phase with API tokens
#  * --custom-packerfile: Use custom Packer template (local path or URL)
#  * --custom-ansible: Use custom Ansible playbook in Packer (local path or URL)
#  * --custom-ansible-varfile: Use custom variables file in Packer (local path or URL)
#
# Smart dependency management:
#  * Installs only required packages based on selected options
#  * Installs Packer only if --run-packer is specified
#
# Usage: ./build.sh [OPTIONS]
#
# Configuration modes (choose one):
#   ./build.sh --interactive       Prompts for all settings interactively
#   ./build.sh [CLI arguments]     Use command-line arguments directly
#   ./build.sh                     Load from .env.local (if exists), then prompts missing values
#   ./build.sh --answerfile-path=FILE   Load from custom answerfile, then prompts missing values
#
# CLI argument options:
#   --run-packer                       Enable Packer customization phase
#   --rebuild-templates                   Delete existing VMs before rebuilding (destructive)
#   --local                        Run directly on Proxmox host (no SSH needed)
#   --proxmox-host=HOSTNAME        Proxmox hostname or IP address
#   --proxmox-ssh-user=USERNAME        SSH username for Proxmox (default: root)
#   --proxmox-ssh-password=PASS    SSH password for Proxmox authentication
#   --ssh-private-key-path=PATH   Path to SSH private key for authentication
#   --proxmox-storage=POOL         Proxmox storage pool name (default: local-lvm)
#   --build-distros=LIST               Comma-separated list of distros to build (e.g., debian12,ubuntu2404)
#                                  Also accepts: all, debian, ubuntu
#   --answerfile-path=PATH              Path to custom answerfile (.env.local used by default if exists)
#   --custom-packerfile=PATH       Path to custom Packer template file
#   --custom-ansible-playbook=PATH     Path to custom Ansible playbook for Packer
#   --custom-ansible-varfile=PATH  Path to custom variables file for Ansible in Packer
#   --packer-token-id=TOKEN        Proxmox API Token ID for Packer
#   --packer-token-secret=SEC      Proxmox API Token Secret for Packer
#   --customize-cloudinit          Bake Cloud-Init defaults (username/password/SSH key) into templates
#   --cloudinit-user=USER          Cloud-Init default username (requires --customize-cloudinit)
#   --cloudinit-password=PASS      Cloud-Init default password (plaintext in the VM config; SSH keys are safer)
#   --cloudinit-ssh-keys=KEY       Literal SSH public key to inject (mutually exclusive with the file variant below)
#   --cloudinit-ssh-key-file=PATH  Local path to a file of SSH public keys, one per line
#   --help                         Show help message
#
# Answerfile (.env.local) variables:
#   PROXMOX_HOST                   Proxmox hostname (overridden by CLI args)
#   PROXMOX_TARGET_NODE            Proxmox cluster node name (default: pve)
#   PROXMOX_SSH_USER               SSH username (overridden by CLI args)
#   PROXMOX_SSH_PASSWORD           SSH password (overridden by CLI args)
#   SSH_PRIVATE_KEY_PATH           SSH key path (overridden by CLI args)
#   PROXMOX_STORAGE                Storage pool name (overridden by CLI args)
#   VMID_BASE                      Base VMID for templates (override with PACT_VMID_BASE env var)
#   BUILD_DISTROS                   Distros to build, comma-separated (overridden by CLI args)
#   PROXMOX_IS_REMOTE              Use SSH to Proxmox (true/false, default: true)
#   RUN_PACKER                     Enable Packer customization (true/false, default: false)
#   REBUILD_TEMPLATES                     Delete existing VMs before building (true/false, default: false)
#   PACKER_TOKEN_ID                Proxmox API Token ID (required if RUN_PACKER=true)
#   PACKER_TOKEN_SECRET            Proxmox API Token Secret (required if RUN_PACKER=true)
#   CUSTOM_PACKERFILE              Custom Packer template path (optional)
#   CUSTOM_ANSIBLE_PLAYBOOK        Custom Ansible playbook for Packer (optional)
#   CUSTOM_ANSIBLE_VARFILE         Custom Ansible variables file for Packer (optional)
#   CUSTOMIZE_CLOUDINIT            Bake Cloud-Init defaults into templates (true/false, default: false)
#   CLOUDINIT_USER                 Cloud-Init default username (optional, requires CUSTOMIZE_CLOUDINIT=true)
#   CLOUDINIT_PASSWORD             Cloud-Init default password (optional; stored in plaintext by Proxmox)
#   CLOUDINIT_SSH_KEYS             Literal SSH public key(s) to inject (optional, one per line)
#   CLOUDINIT_SSH_KEY_FILE         Path to a file of SSH public keys (optional, overrides CLOUDINIT_SSH_KEYS)
#
################################################################################

#####################################################################################
################### WORKING DIRECTORY SETUP
#####################################################################################

# Generate a unique working directory name to avoid conflicts
WORK_DIR_NAME="pact_build_$(date +%s)_${RANDOM}"

# Number of CLI args the user passed (used to decide whether to show the bootstrap prompt).
PACT_ARGC=$#

# Directory containing this script (empty when curl-piped via process substitution).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""

# Base URL for fetching companion files (proxmox.sh, the Packer template, the Ansible
# files) when build.sh is run standalone (curl-piped) instead of from a clone. PACT_REF
# defaults to main; the README bootstrap one-liner overrides it to the current branch
# until this is merged. Both are overridable via the environment.
PACT_REF="${PACT_REF:-main}"
PACT_BASE_URL="${PACT_BASE_URL:-https://raw.githubusercontent.com/ColtonDx/Proxmox-PACT/$PACT_REF}"

# Cleanup for URL-download temp files and the bootstrap working tree (single EXIT trap;
# resolve_file_reference must NOT set its own trap, as an in-function trap inside a command
# substitution would fire and delete the download the moment it returned).
PACT_TMP_FILES=()
PACT_BOOTSTRAP_DIR=""
cleanup() {
    [ "${#PACT_TMP_FILES[@]}" -gt 0 ] && rm -f "${PACT_TMP_FILES[@]}"
    [ -n "$PACT_BOOTSTRAP_DIR" ] && rm -rf "$PACT_BOOTSTRAP_DIR"
}
trap cleanup EXIT

# Clone vs standalone. When standalone, download the companion files into a temp working
# tree and cd into it so the rest of the script behaves exactly as it would from a clone.
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/proxmox.sh" ]; then
    RUNNING_FROM_CLONE=true
else
    RUNNING_FROM_CLONE=false
    PACT_BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pact_bootstrap.XXXXXX")"
    echo "Bootstrapping companion files from $PACT_BASE_URL ..."
    mkdir -p "$PACT_BOOTSTRAP_DIR/Scripts" \
             "$PACT_BOOTSTRAP_DIR/Packer/Templates" \
             "$PACT_BOOTSTRAP_DIR/Ansible/Playbooks" \
             "$PACT_BOOTSTRAP_DIR/Ansible/Variables"
    for _f in Scripts/proxmox.sh \
              Packer/Templates/universal.pkr.hcl \
              Ansible/Playbooks/image_customizations.yml \
              Ansible/Variables/vars.yml; do
        if ! curl -fsSL "$PACT_BASE_URL/$_f" -o "$PACT_BOOTSTRAP_DIR/$_f"; then
            echo "Error: failed to fetch $_f from $PACT_BASE_URL" >&2
            exit 1
        fi
    done
    SCRIPT_DIR="$PACT_BOOTSTRAP_DIR/Scripts"
    cd "$PACT_BOOTSTRAP_DIR" || exit 1
fi

# Repository root (parent of the Scripts dir). Companion files are resolved by absolute path
# from here so build.sh works no matter what directory it is invoked from.
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

#####################################################################################
################### CLI OPTION PARSING
#####################################################################################

# Detect whether we're running on a Proxmox host itself (its cluster filesystem or tools
# are present). If so, default to local execution instead of SSH.
ON_PROXMOX=false
if [ -d /etc/pve ] || command -v pveversion &>/dev/null; then
    ON_PROXMOX=true
fi

# Default flags and values (lowest precedence: the answerfile, then PACT_* env vars,
# then CLI arguments each override these in turn)
RUN_PACKER=false
REBUILD_TEMPLATES=false
INTERACTIVE_MODE=false
DRY_RUN=false
SSH_PRIVATE_KEY_PATH=""
# On a Proxmox host, default to local execution; otherwise default to remote (SSH).
if [ "$ON_PROXMOX" = true ]; then PROXMOX_IS_REMOTE=false; else PROXMOX_IS_REMOTE=true; fi
CUSTOM_PACKERFILE=""
CUSTOM_ANSIBLE_PLAYBOOK=""
CUSTOM_ANSIBLE_VARFILE=""
BUILD_DISTROS=""
PACKER_TOKEN_ID=""
PACKER_TOKEN_SECRET=""
ANSWERFILE_PATH=""
CUSTOMIZE_CLOUDINIT=false
CLOUDINIT_USER=""
CLOUDINIT_PASSWORD=""
CLOUDINIT_SSH_KEYS=""
CLOUDINIT_SSH_KEY_FILE=""
# Set only when interactive setup generates a key pair for the user (see generate_ssh_key).
# The paths are reported after the build so they aren't buried under the build output.
GENERATED_KEY_PATH=""
GENERATED_PPK_PATH=""
WANT_PPK=false
PRINT_PRIVATE_KEY=false

#####################################################################################
# LOAD ANSWERFILE (.env.local by default, or --answerfile-path / PACT_ANSWERFILE_PATH)
#####################################################################################
# Resolve the answerfile path first (a CLI --answerfile-path beats PACT_ANSWERFILE_PATH),
# then source it HERE, before the PACT_* env block and the CLI parse loop further down.
# That ordering is what enforces the documented precedence:
#     CLI args  >  PACT_* env vars  >  answerfile  >  built-in defaults
# i.e. the answerfile can only override the defaults, never a value the user passed
# explicitly on the command line or via a PACT_* variable.
[ -n "${PACT_ANSWERFILE_PATH:-}" ] && ANSWERFILE_PATH="${PACT_ANSWERFILE_PATH}"
for arg in "$@"; do
    case "$arg" in
        --answerfile-path=*) ANSWERFILE_PATH="${arg#*=}" ;;
    esac
done

CONFIG_FILE_EXPANDED="${ANSWERFILE_PATH:-$REPO_DIR/.env.local}"
# Expand a leading tilde in the path
CONFIG_FILE_EXPANDED="${CONFIG_FILE_EXPANDED/#\~/$HOME}"
CONFIG_LOADED=false
if [ -f "$CONFIG_FILE_EXPANDED" ]; then
    echo "Loading configuration from $CONFIG_FILE_EXPANDED..."
    # shellcheck source=/dev/null
    source "$CONFIG_FILE_EXPANDED"
    CONFIG_LOADED=true
fi

#####################################################################################
# LOAD ENVIRONMENT VARIABLES (PACT_ PREFIX)
#####################################################################################
# Override the answerfile/defaults with any PACT_* environment variables that are set.
# Priority: CLI args (parsed below) > PACT_* env > answerfile > script defaults
[ -n "${PACT_RUN_PACKER:-}" ] && RUN_PACKER="${PACT_RUN_PACKER}"
[ -n "${PACT_REBUILD_TEMPLATES:-}" ] && REBUILD_TEMPLATES="${PACT_REBUILD_TEMPLATES}"
[ -n "${PACT_INTERACTIVE_MODE:-}" ] && INTERACTIVE_MODE="${PACT_INTERACTIVE_MODE}"
[ -n "${PACT_SSH_PRIVATE_KEY_PATH:-}" ] && SSH_PRIVATE_KEY_PATH="${PACT_SSH_PRIVATE_KEY_PATH}"
[ -n "${PACT_PROXMOX_IS_REMOTE:-}" ] && PROXMOX_IS_REMOTE="${PACT_PROXMOX_IS_REMOTE}"
[ -n "${PACT_CUSTOM_PACKERFILE:-}" ] && CUSTOM_PACKERFILE="${PACT_CUSTOM_PACKERFILE}"
[ -n "${PACT_CUSTOM_ANSIBLE_PLAYBOOK:-}" ] && CUSTOM_ANSIBLE_PLAYBOOK="${PACT_CUSTOM_ANSIBLE_PLAYBOOK}"
[ -n "${PACT_CUSTOM_ANSIBLE_VARFILE:-}" ] && CUSTOM_ANSIBLE_VARFILE="${PACT_CUSTOM_ANSIBLE_VARFILE}"
[ -n "${PACT_BUILD_DISTROS:-}" ] && BUILD_DISTROS="${PACT_BUILD_DISTROS}"
[ -n "${PACT_PACKER_TOKEN_ID:-}" ] && PACKER_TOKEN_ID="${PACT_PACKER_TOKEN_ID}"
[ -n "${PACT_PACKER_TOKEN_SECRET:-}" ] && PACKER_TOKEN_SECRET="${PACT_PACKER_TOKEN_SECRET}"
[ -n "${PACT_ANSWERFILE_PATH:-}" ] && ANSWERFILE_PATH="${PACT_ANSWERFILE_PATH}"
[ -n "${PACT_PROXMOX_HOST:-}" ] && PROXMOX_HOST="${PACT_PROXMOX_HOST}"
[ -n "${PACT_PROXMOX_SSH_USER:-}" ] && PROXMOX_SSH_USER="${PACT_PROXMOX_SSH_USER}"
[ -n "${PACT_PROXMOX_SSH_PASSWORD:-}" ] && PROXMOX_SSH_PASSWORD="${PACT_PROXMOX_SSH_PASSWORD}"
[ -n "${PACT_PROXMOX_STORAGE:-}" ] && PROXMOX_STORAGE="${PACT_PROXMOX_STORAGE}"
[ -n "${PACT_PROXMOX_TARGET_NODE:-}" ] && PROXMOX_TARGET_NODE="${PACT_PROXMOX_TARGET_NODE}"
[ -n "${PACT_VMID_BASE:-}" ] && VMID_BASE="${PACT_VMID_BASE}"
[ -n "${PACT_CUSTOMIZE_CLOUDINIT:-}" ] && CUSTOMIZE_CLOUDINIT="${PACT_CUSTOMIZE_CLOUDINIT}"
[ -n "${PACT_CLOUDINIT_USER:-}" ] && CLOUDINIT_USER="${PACT_CLOUDINIT_USER}"
[ -n "${PACT_CLOUDINIT_PASSWORD:-}" ] && CLOUDINIT_PASSWORD="${PACT_CLOUDINIT_PASSWORD}"
[ -n "${PACT_CLOUDINIT_SSH_KEYS:-}" ] && CLOUDINIT_SSH_KEYS="${PACT_CLOUDINIT_SSH_KEYS}"
[ -n "${PACT_CLOUDINIT_SSH_KEY_FILE:-}" ] && CLOUDINIT_SSH_KEY_FILE="${PACT_CLOUDINIT_SSH_KEY_FILE}"

# Distro metadata (ids, display names, VMID offsets) is defined once in
# Scripts/proxmox.sh. Parse it here so there is a single source of truth: adding or
# removing a distro only touches proxmox.sh and the Packer template, never this file.
declare -a DISTRO_IDS=()
declare -A DISTRO_NAME=()
declare -A DISTRO_OFFSET=()
while IFS= read -r _line; do
    _entry="${_line#*\"}"; _entry="${_entry%%\"*}"
    IFS='|' read -r _id _name _offset _ <<< "$_entry"
    [ -z "$_id" ] && continue
    DISTRO_IDS+=("$_id")
    DISTRO_NAME["$_id"]="$_name"
    DISTRO_OFFSET["$_id"]="$_offset"
done < <(grep -E '^[[:space:]]*"[a-z0-9]+\|' "$SCRIPT_DIR/proxmox.sh")

if [ "${#DISTRO_IDS[@]}" -eq 0 ]; then
    echo "Error: could not read distro metadata from $SCRIPT_DIR/proxmox.sh" >&2
    exit 1
fi

# Expand a build spec into concrete distro ids. Accepts "all", individual ids, or a
# group prefix (e.g. "debian" -> debian12/13). Prints the de-duped id list and
# returns 0; on an unknown token prints an error and returns 1.
expand_selected() {
    local spec="$1" token id out="" bad=""
    if [ -z "$spec" ] || [ "$spec" = "all" ]; then
        echo "${DISTRO_IDS[*]}"
        return 0
    fi
    for token in ${spec//,/ }; do
        local matched=false
        for id in "${DISTRO_IDS[@]}"; do
            if [ "$id" = "$token" ] || [[ "$id" == "$token"* ]]; then
                out="$out $id"; matched=true
            fi
        done
        [ "$matched" = false ] && bad="$bad $token"
    done
    if [ -n "$bad" ]; then
        echo "Error: unknown distro(s):$bad" >&2
        echo "Valid: all, a group (debian/ubuntu/fedora), or one of: ${DISTRO_IDS[*]}" >&2
        return 1
    fi
    echo "$out" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs
}

# Selected distros to build (space-separated list of distro IDs)
SELECTED_DISTROS=""

# Generate a fresh SSH key pair for Cloud-Init, for users who don't already have one.
# On success sets CLOUDINIT_SSH_KEYS to the public key (so it gets baked into the
# templates like any other key) and records GENERATED_KEY_PATH for the post-build report.
# Returns 1 without touching CLOUDINIT_SSH_KEYS if the key could not be created, so the
# caller can re-offer the menu instead of silently continuing with no key.
generate_ssh_key() {
    if ! command -v ssh-keygen &>/dev/null; then
        echo "  Error: ssh-keygen not found (install openssh-client). Pick another option." >&2
        return 1
    fi

    local default_path key_path=""
    default_path="$HOME/.ssh/pact-$(date +%Y%m%d-%H%M%S)"
    read -p "  Path for the new key [$default_path]: " -r key_path
    key_path="${key_path:-$default_path}"
    key_path="${key_path/#\~/$HOME}"
    if [ -e "$key_path" ] || [ -e "$key_path.pub" ]; then
        echo "  Error: $key_path already exists - refusing to overwrite an existing key." >&2
        return 1
    fi
    if ! mkdir -p "$(dirname "$key_path")" 2>/dev/null; then
        echo "  Error: could not create $(dirname "$key_path")" >&2
        return 1
    fi

    # ed25519: supported by every cloud image we build and by PuTTY 0.75+. No passphrase
    # (-N ""), because the point is an unattended first login to a fresh VM; the private
    # key lands in the user's ~/.ssh with ssh-keygen's default 0600.
    if ! ssh-keygen -t ed25519 -N "" -C "proxmox-pact-$(date +%Y%m%d)" -f "$key_path" >/dev/null; then
        echo "  Error: ssh-keygen failed to create $key_path" >&2
        return 1
    fi

    CLOUDINIT_SSH_KEYS="$(cat "$key_path.pub")"
    GENERATED_KEY_PATH="$key_path"
    echo "  Created $key_path and $key_path.pub"

    # The .ppk conversion itself is deferred to report_generated_key(), which runs after
    # install_pkgs() is defined and so can install putty-tools if it's missing.
    read -p "  Also create a PuTTY .ppk file (for PuTTY/WinSCP on Windows)? (y/N): " -r _ppk_choice
    [[ "$_ppk_choice" =~ ^[Yy]$ ]] && WANT_PPK=true

    read -p "  Print the private key to this terminal when the build finishes? (y/N): " -r _print_choice
    [[ "$_print_choice" =~ ^[Yy]$ ]] && PRINT_PRIVATE_KEY=true

    return 0
}

# Interactively prompt for optional Cloud-Init defaults, setting CLOUDINIT_USER,
# CLOUDINIT_PASSWORD, and CLOUDINIT_SSH_KEYS. Shared by full --interactive mode and the
# non-interactive gap-fill prompt (used when --customize-cloudinit is set with no values).
prompt_cloudinit_values() {
    read -p "  Cloud-Init username (blank to leave the image's default user): " -r CLOUDINIT_USER
    echo "  Warning: a Cloud-Init password is stored in PLAINTEXT in the Proxmox VM config (qm config); SSH keys are safer."
    read -sp "  Cloud-Init password (blank to skip): " -r CLOUDINIT_PASSWORD
    echo ""

    local choice="" keyfile=""
    while true; do
        echo "  SSH public key for the Cloud-Init user:"
        echo "    1) Generate a new key pair for me"
        echo "    2) Read one from a file (use this for multiple keys)"
        echo "    3) Paste a single key"
        echo "    4) Skip - don't set an SSH key"
        read -p "  Choice [4]: " -r choice
        case "${choice:-4}" in
            1) generate_ssh_key && break ;;
            2) read -p "  SSH public key file path: " -r keyfile
               keyfile="${keyfile/#\~/$HOME}"
               if [ -f "$keyfile" ]; then
                   CLOUDINIT_SSH_KEYS="$(cat "$keyfile")"
                   break
               fi
               echo "  File not found: $keyfile" >&2 ;;
            3) read -p "  Paste a single SSH public key: " -r CLOUDINIT_SSH_KEYS; break ;;
            4) break ;;
            *) echo "  Please enter 1, 2, 3, or 4." >&2 ;;
        esac
    done
}

print_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --interactive              Prompt the user for all settings interactively.
  --run-packer               Run Packer builds for image customization.
  --rebuild-templates             Delete existing VMs before building new ones (destructive).
  --proxmox-host=HOSTNAME    Proxmox hostname or IP address (default: pve.local).
  --proxmox-ssh-user=USER    SSH username for Proxmox (default: root).
  --proxmox-ssh-password=PASS  SSH password for Proxmox authentication.
  --ssh-private-key-path=PATH  Path to SSH private key for authentication.
  --proxmox-storage=POOL     Proxmox storage pool name (default: local-lvm).
  --proxmox-target-node=NODE Proxmox target node for Packer (default: pve).
  --local                    Run directly on Proxmox host (no SSH needed).
  --dry-run                  Print the resolved plan (target, VMIDs, files) and exit.
  --build-distros=LIST       Comma-separated list of distros to build (e.g., debian12,ubuntu2404).
  --answerfile-path=PATH     Path to custom answerfile (.env.local used by default if exists).
  --custom-packerfile=PATH   Path or URL to custom Packer template file instead of default.
  --custom-ansible-playbook=PATH  Path or URL to custom Ansible playbook for Packer customization.
  --custom-ansible-varfile=PATH  Path or URL to custom variables file for Ansible playbook (default: ./Ansible/Variables/vars.yml).
  --packer-token-id=TOKEN    Proxmox API Token ID for Packer (required with --run-packer).
  --packer-token-secret=SEC  Proxmox API Token Secret for Packer (required with --run-packer).
  --customize-cloudinit      Bake Cloud-Init defaults (username/password/SSH key) into the templates.
  --cloudinit-user=USER      Cloud-Init default username (with --customize-cloudinit).
  --cloudinit-password=PASS  Cloud-Init default password (plaintext in the VM config; SSH keys are safer).
  --cloudinit-ssh-keys=KEY   Literal SSH public key to inject (mutually exclusive with --cloudinit-ssh-key-file).
  --cloudinit-ssh-key-file=PATH  Local path to a file of SSH public keys, one per line.
  --help                     Show this help and exit

Notes:
  - If --interactive is set, no other arguments are allowed (it overrides everything).
  - Without --local, defaults to SSH mode (remote Proxmox).
  - Without --rebuild-templates, existing VMs at target VMIDs are preserved (safer).
  - --build-distros accepts: all, debian, ubuntu, fedora, individual names (debian12, debian13, ubuntu2204, fedora43, etc.)
  - --custom-packerfile allows using a custom Packer template with --run-packer.
  - --customize-cloudinit requires at least one of --cloudinit-user, --cloudinit-password,
    --cloudinit-ssh-keys, or --cloudinit-ssh-key-file.
EOF
}

# Parse CLI arguments
for arg in "$@"; do
    case "$arg" in
        --run-packer|--run-packer=true)
            RUN_PACKER=true
            ;;
        --run-packer=false)
            RUN_PACKER=false
            ;;
        --rebuild-templates|--rebuild-templates=true)
            REBUILD_TEMPLATES=true
            ;;
        --rebuild-templates=false)
            REBUILD_TEMPLATES=false
            ;;
        --interactive)
            INTERACTIVE_MODE=true
            ;;
        --proxmox-host=*)
            PROXMOX_HOST="${arg#*=}"
            ;;
        --proxmox-ssh-user=*)
            PROXMOX_SSH_USER="${arg#*=}"
            ;;
        --proxmox-ssh-password=*)
            PROXMOX_SSH_PASSWORD="${arg#*=}"
            ;;
        --ssh-private-key-path=*)
            SSH_PRIVATE_KEY_PATH="${arg#*=}"
            ;;
        --proxmox-storage=*)
            PROXMOX_STORAGE="${arg#*=}"
            ;;
        --proxmox-target-node=*)
            PROXMOX_TARGET_NODE="${arg#*=}"
            ;;
        --local)
            PROXMOX_IS_REMOTE=false
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --build-distros=*)
            BUILD_DISTROS="${arg#*=}"
            ;;
        --answerfile-path=*)
            ANSWERFILE_PATH="${arg#*=}"
            ;;
        --custom-packerfile=*)
            CUSTOM_PACKERFILE="${arg#*=}"
            ;;
        --custom-ansible-playbook=*)
            CUSTOM_ANSIBLE_PLAYBOOK="${arg#*=}"
            ;;
        --custom-ansible-varfile=*)
            CUSTOM_ANSIBLE_VARFILE="${arg#*=}"
            ;;
        --packer-token-id=*)
            PACKER_TOKEN_ID="${arg#*=}"
            ;;
        --packer-token-secret=*)
            PACKER_TOKEN_SECRET="${arg#*=}"
            ;;
        --customize-cloudinit|--customize-cloudinit=true)
            CUSTOMIZE_CLOUDINIT=true
            ;;
        --customize-cloudinit=false)
            CUSTOMIZE_CLOUDINIT=false
            ;;
        --cloudinit-user=*)
            CLOUDINIT_USER="${arg#*=}"
            ;;
        --cloudinit-password=*)
            CLOUDINIT_PASSWORD="${arg#*=}"
            ;;
        --cloudinit-ssh-keys=*)
            CLOUDINIT_SSH_KEYS="${arg#*=}"
            ;;
        --cloudinit-ssh-key-file=*)
            CLOUDINIT_SSH_KEY_FILE="${arg#*=}"
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            print_usage
            exit 1
            ;;
    esac
done

# Validate that --interactive is not mixed with other arguments
if [ "$INTERACTIVE_MODE" = true ]; then
    # Check if any other non-help arguments were provided
    other_args=false
    for arg in "$@"; do
        case "$arg" in
            --interactive|--help)
                continue
                ;;
            *)
                other_args=true
                break
                ;;
        esac
    done

    if [ "$other_args" = true ]; then
        echo "Error: --interactive cannot be mixed with other arguments" >&2
        echo "Use either: ./build.sh --interactive" >&2
        echo "Or use: ./build.sh [OPTIONS] (without --interactive)" >&2
        exit 1
    fi
fi

# Resolve a local Cloud-Init SSH key file (if given) into CLOUDINIT_SSH_KEYS. Done once,
# after every source (answerfile/env/CLI) has had a chance to set either variable.
if [ -n "$CLOUDINIT_SSH_KEY_FILE" ]; then
    if [ -n "$CLOUDINIT_SSH_KEYS" ]; then
        echo "Error: set only one of --cloudinit-ssh-keys or --cloudinit-ssh-key-file (CLOUDINIT_SSH_KEYS / CLOUDINIT_SSH_KEY_FILE)." >&2
        exit 1
    fi
    CLOUDINIT_SSH_KEY_FILE="${CLOUDINIT_SSH_KEY_FILE/#\~/$HOME}"
    if [ ! -f "$CLOUDINIT_SSH_KEY_FILE" ]; then
        echo "Error: Cloud-Init SSH key file not found: $CLOUDINIT_SSH_KEY_FILE" >&2
        exit 1
    fi
    CLOUDINIT_SSH_KEYS="$(cat "$CLOUDINIT_SSH_KEY_FILE")"
fi

# Set defaults for unset variables (CLI arguments take precedence)
: "${PROXMOX_SSH_USER:=root}"
: "${PROXMOX_HOST:=pve.local}"
: "${PROXMOX_TARGET_NODE:=pve}"
: "${PROXMOX_STORAGE:=local-lvm}"
: "${VMID_BASE:=800}"

#####################################################################################
# BOOTSTRAP PROMPT (only when run with no args and no config): offer interactive
# mode, or let the user point at an answerfile / custom playbook + varfile.
#####################################################################################
if [ "$PACT_ARGC" -eq 0 ] && [ "$INTERACTIVE_MODE" = false ] && [ "$CONFIG_LOADED" = false ] && [ -t 0 ]; then
    echo ""
    read -p "No configuration found. Continue in interactive mode? [Y/n]: " -r _gate
    if [[ "$_gate" =~ ^[Nn]$ ]]; then
        read -p "  Answerfile path or URL (blank to skip): " -r _af
        if [ -n "$_af" ]; then
            if [[ "$_af" =~ ^https?:// ]]; then
                _aftmp="$(mktemp)"
                PACT_TMP_FILES+=("$_aftmp")
                if ! curl -fsSL "$_af" -o "$_aftmp"; then
                    echo "Error: failed to download answerfile from $_af" >&2
                    exit 1
                fi
                # shellcheck source=/dev/null
                source "$_aftmp"
            else
                _af="${_af/#\~/$HOME}"
                if [ ! -f "$_af" ]; then
                    echo "Error: answerfile not found: $_af" >&2
                    exit 1
                fi
                # shellcheck source=/dev/null
                source "$_af"
            fi
        fi
        read -p "  Custom Ansible playbook URL/path (blank to skip): " -r _cap
        [ -n "$_cap" ] && CUSTOM_ANSIBLE_PLAYBOOK="$_cap"
        read -p "  Custom Ansible varfile URL/path (blank to skip): " -r _cav
        [ -n "$_cav" ] && CUSTOM_ANSIBLE_VARFILE="$_cav"
    else
        INTERACTIVE_MODE=true
    fi
fi

#####################################################################################
# INTERACTIVE MODE
#####################################################################################
if [ "$INTERACTIVE_MODE" = true ]; then
    echo "=== Interactive Mode ==="
    echo ""

    # Q1: Ask which images to build
    echo "Select distros to create templates from:"
    echo "  Available: all, debian, ubuntu, fedora, ${DISTRO_IDS[*]}"

    # Keep asking until valid input is provided
    BUILD_VALID=false
    while [ "$BUILD_VALID" = false ]; do
        read -p "Enter comma-separated list (or 'all' for all distros) [Default: all]: " -r build_input
        BUILD_DISTROS="${build_input:-all}"
        if SELECTED_DISTROS="$(expand_selected "$BUILD_DISTROS")"; then
            BUILD_VALID=true
        fi
    done

    # Q2: Ask about Cloud-Init customization (username/password/SSH key baked into templates)
    echo ""
    read -p "Customize Cloud-Init defaults (username/password/SSH key) baked into the templates? (Y/N) [Default: No]: " -r choice_cloudinit
    if [[ "$choice_cloudinit" =~ ^[Yy]$ ]]; then
        CUSTOMIZE_CLOUDINIT=true
        prompt_cloudinit_values
    fi

    # Q3: Ask about Packer customization
    echo ""
    read -p "Do you want to customize the templates with Packer/Ansible? (Y/N) [Default: No]: " -r choice_packer
    if [[ "$choice_packer" =~ ^[Yy]$ ]]; then
        RUN_PACKER=true
    fi

    # Q4: Ask for Base VMID
    echo ""
    read -p "Base VMID (press Enter for default 800): " -r vmid_input
    if [ -n "$vmid_input" ]; then
        VMID_BASE="$vmid_input"
    fi

    # Q5: Ask if Proxmox is remote (defaults to No when we're on a Proxmox host)
    echo ""
    if [ "$ON_PROXMOX" = true ]; then
        echo "This appears to be a Proxmox host, so local execution is the default."
        read -p "Is the Proxmox server remote (build from here over SSH instead)? (Y/N) [Default: No]: " -r choice_remote
        if [[ "$choice_remote" =~ ^[Yy]$ ]]; then
            PROXMOX_IS_REMOTE=true
        else
            PROXMOX_IS_REMOTE=false
        fi
    else
        read -p "Is the Proxmox server remote? (Y/N) [Default: Yes]: " -r choice_remote
        if [[ "$choice_remote" =~ ^[Nn]$ ]]; then
            PROXMOX_IS_REMOTE=false
        else
            PROXMOX_IS_REMOTE=true
        fi
    fi

    # Ask Proxmox settings only if remote
    if [ "$PROXMOX_IS_REMOTE" = true ]; then
        echo ""
        echo "Proxmox Configuration:"

        read -p "Proxmox Hostname or IP Address (press Enter for default 'pve.local'): " -r proxmox_host_input
        if [ -n "$proxmox_host_input" ]; then
            PROXMOX_HOST="$proxmox_host_input"
        fi

        read -p "SSH Username (press Enter for default 'root'): " -r ssh_user_input
        if [ -n "$ssh_user_input" ]; then
            PROXMOX_SSH_USER="$ssh_user_input"
        fi

        read -p "SSH Privatekey Path (leave blank for password authentication): " -r ssh_key_input
        if [ -n "$ssh_key_input" ]; then
            SSH_PRIVATE_KEY_PATH="$ssh_key_input"
        else
            # Ask for SSH password if not using key
            read -sp "SSH Password: " -r PROXMOX_SSH_PASSWORD
            echo ""
        fi
    fi

    # Ask for storage pool (for both remote and local)
    echo ""
    read -p "Proxmox Storage Pool (press Enter for default 'local-lvm'): " -r storage_input
    if [ -n "$storage_input" ]; then
        PROXMOX_STORAGE="$storage_input"
    fi

    # Calculate VMIDs for selected distros
    declare -a SELECTED_VMIDS
    declare -a PACKER_VMIDS
    SELECTED_VMIDS=()
    PACKER_VMIDS=()

    for distro_id in "${DISTRO_IDS[@]}"; do
        if [[ " $SELECTED_DISTROS " == *" $distro_id "* ]]; then
            offset="${DISTRO_OFFSET[$distro_id]}"
            SELECTED_VMIDS+=("$((VMID_BASE + offset))")
            if [ "$RUN_PACKER" = true ]; then
                PACKER_VMIDS+=("$((VMID_BASE + 100 + offset))")
            fi
        fi
    done

    # Display VMID information
    echo ""
    echo "VMIDs that will be created:"
    if [ "$RUN_PACKER" = true ]; then
        # Display base templates with asterisk
        base_vmids_display=""
        for vmid in "${SELECTED_VMIDS[@]}"; do
            if [ -z "$base_vmids_display" ]; then
                base_vmids_display="${vmid}*"
            else
                base_vmids_display="$base_vmids_display ${vmid}*"
            fi
        done
        echo "  Base templates: $base_vmids_display ${PACKER_VMIDS[*]}"
        echo "  * VMs will be created temporarily during the provisioning process"
    else
        echo "  Base templates: ${SELECTED_VMIDS[*]}"
    fi

    # Ask about rebuild with VMID information displayed
    echo ""
    read -p "Delete existing VMs before building (rebuild-templates)? (Y/N) [Default: No]: " -r choice_rebuild
    if [[ "$choice_rebuild" =~ ^[Yy]$ ]]; then
        REBUILD_TEMPLATES=true
    fi

    # If Packer is enabled, ask for Packer configuration
    if [ "$RUN_PACKER" = true ]; then
        echo ""
        echo "Packer Configuration:"

        # Prompt for Packer Token ID only if not provided via CLI
        while [ -z "$PACKER_TOKEN_ID" ]; do
            read -p "Proxmox API Token ID (required): " -r packer_token_id_input
            if [ -n "$packer_token_id_input" ]; then
                PACKER_TOKEN_ID="$packer_token_id_input"
            else
                echo "Error: Proxmox API Token ID is required when using Packer"
            fi
        done

        # Prompt for Packer Token Secret only if not provided via CLI
        while [ -z "$PACKER_TOKEN_SECRET" ]; do
            read -sp "Proxmox API Token Secret (required): " -r packer_token_secret_input
            echo ""
            if [ -n "$packer_token_secret_input" ]; then
                PACKER_TOKEN_SECRET="$packer_token_secret_input"
            else
                echo "Error: Proxmox API Token Secret is required when using Packer"
            fi
        done

        read -p "Proxmox Target Node (press Enter for default 'pve'): " -r proxmox_target_node_input
        if [ -n "$proxmox_target_node_input" ]; then
            PROXMOX_TARGET_NODE="$proxmox_target_node_input"
        fi

        # Ansible/Packer customization files. Each accepts a local path OR a URL
        # (e.g. a GitLab/GitHub raw link); press Enter to use the built-in defaults.
        # This is asked in both remote (SSH) and local modes.
        echo ""
        echo "Customization files (press Enter for the built-in defaults):"
        read -p "  Custom Ansible playbook (local path or URL): " -r ansible_playbook_input
        [ -n "$ansible_playbook_input" ] && CUSTOM_ANSIBLE_PLAYBOOK="$ansible_playbook_input"
        read -p "  Custom Ansible variables file (local path or URL): " -r ansible_varfile_input
        [ -n "$ansible_varfile_input" ] && CUSTOM_ANSIBLE_VARFILE="$ansible_varfile_input"
        read -p "  Custom Packer template (local path or URL): " -r packerfile_input
        [ -n "$packerfile_input" ] && CUSTOM_PACKERFILE="$packerfile_input"
    fi

    echo ""
fi

# Fill in still-missing required values for the non-interactive paths (CLI/answerfile/env).
# On a terminal we prompt for the gaps, so you can supply as much or as little up front;
# without a terminal the validation below fails with a clear message instead.
if [ "$INTERACTIVE_MODE" = false ]; then
    if [ -z "$BUILD_DISTROS" ] && [ -t 0 ]; then
        read -p "Which distros to build? (all, debian, ubuntu, fedora, or e.g. debian12,ubuntu2404) [all]: " -r _bd
        BUILD_DISTROS="${_bd:-all}"
    fi
    if [ "$DRY_RUN" = false ] && [ "$PROXMOX_IS_REMOTE" = true ] && [ -z "$SSH_PRIVATE_KEY_PATH" ] && [ -z "${PROXMOX_SSH_PASSWORD:-}" ] && [ -t 0 ]; then
        read -sp "SSH password for $PROXMOX_SSH_USER@$PROXMOX_HOST: " -r PROXMOX_SSH_PASSWORD
        echo ""
    fi
    if [ "$RUN_PACKER" = true ] && [ "$DRY_RUN" = false ] && [ -t 0 ]; then
        [ -z "$PACKER_TOKEN_ID" ]     && read -p  "Proxmox API Token ID (for Packer): " -r PACKER_TOKEN_ID
        [ -z "$PACKER_TOKEN_SECRET" ] && { read -sp "Proxmox API Token Secret (for Packer): " -r PACKER_TOKEN_SECRET; echo ""; }
    fi
    if [ "$CUSTOMIZE_CLOUDINIT" = true ] && [ -z "$CLOUDINIT_USER" ] && [ -z "$CLOUDINIT_PASSWORD" ] && [ -z "$CLOUDINIT_SSH_KEYS" ] && [ "$DRY_RUN" = false ] && [ -t 0 ]; then
        echo ""
        echo "Cloud-Init customization is enabled (--customize-cloudinit) but no values were provided."
        prompt_cloudinit_values
    fi
fi

# Parse BUILD_DISTROS into SELECTED_DISTROS (set via --build-distros=, answerfile, env,
# or interactive mode). expand_selected handles all/groups/ids and reports bad input.
if [ -n "$BUILD_DISTROS" ]; then
    if ! SELECTED_DISTROS="$(expand_selected "$BUILD_DISTROS")"; then
        exit 1
    fi
fi

# Validate required variables for Packer
if [ "$RUN_PACKER" = true ] && [ "$DRY_RUN" = false ]; then
    if [ -z "$PACKER_TOKEN_ID" ] || [ -z "$PACKER_TOKEN_SECRET" ]; then
        echo "Error: PACKER_TOKEN_ID and PACKER_TOKEN_SECRET are required when using --run-packer" >&2
        exit 1
    fi
fi

# Validate that Cloud-Init customization has at least one value to apply.
if [ "$CUSTOMIZE_CLOUDINIT" = true ] && [ -z "$CLOUDINIT_USER" ] && [ -z "$CLOUDINIT_PASSWORD" ] && [ -z "$CLOUDINIT_SSH_KEYS" ]; then
    echo "Error: --customize-cloudinit is set but no username, password, or SSH key was provided." >&2
    echo "Set --cloudinit-user, --cloudinit-password, --cloudinit-ssh-keys, or --cloudinit-ssh-key-file (or use --interactive)." >&2
    exit 1
fi

# Validate that SSH authentication is available for remote mode.
if [ "$DRY_RUN" = false ] && [ "$PROXMOX_IS_REMOTE" = true ] && [ -z "$SSH_PRIVATE_KEY_PATH" ] && [ -z "${PROXMOX_SSH_PASSWORD:-}" ]; then
    echo "Error: SSH authentication required for $PROXMOX_SSH_USER@$PROXMOX_HOST." >&2
    echo "Provide --proxmox-ssh-password or --ssh-private-key-path, or use --local." >&2
    exit 1
fi

# Validate that at least one distro is selected
if [ -z "$SELECTED_DISTROS" ]; then
    echo "Error: At least one distro must be selected" >&2
    echo "Use --interactive mode for guidance or set BUILD_DISTROS via CLI/config file" >&2
    exit 1
fi

# Validate the VMID base is numeric (proxmox.sh does arithmetic with it).
if ! [[ "$VMID_BASE" =~ ^[0-9]+$ ]]; then
    echo "Error: VMID base must be a positive number (got '$VMID_BASE')." >&2
    echo "Set it via PACT_VMID_BASE, the answerfile (VMID_BASE=), or interactive mode." >&2
    exit 1
fi

# Display configuration
if [ "$ON_PROXMOX" = true ] && [ "$PROXMOX_IS_REMOTE" = false ]; then
    echo "Note: detected a Proxmox host - executing locally (no SSH)."
fi
echo "Build Configuration:"
echo "  Proxmox Host: $PROXMOX_HOST"
echo "  Proxmox SSH User: $PROXMOX_SSH_USER"
echo "  Proxmox Is Remote: $PROXMOX_IS_REMOTE"
echo "  Storage Pool: $PROXMOX_STORAGE"
echo "  Base VMID: $VMID_BASE"
echo "  Selected Distros: $SELECTED_DISTROS"
echo "  Run Packer: $RUN_PACKER"
echo "  Rebuild Templates: $REBUILD_TEMPLATES"
if [ "$RUN_PACKER" = true ]; then
    [ -n "$CUSTOM_PACKERFILE" ]       && echo "  Custom Packer template: $CUSTOM_PACKERFILE"
    [ -n "$CUSTOM_ANSIBLE_PLAYBOOK" ] && echo "  Custom Ansible playbook: $CUSTOM_ANSIBLE_PLAYBOOK"
    [ -n "$CUSTOM_ANSIBLE_VARFILE" ]  && echo "  Custom Ansible varfile: $CUSTOM_ANSIBLE_VARFILE"
fi
echo "  Customize Cloud-Init: $CUSTOMIZE_CLOUDINIT"
if [ "$CUSTOMIZE_CLOUDINIT" = true ]; then
    # Never print the password or key material itself - only whether they're set.
    [ -n "$CLOUDINIT_USER" ]     && echo "    Cloud-Init user: $CLOUDINIT_USER"
    [ -n "$CLOUDINIT_PASSWORD" ] && echo "    Cloud-Init password: (set)"
    [ -n "$CLOUDINIT_SSH_KEYS" ] && echo "    Cloud-Init SSH key(s): (set)"
fi
echo ""

# --dry-run: show the resolved plan and exit before doing anything.
if [ "$DRY_RUN" = true ]; then
    echo "Planned templates (VMID base $VMID_BASE):"
    for distro_id in "${DISTRO_IDS[@]}"; do
        [[ " $SELECTED_DISTROS " == *" $distro_id "* ]] || continue
        offset="${DISTRO_OFFSET[$distro_id]}"
        if [ "$RUN_PACKER" = true ]; then
            echo "  ${DISTRO_NAME[$distro_id]}: base $((VMID_BASE + offset)) -> Packer $((VMID_BASE + 100 + offset))"
        else
            echo "  ${DISTRO_NAME[$distro_id]}: $((VMID_BASE + offset))"
        fi
    done
    if [ "$CUSTOMIZE_CLOUDINIT" = true ]; then
        echo ""
        echo "Cloud-Init customization: enabled (baked into each base template)"
    fi
    echo ""
    echo "Dry run - no changes made."
    exit 0
fi

#####################################################################################
###################FUNCTIONS
#####################################################################################

#####################################################################################
################### PROXMOX SSH/SCP HELPERS
#####################################################################################

# Run a command on the Proxmox host over SSH, using key or password auth automatically.
# Extra arguments form the remote command; with no arguments ssh runs the login shell
# reading commands from stdin (used for the build heredoc below).
pve_ssh() {
    if [ -n "$SSH_PRIVATE_KEY_PATH" ]; then
        ssh -i "$SSH_PRIVATE_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$PROXMOX_SSH_USER@$PROXMOX_HOST" "$@"
    else
        sshpass -p "$PROXMOX_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$PROXMOX_SSH_USER@$PROXMOX_HOST" "$@"
    fi
}

# Copy a local file to the Proxmox host over SCP (key or password auth).
pve_scp() {
    local src="$1" dest="$2"
    if [ -n "$SSH_PRIVATE_KEY_PATH" ]; then
        scp -i "$SSH_PRIVATE_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$src" "$PROXMOX_SSH_USER@$PROXMOX_HOST:$dest"
    else
        sshpass -p "$PROXMOX_SSH_PASSWORD" scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$src" "$PROXMOX_SSH_USER@$PROXMOX_HOST:$dest"
    fi
}

#####################################################################################
################### HELPER FUNCTION FOR URL/PATH RESOLUTION
#####################################################################################

# (URL-download temp files are cleaned by the top-level cleanup()/EXIT trap.)

# Resolve a file reference that can be either a URL or a local path.
# For a URL it downloads to a temp file (tracked in PACT_TMP_FILES for cleanup); for a
# local path it validates the file exists. On success it sets the global RESOLVED_FILE
# to the usable local path and returns 0; on failure it prints an error and returns 1.
# Call it directly (not via $(...)) so RESOLVED_FILE and PACT_TMP_FILES persist.
resolve_file_reference() {
    local ref="$1"
    local name="$2"  # For error messages

    if [[ "$ref" =~ ^https?:// ]]; then
        # It's a URL - download it to a temp file
        local safe_name="${name// /-}"
        local temp_file="/tmp/pact_${safe_name}_$$_${RANDOM}.tmp"
        echo "Downloading $name from URL: $ref" >&2

        if ! command -v curl &> /dev/null; then
            echo "Error: curl is required to download $name from a URL" >&2
            return 1
        fi
        if ! curl -fsSL -o "$temp_file" "$ref"; then
            echo "Error: Failed to download $name from $ref" >&2
            return 1
        fi

        PACT_TMP_FILES+=("$temp_file")
        RESOLVED_FILE="$temp_file"
    else
        # It's a local path - validate it exists
        if [ ! -f "$ref" ]; then
            echo "Error: $name not found at path: $ref" >&2
            return 1
        fi
        RESOLVED_FILE="$ref"
    fi
}

#Function to customize selected distros with Packer.
start_packer() {
    # Resolve the Packer template and Ansible files ONCE (downloading any URLs a single
    # time) and initialize Packer once, then reuse them for every selected distro instead
    # of re-downloading / re-initializing per VM.
    local packerfile="${CUSTOM_PACKERFILE:-$REPO_DIR/Packer/Templates/universal.pkr.hcl}"
    local ansiblefile="${CUSTOM_ANSIBLE_PLAYBOOK:-$REPO_DIR/Ansible/Playbooks/image_customizations.yml}"
    local ansiblevarfile="${CUSTOM_ANSIBLE_VARFILE:-$REPO_DIR/Ansible/Variables/vars.yml}"

    resolve_file_reference "$packerfile" "Packer template" || return 1
    packerfile="$RESOLVED_FILE"
    resolve_file_reference "$ansiblefile" "Ansible playbook" || return 1
    ansiblefile="$RESOLVED_FILE"
    resolve_file_reference "$ansiblevarfile" "Ansible variables file" || return 1
    ansiblevarfile="$RESOLVED_FILE"

    if ! packer init "$packerfile"; then
        echo "Error: Packer init failed" >&2
        return 1
    fi

    # Iterate through selected distros, reusing the resolved files.
    for distro_id in "${DISTRO_IDS[@]}"; do
        # Check if this distro was selected
        if [[ " $SELECTED_DISTROS " != *" $distro_id "* ]]; then
            continue
        fi

        local offset="${DISTRO_OFFSET[$distro_id]}"
        local vmid=$((VMID_BASE + 100 + offset))
        packer_build "$distro_id" "$vmid" "${DISTRO_NAME[$distro_id]}" \
            "$packerfile" "$ansiblefile" "$ansiblevarfile" || return 1
    done
}

#Function that runs a single Packer build with the already-resolved files.
packer_build() {
    local distro_id="$1"
    local vmid="$2"
    local distro_name="$3"
    local packerfile="$4"
    local ansiblefile="$5"
    local ansiblevarfile="$6"

    if ! packer build \
        -var "proxmox_target_node=$PROXMOX_TARGET_NODE" \
        -var "proxmox_api_url=https://${PROXMOX_HOST}:8006/api2/json" \
        -var "proxmox_api_token_id=$PACKER_TOKEN_ID" \
        -var "proxmox_api_token_secret=$PACKER_TOKEN_SECRET" \
        -var "vmid=$vmid" \
        -var "proxmox_storage=$PROXMOX_STORAGE" \
        -var "distro=$distro_id" \
        -var "ansible_playbook=$ansiblefile" \
        -var "ansible_varfile=$ansiblevarfile" \
        "$packerfile"; then
        echo "Error: Packer build failed for $distro_name" >&2
        return 1
    fi
}

# Detect the distribution of the runner
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS=$ID
else
    echo "Unsupported distribution"
    exit 1
fi

#####################################################################################
###################REQUIREMENTS
#####################################################################################

# Install the given packages that aren't already on PATH (command name == package name
# for everything we need here, which avoids dpkg/rpm substring false positives).
install_pkgs() {
    local want=("$@") missing=() pkg
    for pkg in "${want[@]}"; do
        command -v "$pkg" &>/dev/null || missing+=("$pkg")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0
    echo "Installing on $(hostname): ${missing[*]}"
    case "$OS" in
        ubuntu|debian) sudo apt-get update >/dev/null 2>&1; sudo apt-get install -y "${missing[@]}" ;;
        centos|rocky|almalinux|fedora|rhel) sudo dnf install -y "${missing[@]}" ;;
        opensuse|sles) sudo zypper install -y "${missing[@]}" ;;
        *) echo "Error: unsupported distribution '$OS'; install manually: ${missing[*]}" >&2; return 1 ;;
    esac || { echo "Error: failed to install: ${missing[*]}" >&2; return 1; }
}

# Report a key created by generate_ssh_key, and do the deferred .ppk conversion (deferred
# so install_pkgs is available for putty-tools). Called at the very end of the run so the
# paths are the last thing on screen instead of being buried under the build output.
report_generated_key() {
    [ -z "$GENERATED_KEY_PATH" ] && return 0

    if [ "$WANT_PPK" = true ]; then
        if ! command -v puttygen &>/dev/null; then
            echo "Installing putty-tools for the .ppk conversion ..."
            install_pkgs putty-tools >/dev/null 2>&1 || true
        fi
        if command -v puttygen &>/dev/null; then
            if puttygen "$GENERATED_KEY_PATH" -O private -o "$GENERATED_KEY_PATH.ppk" 2>/dev/null; then
                chmod 600 "$GENERATED_KEY_PATH.ppk"
                GENERATED_PPK_PATH="$GENERATED_KEY_PATH.ppk"
            else
                echo "Warning: puttygen could not convert the key; skipping the .ppk file." >&2
            fi
        else
            echo "Warning: puttygen unavailable (install putty-tools); skipping the .ppk file." >&2
        fi
    fi

    echo ""
    echo "=== SSH key for Cloud-Init ==="
    echo "  Private key : $GENERATED_KEY_PATH"
    echo "  Public key  : $GENERATED_KEY_PATH.pub"
    [ -n "$GENERATED_PPK_PATH" ] && echo "  PuTTY key   : $GENERATED_PPK_PATH"
    # Kept in a variable rather than inline: a ${VAR:-default} containing an apostrophe
    # inside a double-quoted string is a bash quoting trap.
    local login_user="$CLOUDINIT_USER"
    [ -z "$login_user" ] && login_user="<image default user>"

    echo ""
    echo "  The public key is baked into the templates. Once a VM cloned from one has an IP:"
    echo "    ssh -i $GENERATED_KEY_PATH $login_user@<vm-ip>"
    echo ""
    echo "  Keep the private key safe - anything cloned from these templates trusts it."

    if [ "$PRINT_PRIVATE_KEY" = true ]; then
        echo ""
        echo "  Private key follows. It stays in this terminal scrollback:"
        echo ""
        cat "$GENERATED_KEY_PATH"
    fi
}

# Warn (and, on a TTY, confirm) before installing tooling on what looks like a Proxmox host.
warn_local_install() {
    [ "$ON_PROXMOX" != true ] && return 0
    echo "Warning: this appears to be your Proxmox host. Installing $* here is NOT recommended;" >&2
    echo "         prefer running build.sh from a separate management machine." >&2
    if [ -t 0 ]; then
        read -p "Continue installing on the Proxmox host anyway? (y/N): " -r _ok
        [[ "$_ok" =~ ^[Yy]$ ]] || { echo "Aborted." >&2; exit 1; }
    fi
}

# For remote password auth we need sshpass just to reach the host. Install that first (it's
# tiny) so the connectivity preflight below runs before the heavier toolchain / downloads.
if [ "$PROXMOX_IS_REMOTE" = true ] && [ -z "$SSH_PRIVATE_KEY_PATH" ] && ! command -v sshpass &>/dev/null; then
    warn_local_install "sshpass"
    install_pkgs sshpass || exit 1
    command -v sshpass &>/dev/null || { echo "Error: sshpass is required for password auth but is not installed." >&2; exit 1; }
fi

# Preflight: confirm we can reach Proxmox and that 'qm' exists BEFORE installing the build
# toolchain or downloading any images, so a bad host/credentials/target fails in seconds.
if [ "$PROXMOX_IS_REMOTE" = true ]; then
    echo "Checking connectivity to $PROXMOX_SSH_USER@$PROXMOX_HOST ..."
    if ! pve_ssh 'command -v qm >/dev/null 2>&1'; then
        echo "Error: cannot reach $PROXMOX_SSH_USER@$PROXMOX_HOST over SSH, or 'qm' is not available there." >&2
        echo "Check the hostname/credentials and that the target is a Proxmox host." >&2
        exit 1
    fi
    echo "Connected to Proxmox ('qm' found)."
    if pve_ssh "command -v pvesm >/dev/null 2>&1 && ! pvesm status --storage $PROXMOX_STORAGE >/dev/null 2>&1"; then
        echo "Warning: storage pool '$PROXMOX_STORAGE' was not found on the Proxmox host; the build may fail." >&2
    fi
else
    if ! command -v qm &>/dev/null; then
        echo "Error: running locally but 'qm' was not found - is this a Proxmox host?" >&2
        echo "Use the SSH options (e.g. --proxmox-host=...) to target a remote Proxmox instead." >&2
        exit 1
    fi
    if command -v pvesm >/dev/null 2>&1 && ! pvesm status --storage "$PROXMOX_STORAGE" >/dev/null 2>&1; then
        echo "Warning: storage pool '$PROXMOX_STORAGE' was not found; the build may fail." >&2
    fi
fi

# Install the (heavier) Packer/Ansible toolchain now that connectivity is confirmed.
if [ "$RUN_PACKER" = true ]; then
    warn_local_install "Packer and Ansible"
    install_pkgs unzip git curl ansible || exit 1
fi

# Install Packer only if --run-packer option is enabled (regardless of local or remote)
if [ "$RUN_PACKER" = true ]; then
    # Keep this in sync with .github/workflows/ci.yml (the setup-packer version) so the
    # template is built with the same Packer that CI validates it against.
    PACKER_VERSION="1.16.0"
    if ! command -v packer &> /dev/null; then
        echo "Packer is not installed. Installing Packer ${PACKER_VERSION}..."
        packer_zip="packer_${PACKER_VERSION}_linux_amd64.zip"
        # Download and unpack in a temp dir so the archive's other files (LICENSE.txt, etc.)
        # never land in the working directory/repo; only the packer binary is installed.
        _pkdir="$(mktemp -d)"
        if ! curl -fSL -o "$_pkdir/$packer_zip" "https://releases.hashicorp.com/packer/${PACKER_VERSION}/${packer_zip}"; then
            echo "Error: Failed to download Packer ${PACKER_VERSION}" >&2
            rm -rf "$_pkdir"
            exit 1
        fi
        unzip -o -q "$_pkdir/$packer_zip" -d "$_pkdir"
        sudo mv "$_pkdir/packer" /usr/local/bin/
        rm -rf "$_pkdir"
        echo "Packer ${PACKER_VERSION} installed successfully."
    else
        echo "Packer is already installed."
    fi
fi

#####################################################################################
################### MAIN
#####################################################################################

# Base64-encode the Cloud-Init password/SSH keys once (empty strings encode to empty, so
# this is safe to compute unconditionally). Handed to proxmox.sh via env vars rather than
# CLI args so arbitrary content (spaces, newlines, quotes) survives the SSH command line
# intact and isn't exposed as plaintext in `ps` output on the Proxmox host.
CI_USER_B64="" CI_PASSWORD_B64="" CI_SSHKEYS_B64=""
if [ "$CUSTOMIZE_CLOUDINIT" = true ]; then
    CI_USER_B64="$(printf '%s' "$CLOUDINIT_USER" | base64 | tr -d '\n')"
    CI_PASSWORD_B64="$(printf '%s' "$CLOUDINIT_PASSWORD" | base64 | tr -d '\n')"
    CI_SSHKEYS_B64="$(printf '%s' "$CLOUDINIT_SSH_KEYS" | base64 | tr -d '\n')"
fi

# Arguments for proxmox.sh. Built once here rather than per-branch: remote and local mode
# pass an identical argument list (they differ only in how the script is delivered and
# invoked), so keeping a single copy means a new flag can't be added to one path and
# silently forgotten on the other.
PROXMOX_SCRIPT_ARGS=("--vmid-base=$VMID_BASE" "--proxmox-storage=$PROXMOX_STORAGE")

# Add rebuild flag if enabled
if [ "$REBUILD_TEMPLATES" = true ]; then
    PROXMOX_SCRIPT_ARGS+=("--rebuild-templates")
fi

# Add run-packer flag if Packer will be run
if [ "$RUN_PACKER" = true ]; then
    PROXMOX_SCRIPT_ARGS+=("--run-packer")
fi

# Add customize-cloudinit flag if enabled (values travel via the PACT_CI_*_B64 env vars)
if [ "$CUSTOMIZE_CLOUDINIT" = true ]; then
    PROXMOX_SCRIPT_ARGS+=("--customize-cloudinit")
fi

# Add build list to arguments
if [ -n "$BUILD_DISTROS" ]; then
    PROXMOX_SCRIPT_ARGS+=("--build=$BUILD_DISTROS")
fi

# Run proxmox.sh to create templates (SSH to remote or run locally)
if [ "$PROXMOX_IS_REMOTE" = true ]; then
    # Verify the private key file exists when key auth is requested.
    if [ -n "$SSH_PRIVATE_KEY_PATH" ]; then
        if [ ! -f "$SSH_PRIVATE_KEY_PATH" ]; then
            echo "Private key file not found: $SSH_PRIVATE_KEY_PATH" >&2
            exit 1
        fi
        echo "Starting build using public key authentication"
    else
        echo "Starting build using password authentication"
    fi

    # Put proxmox.sh into a unique working directory on the host and run it there. From a
    # clone we scp our (possibly locally edited) copy; when bootstrapped we have the host
    # curl it straight from PACT_BASE_URL (it already needs outbound HTTPS for the images).
    pve_ssh mkdir -p "./$WORK_DIR_NAME"
    if [ "$RUNNING_FROM_CLONE" = true ]; then
        pve_scp "$SCRIPT_DIR/proxmox.sh" "./$WORK_DIR_NAME"
        remote_fetch=":"
    else
        remote_fetch="curl -fsSL $PACT_BASE_URL/Scripts/proxmox.sh -o ./$WORK_DIR_NAME/proxmox.sh"
    fi
    # shellcheck disable=SC2087  # heredoc is expanded locally on purpose to inject the fetch + build args
    pve_ssh << EOF
        $remote_fetch
        chmod +x ./$WORK_DIR_NAME/proxmox.sh
        PACT_CI_USER_B64='$CI_USER_B64' PACT_CI_PASSWORD_B64='$CI_PASSWORD_B64' PACT_CI_SSHKEYS_B64='$CI_SSHKEYS_B64' ./$WORK_DIR_NAME/proxmox.sh ${PROXMOX_SCRIPT_ARGS[*]}
        proxmox_rc=\$?
        rm -rf ./$WORK_DIR_NAME
        exit \$proxmox_rc
EOF
    proxmox_exit=$?
    if [ "$proxmox_exit" -ne 0 ]; then
        echo "Error: template creation on the Proxmox host failed (exit $proxmox_exit). Aborting." >&2
        exit 1
    fi
else
    # Run proxmox.sh locally
    echo "Running proxmox.sh locally..."

    # Create unique local working directory and run
    mkdir -p "./$WORK_DIR_NAME"
    cp "$SCRIPT_DIR/proxmox.sh" "./$WORK_DIR_NAME/"
    chmod +x "./$WORK_DIR_NAME/proxmox.sh"

    PACT_CI_USER_B64="$CI_USER_B64" PACT_CI_PASSWORD_B64="$CI_PASSWORD_B64" PACT_CI_SSHKEYS_B64="$CI_SSHKEYS_B64" \
        "./$WORK_DIR_NAME/proxmox.sh" "${PROXMOX_SCRIPT_ARGS[@]}"
    proxmox_exit=$?

    # Cleanup working directory
    rm -rf "./$WORK_DIR_NAME"

    if [ "$proxmox_exit" -ne 0 ]; then
        echo "Error: template creation failed (exit $proxmox_exit). Aborting." >&2
        exit 1
    fi
fi

# Run Packer if enabled
if [ "$RUN_PACKER" = true ]; then
    echo "Running Packer builds..."
    if ! start_packer; then
        echo "Error: Packer build failed" >&2
        exit 1
    fi
else
    echo "Packer builds skipped"
fi

# Cleanup intermediate build VMs if Packer was run
if [ "$RUN_PACKER" = true ]; then
    echo "Cleaning up intermediate build VMs..."

    # The intermediate build VMs are at the base VMID offsets from the distro metadata
    # After Packer creates customized versions at offset+100, we no longer need these
    for distro_id in "${DISTRO_IDS[@]}"; do
        # Check if this distro was selected
        if [[ " $SELECTED_DISTROS " != *" $distro_id "* ]]; then
            continue
        fi

        offset="${DISTRO_OFFSET[$distro_id]}"
        vmid=$((VMID_BASE + offset))
        echo "  Destroying intermediate VMID $vmid..."

        # If remote, execute qm destroy on the remote host
        if [ "$PROXMOX_IS_REMOTE" = true ]; then
            pve_ssh qm destroy "$vmid" 2>/dev/null || true
        else
            qm destroy "$vmid" 2>/dev/null || true
        fi
    done
fi

echo ""
echo "=== Build Complete ==="
echo "Template build process finished successfully!"

report_generated_key
