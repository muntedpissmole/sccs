#!/usr/bin/env bash
# SCCS installer & setup utility
#
#   sudo ./install.sh              # interactive menu
#   sudo ./install.sh --install    # Install SCCS
#   sudo ./install.sh --update     # git pull + deps (keeps sccs.conf)
#   sudo ./install.sh --esp        # ESP32 flash only
#   sudo ./install.sh --victron    # Victron only
#   sudo ./install.sh --sensors    # 1-Wire only
#   sudo ./install.sh --lan        # LAN / DHCP / NAT only
#   sudo ./install.sh --usb-tether # Guided phone USB internet
#   sudo ./install.sh --screens    # Touchscreen SSH / blank setup
#   sudo ./install.sh --service    # rewrite/restart systemd unit
#   sudo ./install.sh --help
#
# Safe to re-run: never replaces an existing config/sccs.conf; only updates
# keys you choose to set. UART/GPIO mapping is fixed by the PCB + stock config.
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (PCB-fixed — not prompted)
# ---------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/muntedpissmole/pccs5.git}"
SERVICE_NAME="${SERVICE_NAME:-sccs}"
LAN_ADDR="${LAN_ADDR:-10.10.10.1}"
ESP_FQBN="${ESP_FQBN:-esp32:esp32:esp32s3}"
W1_GPIO="${W1_GPIO:-3}"

# ---------------------------------------------------------------------------
# Colours (subtle; disabled when not a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_WHITE=$'\033[37m'
else
    C_RESET= C_BOLD= C_DIM= C_GREEN= C_YELLOW= C_RED=
    C_CYAN= C_BLUE= C_MAGENTA= C_WHITE=
fi

STEP=0
TOTAL_STEPS=0
NEED_REBOOT=0
GROUPS_CHANGED=0
SKIPPED_NOTES=()
REQUIRED_GROUPS=(www-data tty dialout gpio netdev)
RUN_MODE="menu"   # menu | install | sensors | esp | victron | lan | screens | service

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
logo() {
    echo
    echo "${C_CYAN}${C_BOLD}"
    cat <<'EOF'
  ██████╗   ██████╗  ██████╗ ███████╗
  ██╔══██╗ ██╔════╝ ██╔════╝ ██╔════╝
  ██████╔╝ ██║      ██║      ███████╗
  ██╔═══╝  ██║      ██║      ╚════██║
  ██║      ╚██████╗ ╚██████╗ ███████║
  ╚═╝       ╚═════╝  ╚═════╝ ╚══════╝
EOF
    echo "${C_RESET}${C_DIM}     Singularity Camper Control System${C_RESET}"
    echo "${C_DIM}     ──────────────────────────────${C_RESET}"
    echo
}

hr() {
    echo "${C_DIM}  ────────────────────────────────────────────────────────${C_RESET}"
}

section_title() {
    echo
    echo "${C_BOLD}${C_CYAN}  ▸ $*${C_RESET}"
    hr
}

step_begin() {
    STEP=$((STEP + 1))
    echo
    if [[ "$TOTAL_STEPS" -gt 0 ]]; then
        echo "${C_BOLD}${C_BLUE}  [$STEP/$TOTAL_STEPS]${C_RESET} ${C_BOLD}$*${C_RESET}"
    else
        echo "${C_BOLD}${C_BLUE}  ›${C_RESET} ${C_BOLD}$*${C_RESET}"
    fi
    echo "${C_DIM}  ────────────────────────────────────────────────────────${C_RESET}"
}

info()      { echo "  ${C_DIM}•${C_RESET} $*"; }
ok()        { echo "  ${C_GREEN}✓${C_RESET} $*"; }
warn()      { echo "  ${C_YELLOW}!${C_RESET} $*"; }
fail()      { echo "  ${C_RED}✗${C_RESET} $*" >&2; }
die()       { fail "$*"; exit 1; }
skip_note() { SKIPPED_NOTES+=("$*"); warn "$*"; }

ask_yn() {
    local prompt="$1" def="${2:-n}" hint
    if [[ "$def" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        read -r -p "  ${prompt} [${hint}]: " ans || true
        ans="${ans:-$def}"
        case "${ans,,}" in
            y|yes) REPLY=y; return 0 ;;
            n|no)  REPLY=n; return 0 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

pause_enter() {
    read -r -p "  ${C_DIM}Press Enter to continue…${C_RESET} " _ || true
}

run_as_user() {
    sudo -u "$USERNAME" -H -- "$@"
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo
        fail "This script must be run as root."
        echo "  ${C_DIM}Try:${C_RESET}  ${C_BOLD}sudo $0 $*${C_RESET}"
        echo
        exit 1
    fi
}

show_context() {
    echo "  ${C_DIM}User${C_RESET}     ${C_BOLD}${USERNAME}${C_RESET}"
    echo "  ${C_DIM}Install${C_RESET}  ${C_BOLD}${SCCS_HOME}${C_RESET}"
    echo "  ${C_DIM}LAN IP${C_RESET}   ${C_BOLD}${LAN_ADDR}${C_RESET}"
    echo "  ${C_DIM}Service${C_RESET}  ${C_BOLD}${SERVICE_NAME}.service${C_RESET}"
    if [[ -f "$CONF" ]]; then
        echo "  ${C_DIM}Config${C_RESET}   ${C_GREEN}present${C_RESET}  ${C_DIM}(will not be replaced)${C_RESET}"
    else
        echo "  ${C_DIM}Config${C_RESET}   ${C_YELLOW}missing${C_RESET}  ${C_DIM}(created on install)${C_RESET}"
    fi
    echo
}

# ---------------------------------------------------------------------------
# Config helpers (preserve comments; never rewrite whole file)
# ---------------------------------------------------------------------------
conf_get() {
    local section="$1" key="$2"
    [[ -f "$CONF" ]] || { echo ""; return 0; }
    python3 - "$CONF" "$section" "$key" <<'PY'
import configparser, sys
path, section, key = sys.argv[1:4]
c = configparser.ConfigParser()
c.read(path)
print(c.get(section, key, fallback="").strip())
PY
}

conf_set() {
    local section="$1"
    shift
    [[ -f "$CONF" ]] || die "No config at $CONF — run Install SCCS first"
    python3 - "$CONF" "$section" "$@" <<'PY'
import re, sys
path = sys.argv[1]
section = sys.argv[2]
pairs = list(zip(sys.argv[3::2], sys.argv[4::2]))
text = open(path, encoding="utf-8").read()
sec_pat = re.compile(rf"(?ms)^(\[{re.escape(section)}\][^\[]*)")
m = sec_pat.search(text)
if not m:
    sys.exit(f"section [{section}] not found in {path}")
block = m.group(1)
for key, value in pairs:
    if value is None:
        continue
    # Spaces/tabs only — \s would eat newlines and the next key.
    # Lambda replacement so MAC ":" is never a re escape.
    pat = re.compile(rf"(?m)^({re.escape(key)}[ \t]*=[ \t]*)(.*)$")
    if not pat.search(block):
        sys.exit(f"key {key} not found in [{section}]")
    block = pat.sub(lambda mo, v=value: mo.group(1) + v, block, count=1)
text = text[: m.start(1)] + block + text[m.end(1) :]
open(path, "w", encoding="utf-8").write(text)
PY
    chown "$USERNAME":www-data "$CONF" 2>/dev/null || true
}

normalize_mac() {
    local raw="${1// /}"
    raw="${raw,,}"
    if [[ "$raw" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
        printf '%s' "$raw"; return 0
    fi
    if [[ "$raw" =~ ^[0-9a-f]{12}$ ]]; then
        printf '%s' "${raw:0:2}:${raw:2:2}:${raw:4:2}:${raw:6:2}:${raw:8:2}:${raw:10:2}"
        return 0
    fi
    return 1
}

normalize_victron_key() {
    local raw="${1// /}"
    raw="${raw,,}"
    raw="${raw#0x}"
    [[ "$raw" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf '%s' "$raw"
}

require_checkout() {
    [[ -f "$SCCS_HOME/app.py" && -f "$SCCS_HOME/requirements.txt" ]] \
        || die "SCCS checkout not found at $SCCS_HOME — choose Install SCCS first"
    CONF="$SCCS_HOME/config/sccs.conf"
    CONF_DIST="$SCCS_HOME/config/sccs.conf.dist"
    [[ -f "$CONF_DIST" ]] || die "Missing $CONF_DIST"
}

require_conf() {
    require_checkout
    [[ -f "$CONF" ]] || die "Missing $CONF — choose Install SCCS first"
}

# True when running on a Raspberry Pi 5 (device-tree model string).
is_raspberry_pi5() {
    local model=""
    if [[ -r /proc/device-tree/model ]]; then
        model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
    fi
    [[ "${model,,}" == *"raspberry pi 5"* ]]
}

# Ensure key=value exists under [section] in $CONFIG_TXT. Returns 0 if changed.
ensure_boot_config_kv() {
    local section="$1" key="$2" value="$3" line="${2}=${3}"
    [[ -n "${CONFIG_TXT:-}" && -f "$CONFIG_TXT" ]] || return 1

    if grep -qE "^${key}=${value}$" "$CONFIG_TXT"; then
        info "Already present: ${line}"
        return 1
    fi

    if grep -qE "^${key}=" "$CONFIG_TXT"; then
        # Update any existing assignment (section-agnostic — power keys are global).
        sed -i -E "s|^${key}=.*$|${line}|" "$CONFIG_TXT"
        ok "Updated ${line} in ${CONFIG_TXT}"
        return 0
    fi

    if grep -qE "^\[${section}\]" "$CONFIG_TXT"; then
        awk -v sec="[${section}]" -v line="$line" '
            BEGIN { done = 0 }
            $0 == sec {
                print
                if (!done) { print line; done = 1 }
                next
            }
            { print }
            END {
                if (!done) {
                    print sec
                    print line
                }
            }
        ' "$CONFIG_TXT" >"${CONFIG_TXT}.sccs.tmp" && mv "${CONFIG_TXT}.sccs.tmp" "$CONFIG_TXT"
    else
        printf '\n[%s]\n%s\n' "$section" "$line" >>"$CONFIG_TXT"
    fi
    ok "Enabled ${line} under [${section}]"
    return 0
}

# Pi 5 powered via the PCB 5V rail (not USB-C PD) cannot negotiate 5A.
# Force a 5A PSU declaration in bootloader EEPROM + full USB current in config.txt.
ensure_pi5_5a_power() {
    info "Raspberry Pi 5 detected — power is on the 5V pin (no USB-PD negotiation)"

    local changed=0
    if [[ -n "${CONFIG_TXT:-}" && -f "$CONFIG_TXT" ]]; then
        # Full USB bus current (1.6A) instead of the 600mA non-PD default.
        if ensure_boot_config_kv pi5 usb_max_current_enable 1; then
            changed=1
            NEED_REBOOT=1
        fi
    else
        warn "config.txt not found — cannot set usb_max_current_enable"
    fi

    if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
        warn "rpi-eeprom-config not found — cannot set PSU_MAX_CURRENT=5000"
        warn "Install raspberrypi-eeprom (or reboot after packages) and re-run install"
        return 0
    fi

    local current_psu
    current_psu="$(rpi-eeprom-config 2>/dev/null | grep -E '^PSU_MAX_CURRENT=' | tail -n1 || true)"
    if [[ "$current_psu" == "PSU_MAX_CURRENT=5000" ]]; then
        info "Bootloader EEPROM already has PSU_MAX_CURRENT=5000"
        [[ "$changed" -eq 1 ]] && ok "Pi 5 5A power config updated (reboot required)" \
            || ok "Pi 5 5A power config already applied"
        return 0
    fi

    local eeprom_conf
    eeprom_conf="$(mktemp)"
    if ! rpi-eeprom-config >"$eeprom_conf" 2>/dev/null; then
        rm -f "$eeprom_conf"
        warn "Could not read bootloader EEPROM config — skipped PSU_MAX_CURRENT"
        return 0
    fi

    if grep -qE '^PSU_MAX_CURRENT=' "$eeprom_conf"; then
        sed -i -E 's/^PSU_MAX_CURRENT=.*$/PSU_MAX_CURRENT=5000/' "$eeprom_conf"
    else
        # Keep a trailing newline; append the override.
        printf 'PSU_MAX_CURRENT=5000\n' >>"$eeprom_conf"
    fi

    if rpi-eeprom-config --apply "$eeprom_conf"; then
        ok "Bootloader EEPROM: PSU_MAX_CURRENT=5000 (scheduled — reboot applies it)"
        NEED_REBOOT=1
    else
        warn "Failed to apply PSU_MAX_CURRENT=5000 via rpi-eeprom-config"
    fi
    rm -f "$eeprom_conf"
}

# ---------------------------------------------------------------------------
# Identity / paths
# ---------------------------------------------------------------------------
resolve_identity() {
    # Prefer explicit USERNAME=, then the user who invoked sudo (whoami of the real session).
    if [[ -z "${USERNAME:-}" ]]; then
        if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            USERNAME="$SUDO_USER"
        elif [[ -n "${LOGNAME:-}" && "${LOGNAME}" != "root" ]]; then
            USERNAME="$LOGNAME"
        else
            die "Set USERNAME to your login (e.g. sudo env USERNAME=\$(whoami) $0)"
        fi
    fi
    id "$USERNAME" &>/dev/null || die "User '$USERNAME' does not exist"

    USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
    SCCS_HOME="${SCCS_HOME:-$USER_HOME/sccs}"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # install.sh lives at the repo root
    if [[ -f "$SCRIPT_DIR/app.py" && -f "$SCRIPT_DIR/requirements.txt" ]]; then
        SCCS_HOME="$SCRIPT_DIR"
    fi

    CONF="$SCCS_HOME/config/sccs.conf"
    CONF_DIST="$SCCS_HOME/config/sccs.conf.dist"
    CONFIG_TXT=""
    for candidate in /boot/firmware/config.txt /boot/config.txt; do
        [[ -f "$candidate" ]] && { CONFIG_TXT="$candidate"; break; }
    done
}

# ===========================================================================
# Steps
# ===========================================================================

step_packages() {
    step_begin "System packages"
    info "apt update + upgrade (this can take a while)…"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    info "Installing required packages…"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        nginx samba samba-common-bin \
        python3-venv python3-lgpio \
        git network-manager nftables \
        usbmuxd libimobiledevice-utils ipheth-utils \
        bluez curl \
        avahi-daemon libavahi-compat-libdnssd1 avahi-utils \
        nodejs
    systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
    ok "Packages installed"
}

step_groups_and_dirs() {
    step_begin "User groups and project directory"
    mkdir -p "$SCCS_HOME"
    for g in "${REQUIRED_GROUPS[@]}"; do
        if getent group "$g" >/dev/null 2>&1; then
            if id -nG "$USERNAME" | tr ' ' '\n' | grep -qx "$g"; then
                info "Already in group: $g"
            else
                usermod -aG "$g" "$USERNAME"
                ok "Added $USERNAME to $g"
                GROUPS_CHANGED=1
                NEED_REBOOT=1
            fi
        else
            warn "Group '$g' not present on this OS — skipped"
        fi
    done
    chown -R "$USERNAME":www-data "$SCCS_HOME"
    find "$SCCS_HOME" -type d -exec chmod 2775 {} +
    find "$SCCS_HOME" -type f -exec chmod ug+rw {} + 2>/dev/null || true
    [[ -f "$SCCS_HOME/install.sh" ]] && chmod ug+x "$SCCS_HOME/install.sh" || true
    ok "Ownership ${USERNAME}:www-data on $SCCS_HOME"
    # nginx (www-data) must traverse $USER_HOME to serve $SCCS_HOME/static/.
    # o+x allows traverse only — not listing (home stays non-listable for others).
    if [[ -d "$USER_HOME" ]]; then
        local home_mode
        home_mode="$(stat -c '%a' "$USER_HOME" 2>/dev/null || echo '')"
        if [[ -n "$home_mode" && "$((8#$home_mode & 8#001))" -eq 0 ]]; then
            chmod o+x "$USER_HOME"
            ok "Added other-execute on $USER_HOME (nginx can reach static files)"
        else
            info "Home already traversable by others: $USER_HOME"
        fi
    fi
    if [[ "$GROUPS_CHANGED" -eq 1 ]]; then
        warn "New groups apply to new logins and to systemd after the next service start."
    fi
}

step_repo() {
    step_begin "Repository"
    if [[ -f "$SCCS_HOME/app.py" && -f "$SCCS_HOME/requirements.txt" ]]; then
        ok "Repository already present at $SCCS_HOME"
        if [[ -d "$SCCS_HOME/.git" ]]; then
            info "git remote: $(run_as_user git -C "$SCCS_HOME" remote get-url origin 2>/dev/null || echo unknown)"
        fi
    else
        info "Cloning $REPO_URL → $SCCS_HOME"
        mkdir -p "$SCCS_HOME"
        chown "$USERNAME":www-data "$SCCS_HOME" 2>/dev/null || chown "$USERNAME" "$SCCS_HOME"
        # Empty dir is fine (bootstrap: mkdir then run install from /tmp).
        # Non-empty non-checkout is a hard stop so we never clobber random files.
        if [[ -n "$(ls -A "$SCCS_HOME" 2>/dev/null || true)" ]]; then
            die "$SCCS_HOME is not empty and is not a SCCS checkout — move it aside or set SCCS_HOME"
        fi
        run_as_user git clone "$REPO_URL" "$SCCS_HOME"
        chown -R "$USERNAME":www-data "$SCCS_HOME"
        ok "Cloned repository"
    fi
    CONF="$SCCS_HOME/config/sccs.conf"
    CONF_DIST="$SCCS_HOME/config/sccs.conf.dist"
    [[ -f "$CONF_DIST" ]] || die "Missing $CONF_DIST — incomplete checkout?"
}

step_samba() {
    step_begin "Samba share [sccs]"
    # Always (re)write the share so force user matches the installing login (whoami / SUDO_USER).
    info "Installing [sccs] share for user ${C_BOLD}${USERNAME}${C_RESET} → $SCCS_HOME"
    python3 - "$SCCS_HOME" "$USERNAME" <<'PY'
import re, sys
path_home, user = sys.argv[1], sys.argv[2]
smb = "/etc/samba/smb.conf"
text = open(smb, encoding="utf-8").read()
# Drop any existing [sccs] section (until next [section] or EOF)
text = re.sub(
    r"(?ms)^\s*\[sccs\]\s*\n.*?(?=^\s*\[|\Z)",
    "",
    text,
)
block = f"""
[sccs]
    path = {path_home}
    writable = yes
    browsable = yes
    public = no
    valid users = {user}
    write list = {user}
    force user = {user}
    force group = www-data
    create mask = 0664
    force create mode = 0664
    directory mask = 0775
    force directory mode = 2775
    hide dot files = no
"""
if not text.endswith("\n"):
    text += "\n"
open(smb, "w", encoding="utf-8").write(text.rstrip() + "\n" + block)
print("wrote [sccs]")
PY
    ok "force user = $USERNAME  (force group = www-data)"
    testparm -s >/dev/null 2>&1 && ok "smb.conf syntax OK" || warn "testparm reported issues"
    ask_yn "Set or update Samba password for '$USERNAME'?" y
    if [[ "$REPLY" == "y" ]]; then
        smbpasswd -a "$USERNAME" && ok "Samba user configured" \
            || warn "smbpasswd failed — sudo smbpasswd -a $USERNAME"
    else
        skip_note "Samba password left unchanged"
    fi
    systemctl enable --now smbd nmbd >/dev/null 2>&1 || systemctl restart smbd nmbd
    ok "smbd/nmbd running"
}

step_nginx() {
    step_begin "nginx reverse proxy (port 80 → 5000)"
    cat >/etc/nginx/sites-available/sccs <<EOF
server {
    listen 80;
    server_name _;
    root $SCCS_HOME;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }

    # Served from \$document_root/static/ (root above). Do not pair alias with
    # try_files — that combination often 404s. Requires o+x on the user home
    # so www-data can traverse to this tree (set in step_groups_and_dirs).
    location /static/ {
        expires 30d;
        add_header Cache-Control "public";
        access_log off;
    }
}
EOF
    ln -sfn /etc/nginx/sites-available/sccs /etc/nginx/sites-enabled/sccs
    rm -f /etc/nginx/sites-enabled/default
    nginx -t 2>/dev/null || die "nginx -t failed"
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
    ok "nginx configured and restarted"
}

step_venv() {
    step_begin "Python virtualenv and dependencies"
    if [[ ! -d "$SCCS_HOME/venv" ]]; then
        info "Creating venv with --system-site-packages (for python3-lgpio)…"
        run_as_user python3 -m venv --system-site-packages "$SCCS_HOME/venv"
        ok "venv created"
    else
        ok "venv already exists"
    fi
    info "pip install --upgrade (latest) -r requirements.txt…"
    run_as_user "$SCCS_HOME/venv/bin/pip" install --upgrade pip
    run_as_user "$SCCS_HOME/venv/bin/pip" install --upgrade --upgrade-strategy eager -r "$SCCS_HOME/requirements.txt"
    ok "Python packages installed"
}

step_config() {
    step_begin "Application config"
    if [[ ! -f "$CONF" ]]; then
        run_as_user cp "$CONF_DIST" "$CONF"
        ok "Created $CONF from sccs.conf.dist"
    else
        ok "Keeping existing $CONF (not overwritten)"
    fi
    local secret
    secret="$(conf_get system secret_key)"
    if [[ -z "$secret" || "$secret" == "CHANGE_ME_TO_A_LONG_RANDOM_STRING" ]]; then
        conf_set system secret_key "$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
        ok "Generated system.secret_key"
    else
        ok "secret_key already set (left unchanged)"
    fi
}

# mode: optional (full install — may skip) | required (menu path — configure now)
step_sensors() {
    local mode="${1:-optional}"
    step_begin "1-Wire temperature sensors"
    require_conf

    modprobe w1-gpio 2>/dev/null || true
    modprobe w1-therm 2>/dev/null || true
    mapfile -t W1_IDS < <(ls /sys/bus/w1/devices/ 2>/dev/null | grep '^28' || true)

    local cur_out cur_fridge cur_freezer
    cur_out="$(conf_get sensors outside_temp_sensor)"
    cur_fridge="$(conf_get sensors fridge_temp_sensor)"
    cur_freezer="$(conf_get sensors freezer_temp_sensor)"
    if [[ -n "$cur_out$cur_fridge$cur_freezer" ]]; then
        info "Current: ambient=${cur_out:-∅}  fridge=${cur_fridge:-∅}  freezer=${cur_freezer:-∅}"
    fi

    read_w1_temp() {
        local id="$1" raw t
        raw="$(cat "/sys/bus/w1/devices/${id}/w1_slave" 2>/dev/null || true)"
        if [[ "$raw" == *"YES"* ]]; then
            t="$(echo "$raw" | sed -n 's/.*t=\([-0-9]*\).*/\1/p' | tail -1)"
            if [[ -n "$t" ]]; then
                python3 -c "print(f'{int($t)/1000:.1f}°C')" 2>/dev/null || echo "${t} m°C"
                return
            fi
        fi
        echo "n/a"
    }

    local do_assign=0
    if [[ ${#W1_IDS[@]} -eq 0 ]]; then
        warn "No DS18B20 devices under /sys/bus/w1/devices/"
        if [[ "$mode" == "optional" ]]; then
            skip_note "1-Wire skipped — no sensors detected (configure later from the menu)"
        else
            warn "Wire sensors / reboot after overlays, then try again"
        fi
        return 0
    fi

    echo
    info "Detected ${#W1_IDS[@]} sensor(s):"
    local i id temp
    for i in "${!W1_IDS[@]}"; do
        id="${W1_IDS[$i]}"
        temp="$(read_w1_temp "$id")"
        printf "  ${C_BOLD}[%d]${C_RESET}  %s   ${C_CYAN}%s${C_RESET}\n" "$((i + 1))" "$id" "$temp"
    done
    echo

    if [[ "$mode" == "optional" ]]; then
        ask_yn "Assign sensors to ambient / fridge / freezer now?" y
        [[ "$REPLY" == "y" ]] && do_assign=1
    else
        do_assign=1
    fi

    if [[ "$do_assign" -ne 1 ]]; then
        skip_note "1-Wire assignment skipped"
        return 0
    fi

    info "ambient → outside_temp_sensor · fridge → fridge_temp_sensor · freezer → freezer_temp_sensor"
    info "Only roles you assign are written; others keep existing values."

    declare -A ROLE_FOR=()
    local used_ambient=0 used_fridge=0 used_freezer=0 choice

    for id in "${W1_IDS[@]}"; do
        temp="$(read_w1_temp "$id")"
        while true; do
            echo
            echo "  Sensor ${C_BOLD}${id}${C_RESET} (${temp})"
            read -r -p "    [a] ambient  [f] fridge  [z] freezer  [s] skip  — " choice || true
            case "${choice,,}" in
                a|ambient)
                    [[ "$used_ambient" -eq 1 ]] && { warn "ambient already assigned"; continue; }
                    ROLE_FOR[ambient]="$id"; used_ambient=1; ok "ambient ← $id"; break ;;
                f|fridge)
                    [[ "$used_fridge" -eq 1 ]] && { warn "fridge already assigned"; continue; }
                    ROLE_FOR[fridge]="$id"; used_fridge=1; ok "fridge ← $id"; break ;;
                z|freezer)
                    [[ "$used_freezer" -eq 1 ]] && { warn "freezer already assigned"; continue; }
                    ROLE_FOR[freezer]="$id"; used_freezer=1; ok "freezer ← $id"; break ;;
                s|skip|"") info "skipped $id"; break ;;
                *) echo "    Enter a, f, z, or s." ;;
            esac
        done
    done

    local set_args=()
    [[ -n "${ROLE_FOR[ambient]:-}" ]] && set_args+=(outside_temp_sensor "${ROLE_FOR[ambient]}")
    [[ -n "${ROLE_FOR[fridge]:-}" ]] && set_args+=(fridge_temp_sensor "${ROLE_FOR[fridge]}")
    [[ -n "${ROLE_FOR[freezer]:-}" ]] && set_args+=(freezer_temp_sensor "${ROLE_FOR[freezer]}")
    if [[ ${#set_args[@]} -gt 0 ]]; then
        conf_set sensors "${set_args[@]}"
        ok "Updated [sensors] (other config unchanged)"
    else
        info "No roles chosen — sensor config left unchanged"
    fi
}

step_boot_firmware() {
    step_begin "Pi boot firmware (UART · 1-Wire · Bluetooth · power)"
    # Fixed SCCS mapping — no user choices
    if [[ -z "${CONFIG_TXT:-}" ]]; then
        warn "config.txt not found — cannot enable overlays automatically"
    else
        cp -a "$CONFIG_TXT" "${CONFIG_TXT}.bak.sccs.$(date +%Y%m%d%H%M%S)"
        local changed_cfg=0 ov w1_line

        if ! grep -qE '^\[pi4\]' "$CONFIG_TXT"; then
            printf '\n[pi4]\n' >>"$CONFIG_TXT"
            changed_cfg=1
        fi
        for ov in uart2 uart3 uart4; do
            if ! grep -qE "^dtoverlay=${ov}\b" "$CONFIG_TXT"; then
                awk -v ov="dtoverlay=${ov}" '
                    BEGIN { done=0 }
                    /^\[pi4\]/ { print; if (!done) { print ov; done=1 } next }
                    { print }
                    END { if (!done) { print "[pi4]"; print ov } }
                ' "$CONFIG_TXT" >"${CONFIG_TXT}.sccs.tmp" && mv "${CONFIG_TXT}.sccs.tmp" "$CONFIG_TXT"
                ok "Enabled dtoverlay=${ov}"
                changed_cfg=1
                NEED_REBOOT=1
            else
                info "Already present: dtoverlay=${ov}"
            fi
        done

        w1_line="dtoverlay=w1-gpio,gpiopin=${W1_GPIO}"
        if ! grep -qE "dtoverlay=w1-gpio" "$CONFIG_TXT"; then
            if grep -qE '^\[all\]' "$CONFIG_TXT"; then
                awk -v line="$w1_line" '
                    BEGIN { done=0 }
                    /^\[all\]/ && !done { print; print line; done=1; next }
                    { print }
                    END { if (!done) print line }
                ' "$CONFIG_TXT" >"${CONFIG_TXT}.sccs.tmp" && mv "${CONFIG_TXT}.sccs.tmp" "$CONFIG_TXT"
            else
                printf '\n[all]\n%s\n' "$w1_line" >>"$CONFIG_TXT"
            fi
            ok "Enabled $w1_line"
            changed_cfg=1
            NEED_REBOOT=1
        else
            info "Already present: w1-gpio overlay"
        fi

        [[ "$changed_cfg" -eq 0 ]] && ok "Boot overlays already match SCCS defaults" \
            || ok "Updated $CONFIG_TXT (reboot required for new devices)"
    fi

    local cmdline="" before after
    for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
        [[ -f "$candidate" ]] && { cmdline="$candidate"; break; }
    done
    if [[ -z "$cmdline" ]]; then
        warn "cmdline.txt not found"
    else
        before="$(cat "$cmdline")"
        after="$(echo "$before" | sed -E 's/\s*console=serial0,[0-9]+\s*/ /g; s/\s*console=ttyAMA0,[0-9]+\s*/ /g; s/  +/ /g; s/^ //; s/ $//')"
        if [[ "$before" != "$after" ]]; then
            cp -a "$cmdline" "${cmdline}.bak.sccs"
            printf '%s\n' "$after" >"$cmdline"
            ok "Freed primary UART for Bluetooth"
            NEED_REBOOT=1
        else
            ok "Primary UART already free for Bluetooth"
        fi
    fi

    # SCCS board feeds the Pi from the 5V rail, so USB-C PD never negotiates 5A.
    if is_raspberry_pi5; then
        ensure_pi5_5a_power
    else
        info "Not a Raspberry Pi 5 — skipping 5A power supply override"
    fi
}

ensure_arduino_cli() {
    export PATH="/usr/local/bin:${PATH}"
    if command -v arduino-cli >/dev/null 2>&1; then
        ok "arduino-cli: $(command -v arduino-cli)"
        return 0
    fi
    info "Installing arduino-cli to /usr/local/bin…"
    curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh \
        | BINDIR=/usr/local/bin sh
    command -v arduino-cli >/dev/null 2>&1 || die "arduino-cli install failed"
    ok "arduino-cli installed"
}

# Returns: 0 = port found (ESP_PORT set), 1 = timeout/fail, 2 = user skip
wait_for_esp_port() {
    local label="$1" tries=0 max_tries=90 ans
    info "Waiting for USB serial (download mode)…" >&2
    info "Type ${C_BOLD}s${C_RESET}${C_DIM} + Enter anytime to skip (no hardware / wrong step).${C_RESET}" >&2
    while (( tries < max_tries )); do
        mapfile -t ports < <(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null | sort || true)
        if [[ ${#ports[@]} -ge 1 ]]; then
            ESP_PORT="${ports[0]}"
            ok "Found ${ESP_PORT} for ${label}" >&2
            return 0
        fi
        tries=$((tries + 1))
        if (( tries % 5 == 1 )); then
            info "No /dev/ttyACM* yet — hold BOOT, tap RESET, release BOOT — or ${C_BOLD}s${C_RESET}${C_DIM} to skip.${C_RESET}" >&2
        fi
        # Interruptible wait: user can type s/skip/q while we poll
        ans=""
        if read -r -t 2 ans 2>/dev/null; then
            case "${ans,,}" in
                s|skip|q|quit|abort)
                    warn "Skip requested — leaving download wait for ${label}" >&2
                    return 2
                    ;;
            esac
        fi
    done
    warn "Timed out waiting for USB serial for ${label}" >&2
    return 1
}

flash_one_esp() {
    local sketch_rel="$1" label="$2"
    local sketch_dir="$SCCS_HOME/$sketch_rel" ans wait_rc
    [[ -d "$sketch_dir" ]] || { warn "Missing $sketch_dir"; return 1; }

    while true; do
        echo
        echo "  ${C_BOLD}${label}${C_RESET} — ${C_CYAN}download mode${C_RESET}:"
        echo "    1. Hold ${C_BOLD}BOOT${C_RESET}"
        echo "    2. Press and release ${C_BOLD}RESET${C_RESET}"
        echo "    3. Release ${C_BOLD}BOOT${C_RESET}"
        echo "    ${C_DIM}(programming USB connected to the SCCS PCB)${C_RESET}"
        echo
        echo "  ${C_YELLOW}!${C_RESET} No ESP / SCCS core on the bench? Type ${C_BOLD}s${C_RESET} to skip this module."
        echo "  ${C_DIM}You can also type s during the USB wait if you started this by mistake.${C_RESET}"
        echo
        read -r -p "  Enter when ready (s = skip module, a = abort all ESP flashing)… " ans || true
        case "${ans,,}" in
            s|skip)
                skip_note "${label} flash skipped"
                return 0
                ;;
            a|abort|q|quit)
                skip_note "ESP flash aborted (remaining modules not attempted)"
                return 2
                ;;
        esac

        ESP_PORT=""
        wait_rc=0
        wait_for_esp_port "$label" || wait_rc=$?
        if [[ "$wait_rc" -eq 2 ]]; then
            skip_note "${label} flash skipped during download wait"
            return 0
        fi
        if [[ "$wait_rc" -ne 0 ]]; then
            ask_yn "Retry ${label}? (n skips this module)" y
            [[ "$REPLY" == "y" ]] && continue
            skip_note "${label} flash abandoned"
            return 0
        fi

        info "Uploading $sketch_rel → $ESP_PORT…"
        if arduino-cli upload -p "$ESP_PORT" --fqbn "$ESP_FQBN" "$sketch_dir"; then
            ok "${label} firmware uploaded"
            sleep 2
            return 0
        fi
        warn "Upload failed for ${label}"
        ask_yn "Retry ${label}?" y
        [[ "$REPLY" == "y" ]] || { skip_note "${label} flash failed"; return 0; }
    done
}

# mode: optional | required
step_esp() {
    local mode="${1:-optional}" flash_rc=0
    step_begin "ESP32 firmware"
    require_checkout

    echo
    warn "Only needed when the SCCS core / ESP32 modules are present."
    info "Test-bench Pi with no PCB? Answer ${C_BOLD}n${C_RESET} below, or ${C_BOLD}s${C_RESET} later to skip a module."
    info "If you start flashing by mistake: type ${C_BOLD}s${C_RESET} during the download wait, or ${C_BOLD}a${C_RESET} to abort all."
    echo

    if [[ "$mode" == "optional" ]]; then
        info "Needs the SCCS PCB, programming USB, and both ESP32 modules."
        ask_yn "Compile and flash both ESP32 modules now?" n
        if [[ "$REPLY" != "y" ]]; then
            skip_note "ESP32 flash skipped — use menu later when hardware is present"
            return 0
        fi
    fi

    ensure_arduino_cli
    info "Arduino ESP32 core (may take several minutes on first run)…"
    run_as_user env PATH="$PATH" arduino-cli core update-index
    run_as_user env PATH="$PATH" arduino-cli core install esp32:esp32
    ok "esp32:esp32 core ready"

    if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        info "Stopping ${SERVICE_NAME}.service during upload…"
        systemctl stop "${SERVICE_NAME}.service" || true
    fi

    info "Compiling sketches…"
    run_as_user env PATH="$PATH" arduino-cli compile --fqbn "$ESP_FQBN" "$SCCS_HOME/esp32/esp32_1"
    ok "Compiled esp32_1"
    run_as_user env PATH="$PATH" arduino-cli compile --fqbn "$ESP_FQBN" "$SCCS_HOME/esp32/esp32_2"
    ok "Compiled esp32_2"

    flash_one_esp "esp32/esp32_1" "ESP32-1 (lighting / water)" || flash_rc=$?
    if [[ "$flash_rc" -eq 2 ]]; then
        warn "Stopped before ESP32-2"
    else
        flash_one_esp "esp32/esp32_2" "ESP32-2 (lighting)" || true
    fi
    ok "ESP32 flash step finished"

    if systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null; then
        ask_yn "Start ${SERVICE_NAME}.service again?" y
        [[ "$REPLY" == "y" ]] && systemctl start "${SERVICE_NAME}.service" && ok "Service started"
    fi
}

# mode: optional | required
step_victron() {
    local mode="${1:-optional}"
    step_begin "Victron Instant Readout"
    require_conf

    echo
    info "In the ${C_BOLD}VictronConnect${C_RESET} app you should already have:"
    info "  · SmartShunt (or BMV) and MPPT added, firmware current"
    info "  · Devices ${C_BOLD}meshed${C_RESET} if you use VE.Smart Networking"
    info "  · ${C_BOLD}Instant readout via Bluetooth${C_RESET} enabled on each device"
    info "  · gear → Product info → Instant readout → Show  (MAC + 32-char key)"
    echo
    info "The Pi only listens for BLE advertisements — no VE.Direct cable."
    echo

    local cur_sa cur_sk cur_ma cur_mk
    cur_sa="$(conf_get victron shunt_address)"
    cur_sk="$(conf_get victron shunt_key)"
    cur_ma="$(conf_get victron mppt_address)"
    cur_mk="$(conf_get victron mppt_key)"
    if [[ -n "$cur_sa$cur_ma$cur_sk$cur_mk" ]]; then
        info "Current (keys hidden):"
        info "  shunt MAC=${cur_sa:-∅}  key=$([ -n "$cur_sk" ] && echo set || echo empty)"
        info "  mppt  MAC=${cur_ma:-∅}  key=$([ -n "$cur_mk" ] && echo set || echo empty)"
    fi

    if [[ "$mode" == "optional" ]]; then
        ask_yn "Configure Victron SmartShunt / MPPT now?" n
        if [[ "$REPLY" != "y" ]]; then
            skip_note "Victron skipped — use menu item when you have MAC+keys"
            return 0
        fi
    fi

    info "Ensuring Bluetooth is available…"
    systemctl enable --now bluetooth >/dev/null 2>&1 || true
    rfkill unblock bluetooth 2>/dev/null || true
    command -v hciconfig >/dev/null 2>&1 && hciconfig hci0 up 2>/dev/null || true
    if [[ -n "${CONFIG_TXT:-}" ]] && grep -qE '^\s*dtoverlay=disable-bt' "$CONFIG_TXT" 2>/dev/null; then
        warn "dtoverlay=disable-bt is set — remove it and reboot for Instant Readout"
        NEED_REBOOT=1
    fi
    ok "Bluetooth service enabled"

    prompt_mac() {
        local label="$1" current="$2" out
        while true; do
            read -r -p "  ${label} MAC [${current:-empty / s to skip}]: " ans || true
            ans="${ans:-$current}"
            if [[ -z "$ans" || "${ans,,}" == "s" || "${ans,,}" == "skip" ]]; then
                PROMPT_VAL=""; return 1
            fi
            if out="$(normalize_mac "$ans")"; then
                PROMPT_VAL="$out"; return 0
            fi
            warn "Invalid MAC — use aa:bb:cc:dd:ee:ff"
        done
    }
    prompt_key() {
        local label="$1" current="$2" out hint
        while true; do
            hint="empty / s to skip"
            [[ -n "$current" ]] && hint="Enter keeps existing / s skips"
            read -r -p "  ${label} Instant Readout key (32 hex) [${hint}]: " ans || true
            if [[ -z "$ans" ]]; then
                if [[ -n "$current" ]]; then PROMPT_VAL="$current"; return 0; fi
                PROMPT_VAL=""; return 1
            fi
            if [[ "${ans,,}" == "s" || "${ans,,}" == "skip" ]]; then
                PROMPT_VAL=""; return 1
            fi
            if out="$(normalize_victron_key "$ans")"; then
                PROMPT_VAL="$out"; return 0
            fi
            warn "Key must be exactly 32 hex characters"
        done
    }

    local shunt_args=() mppt_args=() victron_args=()
    echo
    info "SmartShunt / BMV"
    if prompt_mac "Shunt" "$cur_sa"; then
        shunt_args+=(shunt_address "$PROMPT_VAL")
        ok "shunt_address = $PROMPT_VAL"
        if prompt_key "Shunt" "$cur_sk"; then
            shunt_args+=(shunt_key "$PROMPT_VAL")
            ok "shunt_key saved"
        else
            warn "No shunt key — address alone is not enough"
        fi
    else
        info "Shunt left unchanged"
    fi

    echo
    info "MPPT SmartSolar / BlueSolar"
    if prompt_mac "MPPT" "$cur_ma"; then
        mppt_args+=(mppt_address "$PROMPT_VAL")
        ok "mppt_address = $PROMPT_VAL"
        if prompt_key "MPPT" "$cur_mk"; then
            mppt_args+=(mppt_key "$PROMPT_VAL")
            ok "mppt_key saved"
        else
            warn "No MPPT key — address alone is not enough"
        fi
    else
        info "MPPT left unchanged"
    fi

    [[ ${#shunt_args[@]} -gt 0 ]] && victron_args+=("${shunt_args[@]}")
    [[ ${#mppt_args[@]} -gt 0 ]] && victron_args+=("${mppt_args[@]}")
    if [[ ${#victron_args[@]} -gt 0 ]]; then
        conf_set victron "${victron_args[@]}"
        ok "Updated [victron] (other config unchanged)"
        info "Test: cd $SCCS_HOME && source venv/bin/activate && victron discover"
        if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
            systemctl restart "${SERVICE_NAME}.service"
            ok "Restarted ${SERVICE_NAME}.service to load new keys"
        fi
    else
        info "No Victron fields entered — config left unchanged"
    fi
}

# ---------------------------------------------------------------------------
# Integrated: LAN IP + NAT + Pi-hole (DNS + DHCP)
# Env: LAN_IF WAN_IF EXTRA_WAN_IF WAN_IFS LAN_ADDR LAN_CIDR DHCP_* SCCS_CONF
# ---------------------------------------------------------------------------
apply_lan_nat_dhcp() {
    local LAN_IF="${LAN_IF:-eth0}"
    local WAN_IF="${WAN_IF:-wlan0}"
    local LAN_ADDR="${LAN_ADDR:-10.10.10.1}"
    local LAN_CIDR="${LAN_CIDR:-24}"
    local DHCP_RANGE_START="${DHCP_RANGE_START:-10.10.10.50}"
    local DHCP_RANGE_END="${DHCP_RANGE_END:-10.10.10.200}"
    local DHCP_LEASE="${DHCP_LEASE:-12h}"
    local SCCS_CONF="${SCCS_CONF:-$CONF}"
    local POLKIT_SRC="$SCCS_HOME/config/polkit/50-sccs-networkmanager.rules"
    local POLKIT_DEST="/etc/polkit-1/rules.d/50-sccs-networkmanager.rules"
    local SYSCTL_DROPIN="/etc/sysctl.d/99-sccs-forward.conf"
    local NFTABLES_CONF="/etc/nftables.conf"
    local PIHOLE_STATIC="/etc/dnsmasq.d/99-sccs-static-dhcp.conf"
    local PIHOLE_WAN_EXCEPT="/etc/dnsmasq.d/02-sccs-wan-except.conf"
    local PIHOLE_PASS_FILE="/root/.sccs-pihole-web-password"

    [[ -f "$SCCS_CONF" ]] || die "Missing config: $SCCS_CONF"
    ip link show "$LAN_IF" &>/dev/null || die "LAN interface not found: $LAN_IF"

    local WAN_LIST=() WAN_CLEAN=() w rest name ip mac
    if [[ -n "${WAN_IFS:-}" ]]; then
        # shellcheck disable=SC2206
        WAN_LIST=($WAN_IFS)
    else
        WAN_LIST=("$WAN_IF")
        [[ -n "${EXTRA_WAN_IF:-}" ]] && WAN_LIST+=("$EXTRA_WAN_IF")
    fi
    declare -A _seen_wan=()
    for w in "${WAN_LIST[@]}"; do
        [[ -z "$w" || "$w" == "$LAN_IF" ]] && continue
        [[ -n "${_seen_wan[$w]:-}" ]] && continue
        if ! ip link show "$w" &>/dev/null; then
            warn "WAN interface not found (skipped): $w"
            continue
        fi
        _seen_wan[$w]=1
        WAN_CLEAN+=("$w")
    done
    WAN_LIST=("${WAN_CLEAN[@]}")
    [[ ${#WAN_LIST[@]} -gt 0 ]] || die "No WAN interfaces available — need wlan0 and/or USB tether"

    [[ -f "$POLKIT_SRC" ]] || die "Missing polkit rule: $POLKIT_SRC"
    install -m 644 "$POLKIT_SRC" "$POLKIT_DEST"
    ok "Installed $POLKIT_DEST"

    mapfile -t RESERVATIONS < <(python3 - "$SCCS_CONF" <<'PY'
import configparser, ipaddress, re, sys
path = sys.argv[1]
cfg = configparser.ConfigParser()
cfg.read(path)
if not cfg.has_section("screens"):
    sys.exit(0)
mac_re = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$")
for name, line in cfg.items("screens"):
    parts = [p.strip() for p in str(line).split("|")]
    if len(parts) < 11:
        print(f"skip {name}: need host + mac", file=sys.stderr)
        continue
    host, mac = parts[2], parts[10].strip().lower()
    if not mac or mac in ("none", "-"):
        print(f"skip {name}: empty mac", file=sys.stderr)
        continue
    if not mac_re.match(mac):
        print(f"skip {name}: bad mac {mac!r}", file=sys.stderr)
        continue
    try:
        ip = str(ipaddress.IPv4Address(host))
    except Exception:
        print(f"skip {name}: host must be IPv4", file=sys.stderr)
        continue
    print(f"{name}\t{ip}\t{mac}")
PY
)
    if [[ ${#RESERVATIONS[@]} -eq 0 ]]; then
        info "No DHCP reservations yet — normal on first install before you edit [screens]."
        info "After setting host + mac under [screens], re-run menu 6 (or menu 8) to apply them."
    fi

    info "LAN $LAN_IF = ${LAN_ADDR}/${LAN_CIDR} · WAN: ${WAN_LIST[*]}"
    command -v nmcli >/dev/null 2>&1 || die "nmcli not found — install NetworkManager"

    local LAN_CON
    LAN_CON="$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v d="$LAN_IF" '$2==d {print $1; exit}')"
    if [[ -z "${LAN_CON:-}" ]]; then
        LAN_CON="$(nmcli -t -f NAME,TYPE,DEVICE connection show | awk -F: -v d="$LAN_IF" '
            $2=="802-3-ethernet" && ($3=="" || $3==d) {print $1; exit}')"
    fi
    if [[ -z "${LAN_CON:-}" ]]; then
        LAN_CON="sccs-lan"
        info "Creating NM connection $LAN_CON for $LAN_IF"
        nmcli connection add type ethernet ifname "$LAN_IF" con-name "$LAN_CON" \
            ipv4.method manual ipv4.addresses "${LAN_ADDR}/${LAN_CIDR}" \
            ipv4.gateway "" ipv4.dns "${LAN_ADDR}" \
            ipv6.method link-local ipv6.never-default yes \
            connection.autoconnect yes
    else
        info "Configuring NM connection '$LAN_CON' for $LAN_IF"
        nmcli connection modify "$LAN_CON" \
            connection.interface-name "$LAN_IF" \
            ipv4.method manual \
            ipv4.addresses "${LAN_ADDR}/${LAN_CIDR}" \
            ipv4.gateway "" \
            ipv4.never-default yes \
            ipv6.method link-local \
            ipv6.never-default yes \
            connection.autoconnect yes
    fi
    nmcli connection up "$LAN_CON" || true
    ip -4 addr show dev "$LAN_IF" | sed -n 's/^/    /p'

    echo "net.ipv4.ip_forward=1" >"$SYSCTL_DROPIN"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    ok "IP forwarding enabled"

    command -v nft >/dev/null 2>&1 || apt-get install -y nftables
    local FORWARD_RULES="" MASQ_RULES=""
    for w in "${WAN_LIST[@]}"; do
        FORWARD_RULES+="        iifname \"${LAN_IF}\" oifname \"${w}\" accept"$'\n'
        FORWARD_RULES+="        iifname \"${w}\" oifname \"${LAN_IF}\" ct state established,related accept"$'\n'
        MASQ_RULES+="        oifname \"${w}\" masquerade"$'\n'
    done
    cat >"$NFTABLES_CONF" <<EOF
#!/usr/sbin/nft -f
# Generated by SCCS install.sh — LAN gateway
# WAN: ${WAN_LIST[*]}

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
${FORWARD_RULES}    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
${MASQ_RULES}    }
}
EOF
    chmod 644 "$NFTABLES_CONF"
    nft -f "$NFTABLES_CONF"
    systemctl enable --now nftables >/dev/null 2>&1 || true
    ok "nftables NAT: ${LAN_IF} → ${WAN_LIST[*]}"

    # System dnsmasq must not own DHCP/DNS — Pi-hole FTL does
    info "Stopping system dnsmasq (DHCP/DNS handled by Pi-hole)…"
    systemctl disable --now dnsmasq 2>/dev/null || true
    systemctl mask dnsmasq 2>/dev/null || true
    rm -f /etc/dnsmasq.d/sccs-lan.conf /etc/dnsmasq.d/50-sccs-screens.conf

    # --- Pi-hole (DNS + DHCP) ---
    # Prefer the iface that already holds LAN_ADDR (USB-ETH may enumerate as eth1).
    local lan_if_resolved=""
    lan_if_resolved="$(ip -4 -o addr show 2>/dev/null \
        | awk -v a="${LAN_ADDR}/" '$0 ~ a {print $2; exit}')"
    if [[ -n "$lan_if_resolved" && "$lan_if_resolved" != "$LAN_IF" ]]; then
        warn "LAN address ${LAN_ADDR} is on ${lan_if_resolved}, not ${LAN_IF} — using ${lan_if_resolved} for Pi-hole"
        LAN_IF="$lan_if_resolved"
    fi

    if ! command -v pihole >/dev/null 2>&1; then
        info "Installing Pi-hole (unattended) — this can take several minutes…"
        mkdir -p /etc/pihole
        # Pre-seed classic setupVars (basic-install still uses these for --unattended).
        # Upstream must be bare IPs/hostnames — "1.1.1.1#cloudflare" is NOT valid
        # dnsmasq (the #suffix is treated as a port and FTL aborts with "bad port").
        cat >/etc/pihole/setupVars.conf <<EOF
PIHOLE_INTERFACE=${LAN_IF}
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=false
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=local
WEBPASSWORD=
BLOCKING_ENABLED=true
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=1.0.0.1
DHCP_ACTIVE=true
DHCP_START=${DHCP_RANGE_START}
DHCP_END=${DHCP_RANGE_END}
DHCP_ROUTER=${LAN_ADDR}
DHCP_LEASETIME=12
PIHOLE_DOMAIN=lan
DHCP_IPv6=false
DNSSEC=false
REV_SERVER=false
EOF
        export PIHOLE_SKIP_OS_CHECK="${PIHOLE_SKIP_OS_CHECK:-true}"
        if ! curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended; then
            die "Pi-hole install failed — check network and re-run LAN setup"
        fi
        ok "Pi-hole installed"
    else
        ok "Pi-hole already installed"
    fi

    # v5/v6 post-config via FTL CLI when available
    if command -v pihole-FTL >/dev/null 2>&1; then
        info "Configuring Pi-hole DNS + DHCP on ${LAN_IF}…"
        # Force clean upstreams even if an older setupVars left "#name" tags.
        pihole-FTL --config dns.upstreams '[ "1.1.1.1", "1.0.0.1" ]' 2>/dev/null || true
        pihole-FTL --config dhcp.active true 2>/dev/null || true
        pihole-FTL --config dhcp.start "${DHCP_RANGE_START}" 2>/dev/null || true
        pihole-FTL --config dhcp.end "${DHCP_RANGE_END}" 2>/dev/null || true
        pihole-FTL --config dhcp.router "${LAN_ADDR}" 2>/dev/null || true
        pihole-FTL --config dhcp.leasetime "12h" 2>/dev/null \
            || pihole-FTL --config dhcp.leaseTime "12h" 2>/dev/null || true
        # Prefer the real LAN iface; LOCAL mode still answers DNS on other local
        # subnets (e.g. admin login via wlan/WAN IP for diagnosis).
        # DHCP is hard-blocked on WAN ifaces via no-dhcp-interface (below).
        pihole-FTL --config dns.interface "${LAN_IF}" 2>/dev/null \
            || pihole-FTL --config interface "${LAN_IF}" 2>/dev/null || true
        pihole-FTL --config dns.listeningMode LOCAL 2>/dev/null \
            || pihole-FTL --config dns.listeningMode local 2>/dev/null || true
        # Keep port 80 free for SCCS nginx — admin on 8080
        pihole-FTL --config webserver.port "8080o,[::]:8080o" 2>/dev/null \
            || pihole-FTL --config webserver.port "8080" 2>/dev/null || true
        # Load /etc/dnsmasq.d/*.conf (WAN DHCP block + screen reservations).
        pihole-FTL --config misc.etc_dnsmasq_d true 2>/dev/null || true

        # Dual-homed Pi: FTL listens on * for DHCP under LOCAL mode, then logs
        # "no address range available for DHCP request via wlan0" when home-LAN
        # broadcasts arrive. no-dhcp-interface disables DHCP on WAN only (DNS OK).
        {
            echo "# Generated by SCCS install.sh — do not edit by hand"
            echo "# DHCP only on ${LAN_IF} (${LAN_ADDR}/${LAN_CIDR}). Never lease on WAN."
            for w in "${WAN_LIST[@]}"; do
                echo "no-dhcp-interface=${w}"
            done
        } >"$PIHOLE_WAN_EXCEPT"
        chmod 644 "$PIHOLE_WAN_EXCEPT"
        ok "Pi-hole DHCP disabled on WAN: ${WAN_LIST[*]}"

        ok "Pi-hole DHCP ${DHCP_RANGE_START}–${DHCP_RANGE_END}, router ${LAN_ADDR}"
        info "Pi-hole admin UI: http://${LAN_ADDR}:8080/admin (or http://<wlan-ip>:8080/admin)"
        info "Admin on port 8080 so SCCS nginx can use :80"
    fi

    # Static DHCP from [screens] only when host+mac are already filled in (often empty on first install)
    apply_pihole_screen_reservations "$SCCS_CONF"

    # Web password: set once and record for the operator
    if [[ ! -f "$PIHOLE_PASS_FILE" ]]; then
        local ppass
        ppass="$(openssl rand -base64 15 | tr -d '/+=' | head -c 16)"
        if pihole setpassword "$ppass" 2>/dev/null \
            || pihole -a -p "$ppass" 2>/dev/null; then
            printf '%s\n' "$ppass" >"$PIHOLE_PASS_FILE"
            chmod 600 "$PIHOLE_PASS_FILE"
            ok "Pi-hole web password saved to $PIHOLE_PASS_FILE"
            warn "Pi-hole admin password: ${ppass}"
        else
            warn "Could not auto-set Pi-hole password — run: pihole setpassword"
        fi
    else
        info "Pi-hole web password file already exists: $PIHOLE_PASS_FILE"
    fi

    if command -v pihole >/dev/null 2>&1; then
        pihole restartdns 2>/dev/null || systemctl restart pihole-FTL 2>/dev/null || true
    else
        systemctl restart pihole-FTL 2>/dev/null || true
    fi
    ok "Pi-hole DNS + DHCP active on ${LAN_IF}"
}

# Write Pi-hole static DHCP from [screens] host+mac (safe if none configured yet).
apply_pihole_screen_reservations() {
    local conf_path="${1:-$CONF}"
    local PIHOLE_STATIC="/etc/dnsmasq.d/99-sccs-static-dhcp.conf"
    local name rest ip mac row hosts_json first

    mapfile -t RESERVATIONS < <(python3 - "$conf_path" <<'PY'
import configparser, ipaddress, re, sys
path = sys.argv[1]
cfg = configparser.ConfigParser()
cfg.read(path)
if not cfg.has_section("screens"):
    sys.exit(0)
mac_re = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$")
for name, line in cfg.items("screens"):
    parts = [p.strip() for p in str(line).split("|")]
    if len(parts) < 11:
        continue
    host, mac = parts[2], parts[10].strip().lower()
    if not mac or mac in ("none", "-") or not mac_re.match(mac):
        continue
    try:
        ip = str(ipaddress.IPv4Address(host))
    except Exception:
        continue
    print(f"{name}\t{ip}\t{mac}")
PY
)

    {
        echo "# Generated by SCCS install.sh from ${conf_path}"
        echo "# Panel DHCP reservations from [screens] — re-run menu 6 or 8 after editing conf"
        if [[ ${#RESERVATIONS[@]} -gt 0 ]]; then
            for row in "${RESERVATIONS[@]}"; do
                name="${row%%$'\t'*}"
                rest="${row#*$'\t'}"
                ip="${rest%%$'\t'*}"
                mac="${rest##*$'\t'}"
                echo "dhcp-host=${mac},${ip},${name},infinite"
                info "  Pi-hole reserve ${name}: ${mac} → ${ip}"
            done
        else
            echo "# (none yet — add host + mac under [screens], then re-run menu 6 or 8)"
        fi
    } >"$PIHOLE_STATIC"
    chmod 644 "$PIHOLE_STATIC"

    if command -v pihole-FTL >/dev/null 2>&1 && [[ ${#RESERVATIONS[@]} -gt 0 ]]; then
        hosts_json="["
        first=1
        for row in "${RESERVATIONS[@]}"; do
            name="${row%%$'\t'*}"
            rest="${row#*$'\t'}"
            ip="${rest%%$'\t'*}"
            mac="${rest##*$'\t'}"
            if [[ "$first" -eq 1 ]]; then first=0; else hosts_json+=","; fi
            hosts_json+="\"${mac},${ip},${name}\""
        done
        hosts_json+="]"
        pihole-FTL --config dhcp.hosts "$hosts_json" 2>/dev/null || true
    fi

    if command -v pihole >/dev/null 2>&1; then
        pihole restartdns 2>/dev/null || systemctl restart pihole-FTL 2>/dev/null || true
    else
        systemctl restart pihole-FTL 2>/dev/null || true
    fi

    if [[ ${#RESERVATIONS[@]} -gt 0 ]]; then
        ok "Pi-hole DHCP reservations: ${#RESERVATIONS[@]} from [screens]"
    else
        info "Pi-hole DHCP pool only (no static reservations yet)"
    fi
}

# ---------------------------------------------------------------------------
# Integrated: one touchscreen (SSH + blank/shutdown)
# Args: user host alias blank_path skip_blank(0|1) — runs as USERNAME
# ---------------------------------------------------------------------------
configure_touchscreen_panel() {
    local screen_user="$1" screen_host="$2" screen_alias="$3" blank_path="${4:-/sys/class/graphics/fb0/blank}" skip_blank="${5:-0}"
    run_as_user env \
        SCREEN_USER="$screen_user" \
        SCREEN_HOST="$screen_host" \
        SCREEN_ALIAS="$screen_alias" \
        BLANK_PATH="$blank_path" \
        SKIP_BLANK="$skip_blank" \
        bash -s <<'EOS'
set -euo pipefail
KEY="$HOME/.ssh/sccs_screen"
SSH_CONFIG="$HOME/.ssh/config"
KNOWN_HOSTS="$HOME/.sccs/screen_known_hosts"
SSH_BASE=(
    -o PreferredAuthentications=publickey
    -o UserKnownHostsFile="${KNOWN_HOSTS}"
    -o StrictHostKeyChecking=accept-new
)
SSH_BATCH=("${SSH_BASE[@]}" -o BatchMode=yes)

mkdir -p "$HOME/.ssh" "$(dirname "$KNOWN_HOSTS")"
chmod 700 "$HOME/.ssh"

if [[ ! -f "$KEY" ]]; then
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "sccs-screen-control"
    echo "Created $KEY"
fi

if ! grep -q "Host ${SCREEN_HOST} " "$SSH_CONFIG" 2>/dev/null && \
   ! grep -q "Host ${SCREEN_ALIAS}" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<EOF

# Screen control — ${SCREEN_HOST} (config/sccs.conf [screens])
Host ${SCREEN_HOST} ${SCREEN_ALIAS}
    HostName ${SCREEN_HOST}
    User ${SCREEN_USER}
    IdentityFile ~/.ssh/sccs_screen
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
    chmod 600 "$SSH_CONFIG"
    echo "Appended SSH config for ${SCREEN_USER}@${SCREEN_HOST}"
fi

if ssh "${SSH_BATCH[@]}" -i "${KEY}" "${SCREEN_USER}@${SCREEN_HOST}" 'echo ok' 2>/dev/null; then
    echo "Passwordless SSH already works for ${SCREEN_USER}@${SCREEN_HOST}"
else
    echo "Installing public key on ${SCREEN_USER}@${SCREEN_HOST}..."
    echo "(enter the touchscreen password if prompted)"
    if ! ssh-copy-id -i "${KEY}.pub" "${SCREEN_USER}@${SCREEN_HOST}" 2>/dev/null; then
        echo "" >&2
        echo "ssh-copy-id failed — password SSH may be disabled (common on Armbian)." >&2
        echo "On the panel: set PasswordAuthentication yes in sshd_config, restart ssh, retry." >&2
        exit 1
    fi
    echo "Verifying passwordless login..."
    ssh "${SSH_BATCH[@]}" -i "${KEY}" "${SCREEN_USER}@${SCREEN_HOST}" 'echo ok'
fi

if [[ "${SKIP_BLANK}" == "1" ]]; then
    remote_cmd=$(cat <<EOF
set -euo pipefail
SHUTDOWN_SUDOERS='/etc/sudoers.d/sccs-screen-shutdown'
SHUTDOWN_LINE='${SCREEN_USER} ALL=(root) NOPASSWD: /sbin/shutdown -h now, /usr/sbin/shutdown -h now, /sbin/poweroff, /usr/sbin/poweroff'
install -d -m 755 /etc/sudoers.d
printf '%s\n' "\$SHUTDOWN_LINE" > "\$SHUTDOWN_SUDOERS"
chmod 440 "\$SHUTDOWN_SUDOERS"
visudo -cf "\$SHUTDOWN_SUDOERS"
visudo -c
echo "Installed shutdown sudoers"
EOF
)
    echo "Installing passwordless shutdown on ${SCREEN_USER}@${SCREEN_HOST}..."
    ssh -t "${SSH_BASE[@]}" -i "${KEY}" "${SCREEN_USER}@${SCREEN_HOST}" \
        "sudo bash -c $(printf '%q' "$remote_cmd")"
else
    remote_cmd=$(cat <<EOF
set -euo pipefail
BLANK_PATH='${BLANK_PATH}'
BLANK_SUDOERS='/etc/sudoers.d/sccs-screen-blank'
SHUTDOWN_SUDOERS='/etc/sudoers.d/sccs-screen-shutdown'
BLANK_LINE='${SCREEN_USER} ALL=(root) NOPASSWD: /usr/bin/tee ${BLANK_PATH}'
SHUTDOWN_LINE='${SCREEN_USER} ALL=(root) NOPASSWD: /sbin/shutdown -h now, /usr/sbin/shutdown -h now, /sbin/poweroff, /usr/sbin/poweroff'
install -d -m 755 /etc/sudoers.d
printf '%s\n' "\$BLANK_LINE" > "\$BLANK_SUDOERS"
chmod 440 "\$BLANK_SUDOERS"
visudo -cf "\$BLANK_SUDOERS"
printf '%s\n' "\$SHUTDOWN_LINE" > "\$SHUTDOWN_SUDOERS"
chmod 440 "\$SHUTDOWN_SUDOERS"
visudo -cf "\$SHUTDOWN_SUDOERS"
visudo -c
echo "Installed blank + shutdown sudoers"
sudo -n -l | grep -F "/usr/bin/tee \${BLANK_PATH}" >/dev/null
sudo -n -l | grep -F '/sbin/shutdown -h now' >/dev/null
echo "passwordless blank and shutdown verified"
EOF
)
    echo "Installing passwordless blank/shutdown on ${SCREEN_USER}@${SCREEN_HOST}..."
    echo "(enter the touchscreen sudo password when prompted)"
    ssh -t "${SSH_BASE[@]}" -i "${KEY}" "${SCREEN_USER}@${SCREEN_HOST}" \
        "sudo bash -c $(printf '%q' "$remote_cmd")"
    echo "Verifying passwordless sudo from SCCS..."
    ssh "${SSH_BATCH[@]}" -i "${KEY}" "${SCREEN_USER}@${SCREEN_HOST}" \
        "sudo -n -l | grep -F '/usr/bin/tee ${BLANK_PATH}'"
fi

echo "Done — SCCS can control ${SCREEN_USER}@${SCREEN_HOST} over SSH."
EOS
}


# Resolve which ethernet iface should be the van LAN (default eth0).
# If LAN_ADDR is already assigned, prefer that device (USB adapters often show as eth1).
resolve_lan_if() {
    local preferred="${LAN_IF:-eth0}" found=""
    found="$(ip -4 -o addr show 2>/dev/null \
        | awk -v a="${LAN_ADDR:-10.10.10.1}/" '$0 ~ a {print $2; exit}')"
    if [[ -n "$found" ]]; then
        printf '%s' "$found"
        return 0
    fi
    if ip link show "$preferred" &>/dev/null; then
        printf '%s' "$preferred"
        return 0
    fi
    # Fall back to first non-wlan ethernet that exists
    local dev
    for dev in eth0 eth1 enx0 enp1s0; do
        if ip link show "$dev" &>/dev/null; then
            printf '%s' "$dev"
            return 0
        fi
    done
    return 1
}

# mode: optional | required
step_lan() {
    local mode="${1:-optional}"
    local lan_if
    step_begin "LAN gateway · Pi-hole DHCP/DNS · NAT"
    require_checkout
    if ! lan_if="$(resolve_lan_if)"; then
        skip_note "LAN skipped — no ethernet interface found"
        return 0
    fi
    if ! ip link show wlan0 &>/dev/null && [[ -z "${WAN_IF:-}" && -z "${WAN_IFS:-}" ]]; then
        skip_note "LAN skipped — no wlan0 (connect Wi‑Fi first, or set WAN_IF)"
        return 0
    fi

    if [[ "$mode" == "optional" ]]; then
        ask_yn "Configure ${lan_if}=${LAN_ADDR}, NAT via ${WAN_IF:-wlan0}, and Pi-hole (DNS + DHCP)?" y
        [[ "$REPLY" == "y" ]] || { skip_note "LAN gateway / Pi-hole skipped"; return 0; }
    fi

    LAN_IF="$lan_if" \
    LAN_ADDR="$LAN_ADDR" \
    DHCP_RANGE_START="${DHCP_RANGE_START:-10.10.10.50}" \
    DHCP_RANGE_END="${DHCP_RANGE_END:-10.10.10.200}" \
    SCCS_CONF="$CONF" \
    WAN_IF="${WAN_IF:-wlan0}" \
        apply_lan_nat_dhcp
    ok "Network gateway configured"
}

# Candidate USB tether / RNDIS / phone-as-modem style interfaces (not eth0 LAN).
list_tether_candidates() {
    local dev
    for dev in $(ls /sys/class/net 2>/dev/null | sort); do
        [[ "$dev" == "lo" || "$dev" == "eth0" || "$dev" == "wlan0" || "$dev" == "wlan1" ]] && continue
        # Common: eth1, usb0, enx..., rndis0, enp*s*u*
        if [[ "$dev" =~ ^(eth[1-9]|usb[0-9]|rndis[0-9]|enx[0-9a-f]+|enp[0-9]+s[0-9]+u[0-9]+) ]]; then
            echo "$dev"
        elif [[ -d "/sys/class/net/$dev/device" ]]; then
            # Any non-wlan extra interface with a device (likely USB)
            if ! [[ "$dev" =~ ^wlan ]]; then
                # Skip pure virtual bridges/veth unless they look like usb
                if [[ "$dev" =~ ^(veth|br|docker|virbr) ]]; then
                    continue
                fi
                # Include other eth* beyond eth0
                if [[ "$dev" =~ ^eth ]]; then
                    echo "$dev"
                fi
            fi
        fi
    done
}

nm_con_for_device() {
    local dev="$1"
    nmcli -t -f NAME,DEVICE connection show | awk -F: -v d="$dev" '$2==d {print $1; exit}'
}

# Guided phone USB tethering: detect interface, prefer over Wi‑Fi, refresh NAT.
# mode: optional | required
step_usb_tether() {
    local mode="${1:-optional}"
    step_begin "Phone USB internet (tether)"
    require_checkout
    if [[ "$mode" == "optional" ]]; then
        ask_yn "Set up phone USB tethering as internet uplink now?" n
        if [[ "$REPLY" != "y" ]]; then
            skip_note "USB tether skipped — use menu later when a phone is available"
            return 0
        fi
    fi

    echo
    info "This shares the phone’s internet to the van LAN (via the Pi)."
    info "Works with iPhone USB hotspot, Android USB tethering, etc."
    echo
    echo "  ${C_BOLD}On the phone:${C_RESET}"
    echo "    1. Unlock the phone"
    echo "    2. Enable ${C_BOLD}USB tethering${C_RESET} / ${C_BOLD}Personal Hotspot${C_RESET} (USB, not only Wi‑Fi)"
    echo "    3. Plug the phone into a ${C_BOLD}USB port on the Pi${C_RESET}"
    echo "    4. If prompted on the phone, allow the computer / trust this computer"
    echo
    read -r -p "  Press Enter when the phone is plugged in and tethering is on (s = skip)… " ans || true
    if [[ "${ans,,}" == "s" || "${ans,,}" == "skip" ]]; then
        skip_note "USB tether skipped by user"
        return 0
    fi

    local before="" after="" found="" tries=0 max_tries=45
    before="$(list_tether_candidates | tr '\n' ' ')"
    info "Interfaces already looking like tether candidates: ${before:-none}"
    info "Scanning for a phone USB network device…"
    echo "  ${C_DIM}(type s + Enter anytime to cancel)${C_RESET}"

    while (( tries < max_tries )); do
        mapfile -t cands < <(list_tether_candidates)
        if [[ ${#cands[@]} -ge 1 ]]; then
            # Prefer a newly appeared interface if we can tell
            found=""
            for d in "${cands[@]}"; do
                if [[ " $before " != *" $d "* ]]; then
                    found="$d"
                    break
                fi
            done
            [[ -z "$found" ]] && found="${cands[0]}"
            ok "Found candidate interface: ${C_BOLD}${found}${C_RESET}"
            break
        fi
        tries=$((tries + 1))
        if (( tries % 5 == 1 )); then
            info "Scan ${tries}/${max_tries}: no tether device yet…"
            info "  nmcli device status:"
            nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null | sed 's/^/    /' || true
            info "  links:"
            ip -br link 2>/dev/null | sed 's/^/    /' || true
        fi
        ans=""
        if read -r -t 2 ans 2>/dev/null; then
            case "${ans,,}" in
                s|skip|q) skip_note "USB tether scan cancelled"; return 0 ;;
            esac
        fi
    done

    if [[ -z "$found" ]]; then
        warn "No USB tether interface appeared."
        info "Check cable, phone tethering setting, and try another USB port."
        ask_yn "Enter an interface name manually (e.g. eth1)?" n
        if [[ "$REPLY" == "y" ]]; then
            read -r -p "  Interface name: " found || true
            found="$(echo "$found" | tr -d '[:space:]')"
            if [[ -z "$found" ]] || ! ip link show "$found" &>/dev/null; then
                skip_note "USB tether aborted — invalid interface"
                return 0
            fi
        else
            skip_note "USB tether not configured — no interface found"
            return 0
        fi
    fi

    echo
    info "Device detail for ${found}:"
    ip -br link show "$found" 2>/dev/null | sed 's/^/    /' || true
    ip -4 -br addr show "$found" 2>/dev/null | sed 's/^/    /' || true
    nmcli device show "$found" 2>/dev/null | grep -E 'GENERAL\.(DEVICE|TYPE|STATE|CONNECTION)|IP4\.(ADDRESS|GATEWAY)' | sed 's/^/    /' || true

    # Bring interface up via NetworkManager
    info "Connecting ${found} with NetworkManager…"
    nmcli device set "$found" managed yes 2>/dev/null || true
    if nmcli device connect "$found" 2>/dev/null; then
        ok "nmcli device connect ${found} succeeded"
    else
        warn "nmcli device connect failed — trying connection up if a profile exists"
        local con
        con="$(nm_con_for_device "$found")"
        if [[ -n "$con" ]]; then
            nmcli connection up "$con" || warn "connection up failed for $con"
        else
            # Create a simple ethernet profile for the USB NIC
            con="sccs-usb-tether"
            nmcli connection delete "$con" 2>/dev/null || true
            nmcli connection add type ethernet ifname "$found" con-name "$con" \
                ipv4.method auto ipv6.method ignore connection.autoconnect yes \
                || warn "Could not create connection profile"
            nmcli connection up "$con" || warn "Could not bring up $con"
        fi
    fi

    sleep 2
    info "Addresses after connect:"
    ip -4 addr show dev "$found" 2>/dev/null | sed 's/^/    /' || warn "No IPv4 on $found yet"

    # Prefer USB tether over Wi‑Fi (lower metric wins)
    local tether_con wlan_con
    tether_con="$(nm_con_for_device "$found")"
    if [[ -n "$tether_con" ]]; then
        nmcli connection modify "$tether_con" ipv4.route-metric 50 connection.autoconnect yes
        ok "Route metric 50 on '${tether_con}' (preferred uplink)"
        nmcli connection up "$tether_con" 2>/dev/null || true
    else
        warn "No NM connection name for $found — skip metric tweak"
    fi

    if ip link show wlan0 &>/dev/null; then
        wlan_con="$(nm_con_for_device wlan0)"
        if [[ -n "$wlan_con" ]]; then
            nmcli connection modify "$wlan_con" ipv4.route-metric 200
            ok "Route metric 200 on Wi‑Fi '${wlan_con}' (fallback)"
            nmcli connection up "$wlan_con" 2>/dev/null || true
        fi
    fi

    echo
    info "Default routes:"
    ip route show default 2>/dev/null | sed 's/^/    /' || true

    # Rebuild LAN NAT/DHCP with all WAN ifaces
    local wans=()
    ip link show wlan0 &>/dev/null && wans+=(wlan0)
    wans+=("$found")
    info "Refreshing NAT/DHCP for WAN: ${wans[*]}"
    LAN_ADDR="$LAN_ADDR" \
    DHCP_RANGE_START="${DHCP_RANGE_START:-10.10.10.50}" \
    DHCP_RANGE_END="${DHCP_RANGE_END:-10.10.10.200}" \
    SCCS_CONF="$CONF" \
    WAN_IFS="${wans[*]}" \
        apply_lan_nat_dhcp

    ok "Phone USB tether configured on ${found}"
    info "LAN clients should reach the internet via the Pi. Test: ping 8.8.8.8 from a LAN device."
}

# mode: optional | required
# Sets up each [screens] entry (SSH key + blank/shutdown) as USERNAME, not root.
step_screens() {
    local mode="${1:-optional}"
    step_begin "Touchscreens (SSH + blank/shutdown)"
    require_conf

    # name|host|user|blank_path  (blank_path may be empty)
    mapfile -t SCREEN_ROWS < <(python3 - "$CONF" <<'PY'
import configparser, sys
cfg = configparser.ConfigParser()
cfg.read(sys.argv[1])
if not cfg.has_section("screens"):
    sys.exit(0)
for name, line in cfg.items("screens"):
    parts = [p.strip() for p in str(line).split("|")]
    if len(parts) < 4:
        continue
    host = parts[2]
    user = parts[3]
    blank = parts[9] if len(parts) > 9 else ""
    if blank.lower() in ("none", "-", ""):
        blank = ""
    print(f"{name}\t{host}\t{user}\t{blank}")
PY
)

    if [[ ${#SCREEN_ROWS[@]} -eq 0 ]]; then
        warn "No screens in [screens] — add host/user (and mac) in sccs.conf first"
        if [[ "$mode" == "optional" ]]; then
            skip_note "Touchscreen setup skipped — no [screens] entries"
        fi
        return 0
    fi

    echo
    info "Screens from sccs.conf:"
    local i row name host user blank
    for i in "${!SCREEN_ROWS[@]}"; do
        row="${SCREEN_ROWS[$i]}"
        IFS=$'\t' read -r name host user blank <<<"$row"
        printf "  ${C_BOLD}[%d]${C_RESET}  %s  →  %s@%s\n" "$((i + 1))" "$name" "$user" "$host"
    done
    echo
    info "Each panel must be on the network with password SSH enabled once (for key install)."
    info "Armbian: on the panel set PasswordAuthentication yes in sshd_config, restart ssh, then continue."
    info "Type ${C_BOLD}s${C_RESET} to skip a panel. Run again later from this menu."
    echo

    if [[ "$mode" == "optional" ]]; then
        ask_yn "Set up SSH control for touchscreen(s) now?" n
        if [[ "$REPLY" != "y" ]]; then
            skip_note "Touchscreen setup skipped — menu item later when panels are online"
            return 0
        fi
    fi

    for row in "${SCREEN_ROWS[@]}"; do
        IFS=$'\t' read -r name host user blank <<<"$row"
        echo
        echo "  ${C_BOLD}${name}${C_RESET} — ${user}@${host}"
        read -r -p "  Set up this panel? [Y/n/s]: " ans || true
        ans="${ans:-y}"
        case "${ans,,}" in
            n|no|s|skip)
                skip_note "Screen ${name} skipped"
                continue
                ;;
        esac

        local alias="${name//_/-}-screen"
        local skip_blank=0 blank_path="/sys/class/graphics/fb0/blank"
        if [[ "$blank" == /* ]]; then
            blank_path="$blank"
            skip_blank=0
        else
            skip_blank=1
            info "blank_path is not sysfs (${blank:-unset}) — installing SSH + shutdown only"
        fi

        info "Configuring panel as ${USERNAME}…"
        if configure_touchscreen_panel "$user" "$host" "$alias" "$blank_path" "$skip_blank"; then
            ok "Screen ${name} configured"
        else
            warn "Could not configure ${name}"
            info "If password SSH is off (Armbian): enable PasswordAuthentication on the panel, restart ssh, retry."
            ask_yn "Continue with remaining screens?" y
            [[ "$REPLY" == "y" ]] || break
        fi
    done
    if command -v pihole >/dev/null 2>&1 || systemctl is-active --quiet pihole-FTL 2>/dev/null; then
        info "Refreshing Pi-hole DHCP reservations from [screens]…"
        apply_pihole_screen_reservations "$CONF"
    fi
    ok "Touchscreen step finished"
}

step_service() {
    step_begin "systemd service ${SERVICE_NAME}.service"
    require_checkout
    [[ -x "$SCCS_HOME/venv/bin/python3" ]] || die "venv missing — run Install SCCS first"

    local unit_etc="/etc/systemd/system/${SERVICE_NAME}.service"
    cat >"$unit_etc" <<EOF
[Unit]
Description=The Singularity Camper Control System
After=network.target nginx.service

[Service]
User=$USERNAME
Group=www-data
WorkingDirectory=$SCCS_HOME
ExecStart=$SCCS_HOME/venv/bin/python3 $SCCS_HOME/app.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    cp -a "$unit_etc" "${SCCS_HOME}.service"
    chown "$USERNAME":www-data "${SCCS_HOME}.service" 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    systemctl restart "${SERVICE_NAME}.service"
    sleep 1
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        ok "${SERVICE_NAME}.service is active"
    else
        warn "Service failed — journalctl -u ${SERVICE_NAME}.service -b --no-pager"
        systemctl status "${SERVICE_NAME}.service" --no-pager -l || true
    fi
}

step_checklist() {
    step_begin "Notes"
    info "Touchscreens: set [screens] in sccs.conf, then menu item or --screens"
    info "Hardware you skipped: use this menu anytime; sccs.conf is never replaced"
    ok "Done"
}

step_update() {
    step_begin "Update from repository"
    require_checkout
    [[ -d "$SCCS_HOME/.git" ]] || die "Not a git checkout — cannot update"

    # Live site config is gitignored; still refuse any path that would clobber it.
    if [[ -f "$CONF" ]]; then
        ok "Keeping $CONF (not in git; will not be modified)"
    else
        warn "No sccs.conf yet — after update, copy from sccs.conf.dist if this is a new tree"
    fi

    local before after dirty
    before="$(run_as_user git -C "$SCCS_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    info "Current revision: $before"

    dirty="$(run_as_user git -C "$SCCS_HOME" status --porcelain 2>/dev/null || true)"
    if [[ -n "$dirty" ]]; then
        warn "Working tree has local changes:"
        run_as_user git -C "$SCCS_HOME" status --short | sed 's/^/    /' || true
        ask_yn "Continue with git pull anyway (may fail if files conflict)?" n
        [[ "$REPLY" == "y" ]] || { skip_note "Update cancelled (dirty tree)"; return 0; }
    fi

    info "Fetching and pulling (fast-forward only)…"
    if ! run_as_user git -C "$SCCS_HOME" fetch --prune origin; then
        die "git fetch failed"
    fi
    if ! run_as_user git -C "$SCCS_HOME" pull --ff-only; then
        warn "git pull --ff-only failed (diverged history or local edits)"
        warn "Resolve manually in $SCCS_HOME, then re-run Update"
        return 1
    fi

    after="$(run_as_user git -C "$SCCS_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [[ "$before" == "$after" ]]; then
        ok "Already up to date ($after)"
    else
        ok "Updated $before → $after"
        run_as_user git -C "$SCCS_HOME" log --oneline "${before}..${after}" 2>/dev/null | head -15 | sed 's/^/    /' || true
    fi

    # Never: cp sccs.conf.dist → sccs.conf
    [[ -f "$CONF" ]] && ok "config/sccs.conf still present and untouched"

    if [[ -x "$SCCS_HOME/venv/bin/pip" ]]; then
        info "Refreshing Python dependencies to latest…"
        run_as_user "$SCCS_HOME/venv/bin/pip" install --upgrade pip
        run_as_user "$SCCS_HOME/venv/bin/pip" install --upgrade --upgrade-strategy eager -r "$SCCS_HOME/requirements.txt"
        ok "requirements.txt installed (latest)"
    else
        warn "No venv — skip pip (run Install SCCS first)"
    fi

    chown -R "$USERNAME":www-data "$SCCS_HOME"
    [[ -f "$SCCS_HOME/install.sh" ]] && chmod ug+x "$SCCS_HOME/install.sh" || true

    if systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null \
        && systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        ask_yn "Restart ${SERVICE_NAME}.service to load the update?" y
        if [[ "$REPLY" == "y" ]]; then
            systemctl restart "${SERVICE_NAME}.service"
            sleep 1
            if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
                ok "Service restarted"
            else
                warn "Service failed after restart — journalctl -u ${SERVICE_NAME}.service -b"
            fi
        fi
    fi
}

finish_summary() {
    section_title "Summary"
    echo "  ${C_DIM}App${C_RESET}      $SCCS_HOME"
    echo "  ${C_DIM}Config${C_RESET}   $CONF"
    echo "  ${C_DIM}UI${C_RESET}       http://${LAN_ADDR}/"
    echo "  ${C_DIM}Service${C_RESET}  systemctl status ${SERVICE_NAME}"
    echo "  ${C_DIM}Logs${C_RESET}     journalctl -u ${SERVICE_NAME}.service -f"
    echo "  ${C_DIM}Samba${C_RESET}    \\\\${LAN_ADDR}\\sccs  (${USERNAME})"
    echo

    if [[ ${#SKIPPED_NOTES[@]} -gt 0 ]]; then
        echo "  ${C_YELLOW}${C_BOLD}Skipped this session${C_RESET}"
        local note
        for note in "${SKIPPED_NOTES[@]}"; do
            echo "    ${C_DIM}·${C_RESET} $note"
        done
        echo "  ${C_DIM}Re-open this menu to finish when hardware is ready.${C_RESET}"
        echo
    fi

    if [[ "$GROUPS_CHANGED" -eq 1 ]]; then
        echo "  ${C_YELLOW}${C_BOLD}Groups updated${C_RESET} for $USERNAME (${REQUIRED_GROUPS[*]})"
        echo "  ${C_DIM}Service already has them after restart; SSH needs re-login or reboot.${C_RESET}"
        echo
    fi

    if [[ "$NEED_REBOOT" -eq 1 ]]; then
        ask_yn "Reboot now?" n
        if [[ "$REPLY" == "y" ]]; then
            ok "Rebooting…"
            systemctl reboot
        else
            warn "Reboot later if UART / Bluetooth / 1-Wire are not active yet"
        fi
    fi
    echo
    ok "Finished"
    echo
}

# ===========================================================================
# Orchestration
# ===========================================================================

run_install() {
    TOTAL_STEPS=16
    STEP=0
    SKIPPED_NOTES=()
    section_title "Install SCCS"
    info "Full install for a new Pi. Hardware steps can be skipped and finished later."
    info "Existing sccs.conf is never replaced."
    echo
    ask_yn "Start Install SCCS?" y
    [[ "$REPLY" == "y" ]] || return 0

    step_packages
    step_groups_and_dirs
    step_repo
    step_samba
    step_nginx
    step_venv
    step_config
    step_sensors optional
    step_boot_firmware
    step_esp optional
    step_victron optional
    step_lan optional
    step_usb_tether optional
    step_screens optional
    step_service
    step_checklist
    finish_summary
}

run_partial() {
    local title="$1"
    shift
    TOTAL_STEPS=0
    STEP=0
    SKIPPED_NOTES=()
    section_title "$title"
    "$@"
    finish_summary
}

usage() {
    cat <<EOF
${C_BOLD}SCCS setup${C_RESET}

  sudo $0                 Interactive menu
  sudo $0 --install       Install SCCS
  sudo $0 --update        Pull latest code (keeps sccs.conf)
  sudo $0 --sensors       1-Wire temperature sensors
  sudo $0 --esp           Flash ESP32 firmware
  sudo $0 --victron       Victron Instant Readout
  sudo $0 --lan           LAN gateway + Pi-hole DHCP/DNS
  sudo $0 --usb-tether    Phone USB internet
  sudo $0 --screens       Touchscreen SSH / blank setup
  sudo $0 --service       Install / restart systemd service
  sudo $0 --help          This help

Environment: USERNAME  SCCS_HOME  LAN_ADDR  REPO_URL
EOF
}

show_menu() {
    while true; do
        logo
        show_context
        echo "  ${C_BOLD}${C_WHITE}Main menu${C_RESET}"
        hr
        echo "  ${C_CYAN}1${C_RESET}  Install SCCS"
        echo "  ${C_CYAN}2${C_RESET}  Update from repository"
        echo "  ${C_CYAN}3${C_RESET}  1-Wire temperature sensors"
        echo "  ${C_CYAN}4${C_RESET}  ESP32 firmware (compile + flash)"
        echo "  ${C_CYAN}5${C_RESET}  Victron Instant Readout"
        echo "  ${C_CYAN}6${C_RESET}  LAN gateway · Pi-hole · NAT"
        echo "  ${C_CYAN}7${C_RESET}  Phone USB internet (tether)"
        echo "  ${C_CYAN}8${C_RESET}  Touchscreens (SSH + blank)"
        echo "  ${C_CYAN}9${C_RESET}  Restart ${SERVICE_NAME} service"
        echo "  ${C_CYAN}q${C_RESET}  Quit"
        echo
        read -r -p "  ${C_BOLD}Select${C_RESET} [1-9 / q]: " choice || true
        case "${choice,,}" in
            1)
                run_install
                pause_enter
                ;;
            2)
                run_partial "Update from repository" step_update
                pause_enter
                ;;
            3)
                run_partial "1-Wire temperature sensors" step_sensors required
                pause_enter
                ;;
            4)
                run_partial "ESP32 firmware" step_esp required
                pause_enter
                ;;
            5)
                run_partial "Victron Instant Readout" step_victron required
                pause_enter
                ;;
            6)
                run_partial "LAN gateway" step_lan required
                pause_enter
                ;;
            7)
                run_partial "Phone USB internet" step_usb_tether required
                pause_enter
                ;;
            8)
                run_partial "Touchscreens" step_screens required
                pause_enter
                ;;
            9)
                run_partial "Service" step_service
                pause_enter
                ;;
            q|quit|exit|"")
                echo
                info "Goodbye."
                echo
                exit 0
                ;;
            *)
                warn "Unknown option: $choice"
                sleep 1
                ;;
        esac
        # reset counters between menu actions
        NEED_REBOOT=0
        GROUPS_CHANGED=0
        SKIPPED_NOTES=()
    done
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

require_root "$@"
resolve_identity

case "${1:-}" in
    --install|install) RUN_MODE=install ;;
    --update|update)   RUN_MODE=update ;;
    --sensors|sensors) RUN_MODE=sensors ;;
    --esp|esp)         RUN_MODE=esp ;;
    --victron|victron) RUN_MODE=victron ;;
    --lan|lan)         RUN_MODE=lan ;;
    --usb-tether|usb-tether|tether) RUN_MODE=usb_tether ;;
    --screens|screens) RUN_MODE=screens ;;
    --service|service) RUN_MODE=service ;;
    --menu|menu|"")    RUN_MODE=menu ;;
    *)
        fail "Unknown option: $1"
        usage
        exit 1
        ;;
esac

case "$RUN_MODE" in
    menu)    show_menu ;;
    install) logo; show_context; run_install ;;
    update)  logo; show_context; run_partial "Update from repository" step_update ;;
    sensors) logo; show_context; run_partial "1-Wire temperature sensors" step_sensors required ;;
    esp)     logo; show_context; run_partial "ESP32 firmware" step_esp required ;;
    victron) logo; show_context; run_partial "Victron Instant Readout" step_victron required ;;
    lan)     logo; show_context; run_partial "LAN gateway" step_lan required ;;
    usb_tether) logo; show_context; run_partial "Phone USB internet" step_usb_tether required ;;
    screens) logo; show_context; run_partial "Touchscreens" step_screens required ;;
    service) logo; show_context; run_partial "Service" step_service ;;
esac
