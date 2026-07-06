#!/bin/bash

################################################################################
# Proxmox-P.A.C.T. Pre-Release Test Script
#
# Exercises the full build pipeline end-to-end against a real Proxmox host
# before a release, using an isolated VMID range (88xxx) so it never collides
# with production templates.
#
# What it does:
#   1. VARIABLE MODE   - run build.sh with CLI arguments, verify the templates
#                        were created, boot-test each, then delete them.
#   2. ANSWERFILE MODE - run build.sh with a generated answerfile, verify,
#                        boot-test each, then delete them.
#
# Boot validation (the important part):
#   build.sh produces *templates*, which are never started. To prove an image
#   actually boots after customization, each finished template is full-cloned
#   to a temporary VM, started, and polled with `qm agent <id> ping`. The QEMU
#   guest agent only answers once the OS has fully booted and brought up its
#   services, so a successful ping is concrete proof the image boots.
#
# VMID layout (with default --vmid-base=88000):
#   Base templates    : 88000 + offset           (e.g. debian12 -> 88002)
#   Packer templates  : 88000 + 100 + offset     (e.g. debian12 -> 88102)
#   Boot-test clones  : 88500 + (vmid - 88000)   (e.g. 88002 -> 88502)
#   Everything stays inside the 88xxx range and is destroyed on completion.
#
# Configuration (same settings build.sh uses), resolved in this priority order:
#   CLI args  >  PACT_* env vars  >  .env.local  >  built-in defaults
#
# Usage:
#   ./Scripts/test.sh --proxmox-host=pve.local --proxmox-ssh-password=secret \
#                     --proxmox-storage=local-lvm --build-distros=debian12
#
# Common options (see --help for the full list):
#   --vmid-base=NUM        Base VMID for the test range (default: 88000)
#   --build-distros=LIST   Distros to test (default: all). e.g. debian12,ubuntu2404
#   --mode=MODE            variable | answerfile | both (default: both)
#   --run-packer           Also build & boot-test Packer-customized templates
#   --boot-timeout=SEC     Seconds to wait for the guest agent (default: 300)
#   --keep                 Do not delete templates/clones on exit (debugging)
#   --local                Run qm/build directly on the Proxmox host (no SSH)
################################################################################

#####################################################################################
################### DEFAULTS & CONFIGURATION
#####################################################################################

# Resolve repository root (this script lives in <root>/Scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test-specific defaults
TEST_VMID_BASE=88000          # Isolated VMID range so we never touch production templates
CLONE_OFFSET=500              # Boot-test clones live at base+500+(...)
BOOT_TIMEOUT=300              # Seconds to wait for the guest agent to answer
TEST_MODE="both"             # variable | answerfile | both
KEEP_RESOURCES=false          # Skip cleanup when true (debugging)

# Build/connection defaults (mirror build.sh)
RUN_PACKER=false
PROXMOX_IS_REMOTE=true
SSH_PRIVATE_KEY_PATH=""
PACKER_TOKEN_ID=""
PACKER_TOKEN_SECRET=""
BUILD_DISTROS="all"

#####################################################################################
# LOAD CONFIG: .env.local  ->  PACT_* env vars  (CLI args applied afterwards)
#####################################################################################
if [ -f "$REPO_ROOT/.env.local" ]; then
    echo "Loading defaults from $REPO_ROOT/.env.local ..."
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env.local"
fi

[ -n "${PACT_PROXMOX_HOST:-}" ]         && PROXMOX_HOST="${PACT_PROXMOX_HOST}"
[ -n "${PACT_PROXMOX_SSH_USER:-}" ]     && PROXMOX_SSH_USER="${PACT_PROXMOX_SSH_USER}"
[ -n "${PACT_PROXMOX_SSH_PASSWORD:-}" ] && PROXMOX_SSH_PASSWORD="${PACT_PROXMOX_SSH_PASSWORD}"
[ -n "${PACT_SSH_PRIVATE_KEY_PATH:-}" ] && SSH_PRIVATE_KEY_PATH="${PACT_SSH_PRIVATE_KEY_PATH}"
[ -n "${PACT_PROXMOX_STORAGE:-}" ]      && PROXMOX_STORAGE="${PACT_PROXMOX_STORAGE}"
[ -n "${PACT_PROXMOX_TARGET_NODE:-}" ]  && PROXMOX_TARGET_NODE="${PACT_PROXMOX_TARGET_NODE}"
[ -n "${PACT_PROXMOX_IS_REMOTE:-}" ]    && PROXMOX_IS_REMOTE="${PACT_PROXMOX_IS_REMOTE}"
[ -n "${PACT_BUILD_DISTROS:-}" ]        && BUILD_DISTROS="${PACT_BUILD_DISTROS}"
[ -n "${PACT_RUN_PACKER:-}" ]           && RUN_PACKER="${PACT_RUN_PACKER}"
[ -n "${PACT_PACKER_TOKEN_ID:-}" ]      && PACKER_TOKEN_ID="${PACT_PACKER_TOKEN_ID}"
[ -n "${PACT_PACKER_TOKEN_SECRET:-}" ]  && PACKER_TOKEN_SECRET="${PACT_PACKER_TOKEN_SECRET}"
[ -n "${PACT_VMID_BASE:-}" ]            && TEST_VMID_BASE="${PACT_VMID_BASE}"

#####################################################################################
################### CLI PARSING
#####################################################################################

print_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Builds Proxmox templates in an isolated 88xxx VMID range using both of build.sh's
configuration methods, verifies each image actually boots, then deletes everything.

Connection options (same meaning as build.sh):
  --proxmox-host=HOSTNAME      Proxmox hostname or IP address
  --proxmox-ssh-user=USER      SSH username for Proxmox (default: root)
  --proxmox-ssh-password=PASS  SSH password for Proxmox authentication
  --ssh-private-key-path=PATH  SSH private key (used instead of a password)
  --proxmox-storage=POOL       Storage pool name (default: local-lvm)
  --proxmox-target-node=NODE   Target node, needed for --run-packer (default: pve)
  --local                      Run directly on the Proxmox host (no SSH)

Test options:
  --vmid-base=NUM              Base VMID for the test range (default: 88000)
  --build-distros=LIST         Distros to test (default: all), e.g. debian12,ubuntu2404
  --mode=MODE                  variable | answerfile | both (default: both)
  --run-packer                 Also build/boot-test Packer templates (needs tokens)
  --packer-token-id=TOKEN      Proxmox API Token ID (with --run-packer)
  --packer-token-secret=SEC    Proxmox API Token Secret (with --run-packer)
  --boot-timeout=SEC           Seconds to wait for the guest agent (default: 300)
  --keep                       Do not delete templates/clones on exit (debugging)
  --help                       Show this help and exit
EOF
}

for arg in "$@"; do
    case "$arg" in
        --proxmox-host=*)            PROXMOX_HOST="${arg#*=}" ;;
        --proxmox-ssh-user=*)        PROXMOX_SSH_USER="${arg#*=}" ;;
        --proxmox-ssh-password=*)    PROXMOX_SSH_PASSWORD="${arg#*=}" ;;
        --ssh-private-key-path=*)    SSH_PRIVATE_KEY_PATH="${arg#*=}" ;;
        --proxmox-storage=*)         PROXMOX_STORAGE="${arg#*=}" ;;
        --proxmox-target-node=*)     PROXMOX_TARGET_NODE="${arg#*=}" ;;
        --local)                     PROXMOX_IS_REMOTE=false ;;
        --vmid-base=*)               TEST_VMID_BASE="${arg#*=}" ;;
        --build-distros=*)           BUILD_DISTROS="${arg#*=}" ;;
        --mode=*)                    TEST_MODE="${arg#*=}" ;;
        --run-packer)                RUN_PACKER=true ;;
        --packer-token-id=*)         PACKER_TOKEN_ID="${arg#*=}" ;;
        --packer-token-secret=*)     PACKER_TOKEN_SECRET="${arg#*=}" ;;
        --boot-timeout=*)            BOOT_TIMEOUT="${arg#*=}" ;;
        --keep)                      KEEP_RESOURCES=true ;;
        --help)                      print_usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; print_usage; exit 1 ;;
    esac
done

# Apply remaining defaults (CLI/env/answerfile may already have set these)
: "${PROXMOX_SSH_USER:=root}"
: "${PROXMOX_HOST:=pve.local}"
: "${PROXMOX_TARGET_NODE:=pve}"
: "${PROXMOX_STORAGE:=local-lvm}"

#####################################################################################
################### OUTPUT HELPERS & RESULT TRACKING
#####################################################################################

C_RESET=$'\033[0m'; C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'
C_YELLOW=$'\033[0;33m'; C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'

PASS_COUNT=0
FAIL_COUNT=0
declare -a FAILURES=()
declare -a CREATED_VMIDS=()   # Every VMID we create, for guaranteed cleanup

log_section() { echo ""; echo "${C_BOLD}${C_BLUE}=== $* ===${C_RESET}"; }
log_info()    { echo "  $*"; }
log_pass()    { echo "  ${C_GREEN}PASS${C_RESET} $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail()    { echo "  ${C_RED}FAIL${C_RESET} $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("$*"); }
# shellcheck disable=SC2317  # only called from the EXIT-trap cleanup
log_warn()    { echo "  ${C_YELLOW}WARN${C_RESET} $*"; }

#####################################################################################
################### REMOTE EXECUTION
#####################################################################################

# Run a command on the Proxmox host (over SSH, or locally with --local).
pve_exec() {
    local cmd="$1"
    if [ "$PROXMOX_IS_REMOTE" = true ]; then
        if [ -n "$SSH_PRIVATE_KEY_PATH" ]; then
            ssh -i "$SSH_PRIVATE_KEY_PATH" -o StrictHostKeyChecking=no \
                "$PROXMOX_SSH_USER@$PROXMOX_HOST" "$cmd"
        else
            sshpass -p "$PROXMOX_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
                "$PROXMOX_SSH_USER@$PROXMOX_HOST" "$cmd"
        fi
    else
        bash -c "$cmd"
    fi
}

#####################################################################################
################### DISTRO METADATA (parsed from proxmox.sh to avoid drift)
#####################################################################################

declare -a DISTRO_IDS=()
declare -A DISTRO_OFFSET=()
declare -A DISTRO_NAME=()

parse_distro_metadata() {
    local src="$REPO_ROOT/Scripts/proxmox.sh"
    if [ ! -f "$src" ]; then
        echo "Error: cannot find $src to read distro metadata" >&2
        exit 1
    fi
    local line entry id name offset
    # Metadata rows look like:  "debian12|Debian-12|2|file.qcow2|https://..."
    while IFS= read -r line; do
        entry="${line#*\"}"; entry="${entry%%\"*}"
        IFS='|' read -r id name offset _ <<< "$entry"
        [ -z "$id" ] && continue
        DISTRO_IDS+=("$id")
        DISTRO_NAME["$id"]="$name"
        DISTRO_OFFSET["$id"]="$offset"
    done < <(grep -E '^[[:space:]]*"[a-z0-9]+\|' "$src")

    if [ "${#DISTRO_IDS[@]}" -eq 0 ]; then
        echo "Error: parsed zero distros from $src" >&2
        exit 1
    fi
}

# Expand a BUILD_DISTROS list (groups like "debian"/prefixes, individual ids, or
# "all") into the concrete distro ids. Echoes a space-separated, de-duped list.
expand_selected() {
    local spec="$1" token id out=""
    if [ -z "$spec" ] || [ "$spec" = "all" ]; then
        echo "${DISTRO_IDS[*]}"
        return
    fi
    for token in ${spec//,/ }; do
        local matched=false
        for id in "${DISTRO_IDS[@]}"; do
            # Exact id, or a group/prefix match (e.g. "debian" -> debian11/12/13)
            if [ "$id" = "$token" ] || [[ "$id" == "$token"* ]]; then
                out="$out $id"; matched=true
            fi
        done
        [ "$matched" = false ] && echo "Warning: unknown distro '$token' - ignoring" >&2
    done
    echo "$out" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs
}

#####################################################################################
################### CLEANUP
#####################################################################################

destroy_vmid() {
    local vmid="$1"
    pve_exec "qm stop $vmid --skiplock 1" >/dev/null 2>&1
    # Give a brief moment for the lock to clear, then purge
    pve_exec "for i in 1 2 3 4 5; do qm destroy $vmid --purge 1 --skiplock 1 >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1" >/dev/null 2>&1
}

# Runs via the EXIT trap (shellcheck can't see the indirect invocation).
# shellcheck disable=SC2317
cleanup_all() {
    [ "$KEEP_RESOURCES" = true ] && { echo ""; log_warn "--keep set: leaving ${#CREATED_VMIDS[@]} VMID(s) in place: ${CREATED_VMIDS[*]}"; return; }
    [ "${#CREATED_VMIDS[@]}" -eq 0 ] && return
    log_section "Cleanup"
    local vmid
    for vmid in "${CREATED_VMIDS[@]}"; do
        log_info "Destroying VMID $vmid ..."
        destroy_vmid "$vmid"
    done
}
trap cleanup_all EXIT

# Record a VMID for cleanup (deduped)
track_vmid() {
    local vmid="$1" existing
    for existing in "${CREATED_VMIDS[@]}"; do
        [ "$existing" = "$vmid" ] && return
    done
    CREATED_VMIDS+=("$vmid")
}

# Remove a VMID from the tracking list (after we deliberately destroy it)
untrack_vmid() {
    local vmid="$1" keep=() existing
    for existing in "${CREATED_VMIDS[@]}"; do
        [ "$existing" != "$vmid" ] && keep+=("$existing")
    done
    CREATED_VMIDS=("${keep[@]}")
}

#####################################################################################
################### CORE CHECKS
#####################################################################################

# Verify a VMID exists on the host and is flagged as a template.
verify_template() {
    local vmid="$1" label="$2" cfg
    cfg="$(pve_exec "qm config $vmid" 2>/dev/null)"
    if [ -z "$cfg" ]; then
        log_fail "$label: template VMID $vmid was not created"
        return 1
    fi
    if echo "$cfg" | grep -qE '^template:[[:space:]]*1'; then
        log_pass "$label: template VMID $vmid created"
        return 0
    fi
    log_fail "$label: VMID $vmid exists but is not a template"
    return 1
}

# Clone a template to a temp VM, boot it, and wait for the guest agent to answer.
boot_test() {
    local template_vmid="$1" label="$2"
    local clone_vmid=$((TEST_VMID_BASE + CLONE_OFFSET + (template_vmid - TEST_VMID_BASE)))

    log_info "$label: cloning template $template_vmid -> boot-test VM $clone_vmid"
    track_vmid "$clone_vmid"
    if ! pve_exec "qm clone $template_vmid $clone_vmid --name pact-boottest-$clone_vmid --full 1 --storage $PROXMOX_STORAGE" >/dev/null 2>&1; then
        log_fail "$label: failed to clone template $template_vmid for boot test"
        return 1
    fi

    # Ensure cloud-init brings up networking so the guest agent can start.
    pve_exec "qm set $clone_vmid --ipconfig0 ip=dhcp" >/dev/null 2>&1

    log_info "$label: starting boot-test VM $clone_vmid (timeout ${BOOT_TIMEOUT}s)"
    if ! pve_exec "qm start $clone_vmid" >/dev/null 2>&1; then
        log_fail "$label: VM $clone_vmid failed to start"
        destroy_vmid "$clone_vmid"; untrack_vmid "$clone_vmid"
        return 1
    fi

    # Poll the QEMU guest agent. It only answers once the OS has fully booted.
    local elapsed=0 booted=false
    while [ "$elapsed" -lt "$BOOT_TIMEOUT" ]; do
        if pve_exec "qm agent $clone_vmid ping" >/dev/null 2>&1; then
            booted=true
            break
        fi
        sleep 8
        elapsed=$((elapsed + 8))
    done

    if [ "$booted" = true ]; then
        log_pass "$label: VMID $template_vmid booted (guest agent responded after ~${elapsed}s)"
    else
        log_fail "$label: VMID $template_vmid did NOT boot (no guest-agent response within ${BOOT_TIMEOUT}s)"
    fi

    log_info "$label: tearing down boot-test VM $clone_vmid"
    destroy_vmid "$clone_vmid"; untrack_vmid "$clone_vmid"
    [ "$booted" = true ]
}

# Final template VMIDs that should exist after a build:
#   - With Packer: base+100+offset (build.sh destroys the base intermediates)
#   - Without Packer: base+offset
final_vmids_for() {
    local selected="$1" id offset vmid
    for id in $selected; do
        offset="${DISTRO_OFFSET[$id]}"
        if [ "$RUN_PACKER" = true ]; then
            vmid=$((TEST_VMID_BASE + 100 + offset))
        else
            vmid=$((TEST_VMID_BASE + offset))
        fi
        echo "$vmid $id"
    done
}

#####################################################################################
################### BUILD INVOCATIONS
#####################################################################################

# Build in VARIABLE mode: everything passed as CLI arguments / env to build.sh.
# --answerfile-path=/dev/null prevents build.sh from picking up a stray .env.local.
build_variable_mode() {
    local build_args=(
        --answerfile-path=/dev/null
        --proxmox-host="$PROXMOX_HOST"
        --proxmox-ssh-user="$PROXMOX_SSH_USER"
        --proxmox-storage="$PROXMOX_STORAGE"
        --proxmox-target-node="$PROXMOX_TARGET_NODE"
        --build-distros="$BUILD_DISTROS"
        --rebuild-templates
    )
    if [ -n "$SSH_PRIVATE_KEY_PATH" ]; then
        build_args+=("--ssh-private-key-path=$SSH_PRIVATE_KEY_PATH")
    else
        build_args+=("--proxmox-ssh-password=$PROXMOX_SSH_PASSWORD")
    fi
    [ "$PROXMOX_IS_REMOTE" = false ] && build_args+=("--local")
    if [ "$RUN_PACKER" = true ]; then
        build_args+=("--run-packer" "--packer-token-id=$PACKER_TOKEN_ID" "--packer-token-secret=$PACKER_TOKEN_SECRET")
    fi

    ( cd "$REPO_ROOT" && PACT_VMID_BASE="$TEST_VMID_BASE" ./Scripts/build.sh "${build_args[@]}" )
}

# Build in ANSWERFILE mode: write a temp answerfile and let build.sh source it.
build_answerfile_mode() {
    local answerfile
    answerfile="$(mktemp "${TMPDIR:-/tmp}/pact_test_answerfile.XXXXXX")"
    {
        echo "PROXMOX_HOST=\"$PROXMOX_HOST\""
        echo "PROXMOX_SSH_USER=\"$PROXMOX_SSH_USER\""
        if [ -n "$SSH_PRIVATE_KEY_PATH" ]; then
            echo "SSH_PRIVATE_KEY_PATH=\"$SSH_PRIVATE_KEY_PATH\""
        else
            echo "PROXMOX_SSH_PASSWORD=\"$PROXMOX_SSH_PASSWORD\""
        fi
        echo "PROXMOX_STORAGE=\"$PROXMOX_STORAGE\""
        echo "PROXMOX_TARGET_NODE=\"$PROXMOX_TARGET_NODE\""
        echo "PROXMOX_IS_REMOTE=$PROXMOX_IS_REMOTE"
        echo "VMID_BASE=$TEST_VMID_BASE"
        echo "BUILD_DISTROS=\"$BUILD_DISTROS\""
        echo "REBUILD_TEMPLATES=true"
        echo "RUN_PACKER=$RUN_PACKER"
        if [ "$RUN_PACKER" = true ]; then
            echo "PACKER_TOKEN_ID=\"$PACKER_TOKEN_ID\""
            echo "PACKER_TOKEN_SECRET=\"$PACKER_TOKEN_SECRET\""
        fi
    } > "$answerfile"

    ( cd "$REPO_ROOT" && ./Scripts/build.sh --answerfile-path="$answerfile" )
    local rc=$?
    rm -f "$answerfile"
    return $rc
}

#####################################################################################
################### PHASE RUNNER
#####################################################################################

run_phase() {
    local mode="$1" selected="$2"
    log_section "Phase: $mode mode build"

    # Track every template we expect so cleanup catches them even if build half-fails.
    local vmid id
    while read -r vmid id; do
        [ -n "$vmid" ] && track_vmid "$vmid"
    done < <(final_vmids_for "$selected")

    log_info "Running build.sh in $mode mode (VMID base $TEST_VMID_BASE, distros: $selected)"
    local build_ok=true
    if [ "$mode" = "variable" ]; then
        build_variable_mode || build_ok=false
    else
        build_answerfile_mode || build_ok=false
    fi

    if [ "$build_ok" = true ]; then
        log_pass "$mode mode: build.sh completed without error"
    else
        log_fail "$mode mode: build.sh exited with an error"
    fi

    # Verify + boot-test each expected template, then delete it.
    while read -r vmid id; do
        [ -z "$vmid" ] && continue
        local label="$mode/${DISTRO_NAME[$id]}"
        if verify_template "$vmid" "$label"; then
            boot_test "$vmid" "$label"
        fi
        log_info "$label: deleting template $vmid"
        destroy_vmid "$vmid"; untrack_vmid "$vmid"
    done < <(final_vmids_for "$selected")
}

#####################################################################################
################### PRE-FLIGHT VALIDATION
#####################################################################################

preflight() {
    local errors=0

    case "$TEST_MODE" in
        variable|answerfile|both) ;;
        *) echo "Error: --mode must be variable, answerfile, or both" >&2; errors=$((errors+1)) ;;
    esac

    if [ "$PROXMOX_IS_REMOTE" = true ]; then
        if [ -z "$SSH_PRIVATE_KEY_PATH" ] && [ -z "${PROXMOX_SSH_PASSWORD:-}" ]; then
            echo "Error: provide --proxmox-ssh-password or --ssh-private-key-path (or use --local)" >&2
            errors=$((errors+1))
        fi
        if [ -z "$SSH_PRIVATE_KEY_PATH" ] && ! command -v sshpass >/dev/null 2>&1; then
            echo "Error: sshpass is required for password authentication" >&2
            errors=$((errors+1))
        fi
    fi

    if [ "$RUN_PACKER" = true ]; then
        if [ -z "$PACKER_TOKEN_ID" ] || [ -z "$PACKER_TOKEN_SECRET" ]; then
            echo "Error: --packer-token-id and --packer-token-secret are required with --run-packer" >&2
            errors=$((errors+1))
        fi
    fi

    if ! [[ "$TEST_VMID_BASE" =~ ^[0-9]+$ ]]; then
        echo "Error: --vmid-base must be numeric" >&2; errors=$((errors+1))
    elif [ "$TEST_VMID_BASE" -lt 80000 ]; then
        # This test builds templates and then DELETES every one of them, so it must stay
        # in an isolated high range. A PACT_VMID_BASE left over from a production build
        # (e.g. 800) would otherwise silently retarget it at real templates.
        echo "Error: refusing to run with --vmid-base=$TEST_VMID_BASE (must be >= 80000)." >&2
        echo "       This script destroys every template it creates; keep it out of the" >&2
        echo "       production VMID range. Pass --vmid-base=88000 explicitly." >&2
        errors=$((errors+1))
    fi

    [ "$errors" -gt 0 ] && { echo ""; print_usage; exit 1; }
}

#####################################################################################
################### MAIN
#####################################################################################

parse_distro_metadata
preflight

SELECTED="$(expand_selected "$BUILD_DISTROS")"
if [ -z "$SELECTED" ]; then
    echo "Error: no valid distros selected from '$BUILD_DISTROS'" >&2
    exit 1
fi

log_section "Proxmox-P.A.C.T. Pre-Release Test"
log_info "Proxmox host : $PROXMOX_HOST (remote: $PROXMOX_IS_REMOTE)"
log_info "Storage pool : $PROXMOX_STORAGE"
log_info "VMID base    : $TEST_VMID_BASE (templates $((TEST_VMID_BASE+1))..., clones $((TEST_VMID_BASE+CLONE_OFFSET))...)"
log_info "Distros      : $SELECTED"
log_info "Run Packer   : $RUN_PACKER"
log_info "Mode         : $TEST_MODE"
log_info "Boot timeout : ${BOOT_TIMEOUT}s"

# Quick connectivity check before doing any heavy lifting.
if pve_exec "command -v qm >/dev/null 2>&1"; then
    log_pass "Connected to Proxmox host and 'qm' is available"
else
    log_fail "Could not reach Proxmox host or 'qm' is not available"
    echo "" ; echo "${C_RED}Aborting: cannot run tests without Proxmox access.${C_RESET}" >&2
    exit 1
fi

if [ "$TEST_MODE" = "variable" ] || [ "$TEST_MODE" = "both" ]; then
    run_phase "variable" "$SELECTED"
fi
if [ "$TEST_MODE" = "answerfile" ] || [ "$TEST_MODE" = "both" ]; then
    run_phase "answerfile" "$SELECTED"
fi

#####################################################################################
################### SUMMARY
#####################################################################################

log_section "Test Summary"
log_info "Passed: $PASS_COUNT    Failed: $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    echo "${C_RED}Failures:${C_RESET}"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    echo ""
    echo "${C_RED}${C_BOLD}RESULT: FAIL${C_RESET}"
    exit 1
fi
echo ""
echo "${C_GREEN}${C_BOLD}RESULT: PASS${C_RESET}"
exit 0
