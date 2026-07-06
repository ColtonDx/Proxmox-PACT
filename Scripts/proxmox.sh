#!/bin/bash

################################################################################
# Proxmox Template Creation Script
#
# This script is executed on the Proxmox server to download cloud images and
# create VM templates with cloud-init and QEMU-guest-agent support.
#
# Normally executed remotely by build.sh via SSH, but can also be run locally
# on the Proxmox host directly.
#
# CLI Arguments:
#   --vmid-base=NUM             Base VMID for templates (default: 800)
#                               Also accepts: --vmid=NUM (for backward compatibility)
#   --proxmox-storage=NAME      Storage pool name (default: local-lvm)
#                               Also accepts: --storage=NAME (for backward compatibility)
#   --build=LIST                Comma-separated list of distros to create
#                               Options: all, debian, ubuntu, or individual names
#                               Example: debian12,ubuntu2404,fedora42
#   --rebuild-templates            Delete existing VMs before building (destructive)
#   --run-packer                Packer will customize templates after creation
#                               Also accepts: --packer-enabled (for backward compatibility)
#   --help                      Display help message
#
# Distro Options:
#   Individual: debian11, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604, fedora42, fedora43
#   Groups:     debian (all Debian versions), ubuntu (all Ubuntu versions), fedora (all Fedora versions)
#   Special:    all (create all distros)
#
# VMIDs Assignment (with default VMID_BASE=800):
#   debian11: 801,   debian12: 802,   debian13: 803
#   ubuntu2204: 811, ubuntu2404: 812, ubuntu2604: 814
#   fedora42: 822,   fedora43: 823
#
# If Packer is enabled (--run-packer), customized VMs get base+100 offset
# Example: debian12 base template = 802, Packer customized = 902
#
# Usage Examples:
#   # Create Debian 12 and Ubuntu 24.04 templates
#   ./proxmox.sh --vmid-base=800 --proxmox-storage=local-lvm --build=debian12,ubuntu2404
#
#   # Create all templates and enable Packer customization
#   ./proxmox.sh --vmid-base=800 --proxmox-storage=local-lvm --build=all --run-packer
#
#   # Rebuild existing templates (delete and recreate)
#   ./proxmox.sh --vmid-base=800 --proxmox-storage=local-lvm --build=debian --rebuild-templates
#
################################################################################

# --- CLI parameter handling ---
# Defaults if not provided on the command line
DEFAULT_VMID_BASE=800
DEFAULT_PROXMOX_STORAGE="local-lvm"

# Define distro metadata: id|name|vmid_offset|filename|download_url
# The id field is used for filtering (debian11, ubuntu2404, etc.)
declare -a DISTRO_METADATA=(
    "debian11|Debian-11|1|debian-11-template.qcow2|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
    "debian12|Debian-12|2|debian-12-template.qcow2|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    "debian13|Debian-13|3|debian-13-template.qcow2|https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-genericcloud-amd64-daily.qcow2"
    "ubuntu2204|Ubuntu-2204|11|ubuntu-2204-template.img|https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
    "ubuntu2404|Ubuntu-2404|12|ubuntu-2404-template.img|https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    "ubuntu2604|Ubuntu-2604|14|ubuntu-2604-template.img|https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    "fedora42|Fedora-42|22|fedora-42-template.qcow2|https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2"
    "fedora43|Fedora-43|23|fedora-43-template.qcow2|https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2"
)

# Map of distro groups to their individual IDs
declare -A DISTRO_GROUPS=(
    [debian]="debian11 debian12 debian13"
    [ubuntu]="ubuntu2204 ubuntu2404 ubuntu2604"
    [fedora]="fedora42 fedora43"
    [all]="debian11 debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604 fedora42 fedora43"
)

print_usage() {
        cat <<EOF
Usage: $0 [--vmid-base=800] [--proxmox-storage=local-lvm] [--build=LIST] [--rebuild-templates] [--run-packer]

Options:
    --vmid-base=NUM        Base VMID to use. Defaults to ${DEFAULT_VMID_BASE}.
    --proxmox-storage=NAME Storage pool to use. Defaults to ${DEFAULT_PROXMOX_STORAGE}.
    --build=LIST      Comma-separated list of distros to build. Special values:
                        all      - build every distro (default)
                        debian   - debian11, debian12, debian13
                        ubuntu   - ubuntu2204, ubuntu2404, ubuntu2604
                      Individual names: debian11, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604, fedora42, fedora43
    --rebuild-templates     Delete existing VMs at target VMIDs before building (destructive).
                      Without this flag, existing VMs are preserved.
    --run-packer      Packer will be used for customization. Checks both base and packer VMIDs.
    --help            Show this help and exit
EOF
}

# Runtime defaults (CLI arguments below may override these)
VMID_BASE="${DEFAULT_VMID_BASE}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-$DEFAULT_PROXMOX_STORAGE}"
BUILD_DISTROS="all"
REBUILD_TEMPLATES=false
RUN_PACKER=false

for arg in "$@"; do
    case "$arg" in
        --vmid-base=*) VMID_BASE="${arg#*=}" ;;
        --vmid=*) VMID_BASE="${arg#*=}" ;;
        --proxmox-storage=*) PROXMOX_STORAGE="${arg#*=}" ;;
        --storage=*) PROXMOX_STORAGE="${arg#*=}" ;;
        --build=*) BUILD_DISTROS="${arg#*=}" ;;
        --rebuild-templates) REBUILD_TEMPLATES=true ;;
        --run-packer) RUN_PACKER=true ;;
        --packer-enabled) RUN_PACKER=true ;;
        --help) print_usage; exit 0 ;;
        *) echo "Unknown option: $arg"; print_usage; exit 1 ;;
    esac
done

# Parse build list and populate selected distros
SELECTED_DISTROS=""
if [ -z "${BUILD_DISTROS}" ] || [ "${BUILD_DISTROS}" = "all" ]; then
    SELECTED_DISTROS="${DISTRO_GROUPS[all]}"
else
    # Support comma or space separated list
    items="$(echo "$BUILD_DISTROS" | tr ',' ' ')"
    for item in $items; do
        if [ -n "${DISTRO_GROUPS[$item]}" ]; then
            # It's a group (debian, ubuntu, etc.)
            SELECTED_DISTROS="${SELECTED_DISTROS} ${DISTRO_GROUPS[$item]}"
        else
            # Check if it's a valid individual distro ID
            if [[ " debian11 debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604 fedora42 fedora43 " == *" $item "* ]]; then
                SELECTED_DISTROS="${SELECTED_DISTROS} $item"
            else
                echo "Warning: unknown build item '$item' - ignoring" >&2
            fi
        fi
    done
fi

# Remove duplicates and normalize spacing
SELECTED_DISTROS="$(echo "$SELECTED_DISTROS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)"

echo "Using VMID_BASE=${VMID_BASE}, storage=${PROXMOX_STORAGE}, build='${BUILD_DISTROS}', selected='${SELECTED_DISTROS}', rebuild-templates=${REBUILD_TEMPLATES}, run-packer=${RUN_PACKER}"

# Create and configure a VM template
create_template() {
    local vmid="$1"
    local template_name="$2"
    local filename="$3"
    local download_url="$4"
    local proxmox_storage="$5"
    local image="$WORKING_DIR/$filename"

    echo "Downloading the image from $download_url"
    # -f: fail (non-zero) on HTTP errors instead of saving an error page as the disk.
    if ! curl -fSL -o "$image" "$download_url"; then
        echo "Error: failed to download image for $template_name from $download_url" >&2
        return 1
    fi

    echo "Installing qemu-guest-agent into the image"
    if ! virt-customize -a "$image" --install qemu-guest-agent,bash-completion > /dev/null; then
        echo "Error: virt-customize failed for $template_name" >&2
        return 1
    fi

    echo "Creating template $template_name (VMID: $vmid)"
    qm create "$vmid" --name "$template_name" --ostype l26 || return 1
    qm set "$vmid" --net0 virtio,bridge=vmbr0
    qm set "$vmid" --serial0 socket --vga serial0
    qm set "$vmid" --memory 1024 --cores 4 --cpu host
    # Import the downloaded disk. Uses the same absolute $image path the download wrote to,
    # so it works regardless of the SSH user's home directory.
    if ! qm set "$vmid" --scsi0 "${proxmox_storage}:0,import-from=${image},discard=on"; then
        echo "Error: failed to import disk for $template_name (VMID $vmid)" >&2
        return 1
    fi
    qm set "$vmid" --boot order=scsi0 --scsihw virtio-scsi-single
    qm set "$vmid" --agent enabled=1,fstrim_cloned_disks=1
    qm set "$vmid" --ide3 "${proxmox_storage}:cloudinit"
    qm disk resize "$vmid" scsi0 8G
    qm template "$vmid"
}

# Check if a VMID already exists
check_vmid_exists() {
    local vmid="$1"
    if qm status "$vmid" &>/dev/null; then
        return 0  # VMID exists
    else
        return 1  # VMID does not exist
    fi
}

# Handle template rebuild/destruction (base + customization VMIDs)
manage_vmid_lifecycle() {
    local vmid="$1"

    if [ "$REBUILD_TEMPLATES" = true ]; then
        qm destroy "$vmid" 2>/dev/null
        # Only destroy packer VMID if packer is enabled
        if [ "$RUN_PACKER" = true ]; then
            qm destroy "$((vmid + 100))" 2>/dev/null
        fi
    else
        # Check base VMID
        if check_vmid_exists "$vmid"; then
            echo "Error: VMID $vmid is already in use. Use --rebuild-templates to replace it, or choose a different VMID_BASE." >&2
            return 1
        fi
        # Check packer VMID only if packer is enabled
        if [ "$RUN_PACKER" = true ]; then
            if check_vmid_exists "$((vmid + 100))"; then
                echo "Error: Packer VMID $((vmid + 100)) is already in use. Use --rebuild-templates to replace it, or choose a different VMID_BASE." >&2
                return 1
            fi
        fi
    fi
    return 0
}

apt-get install libguestfs-tools -y > /dev/null 2>&1

# Working directory for downloaded images. Absolute path so `qm ... import-from` resolves
# correctly no matter which user/home the script runs from.
WORKING_DIR="$(pwd)/workingdir"
mkdir -p "$WORKING_DIR"

# Process all selected distros
for distro_config in "${DISTRO_METADATA[@]}"; do
    IFS='|' read -r distro_id distro_name offset filename url <<< "$distro_config"
    
    # Check if this distro was selected for building
    if [[ " $SELECTED_DISTROS " != *" $distro_id "* ]]; then
        continue
    fi
    
    vmid=$((VMID_BASE + offset))
    template_name="Template-${distro_name}"
    
    # Handle VMID lifecycle (destroy or validate)
    if ! manage_vmid_lifecycle "$vmid"; then
        exit 1
    fi
    
    # Build the template
    echo "Creating base ${distro_name} Template"
    if ! create_template "$vmid" "$template_name" "$filename" "$url" "$PROXMOX_STORAGE"; then
        echo "Error: failed to build ${distro_name} template (VMID $vmid). Aborting." >&2
        exit 1
    fi
done
