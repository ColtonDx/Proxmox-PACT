#!/bin/bash

################################################################################
# Proxmox-P.A.C.T. Build Script
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
#
################################################################################

#####################################################################################
################### WORKING DIRECTORY SETUP
#####################################################################################

# Generate a unique working directory name to avoid conflicts
WORK_DIR_NAME="pact_build_$(date +%s)_${RANDOM}"

# Directory containing this script (used to read distro metadata from proxmox.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#####################################################################################
################### CLI OPTION PARSING
#####################################################################################

# Default flags and values (lowest precedence: the answerfile, then PACT_* env vars,
# then CLI arguments each override these in turn)
RUN_PACKER=false
REBUILD_TEMPLATES=false
INTERACTIVE_MODE=false
SSH_PRIVATE_KEY_PATH=""
PROXMOX_IS_REMOTE=true
CUSTOM_PACKERFILE=""
CUSTOM_ANSIBLE_PLAYBOOK=""
CUSTOM_ANSIBLE_VARFILE=""
BUILD_DISTROS=""
PACKER_TOKEN_ID=""
PACKER_TOKEN_SECRET=""
ANSWERFILE_PATH=""

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

CONFIG_FILE_EXPANDED="${ANSWERFILE_PATH:-.env.local}"
# Expand a leading tilde in the path
CONFIG_FILE_EXPANDED="${CONFIG_FILE_EXPANDED/#\~/$HOME}"
if [ -f "$CONFIG_FILE_EXPANDED" ]; then
    echo "Loading configuration from $CONFIG_FILE_EXPANDED..."
    # shellcheck source=/dev/null
    source "$CONFIG_FILE_EXPANDED"
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
# group prefix (e.g. "debian" -> debian11/12/13). Prints the de-duped id list and
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
  --build-distros=LIST       Comma-separated list of distros to build (e.g., debian12,ubuntu2404).
  --answerfile-path=PATH     Path to custom answerfile (.env.local used by default if exists).
  --custom-packerfile=PATH   Path or URL to custom Packer template file instead of default.
  --custom-ansible-playbook=PATH  Path or URL to custom Ansible playbook for Packer customization.
  --custom-ansible-varfile=PATH  Path or URL to custom variables file for Ansible playbook (default: ./Ansible/Variables/vars.yml).
  --packer-token-id=TOKEN    Proxmox API Token ID for Packer (required with --run-packer).
  --packer-token-secret=SEC  Proxmox API Token Secret for Packer (required with --run-packer).
  --help                     Show this help and exit

Notes:
  - If --interactive is set, no other arguments are allowed (it overrides everything).
  - Without --local, defaults to SSH mode (remote Proxmox).
  - Without --rebuild-templates, existing VMs at target VMIDs are preserved (safer).
  - --build-distros accepts: all, debian, ubuntu, fedora, individual names (debian11, debian12, ubuntu2204, fedora43, etc.)
  - --custom-packerfile allows using a custom Packer template with --run-packer.
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

# Set defaults for unset variables (CLI arguments take precedence)
: "${PROXMOX_SSH_USER:=root}"
: "${PROXMOX_HOST:=pve.local}"
: "${PROXMOX_TARGET_NODE:=pve}"
: "${PROXMOX_STORAGE:=local-lvm}"
: "${VMID_BASE:=800}"

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

    # Q2: Ask about Packer customization
    echo ""
    read -p "Do you want to customize the templates with Packer? (Y/N) [Default: No]: " -r choice_packer
    if [[ "$choice_packer" =~ ^[Yy]$ ]]; then
        RUN_PACKER=true
    fi

    # Q3: Ask for Base VMID
    echo ""
    read -p "Base VMID (press Enter for default 800): " -r vmid_input
    if [ -n "$vmid_input" ]; then
        VMID_BASE="$vmid_input"
    fi

    # Q4: Ask if Proxmox is remote
    echo ""
    read -p "Is the Proxmox server remote? (Y/N) [Default: Yes]: " -r choice_remote
    if [[ "$choice_remote" =~ ^[Nn]$ ]]; then
        PROXMOX_IS_REMOTE=false
    else
        PROXMOX_IS_REMOTE=true
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
    fi

    echo ""
fi

# Parse BUILD_DISTROS into SELECTED_DISTROS (set via --build-distros=, answerfile, env,
# or interactive mode). expand_selected handles all/groups/ids and reports bad input.
if [ -n "$BUILD_DISTROS" ]; then
    if ! SELECTED_DISTROS="$(expand_selected "$BUILD_DISTROS")"; then
        exit 1
    fi
fi

# Validate required variables for Packer
if [ "$RUN_PACKER" = true ]; then
    if [ -z "$PACKER_TOKEN_ID" ] || [ -z "$PACKER_TOKEN_SECRET" ]; then
        echo "Error: PACKER_TOKEN_ID and PACKER_TOKEN_SECRET are required when using --run-packer" >&2
        exit 1
    fi
fi

# Validate that at least one distro is selected
if [ -z "$SELECTED_DISTROS" ]; then
    echo "Error: At least one distro must be selected" >&2
    echo "Use --interactive mode for guidance or set BUILD_DISTROS via CLI/config file" >&2
    exit 1
fi

# Display configuration
echo "Build Configuration:"
echo "  Proxmox Host: $PROXMOX_HOST"
echo "  Proxmox SSH User: $PROXMOX_SSH_USER"
echo "  Proxmox Is Remote: $PROXMOX_IS_REMOTE"
echo "  Storage Pool: $PROXMOX_STORAGE"
echo "  Base VMID: $VMID_BASE"
echo "  Selected Distros: $SELECTED_DISTROS"
echo "  Run Packer: $RUN_PACKER"
echo "  Rebuild Templates: $REBUILD_TEMPLATES"
echo ""

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
        ssh -i "$SSH_PRIVATE_KEY_PATH" -o StrictHostKeyChecking=no "$PROXMOX_SSH_USER@$PROXMOX_HOST" "$@"
    else
        sshpass -p "$PROXMOX_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no "$PROXMOX_SSH_USER@$PROXMOX_HOST" "$@"
    fi
}

# Copy a local file to the Proxmox host over SCP (key or password auth).
pve_scp() {
    local src="$1" dest="$2"
    if [ -n "$SSH_PRIVATE_KEY_PATH" ]; then
        scp -i "$SSH_PRIVATE_KEY_PATH" -o StrictHostKeyChecking=no "$src" "$PROXMOX_SSH_USER@$PROXMOX_HOST:$dest"
    else
        sshpass -p "$PROXMOX_SSH_PASSWORD" scp -o StrictHostKeyChecking=no "$src" "$PROXMOX_SSH_USER@$PROXMOX_HOST:$dest"
    fi
}

#####################################################################################
################### HELPER FUNCTION FOR URL/PATH RESOLUTION
#####################################################################################

# Temp files created when custom Packer/Ansible files are passed as URLs. They are
# cleaned up by a single EXIT trap (see below); resolve_file_reference must NOT set its
# own trap, because it is called in the current shell and an in-function trap set inside
# a command substitution would fire — and delete the download — the moment it returned.
PACT_TMP_FILES=()
cleanup_tmp_files() {
    [ "${#PACT_TMP_FILES[@]}" -gt 0 ] && rm -f "${PACT_TMP_FILES[@]}"
}
trap cleanup_tmp_files EXIT

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

        if command -v curl &> /dev/null; then
            curl -fsSL -o "$temp_file" "$ref" || { echo "Error: Failed to download $name from $ref" >&2; return 1; }
        elif command -v wget &> /dev/null; then
            wget -q -O "$temp_file" "$ref" || { echo "Error: Failed to download $name from $ref" >&2; return 1; }
        else
            echo "Error: Neither curl nor wget found to download $name from URL" >&2
            return 1
        fi

        # A 200 response can still be an HTML login/error page (e.g. a private repo or a
        # web-view Git URL) rather than the file itself. curl -f only rejects HTTP error
        # codes, so catch HTML here and fail with a clear message instead of handing a
        # bogus playbook/varfile to Packer and Ansible.
        if head -c 512 "$temp_file" | grep -qiE '<!doctype html|<html[ >]'; then
            echo "Error: $ref returned an HTML page, not a file, for $name." >&2
            echo "       Use the RAW file URL (GitLab: .../-/raw/<branch>/<path>; GitHub:" >&2
            echo "       raw.githubusercontent.com/...) and make sure the repo is public or the" >&2
            echo "       URL carries an access token." >&2
            rm -f "$temp_file"
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
    # Iterate through selected distros
    for distro_id in "${DISTRO_IDS[@]}"; do
        # Check if this distro was selected
        if [[ " $SELECTED_DISTROS " != *" $distro_id "* ]]; then
            continue
        fi

        local offset="${DISTRO_OFFSET[$distro_id]}"
        local vmid=$((VMID_BASE + 100 + offset))
        packer_build "$distro_id" "$vmid" "${DISTRO_NAME[$distro_id]}"
    done
}

#Function that runs Packer Build with Environment variable parameters
packer_build() {
    local distro_id="$1"
    local vmid="$2"
    local distro_name="$3"
    local packerfile="${CUSTOM_PACKERFILE:-./Packer/Templates/universal.pkr.hcl}"
    local ansiblefile="${CUSTOM_ANSIBLE_PLAYBOOK:-./Ansible/Playbooks/image_customizations.yml}"
    local ansiblevarfile="${CUSTOM_ANSIBLE_VARFILE:-./Ansible/Variables/vars.yml}"

    # Resolve packerfile / ansible files (handle URLs and paths). Each call sets the
    # global RESOLVED_FILE on success.
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

# Determine which host packages we actually need, based on what this run will do:
#   - sshpass: only for remote password authentication (not key auth, not local mode)
#   - wget/unzip/git/curl/ansible: whenever Packer runs, local or remote
PACKAGES=""
if [ "$PROXMOX_IS_REMOTE" = true ] && [ -z "$SSH_PRIVATE_KEY_PATH" ]; then
    PACKAGES="sshpass"
fi
if [ "$RUN_PACKER" = true ]; then
    PACKAGES="$PACKAGES wget unzip git curl ansible"
fi

if [ -n "$PACKAGES" ]; then

    # A tool is "missing" if its command isn't on PATH. Every package we need here has
    # a same-named command, so this avoids substring false positives (e.g. dpkg -l | grep
    # curl matching libcurl4) and needs no per-distro detection logic.
    PACKAGES_TO_INSTALL=()
    for pkg in $PACKAGES; do
        if ! command -v "$pkg" &> /dev/null; then
            PACKAGES_TO_INSTALL+=("$pkg")
        fi
    done

    # Only install if there are packages to install
    if [ "${#PACKAGES_TO_INSTALL[@]}" -gt 0 ]; then
        echo "Installing required packages: ${PACKAGES_TO_INSTALL[*]}"
        case "$OS" in
            ubuntu|debian)
                sudo apt-get update > /dev/null 2>&1
                if ! sudo apt-get install -y "${PACKAGES_TO_INSTALL[@]}"; then
                    echo "Error: Failed to install packages. Please install manually: ${PACKAGES_TO_INSTALL[*]}" >&2
                    exit 1
                fi
                ;;
            centos|rocky|almalinux|fedora|rhel)
                if ! sudo dnf install -y "${PACKAGES_TO_INSTALL[@]}"; then
                    echo "Error: Failed to install packages. Please install manually: ${PACKAGES_TO_INSTALL[*]}" >&2
                    exit 1
                fi
                ;;
            opensuse|sles)
                if ! sudo zypper install -y "${PACKAGES_TO_INSTALL[@]}"; then
                    echo "Error: Failed to install packages. Please install manually: ${PACKAGES_TO_INSTALL[*]}" >&2
                    exit 1
                fi
                ;;
            *)
                echo "Unsupported distribution: $OS"
                exit 1
                ;;
        esac
    else
        echo "All required packages are already installed."
    fi
fi

# Verify sshpass is available for remote password authentication (not needed with a key).
if [ "$PROXMOX_IS_REMOTE" = true ] && [ -z "$SSH_PRIVATE_KEY_PATH" ]; then
    if ! command -v sshpass &> /dev/null; then
        echo "Error: sshpass is required for SSH password authentication but is not installed" >&2
        exit 1
    fi
fi

# Install Packer only if --run-packer option is enabled (regardless of local or remote)
if [ "$RUN_PACKER" = true ]; then
    # Keep this in sync with .github/workflows/ci.yml (the setup-packer version) so the
    # template is built with the same Packer that CI validates it against.
    PACKER_VERSION="1.11.2"
    if ! command -v packer &> /dev/null; then
        echo "Packer is not installed. Installing Packer ${PACKER_VERSION}..."
        packer_zip="packer_${PACKER_VERSION}_linux_amd64.zip"
        if ! wget -q "https://releases.hashicorp.com/packer/${PACKER_VERSION}/${packer_zip}"; then
            echo "Error: Failed to download Packer ${PACKER_VERSION}" >&2
            exit 1
        fi
        unzip -o -q "$packer_zip"
        sudo mv packer /usr/local/bin/
        rm -f "$packer_zip"
        echo "Packer ${PACKER_VERSION} installed successfully."
    else
        echo "Packer is already installed."
    fi
fi

#####################################################################################
################### MAIN
#####################################################################################

# Run proxmox.sh to create templates (SSH to remote or run locally)
if [ "$PROXMOX_IS_REMOTE" = true ]; then
    # Build proxmox.sh arguments based on configuration
    PROXMOX_SCRIPT_ARGS=("--vmid-base=$VMID_BASE" "--proxmox-storage=$PROXMOX_STORAGE")

    # Add rebuild flag if enabled
    if [ "$REBUILD_TEMPLATES" = true ]; then
        PROXMOX_SCRIPT_ARGS+=("--rebuild-templates")
    fi

    # Add run-packer flag if Packer will be run
    if [ "$RUN_PACKER" = true ]; then
        PROXMOX_SCRIPT_ARGS+=("--run-packer")
    fi

    # Add build list to arguments
    if [ -n "$BUILD_DISTROS" ]; then
        PROXMOX_SCRIPT_ARGS+=("--build=$BUILD_DISTROS")
    fi

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

    # Copy proxmox.sh into a unique working directory on the host and run it there.
    pve_ssh mkdir -p "./$WORK_DIR_NAME"
    pve_scp ./Scripts/proxmox.sh "./$WORK_DIR_NAME"
    # shellcheck disable=SC2087  # heredoc is expanded locally on purpose to inject the build args
    pve_ssh << EOF
        chmod +x ./$WORK_DIR_NAME/proxmox.sh
        ./$WORK_DIR_NAME/proxmox.sh ${PROXMOX_SCRIPT_ARGS[*]}
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

    # Build proxmox.sh arguments
    PROXMOX_SCRIPT_ARGS=("--vmid-base=$VMID_BASE" "--proxmox-storage=$PROXMOX_STORAGE")

    if [ "$REBUILD_TEMPLATES" = true ]; then
        PROXMOX_SCRIPT_ARGS+=("--rebuild-templates")
    fi

    if [ "$RUN_PACKER" = true ]; then
        PROXMOX_SCRIPT_ARGS+=("--run-packer")
    fi

    # Add build list to arguments
    if [ -n "$BUILD_DISTROS" ]; then
        PROXMOX_SCRIPT_ARGS+=("--build=$BUILD_DISTROS")
    fi

    # Create unique local working directory and run
    mkdir -p "./$WORK_DIR_NAME"
    cp ./Scripts/proxmox.sh "./$WORK_DIR_NAME/"
    chmod +x "./$WORK_DIR_NAME/proxmox.sh"

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
