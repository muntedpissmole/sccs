#!/usr/bin/env bash
# SCCS Demo — install, update, or remove the systemd service for this checkout.
#
#   git clone -b demo https://github.com/muntedpissmole/sccs.git sccs-demo
#   cd sccs-demo
#   sudo ./install.sh              # menu
#   sudo ./install.sh --install    # Install Service
#   sudo ./install.sh --update     # Pull latest demo + deps + restart
#   sudo ./install.sh --uninstall  # Uninstall Service
#
# Install root is always the folder containing this script.
#
set -euo pipefail

if [[ ! -t 0 ]] && ( : </dev/tty ) 2>/dev/null; then
    exec </dev/tty
fi

# ---------------------------------------------------------------------------
# Paths — derived from this script's location (the checkout / install root)
# ---------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
INSTALL_DIR="$(dirname "$SCRIPT_PATH")"
SERVICE_NAME="${SERVICE_NAME:-sccs}"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
CONF="${INSTALL_DIR}/config/sccs.conf"
CONF_DIST="${INSTALL_DIR}/config/sccs.conf.dist"
VENV="${INSTALL_DIR}/venv"
PYTHON="${VENV}/bin/python3"
APP="${INSTALL_DIR}/app.py"

# Owner of the install tree (the user who cloned it), not root.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    USERNAME="${SUDO_USER}"
else
    USERNAME="$(stat -c '%U' "$INSTALL_DIR" 2>/dev/null || echo root)"
fi
USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
[[ -n "$USER_HOME" ]] || USER_HOME="/home/${USERNAME}"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
else
    C_RESET= C_BOLD= C_DIM= C_GREEN= C_YELLOW= C_RED= C_CYAN=
fi

info()  { echo "  ${C_DIM}•${C_RESET} $*"; }
ok()    { echo "  ${C_GREEN}✓${C_RESET} $*"; }
warn()  { echo "  ${C_YELLOW}!${C_RESET} $*"; }
fail()  { echo "  ${C_RED}✗${C_RESET} $*" >&2; }
die()   { fail "$*"; exit 1; }

hr() {
    echo "${C_DIM}  ────────────────────────────────────────────────────────${C_RESET}"
}

logo() {
    local ver=""
    echo
    echo "${C_CYAN}${C_BOLD}"
    cat <<'EOF'
   ███████╗  ██████╗  ██████╗ ███████╗
  ██╔════╝ ██╔════╝ ██╔════╝ ██╔════╝
  ███████╗ ██║      ██║      ███████╗
  ╚════██║ ██║      ██║      ╚════██║
  ███████║ ╚██████╗ ╚██████╗ ███████║
   ╚══════╝  ╚═════╝  ╚═════╝ ╚══════╝
EOF
    if [[ -r "${INSTALL_DIR}/VERSION" ]]; then
        ver="$(tr -d '[:space:]' <"${INSTALL_DIR}/VERSION" 2>/dev/null || true)"
    fi
    if [[ -n "$ver" ]]; then
        echo "${C_RESET}${C_DIM}  Singularity Camper Control System Demo · v${ver}${C_RESET}"
    else
        echo "${C_RESET}${C_DIM}  Singularity Camper Control System Demo${C_RESET}"
    fi
    hr
    echo
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

require_checkout() {
    [[ -f "$APP" ]] || die "app.py not found in $INSTALL_DIR — run this from a demo branch checkout"
    [[ -f "${INSTALL_DIR}/requirements.txt" ]] || die "requirements.txt missing in $INSTALL_DIR"
    [[ -f "$CONF_DIST" ]] || die "Missing $CONF_DIST"
}

run_as_user() {
    sudo -u "$USERNAME" -H -- "$@"
}

read_input() {
    local prompt="$1"
    REPLY_LINE=""
    if ( : </dev/tty ) 2>/dev/null; then
        read -r -p "$prompt" REPLY_LINE </dev/tty || return 1
    elif [[ -t 0 ]]; then
        read -r -p "$prompt" REPLY_LINE || return 1
    else
        return 1
    fi
    return 0
}

ask_yn() {
    local prompt="$1" def="${2:-n}" hint ans
    if [[ "$def" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        if ! read_input "  ${prompt} [${hint}]: "; then
            die "No interactive terminal available for prompts"
        fi
        ans="${REPLY_LINE:-$def}"
        case "${ans,,}" in
            y|yes) REPLY=y; return 0 ;;
            n|no)  REPLY=n; return 0 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

show_context() {
    echo "  ${C_DIM}User${C_RESET}      ${C_BOLD}${USERNAME}${C_RESET}"
    echo "  ${C_DIM}Install${C_RESET}   ${C_BOLD}${INSTALL_DIR}${C_RESET}"
    echo "  ${C_DIM}Service${C_RESET}   ${C_BOLD}${SERVICE_NAME}.service${C_RESET}"
    if systemctl cat "${SERVICE_NAME}.service" &>/dev/null; then
        if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
            echo "  ${C_DIM}Status${C_RESET}    ${C_GREEN}active${C_RESET}"
        elif systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
            echo "  ${C_DIM}Status${C_RESET}    ${C_YELLOW}installed (inactive)${C_RESET}"
        else
            echo "  ${C_DIM}Status${C_RESET}    ${C_DIM}unit present${C_RESET}"
        fi
    else
        echo "  ${C_DIM}Status${C_RESET}    ${C_DIM}not installed${C_RESET}"
    fi
    echo
}

# ---------------------------------------------------------------------------
# Install steps
# ---------------------------------------------------------------------------

install_packages() {
    echo "  ${C_BOLD}System packages${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        python3 \
        python3-venv \
        python3-pip \
        python3-dev \
        python3-lgpio \
        build-essential \
        >/dev/null
    ok "python3 + venv + build tools"
}

setup_venv() {
    echo "  ${C_BOLD}Python virtualenv${C_RESET}"
    if [[ ! -x "$PYTHON" ]]; then
        info "Creating venv at $VENV"
        # system-site-packages so python3-lgpio (if present) is visible
        run_as_user python3 -m venv --system-site-packages "$VENV"
        ok "venv created"
    else
        ok "venv already exists"
    fi
    info "Installing Python dependencies from requirements.txt"
    run_as_user "$VENV/bin/pip" install --upgrade pip >/dev/null
    run_as_user "$VENV/bin/pip" install --upgrade --upgrade-strategy eager \
        -r "${INSTALL_DIR}/requirements.txt"
    ok "Python packages installed"
}

setup_config() {
    echo "  ${C_BOLD}Config${C_RESET}"
    mkdir -p "${INSTALL_DIR}/config" "${INSTALL_DIR}/logs"
    chown -R "$USERNAME":"$USERNAME" "${INSTALL_DIR}/config" "${INSTALL_DIR}/logs" 2>/dev/null || true

    if [[ ! -f "$CONF" ]]; then
        run_as_user cp "$CONF_DIST" "$CONF"
        ok "Created config/sccs.conf from sccs.conf.dist"
    else
        ok "Using existing config/sccs.conf"
    fi

    # Ensure demo mode is on for this branch install.
    python3 - "$CONF" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()

def set_in_section(text, section, key, value):
    header = re.compile(rf"(?m)^\[{re.escape(section)}\][ \t]*\r?\n")
    m = header.search(text)
    if not m:
        # Append a minimal section
        return text.rstrip() + f"\n\n[{section}]\n{key} = {value}\n"
    start = m.end()
    nxt = re.compile(r"(?m)^\[[^\]]+\][ \t]*\r?\n")
    m2 = nxt.search(text, start)
    end = m2.start() if m2 else len(text)
    block = text[start:end]
    pat = re.compile(rf"(?m)^({re.escape(key)}[ \t]*=[ \t]*).*$")
    if pat.search(block):
        block = pat.sub(rf"\g<1>{value}", block, count=1)
    else:
        block = f"{key} = {value}\n" + block
    return text[:start] + block + text[end:]

# demo.enabled
if re.search(r"(?m)^\[demo\]", text):
    text = set_in_section(text, "demo", "enabled", "true")
else:
    text = text.rstrip() + "\n\n[demo]\nenabled = true\n"

# secret_key if still placeholder
secret_pat = re.compile(r"(?m)^(secret_key[ \t]*=[ \t]*)(.*)$")
m = secret_pat.search(text)
if m and m.group(2).strip() in ("", "CHANGE_ME_TO_A_LONG_RANDOM_STRING"):
    import secrets
    text = secret_pat.sub(lambda mo: mo.group(1) + secrets.token_urlsafe(48), text, count=1)

open(path, "w", encoding="utf-8").write(text)
PY
    chown "$USERNAME":"$USERNAME" "$CONF" 2>/dev/null || true
    ok "Demo mode enabled in sccs.conf"
}

write_service() {
    echo "  ${C_BOLD}systemd service${C_RESET}"
    [[ -x "$PYTHON" ]] || die "venv python missing at $PYTHON"
    [[ -f "$APP" ]] || die "app.py missing at $APP"

    # Group www-data is used by the production unit; for demo fall back to the
    # user's primary group if www-data is not present.
    local group="www-data"
    if ! getent group www-data >/dev/null 2>&1; then
        group="$(id -gn "$USERNAME")"
    else
        # Ensure the run user can use www-data as supplementary group
        if ! id -nG "$USERNAME" | tr ' ' '\n' | grep -qx www-data; then
            usermod -aG www-data "$USERNAME" 2>/dev/null || true
        fi
    fi

    cat >"$UNIT_PATH" <<EOF
[Unit]
Description=SCCS Demo (Singularity Camper Control System)
Documentation=file://${INSTALL_DIR}/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USERNAME}
Group=${group}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${PYTHON} ${APP}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
Environment=PYTHONUNBUFFERED=1
# Hard-code install root so the service does not depend on cwd or \$HOME
Environment=SCCS_HOME=${INSTALL_DIR}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    # Drop a copy next to the checkout for reference (not required by systemd).
    cp -a "$UNIT_PATH" "${INSTALL_DIR}/${SERVICE_NAME}.service"
    chown "$USERNAME":"$USERNAME" "${INSTALL_DIR}/${SERVICE_NAME}.service" 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    systemctl restart "${SERVICE_NAME}.service"
    sleep 1
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        ok "${SERVICE_NAME}.service is active and enabled at boot"
    else
        warn "${SERVICE_NAME}.service failed to start — check: journalctl -u ${SERVICE_NAME} -b --no-pager"
        systemctl status "${SERVICE_NAME}.service" --no-pager -l || true
        return 1
    fi

    info "Unit file: $UNIT_PATH"
    info "WorkingDirectory / ExecStart rooted at: $INSTALL_DIR"
}

do_install() {
    require_checkout
    echo
    echo "  ${C_BOLD}Install Service${C_RESET}"
    hr
    info "Directory: ${C_BOLD}${INSTALL_DIR}${C_RESET}"
    info "User:      ${C_BOLD}${USERNAME}${C_RESET}"
    info "Service:   ${C_BOLD}${SERVICE_NAME}.service${C_RESET}"
    echo
    ask_yn "Install service?" y
    [[ "$REPLY" == "y" ]] || { warn "Cancelled"; return 0; }
    echo

    install_packages
    echo
    setup_venv
    echo
    setup_config
    echo
    write_service
    echo
    hr
    ok "Service installed"
    local port
    port="$(python3 - "$CONF" <<'PY' 2>/dev/null || echo 5000
import configparser, sys
c = configparser.ConfigParser()
c.read(sys.argv[1])
print(c.get("system", "port", fallback="5000"))
PY
)"
    info "UI:   http://$(hostname -I 2>/dev/null | awk '{print $1}'):${port}/"
    info "Logs: journalctl -u ${SERVICE_NAME} -f"
    echo
}

# ---------------------------------------------------------------------------
# Update — git pull (ff-only), refresh Python deps, restart service
# ---------------------------------------------------------------------------

# True if a porcelain line is a known install artefact that never blocks update
# (reference unit copied next to the checkout by write_service).
_is_harmless_status_line() {
    local line="$1"
    # Untracked only
    [[ "$line" == \?\?* ]] || return 1
    local path="${line#?? }"
    path="${path#\"}"
    path="${path%\"}"
    case "$path" in
        sccs.service|sccs-demo.service|"${SERVICE_NAME}.service") return 0 ;;
        *.service)
            # Any bare unit file sitting at install root (not under subdirs)
            [[ "$path" != */* ]] && return 0
            ;;
    esac
    return 1
}

# Working-tree dirt that should block/prompt — ignore untracked unit copies.
_git_meaningful_dirty() {
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if _is_harmless_status_line "$line"; then
            continue
        fi
        printf '%s\n' "$line"
    done < <(run_as_user git -C "$INSTALL_DIR" status --porcelain 2>/dev/null || true)
}

do_update() {
    require_checkout
    echo
    echo "  ${C_BOLD}Update${C_RESET}"
    hr
    info "Directory: ${C_BOLD}${INSTALL_DIR}${C_RESET}"
    info "User:      ${C_BOLD}${USERNAME}${C_RESET}"
    info "Service:   ${C_BOLD}${SERVICE_NAME}.service${C_RESET}"
    echo
    info "Pulling latest demo branch, refreshing packages, restarting service…"
    info "Existing config/sccs.conf is kept (demo mode re-asserted)."
    echo

    [[ -d "${INSTALL_DIR}/.git" ]] || die "Not a git checkout — cannot update"

    local before after dirty branch service_restarted=0
    before="$(run_as_user git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    branch="$(run_as_user git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo demo)"
    info "Current revision: ${before} (${branch})"

    dirty="$(_git_meaningful_dirty || true)"
    if [[ -n "${dirty// }" ]]; then
        # Non-interactive: note dirt but proceed (pull may still fail on conflicts).
        warn "Working tree has local changes (continuing anyway):"
        printf '%s\n' "$dirty" | sed 's/^/    /'
        echo
    fi

    echo "  ${C_BOLD}Git${C_RESET}"
    info "Fetching and pulling (fast-forward only)…"
    if ! run_as_user env GIT_TERMINAL_PROMPT=0 git -C "$INSTALL_DIR" fetch --prune origin; then
        die "git fetch failed (check network access to GitHub)"
    fi
    # Prefer tracking branch; fall back to origin/demo then origin/main.
    local pull_ref=""
    if run_as_user git -C "$INSTALL_DIR" rev-parse --abbrev-ref '@{u}' &>/dev/null; then
        pull_ref=""
        if ! run_as_user env GIT_TERMINAL_PROMPT=0 git -C "$INSTALL_DIR" pull --ff-only; then
            warn "git pull --ff-only failed (diverged history or local edits)"
            warn "Resolve manually in $INSTALL_DIR, then re-run Update"
            return 1
        fi
    else
        if run_as_user git -C "$INSTALL_DIR" rev-parse --verify origin/demo &>/dev/null; then
            pull_ref="origin/demo"
        elif run_as_user git -C "$INSTALL_DIR" rev-parse --verify origin/main &>/dev/null; then
            pull_ref="origin/main"
        else
            die "No origin/demo or origin/main after fetch"
        fi
        info "No upstream set — fast-forwarding to ${pull_ref}"
        if ! run_as_user env GIT_TERMINAL_PROMPT=0 git -C "$INSTALL_DIR" merge --ff-only "$pull_ref"; then
            warn "git merge --ff-only ${pull_ref} failed"
            warn "Resolve manually in $INSTALL_DIR, then re-run Update"
            return 1
        fi
    fi

    after="$(run_as_user git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [[ "$before" == "$after" ]]; then
        ok "Already up to date ($after)"
    else
        ok "Updated $before → $after"
        run_as_user git -C "$INSTALL_DIR" log --oneline "${before}..${after}" 2>/dev/null \
            | head -15 | sed 's/^/    /' || true
    fi

    # New files from pull should belong to the install user.
    chown -R "$USERNAME":"$USERNAME" "$INSTALL_DIR" 2>/dev/null || true
    chmod ug+x "${INSTALL_DIR}/install.sh" 2>/dev/null || true

    echo
    setup_venv
    echo
    setup_config
    echo

    if systemctl cat "${SERVICE_NAME}.service" &>/dev/null || [[ -f "$UNIT_PATH" ]]; then
        echo "  ${C_BOLD}Service${C_RESET}"
        # Refresh unit + always restart so the new code is loaded.
        if write_service; then
            service_restarted=1
        else
            warn "Unit rewrite had issues — forcing restart anyway"
            systemctl daemon-reload 2>/dev/null || true
            systemctl restart "${SERVICE_NAME}.service" 2>/dev/null || true
            sleep 1
            if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
                service_restarted=1
            fi
        fi
    else
        warn "Service not installed — code/deps updated; run Install Service to enable"
    fi

    echo
    hr
    ok "Update complete"
    if [[ "$service_restarted" -eq 1 ]] && systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        ok "Service ${SERVICE_NAME}.service has been restarted and is active"
    elif [[ "$service_restarted" -eq 1 ]]; then
        warn "Service restart was attempted but ${SERVICE_NAME}.service is not active"
        warn "Check: journalctl -u ${SERVICE_NAME} -b --no-pager"
    fi
    local port
    port="$(python3 - "$CONF" <<'PY' 2>/dev/null || echo 5000
import configparser, sys
c = configparser.ConfigParser()
c.read(sys.argv[1])
print(c.get("system", "port", fallback="5000"))
PY
)"
    info "UI:   http://$(hostname -I 2>/dev/null | awk '{print $1}'):${port}/"
    info "Logs: journalctl -u ${SERVICE_NAME} -f"
    echo
}

# ---------------------------------------------------------------------------
# Uninstall Service — stop and remove the systemd unit only
# ---------------------------------------------------------------------------

do_uninstall() {
    echo
    echo "  ${C_BOLD}Uninstall Service${C_RESET}"
    hr
    info "Service: ${C_BOLD}${SERVICE_NAME}.service${C_RESET}"
    info "Removes the systemd unit only (checkout is kept)."
    echo
    ask_yn "Uninstall service?" n
    [[ "$REPLY" == "y" ]] || { warn "Cancelled"; return 0; }
    echo

    if systemctl cat "${SERVICE_NAME}.service" &>/dev/null || [[ -f "$UNIT_PATH" ]]; then
        systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
        rm -f "$UNIT_PATH"
        rm -f /etc/systemd/system/sccs-demo.service
        systemctl daemon-reload
        systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true
        ok "Removed ${SERVICE_NAME}.service"
    else
        ok "No ${SERVICE_NAME}.service unit found"
    fi

    # Reference copy next to the checkout (not required by systemd)
    rm -f "${INSTALL_DIR}/${SERVICE_NAME}.service" "${INSTALL_DIR}/sccs.service" 2>/dev/null || true

    echo
    hr
    ok "Service uninstalled"
    echo
}

# ---------------------------------------------------------------------------
# CLI / menu
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
${C_BOLD}SCCS Demo${C_RESET}

  Directory: ${INSTALL_DIR}

  git clone -b demo https://github.com/muntedpissmole/sccs.git sccs-demo
  cd sccs-demo
  sudo ./install.sh --install

  sudo $0                 Menu
  sudo $0 --install       Install Service
  sudo $0 --update        Update (pull + deps + restart)
  sudo $0 --uninstall     Uninstall Service
  sudo $0 --help          This help
EOF
}

menu() {
    while true; do
        logo
        show_context
        echo "  ${C_BOLD}1)${C_RESET}  Install Service"
        echo "  ${C_BOLD}2)${C_RESET}  Update"
        echo "  ${C_BOLD}3)${C_RESET}  Uninstall Service"
        echo "  ${C_BOLD}q)${C_RESET}  Quit"
        echo
        if ! read_input "  Choose: "; then
            die "No interactive terminal"
        fi
        case "${REPLY_LINE,,}" in
            1|i|install)   do_install; pause_menu ;;
            2|up|update)   do_update; pause_menu ;;
            3|u|uninstall) do_uninstall; pause_menu ;;
            q|quit|exit)   echo; exit 0 ;;
            *) warn "Unknown choice" ; sleep 1 ;;
        esac
    done
}

pause_menu() {
    echo
    read_input "  ${C_DIM}Press Enter to return to the menu…${C_RESET} " || true
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

require_root "$@"
cd "$INSTALL_DIR"

MODE="menu"
case "${1:-}" in
    "" ) MODE="menu" ;;
    --install|install|-i) MODE="install" ;;
    --update|update|-U) MODE="update" ;;
    --uninstall|uninstall|-u) MODE="uninstall" ;;
    --help|-h|help) logo; usage; exit 0 ;;
    *)
        fail "Unknown option: $1"
        usage
        exit 1
        ;;
esac

case "$MODE" in
    # menu() draws the logo itself each iteration — do not call logo here
    menu)      menu ;;
    install)   logo; show_context; do_install ;;
    update)    logo; show_context; do_update ;;
    uninstall) logo; show_context; do_uninstall ;;
esac
