#!/bin/bash

################################################################################
# Proxmox-PACT TUI Helpers
#
# Shell-only "TUI" chrome for the guided installer: box-drawn panels, a step
# counter, and prompt wrappers that accept "?" as an answer. When the user
# answers "?", an ASCII penguin explains the option in plain language and the
# same question is asked again.
#
# This file is sourced by Scripts/build.sh; it defines functions only and runs
# nothing at source time. It degrades gracefully: without a TTY (or with
# NO_COLOR / PACT_NO_TUI set) the panels collapse to plain lines and the ask_*
# helpers behave like the plain `read -p` prompts they replaced.
#
# Public API used by build.sh:
#   tui_enabled                       -> 0 when TUI chrome should be drawn
#   tui_banner                        Draw the title banner
#   tui_step "Title"                  Draw a step header (auto-numbered)
#   tui_note / tui_warn / tui_info    One-line annotated output
#   tui_panel "Title" "line" ...      Draw a bordered panel of lines
#   ask        VAR "Prompt" "default" "help-topic"
#   ask_secret VAR "Prompt" "help-topic"
#   ask_yesno  VAR "Prompt" "Y|N"     "help-topic"   (sets VAR to true/false)
#   penguin_say "help-topic"          Print the penguin + a help topic
################################################################################

#####################################################################################
################### CAPABILITY DETECTION AND PALETTE
#####################################################################################

# TUI chrome is drawn only on an interactive terminal. PACT_NO_TUI=1 or NO_COLOR
# force the plain-text path (useful for logs, CI, and `script`-style capture).
# The `?` help itself still works either way - only the decoration is dropped.
PACT_TUI_ENABLED=false
if [ -t 1 ] && [ -z "${PACT_NO_TUI:-}" ] && [ -z "${NO_COLOR:-}" ]; then
    PACT_TUI_ENABLED=true
fi

# Colors, defined empty when disabled so every string interpolates harmlessly.
if [ "$PACT_TUI_ENABLED" = true ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_CYAN=$'\033[36m'
    C_BLUE=$'\033[34m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_WHITE=$'\033[97m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_CYAN=""; C_BLUE=""
    C_GREEN=""; C_YELLOW=""; C_WHITE=""
fi

# Panel width: track the terminal but stay inside sane bounds so the penguin and
# the borders line up on both an 80-column console and a wide terminal.
PACT_TUI_WIDTH="${COLUMNS:-0}"
[ "$PACT_TUI_WIDTH" -lt 10 ] 2>/dev/null && PACT_TUI_WIDTH="$(tput cols 2>/dev/null || echo 80)"
[ "$PACT_TUI_WIDTH" -gt 100 ] && PACT_TUI_WIDTH=100
[ "$PACT_TUI_WIDTH" -lt 60 ] && PACT_TUI_WIDTH=60

# Step counter for the "Step N" headers.
PACT_TUI_STEP=0

# Returns 0 when the decorated TUI should be drawn.
tui_enabled() { [ "$PACT_TUI_ENABLED" = true ]; }

#####################################################################################
################### DRAWING PRIMITIVES
#####################################################################################

# Repeat a string N times (e.g. tui_repeat "-" 20).
tui_repeat() {
    local str="$1" count="$2" out=""
    local i
    for ((i = 0; i < count; i++)); do out+="$str"; done
    printf '%s' "$out"
}

# Length of a string with ANSI escapes stripped, so padding math stays correct
# even when the caller passes colored text.
tui_visible_len() {
    local stripped
    stripped="$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g')"
    printf '%s' "${#stripped}"
}

# Print one line inside a box: "| text<padding> |".
tui_box_line() {
    local text="$1" inner=$((PACT_TUI_WIDTH - 4)) len pad
    len="$(tui_visible_len "$text")"
    pad=$((inner - len))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s│%s %s%s %s│%s\n' \
        "$C_BLUE" "$C_RESET" "$text" "$(tui_repeat ' ' "$pad")" "$C_BLUE" "$C_RESET"
}

tui_box_top()    { printf '%s╭%s╮%s\n' "$C_BLUE" "$(tui_repeat '─' $((PACT_TUI_WIDTH - 2)))" "$C_RESET"; }
tui_box_bottom() { printf '%s╰%s╯%s\n' "$C_BLUE" "$(tui_repeat '─' $((PACT_TUI_WIDTH - 2)))" "$C_RESET"; }
tui_box_sep()    { printf '%s├%s┤%s\n' "$C_BLUE" "$(tui_repeat '─' $((PACT_TUI_WIDTH - 2)))" "$C_RESET"; }

# Draw a titled panel around the remaining arguments (one per line).
tui_panel() {
    local title="$1"; shift
    if ! tui_enabled; then
        echo ""
        echo "== $title =="
        local l
        for l in "$@"; do echo "  $l"; done
        return 0
    fi
    echo ""
    tui_box_top
    tui_box_line "${C_BOLD}${C_WHITE}${title}${C_RESET}"
    tui_box_sep
    local line
    for line in "$@"; do tui_box_line "$line"; done
    tui_box_bottom
}

#####################################################################################
################### BANNER, STEPS, AND ANNOTATIONS
#####################################################################################

# Opening banner for the guided installer. Drawn at most once per run: the
# bootstrap gate and interactive mode can both reach it in the same run.
PACT_TUI_BANNER_DRAWN=false
tui_banner() {
    [ "$PACT_TUI_BANNER_DRAWN" = true ] && return 0
    PACT_TUI_BANNER_DRAWN=true
    if ! tui_enabled; then
        echo ""
        echo "=== Proxmox-PACT Guided Installer ==="
        echo "Answer '?' at any prompt for an explanation."
        echo ""
        return 0
    fi
    echo ""
    tui_box_top
    tui_box_line "${C_BOLD}${C_CYAN}Proxmox-PACT${C_RESET}  ${C_DIM}Packer · Ansible · CloudInit Templates${C_RESET}"
    tui_box_sep
    tui_box_line "${C_DIM}Guided installer${C_RESET}"
    tui_box_line ""
    tui_box_line "Type ${C_BOLD}${C_YELLOW}?${C_RESET} at any prompt and the penguin will explain it."
    tui_box_line "Press ${C_BOLD}Enter${C_RESET} to accept the ${C_DIM}[default]${C_RESET} shown in each question."
    tui_box_bottom
    echo ""
}

# Numbered step header. Call once per logical section of the interview.
tui_step() {
    local title="$1"
    PACT_TUI_STEP=$((PACT_TUI_STEP + 1))
    echo ""
    if tui_enabled; then
        printf '%s%s Step %d %s%s %s\n' \
            "$C_BOLD" "$C_CYAN" "$PACT_TUI_STEP" "$C_RESET" "$C_BOLD" "${title}${C_RESET}"
        printf '%s%s%s\n' "$C_DIM" "$(tui_repeat '─' "$PACT_TUI_WIDTH")" "$C_RESET"
    else
        echo "--- Step $PACT_TUI_STEP: $title ---"
    fi
}

# Dim explanatory line, wrapped to the panel width so long notes do not run off
# a narrow terminal. Defined after tui_wrap is available at call time.
tui_note() {
    local line
    while IFS= read -r line; do
        printf '  %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
    done < <(tui_wrap "$1" $((PACT_TUI_WIDTH - 4)))
}
tui_info() { printf '  %s•%s %s\n' "$C_CYAN" "$C_RESET" "$1"; }
tui_warn() { printf '  %s!%s %s%s%s\n' "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$1" "$C_RESET"; }
tui_ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }

#####################################################################################
################### THE PENGUIN
#####################################################################################

# Wrap text to a given width, emitting one line per output line. Uses `fold -s`
# when available (word-safe) and falls back to the raw text otherwise.
tui_wrap() {
    local text="$1" width="$2"
    if command -v fold &>/dev/null; then
        printf '%s\n' "$text" | fold -s -w "$width"
    else
        printf '%s\n' "$text"
    fi
}

# Draw the penguin next to a speech bubble containing the given text.
# The penguin art is 12 columns wide; the bubble takes the rest of the width.
penguin_speak() {
    local text="$1"
    local bubble_width=$((PACT_TUI_WIDTH - 18))
    [ "$bubble_width" -lt 30 ] && bubble_width=30

    local -a lines=()
    local line
    while IFS= read -r line; do lines+=("$line"); done < <(tui_wrap "$text" "$bubble_width")
    [ "${#lines[@]}" -eq 0 ] && lines=("")

    # Widest line decides the bubble border length.
    local maxlen=0 len
    for line in "${lines[@]}"; do
        len="${#line}"
        [ "$len" -gt "$maxlen" ] && maxlen="$len"
    done

    local -a art=(
        "   .--."
        "  |o_o |"
        "  |:_/ |"
        " //   \\ \\"
        "(|     | )"
        "/'\\_   _/\`\\"
        "\\___)=(___/"
    )

    echo ""
    # Bubble top, drawn above the penguin's head (indented to the art gutter).
    printf '%-12s%s╭─%s─╮%s\n' "" "$C_CYAN" "$(tui_repeat '─' "$maxlen")" "$C_RESET"

    # Interleave the art rows with the text rows; whichever list is longer
    # keeps printing while the other side pads with blanks.
    local total="${#art[@]}"
    [ "${#lines[@]}" -gt "$total" ] && total="${#lines[@]}"

    local i art_row text_row pad
    for ((i = 0; i < total; i++)); do
        art_row="${art[i]:-}"
        # Rows with nothing beside them print bare, so no trailing spaces are
        # left on the line; rows facing the bubble pad the art column to 12.
        if [ "$i" -gt "${#lines[@]}" ]; then
            printf '%s%s%s\n' "$C_WHITE" "$art_row" "$C_RESET"
            continue
        fi
        printf '%s%-12s%s' "$C_WHITE" "$art_row" "$C_RESET"
        if [ "$i" -lt "${#lines[@]}" ]; then
            text_row="${lines[i]}"
            pad=$((maxlen - ${#text_row}))
            [ "$pad" -lt 0 ] && pad=0
            printf '%s│%s %s%s %s│%s\n' \
                "$C_CYAN" "$C_RESET" "$text_row" "$(tui_repeat ' ' "$pad")" "$C_CYAN" "$C_RESET"
        elif [ "$i" -eq "${#lines[@]}" ]; then
            # The row right after the last text line closes the bubble.
            printf '%s╰─%s─╯%s\n' "$C_CYAN" "$(tui_repeat '─' "$maxlen")" "$C_RESET"
        fi
    done

    # If the text outlasted the art, the bubble was never closed above.
    if [ "${#lines[@]}" -ge "${#art[@]}" ]; then
        printf '%s%-12s%s%s╰─%s─╯%s\n' \
            "$C_WHITE" "" "$C_RESET" "$C_CYAN" "$(tui_repeat '─' "$maxlen")" "$C_RESET"
    fi
    echo ""
}

#####################################################################################
################### HELP TOPICS
#####################################################################################

# Every prompt names a help topic; this is what the penguin reads out when the
# user answers "?". Keep each entry to a short paragraph in plain language -
# the reference material lives in the README and the wiki, not here.
penguin_help_text() {
    case "$1" in
        distros)
            echo "This picks which Linux images become templates. 'all' builds every supported distro. You can name a family - debian, ubuntu, or fedora - to get every version of it, or list exact ones separated by commas, like debian12,ubuntu2404. Each one is downloaded as an official cloud image and turned into a Proxmox template you can clone. Building all of them takes longer and uses more storage, so if you are trying this out for the first time, one distro is a good start."
            ;;
        cloudinit)
            echo "Cloud-Init is the tool inside the image that configures a VM on its very first boot - the user account, password, and SSH keys. By default PACT leaves those blank so you fill them in from the Proxmox UI each time you clone a template. Answer Yes here to bake defaults into the templates instead, so every clone already has your user and SSH key. Answer No if different VMs should get different logins."
            ;;
        cloudinit_user)
            echo "The default login name created on first boot. Leave it blank to keep the name the distro ships with - debian for Debian, ubuntu for Ubuntu, fedora for Fedora. Set it if you would rather every VM you clone have the same account name, for example your own username or an automation account your Ansible playbooks expect."
            ;;
        cloudinit_password)
            echo "A default password for that account. Be aware: Proxmox stores this in the VM's config in plaintext, so anyone who can run 'qm config' on the host can read it. An SSH key is the safer choice and you can leave this blank entirely. A password is mainly useful if you need console access to a VM that has no network yet."
            ;;
        cloudinit_sshkey)
            echo "Your SSH public key gets installed for the default user, so you can log in without a password. Give a file path if you keep several keys in one file - the usual one is ~/.ssh/authorized_keys, or ~/.ssh/id_ed25519.pub for a single key. Leave the path blank and you can paste one key directly instead. This is the recommended way to get into your VMs."
            ;;
        packer)
            echo "Packer plus Ansible take the plain templates you just built and customize them - installing packages, applying settings, and generalizing the image. It leaves the plain templates alone and produces a second set at VMID plus 100, so Debian 12 at 802 gains a customized twin at 902. It needs a Proxmox API token and adds real time to the build. Answer No for plain templates, which is all you need if you configure VMs after cloning."
            ;;
        vmid_base)
            echo "Every VM in Proxmox has a numeric ID, and PACT assigns them by adding a fixed offset to this base. With the default base of 800 you get Debian 12 at 802 and Ubuntu 24.04 at 811. Change it if 800-830 is already occupied on your cluster - pick a free block, for example 700 or 900. It must be a plain number and needs enough room above it for every distro you selected."
            ;;
        remote)
            echo "This asks where the templates get built. If you are running this script on your laptop or workstation, the Proxmox server is remote and PACT connects over SSH to do the work. If you are already sitting on the Proxmox host itself - a shell on the node - then it is local and no SSH is needed. PACT checks for Proxmox on this machine and defaults accordingly, so the offered default is usually right."
            ;;
        proxmox_host)
            echo "The hostname or IP address PACT connects to over SSH. Use whatever you would type into 'ssh' yourself, for example pve.local, proxmox.lan, or 192.168.1.50. On a cluster, point it at the specific node you want the templates created on - templates live on the node that builds them unless your storage is shared."
            ;;
        ssh_user)
            echo "The account PACT logs in as on the Proxmox host. This needs to be root, or a user allowed to run the 'qm' commands that create VMs and templates - in practice that means root on most Proxmox installs. It is the same user you would use for a normal SSH session to the node."
            ;;
        ssh_key)
            echo "The path to your SSH private key, for example ~/.ssh/id_ed25519. Give a path here and PACT authenticates with the key. Leave it blank and it will ask for a password instead. A key is the smoother option because it also avoids needing sshpass installed. Note this is the private key - the file without the .pub extension."
            ;;
        ssh_password)
            echo "The SSH password for the account you just named on the Proxmox host. It is not echoed as you type and it is never written to disk or printed in the build summary - it is held only for this run. PACT needs the sshpass tool for password authentication and will install it if it is missing. An SSH key avoids both the prompt and that dependency."
            ;;
        storage)
            echo "The Proxmox storage pool that holds the template disks. The default local-lvm exists on a standard single-node install. If you use ZFS, Ceph, or a NAS, name that pool instead - local-zfs, ceph-vm, and so on. Whatever you pick has to allow disk images, and 'pvesm status' on the host lists the pools you have."
            ;;
        rebuild)
            echo "This decides what happens when a VMID you are about to build is already taken. Answer Yes and PACT deletes the existing VM or template at that ID first, then builds fresh - this destroys whatever is there, so be certain those IDs hold old templates and not VMs you care about. Answer No and the build stops on a conflict instead, which is the safe choice."
            ;;
        token_id)
            echo "Packer talks to the Proxmox API rather than using SSH, so it needs an API token. The ID looks like root@pam!packer - the user, then an exclamation mark, then the token name. You create it in the Proxmox UI under Datacenter, Permissions, API Tokens. Give it privileges on the storage and VMs, and uncheck Privilege Separation unless you plan to assign permissions to the token yourself."
            ;;
        token_secret)
            echo "The secret half of that API token - a UUID that Proxmox shows exactly once, when you create the token. If you did not save it, there is no way to read it back; create a new token instead. It is not echoed as you type and is never written to disk or printed in the summary."
            ;;
        target_node)
            echo "The name of the Proxmox node Packer builds on - the short name shown in the left-hand tree of the web UI, usually 'pve' on a single-node install. On a cluster this must match the node exactly, and it should be the node whose storage pool you named earlier."
            ;;
        custom_playbook)
            echo "Your own Ansible playbook, run against each image instead of the built-in one - this is how you make the templates truly yours, installing your packages and dropping in your config. Give a local path or a URL to a raw file, for example a GitHub raw link. Leave it blank to use the playbook that ships with PACT. There is a working example in the repo's examples/playbooks directory."
            ;;
        custom_varfile)
            echo "A YAML file of variables for the playbook - the usual way to keep the playbook itself generic and put your specifics, like a package list or a timezone, in one place. Give a local path or a URL. Leave it blank to use the default variables that ship with PACT, and see examples/playbooks for the format."
            ;;
        custom_packerfile)
            echo "Your own Packer template, replacing the universal one PACT ships. This is the advanced escape hatch - change it when you need different VM hardware, a different provisioner, or extra build steps. Give a local path or a URL. Leave it blank unless you have a specific reason, because your template has to accept the same variables PACT passes in."
            ;;
        answerfile)
            echo "An answerfile is a plain file of KEY=value settings that replaces this whole interview - handy once you have a configuration you want to repeat or share. Give a local path or a URL to one. PACT already reads .env.local from the repo automatically, so you only need this to point somewhere else. There are ready-made examples in the repo's examples/answerfiles directory."
            ;;
        interactive_gate)
            echo "No configuration was found, so PACT is offering to walk you through the settings one question at a time - that is interactive mode, and it is the easiest way to start. Answer No if you would rather point at an answerfile you already have. You can get this guided interview at any time by running the script with --interactive."
            ;;
        *)
            echo "There is no extra help written for this question yet. Press Enter to take the default shown in the prompt, or check the README and wiki for the full reference on every setting."
            ;;
    esac
}

# Print the penguin explaining one help topic.
penguin_say() {
    penguin_speak "$(penguin_help_text "$1")"
}

#####################################################################################
################### PROMPT WRAPPERS ("?" AWARE)
#####################################################################################

# Format the "(? for help)" hint appended to every prompt.
tui_hint() {
    printf '%s[? for help]%s' "$C_DIM" "$C_RESET"
}

# ask VAR "Prompt text" "default" "help-topic"
# Reads a line into VAR. "?" prints the penguin's explanation and re-asks.
# An empty answer yields the default. The default is shown in the prompt when set.
ask() {
    local __var="$1" prompt="$2" default="${3:-}" topic="${4:-}"
    local answer suffix=""
    [ -n "$default" ] && suffix=" ${C_DIM}[${default}]${C_RESET}"

    while true; do
        printf '\n  %s%s%s%s  %s\n' "$C_BOLD" "$prompt" "$C_RESET" "$suffix" "$(tui_hint)"
        printf '  %s>%s ' "$C_GREEN" "$C_RESET"
        IFS= read -r answer || answer=""
        case "$answer" in
            '?'|'help'|'h')
                penguin_say "$topic"
                continue
                ;;
        esac
        [ -z "$answer" ] && answer="$default"
        printf -v "$__var" '%s' "$answer"
        return 0
    done
}

# ask_secret VAR "Prompt text" "help-topic"
# Same as ask, but the input is not echoed. There is no default: an empty answer
# stays empty, which every caller treats as "skip".
ask_secret() {
    local __var="$1" prompt="$2" topic="${3:-}"
    local answer

    while true; do
        printf '\n  %s%s%s  %s\n' "$C_BOLD" "$prompt" "$C_RESET" "$(tui_hint)"
        printf '  %s>%s ' "$C_GREEN" "$C_RESET"
        IFS= read -rs answer || answer=""
        echo ""
        case "$answer" in
            '?'|'help'|'h')
                penguin_say "$topic"
                continue
                ;;
        esac
        printf -v "$__var" '%s' "$answer"
        return 0
    done
}

# ask_yesno VAR "Prompt text" "Y"|"N" "help-topic"
# Sets VAR to the string "true" or "false" so callers can use it directly as a
# boolean flag. The third argument is the default taken on an empty answer.
ask_yesno() {
    local __var="$1" prompt="$2" default="${3:-N}" topic="${4:-}"
    local answer hint

    if [ "$default" = "Y" ] || [ "$default" = "y" ]; then
        hint="${C_DIM}[Y/n]${C_RESET}"
    else
        hint="${C_DIM}[y/N]${C_RESET}"
    fi

    while true; do
        printf '\n  %s%s%s %s  %s\n' "$C_BOLD" "$prompt" "$C_RESET" "$hint" "$(tui_hint)"
        printf '  %s>%s ' "$C_GREEN" "$C_RESET"
        IFS= read -r answer || answer=""
        case "$answer" in
            '?'|'help'|'h')
                penguin_say "$topic"
                continue
                ;;
            '')
                if [ "$default" = "Y" ] || [ "$default" = "y" ]; then
                    printf -v "$__var" 'true'
                else
                    printf -v "$__var" 'false'
                fi
                return 0
                ;;
            [Yy]|[Yy][Ee][Ss])
                printf -v "$__var" 'true'
                return 0
                ;;
            [Nn]|[Nn][Oo])
                printf -v "$__var" 'false'
                return 0
                ;;
            *)
                tui_warn "Please answer y or n (or ? for help)."
                ;;
        esac
    done
}
