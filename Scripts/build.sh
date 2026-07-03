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
#  * Installs Packer only if --packer is specified
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
#   VMID_BASE                      Base VMID for templates (overridden by CLI args)
#   BUILD_DISTROS                   Distros to build, comma-separated (overridden by CLI args)
#   PROXMOX_IS_REMOTE              Use SSH to Proxmox (true/false, default: true)
#   RUN_PACKER                     Enable Packer customization (true/false, default: false)
#   REBUILD_TEMPLATES                     Delete existing VMs before building (true/false, default: false)
#   PACKER_TOKEN_ID                Proxmox API Token ID (required if RUN_PACKER=true)
#   PACKER_TOKEN_SECRET            Proxmox API Token Secret (required if RUN_PACKER=true)
#   PROXMOX_TARGET_NODE             Proxmox target node for Packer (default: pve)
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

# Define distro metadata: id|name|vmid_offset
# Maps distro names to their identifiers for easy grouping
declare -a DISTRO_METADATA=(
    "debian11|Debian-11|1"
    "debian12|Debian-12|2"
    "debian13|Debian-13|3"
    "ubuntu2204|Ubuntu-22.04|11"
    "ubuntu2404|Ubuntu-24.04|12"
    "ubuntu2604|Ubuntu-26.04|14"
    "fedora42|Fedora-42|22"
    "fedora43|Fedora-43|23"
)

# Map of distro groups to their individual IDs
declare -A DISTRO_GROUPS=(
    [debian]="debian11 debian12 debian13"
    [ubuntu]="ubuntu2204 ubuntu2404 ubuntu2604"
    [fedora]="fedora42 fedora43"
    [all]="debian11 debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604 fedora42 fedora43"
)

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
  --proxmox-user=USERNAME    SSH username for Proxmox (default: root).
  --proxmox-password=PASS    SSH password for Proxmox authentication.
  --proxmox-key=PATH         Path to SSH private key for authentication.
  --proxmox-storage=POOL     Proxmox storage pool name (default: local-lvm).
  --proxmox-target-node=NODE Proxmox target node for Packer (default: pve).
  --local                    Run directly on Proxmox host (no SSH needed).
  --build-distros=LIST       Comma-separated list of distros to build (e.g., debian12,ubuntu2404).
  --answerfile-path=PATH          Path to custom answerfile (.env.local used by default if exists).
  --custom-packerfile=PATH   Path or URL to custom Packer template file instead of default.
  --custom-ansible=PATH      Path or URL to custom Ansible playbook for Packer customization.
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
    echo "  Available: all, debian, ubuntu, fedora, debian11, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604, fedora42, fedora43"
    
    # Keep asking until valid input is provided
    BUILD_VALID=false
    while [ "$BUILD_VALID" = false ]; do
        read -p "Enter comma-separated list (or 'all' for all distros) [Default: all]: " -r build_input
        if [ -z "$build_input" ]; then
            BUILD_DISTROS="all"
        else
            BUILD_DISTROS="$build_input"
        fi
        
        # Parse the input
        SELECTED_DISTROS=""
        if [ "$BUILD_DISTROS" = "all" ]; then
            SELECTED_DISTROS="${DISTRO_GROUPS[all]}"
            BUILD_VALID=true
        else
            # Parse comma-separated list
            items="$(echo "$BUILD_DISTROS" | tr ',' ' ')"
            INVALID_ITEMS=""
            for it in $items; do
                if [ -n "${DISTRO_GROUPS[$it]}" ]; then
                    # It's a group
                    SELECTED_DISTROS="${SELECTED_DISTROS} ${DISTRO_GROUPS[$it]}"
                elif [[ " debian11 debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604 fedora42 fedora43 " == *" $it "* ]]; then
                    # Valid individual distro
                    SELECTED_DISTROS="${SELECTED_DISTROS} $it"
                else
                    INVALID_ITEMS="$INVALID_ITEMS $it"
                fi
            done
            
            if [ -n "$INVALID_ITEMS" ]; then
                echo "Error: Unknown distro(s):$INVALID_ITEMS"
                echo "Valid options: all, debian, ubuntu, fedora, debian11, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604, fedora42, fedora43"
            else
                # Remove duplicates
                SELECTED_DISTROS="$(echo "$SELECTED_DISTROS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)"
                BUILD_VALID=true
            fi
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
        USE_ANSIBLE=false
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
    
    for distro_entry in "${DISTRO_METADATA[@]}"; do
        IFS='|' read -r distro_id distro_name offset <<< "$distro_entry"
        if [[ " $SELECTED_DISTROS " == *" $distro_id "* ]]; then
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

# Parse BUILD_DISTROS and populate SELECTED_DISTROS
# BUILD_DISTROS can be set via: --build-distros=, config file, or interactive mode
if [ -n "$BUILD_DISTROS" ]; then
    if [ "$BUILD_DISTROS" = "all" ]; then
        SELECTED_DISTROS="${DISTRO_GROUPS[all]}"
    else
        # Parse comma or space separated list
        items="$(echo "$BUILD_DISTROS" | tr ',' ' ')"
        for item in $items; do
            if [ -n "${DISTRO_GROUPS[$item]}" ]; then
                # It's a group (debian, ubuntu, fedora, etc.)
                SELECTED_DISTROS="${SELECTED_DISTROS} ${DISTRO_GROUPS[$item]}"
            elif [[ " debian11 debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604 fedora42 fedora43 " == *" $item "* ]]; then
                # It's a valid individual distro
                SELECTED_DISTROS="${SELECTED_DISTROS} $item"
                else
                    echo "Error: Unknown template '$item'" >&2
                    echo "Valid options: all, debian, ubuntu, fedora, debian11, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604, fedora42, fedora43" >&2
                exit 1
            fi
        done
        # Remove duplicates and normalize spacing
        SELECTED_DISTROS="$(echo "$SELECTED_DISTROS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)"
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
    for distro_entry in "${DISTRO_METADATA[@]}"; do
        IFS='|' read -r distro_id distro_name offset <<< "$distro_entry"
        
        # Check if this distro was selected
        if [[ " $SELECTED_DISTROS " != *" $distro_id "* ]]; then
            continue
        fi
        
        local vmid=$((VMID_BASE + 100 + offset))
        packer_build "$distro_id" "$vmid" "$distro_name"
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

# Build package list based on selected options
# Skip packages if Proxmox is local (only install Packer if needed)
if [ "$PROXMOX_IS_REMOTE" = true ]; then
    PACKAGES="sshpass"

    # Add wget, unzip, git, curl, ansible only if running Packer
    if [ "$RUN_PACKER" = true ]; then
        PACKAGES="$PACKAGES wget unzip git curl ansible"
    fi

    # Check which packages are already installed
    PACKAGES_TO_INSTALL=()
    for pkg in $PACKAGES; do
        pkg_installed=false
        
        case "$OS" in
            ubuntu|debian)
                # Check if package is installed via dpkg
                if dpkg -l | grep -q "^ii.*$pkg"; then
                    pkg_installed=true
                fi
                ;;
            centos|rocky|almalinux|fedora|rhel)
                # Check if package is installed via dnf
                if dnf list installed "$pkg" &> /dev/null; then
                    pkg_installed=true
                fi
                ;;
            opensuse|sles)
                # Check if package is installed via zypper
                if zypper se -i "$pkg" &> /dev/null; then
                    pkg_installed=true
                fi
                ;;
        esac
        
        # For wget specifically, also check if the command is available
        if [ "$pkg" = "wget" ]; then
            if command -v wget &> /dev/null || command -v wget2 &> /dev/null; then
                pkg_installed=true
            fi
        fi
        
        if [ "$pkg_installed" = false ]; then
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

# Verify sshpass is available if needed
if [ "$PROXMOX_IS_REMOTE" = true ] && [ "$USE_ANSIBLE" = false ]; then
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
    
    # Determine if using key-based authentication
    if [ -n "$SSH_PRIVATE_KEY_PATH" ]; then
        # Using private key authentication
        echo "Starting build using public key authentication"
        # Verify private key file exists
        if [ ! -f "$SSH_PRIVATE_KEY_PATH" ]; then
            echo "Private key file not found: $SSH_PRIVATE_KEY_PATH" >&2
            exit 1
        fi
        
        # Create unique working directory on remote host
        ssh -i "$SSH_PRIVATE_KEY_PATH" -o StrictHostKeyChecking=no "$PROXMOX_SSH_USER@$PROXMOX_HOST" mkdir -p "./$WORK_DIR_NAME"

        scp -i "$SSH_PRIVATE_KEY_PATH" -o StrictHostKeyChecking=no ./Scripts/proxmox.sh "$PROXMOX_SSH_USER@$PROXMOX_HOST:./$WORK_DIR_NAME"
        # SSH to the remote host and run proxmox.sh with arguments
        # shellcheck disable=SC2087  # heredoc is expanded locally on purpose to inject the build args
        ssh -i "$SSH_PRIVATE_KEY_PATH" -o StrictHostKeyChecking=no "$PROXMOX_SSH_USER@$PROXMOX_HOST" << EOF
        chmod +x ./$WORK_DIR_NAME/proxmox.sh
        ./$WORK_DIR_NAME/proxmox.sh ${PROXMOX_SCRIPT_ARGS[*]}
        proxmox_rc=\$?
        rm -rf ./$WORK_DIR_NAME
        exit \$proxmox_rc
EOF
    else
        # Using password authentication
        echo "Starting build using password authentication"
        # Create unique working directory on remote host
        sshpass -p "$PROXMOX_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no "$PROXMOX_SSH_USER@$PROXMOX_HOST" mkdir -p "./$WORK_DIR_NAME"

        # Copy files to the remote host
        sshpass -p "$PROXMOX_SSH_PASSWORD" scp -o StrictHostKeyChecking=no ./Scripts/proxmox.sh "$PROXMOX_SSH_USER@$PROXMOX_HOST:./$WORK_DIR_NAME"
        # SSH to the remote host and run proxmox.sh with arguments
        # shellcheck disable=SC2087  # heredoc is expanded locally on purpose to inject the build args
        sshpass -p "$PROXMOX_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no "$PROXMOX_SSH_USER@$PROXMOX_HOST" << EOF
        chmod +x ./$WORK_DIR_NAME/proxmox.sh
        ./$WORK_DIR_NAME/proxmox.sh ${PROXMOX_SCRIPT_ARGS[*]}
        proxmox_rc=\$?
        rm -rf ./$WORK_DIR_NAME
        exit \$proxmox_rc
EOF
    fi
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
    
    # The intermediate build VMs are at the base VMID offsets matching DISTRO_METADATA
    # After Packer creates customized versions at offset+100, we no longer need these
    for distro_entry in "${DISTRO_METADATA[@]}"; do
        IFS='|' read -r distro_id distro_name offset <<< "$distro_entry"
        
        # Check if this distro was selected
        if [[ " $SELECTED_DISTROS " != *" $distro_id "* ]]; then
            continue
        fi
        
        vmid=$((VMID_BASE + offset))
        echo "  Destroying intermediate VMID $vmid..."
        
        # If remote, execute qm destroy on the remote host
        if [ "$PROXMOX_IS_REMOTE" = true ]; then
            if [ -n "$SSH_PRIVATE_KEY_PATH" ]; then
                ssh -i "$SSH_PRIVATE_KEY_PATH" -o StrictHostKeyChecking=no "$PROXMOX_SSH_USER@$PROXMOX_HOST" qm destroy "$vmid" 2>/dev/null || true
            else
                sshpass -p "$PROXMOX_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no "$PROXMOX_SSH_USER@$PROXMOX_HOST" qm destroy "$vmid" 2>/dev/null || true
            fi
        else
            # Local execution
            qm destroy "$vmid" 2>/dev/null || true
        fi
    done
fi

echo ""
echo "=== Build Complete ==="
echo "Template build process finished successfully!"
