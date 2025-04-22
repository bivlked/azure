cat > install.sh << 'EOF'
#!/bin/bash

# ==============================================================================
# Install AmneziaWG on Ubuntu 24.04 LTS Minimal (Azure ARM64 Interactive)
# Version: 2.5 (Final Cleaned)
# Author: @bivlked & Gemini
# Repo: https://github.com/bivlked/azure
# ==============================================================================

# --- Strict modes & Constants ---
set -o pipefail
set -o nounset

# --- User & Home Directory Detection ---
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [[ -z "$TARGET_HOME" ]] || [[ ! -d "$TARGET_HOME" ]]; then echo "[ERROR] Cannot determine home directory for '$TARGET_USER'." >&2; exit 1; fi
else
    TARGET_USER="root"; TARGET_HOME="/root"
    if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then echo "[WARN] Running as root. Work dir: ${TARGET_HOME}/awg" >&2; fi
fi

# --- Paths & Filenames ---
AWG_DIR="${TARGET_HOME}/awg"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
STATE_FILE="$AWG_DIR/setup_state"
CLIENT_TEMPLATE_FILE="$AWG_DIR/_defclient.config"
PYTHON_VENV="$AWG_DIR/venv"
PYTHON_EXEC="$PYTHON_VENV/bin/python"
AWGCFG_SCRIPT="$AWG_DIR/awgcfg.py"
MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/azure/main/manage.sh"
MANAGE_SCRIPT_PATH="$AWG_DIR/manage.sh"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"

# --- Script Options ---
HELP=0; VERBOSE=0; NO_COLOR=0;
DISABLE_IPV6=1;

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h) HELP=1;;
        --verbose|-v) VERBOSE=1;;
        --no-color) NO_COLOR=1;;
        *) echo "[ERROR] Unknown argument: $1"; HELP=1;;
    esac
    shift
done

# --- Logging Functions ---
log_msg() {
    local type="$1" msg="$2" ts color_start="" color_end="\033[0m" safe_msg entry
    ts=$(date +'%F %T'); safe_msg=$(echo "$msg" | sed 's/%/%%/g'); entry="[$ts] $type: $safe_msg"
    if [[ "$NO_COLOR" -eq 0 ]]; then case "$type" in INFO) color_start="\033[0;32m";; WARN) color_start="\033[0;33m";; ERROR) color_start="\033[1;31m";; DEBUG) color_start="\033[0;36m";; STEP) color_start="\033[1;34m";; *) color_start=""; color_end="";; esac; fi
    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then printf "${color_start}%s${color_end}\n" "$entry" >&2;
    elif [[ "$type" == "DEBUG" && "$VERBOSE" -eq 1 ]]; then printf "${color_start}%s${color_end}\n" "$entry" >&2;
    elif [[ "$type" == "INFO" || "$type" == "STEP" ]]; then printf "${color_start}%s${color_end}\n" "$entry"; fi
}
log() { log_msg "INFO" "$1"; }; log_warn() { log_msg "WARN" "$1"; }; log_error() { log_msg "ERROR" "$1"; }; log_debug() { if [[ "$VERBOSE" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }; log_step() { log_msg "STEP" "$1"; };
die() { log_error "FATAL ERROR: $1"; log_error "Installation aborted."; exit 1; }

# --- Helper Functions ---
show_help() {
    cat << EOF
Usage: sudo bash $0 [OPTIONS]
Installs AmneziaWG interactively on Ubuntu 24.04 Minimal (Azure ARM64).

Options:
  -h, --help     Show this help and exit
  -v, --verbose  Enable verbose output for debugging
  --no-color     Disable colored output

Description:
  Guides through AmneziaWG installation, system configuration (disables IPv6),
  config generation, service start, and downloads 'manage.sh' script.
  Designed for Azure, does not configure local firewall.

Work directory: ${TARGET_HOME}/awg
EOF
    exit 0
}
update_state() {
    local next_step=$1; mkdir -p "$(dirname "$STATE_FILE")" || die "Cannot create state directory"; echo "$next_step" > "$STATE_FILE" || die "Cannot write state file $STATE_FILE"; chown "${TARGET_USER}:${TARGET_USER}" "$STATE_FILE" || log_warn "Cannot chown $STATE_FILE"; log_debug "State saved: step $next_step";
}
request_reboot() {
    local next_step=$1; update_state "$next_step"; log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; log_warn "!!! SYSTEM REBOOT REQUIRED TO APPLY CHANGES !!!"; log_warn "!!! After reboot, run again: sudo bash $0        !!!"; log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; read -p "Reboot now? [y/N]: " confirm < /dev/tty; if [[ "$confirm" =~ ^[YyЕе]$ ]]; then log "Rebooting..."; sleep 3; if ! reboot; then die "Reboot command failed. Reboot manually and run script again."; fi; exit 1; else log_warn "Reboot cancelled. Please reboot manually and run script again."; exit 1; fi
}
check_os_version() {
    log "Checking OS and architecture..."; local os_ok=1 arch_ok=1
    if command -v lsb_release &> /dev/null; then local os_id; os_id=$(lsb_release -si); local os_ver; os_ver=$(lsb_release -sr); if [[ "$os_id" != "Ubuntu" || "$os_ver" != "24.04" ]]; then log_warn "OS: $os_id $os_ver. Recommended: Ubuntu 24.04."; os_ok=0; else log "OS: Ubuntu $os_ver (OK)"; fi; else log_warn "'lsb_release' not found."; fi; local arch; arch=$(uname -m); if [[ "$arch" != "aarch64" ]]; then log_warn "Architecture: $arch. Recommended: aarch64."; arch_ok=0; else log "Architecture: aarch64 (OK)"; fi
    if [[ "$os_ok" -eq 0 || "$arch_ok" -eq 0 ]]; then read -p "Continue anyway? [y/N]: " confirm < /dev/tty; if ! [[ "$confirm" =~ ^[YyЕе]$ ]]; then die "Aborted by user."; fi; fi
}
check_free_space() {
    log "Checking free disk space..."; local req=1024 avail; avail=$(df -m / | awk 'NR==2 {print $4}'); if [[ -z "$avail" ]]; then log_warn "Cannot determine free space."; return 0; fi; if [[ "$avail" -lt "$req" ]]; then log_warn "Low disk space: ${avail}MB. Recommended >= ${req}MB."; read -p "Continue? [y/N]: " confirm < /dev/tty; if ! [[ "$confirm" =~ ^[YyЕе]$ ]]; then die "Aborted by user due to low disk space."; fi; else log "Free space: ${avail}MB (OK)"; fi
}
check_port_availability() {
    local port=$1; log "Checking UDP port ${port}..."; if ss -lunp | grep -q ":${port} "; then log_error "Port ${port}/udp is already in use:"; ss -lunp | grep ":${port} " | sed 's/^/  /' | log_msg "ERROR"; return 1; else log "Port ${port}/udp is free (OK)."; return 0; fi
}
install_packages() {
    local packages_to_install=("$@") missing_packages=(); log_debug "Checking packages: ${packages_to_install[*]:-}"; for pkg in "${packages_to_install[@]}"; do if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then missing_packages+=("$pkg"); fi; done; if [ ${#missing_packages[@]} -eq 0 ]; then log_debug "All required packages already installed."; return 0; fi; log "The following packages will be installed: ${missing_packages[*]}"; log "Updating apt package list..."; apt update -y || log_warn "apt update failed. Proceeding with install attempt..."; log "Installing packages..."; if ! DEBIAN_FRONTEND=noninteractive apt install -y "${missing_packages[@]}"; then die "Failed to install packages: ${missing_packages[*]}"; fi; log "Packages installed successfully.";
}
cleanup_apt() { log "Cleaning up apt cache..."; apt-get clean -y || log_warn "apt-get clean failed"; rm -rf /var/lib/apt/lists/* || log_warn "Failed to remove apt lists"; log "Apt cache cleaned."; }
configure_routing_mode() {
    echo ""; log "Select client routing mode (AllowedIPs):"; echo "  1) All traffic (0.0.0.0/0)"; echo "  2) Amnezia lists + DNS (Default)"; echo "  3) Custom networks"; read -p "Choice [2]: " r_mode < /dev/tty; ALLOWED_IPS_MODE=${r_mode:-2}; case "$ALLOWED_IPS_MODE" in 1) ALLOWED_IPS="0.0.0.0/0"; log "Mode: All traffic";; 3) read -p "Enter custom networks (comma-separated, e.g., 192.168.1.0/24): " custom_ips < /dev/tty; if ! echo "$custom_ips" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}(,([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2})*$'; then log_warn "Custom networks format ('$custom_ips') seems invalid."; fi; ALLOWED_IPS=$custom_ips; log "Mode: Custom ($ALLOWED_IPS)";; *) ALLOWED_IPS_MODE=2; ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"; log "Mode: Amnezia lists + DNS";; esac; if [ -z "$ALLOWED_IPS" ]; then die "Failed to determine AllowedIPs."; fi; export ALLOWED_IPS_MODE ALLOWED_IPS;
}
run_awgcfg() {
    log_debug "Running awgcfg.py $*"; if [ ! -x "$PYTHON_EXEC" ]; then log_error "Python not found or not executable: $PYTHON_EXEC"; return 1; fi; if [ ! -x "$AWGCFG_SCRIPT" ]; then log_error "awgcfg.py not found or not executable: $AWGCFG_SCRIPT"; return 1; fi; if ! (cd "$AWG_DIR" && "$PYTHON_EXEC" "$AWGCFG_SCRIPT" "$@"); then log_error "awgcfg.py failed: '$PYTHON_EXEC $AWGCFG_SCRIPT $*'"; return 1; fi; chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png &> /dev/null || true; find "$AWG_DIR" -maxdepth 1 -name "*.conf" -type f -exec chmod 600 {} \; &> /dev/null; find "$AWG_DIR" -maxdepth 1 -name "*.png" -type f -exec chmod 644 {} \; &> /dev/null; log_debug "awgcfg.py '$*' completed."; return 0;
}
check_service_status() {
    log "Checking AmneziaWG service status..."; local all_ok=1; if systemctl is-active --quiet awg-quick@awg0; then log " - Service: active (running)"; else local state; state=$(systemctl show -p SubState --value awg-quick@awg0 2>/dev/null || echo "unknown"); if systemctl is-failed --quiet awg-quick@awg0; then log_error " - Service: FAILED ($state)"; all_ok=0; else log_warn " - Service: inactive ($state)"; all_ok=0; fi; journalctl -u awg-quick@awg0 -n 5 --no-pager --output=cat | sed 's/^/    /' >&2; fi; if ip addr show awg0 &>/dev/null; then log " - Interface: awg0 exists"; else log_error " - Interface: awg0 NOT found!"; all_ok=0; fi; if awg show | grep -q "interface: awg0"; then log " - 'awg show': sees awg0"; else log_error " - 'awg show': does NOT see awg0!"; all_ok=0; fi; local port=${AWG_PORT:-0}; if [ "$port" -eq 0 ] && [ -f "$CONFIG_FILE" ]; then port=$(grep '^export AWG_PORT=' "$CONFIG_FILE" | cut -d'=' -f2); port=${port:-0}; fi; if [ "$port" -ne 0 ]; then if ss -lunp | grep -q ":${port} "; then log " - Port: ${port}/udp listening (OK)"; else log_error " - Port: ${port}/udp NOT listening!"; all_ok=0; fi; else log_warn " - Port: Could not determine port to check."; fi; if [ "$all_ok" -eq 1 ]; then log "Status check: PASSED"; return 0; else log_error "Status check: FAILED"; return 1; fi
}
configure_kernel_parameters() {
    log "Configuring kernel parameters (IPv4 forward, disable IPv6)..."; local f="/etc/sysctl.d/99-amneziawg-vpn.conf"; { echo "# AmneziaWG VPN Settings - $(date)"; echo "net.ipv4.ip_forward = 1"; echo ""; echo "# Disable IPv6"; echo "net.ipv6.conf.all.disable_ipv6 = 1"; echo "net.ipv6.conf.default.disable_ipv6 = 1"; echo "net.ipv6.conf.lo.disable_ipv6 = 1"; } > "$f" || die "Failed to write sysctl config $f"; log "Applying sysctl settings..."; if ! sysctl -p "$f" > /dev/null; then log_warn "Failed to apply $f immediately. Should apply on reboot."; else log "Sysctl settings applied."; fi; local v4; v4=$(sysctl -n net.ipv4.ip_forward); local v6; v6=$(sysctl -n net.ipv6.conf.all.disable_ipv6); if [[ "$v4" != "1" || "$v6" != "1" ]]; then log_warn "Sysctl values not immediately reflected. Reboot needed."; fi
}
secure_files() {
    log_debug "Securing files and directories..."; if [ -d "$AWG_DIR" ]; then chmod 700 "$AWG_DIR"; chown -R "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"; find "$AWG_DIR" -type f -name "*.conf" -exec chmod 600 {} \; &> /dev/null; find "$AWG_DIR" -type f -name "*.png" -exec chmod 644 {} \; &> /dev/null; find "$AWG_DIR" -type f -name "*.py" -exec chmod 750 {} \; &> /dev/null; find "$AWG_DIR" -type f -name "*.sh" -exec chmod 750 {} \; &> /dev/null; find "$PYTHON_VENV/bin/" -type f -exec chmod 750 {} \; &> /dev/null; fi; if [ -d "/etc/amnezia" ]; then chmod 700 "/etc/amnezia"; if [ -d "/etc/amnezia/amneziawg" ]; then chmod 700 "/etc/amnezia/amneziawg"; find "/etc/amnezia/amneziawg" -type f -name "*.conf" -exec chmod 600 {} \; &> /dev/null; fi; fi; if [ -f "$CONFIG_FILE" ]; then chmod 600 "$CONFIG_FILE"; fi; if [ -f "$STATE_FILE" ]; then chmod 640 "$STATE_FILE"; fi; log_debug "File permissions set.";
}

# --- STEP 0: Initialization & Parameter Gathering ---
initialize_setup() {
    log_step "--- STEP 0: Initialization & Parameters ---"; if [ "$(id -u)" -ne 0 ]; then die "This script must be run with sudo."; fi; mkdir -p "$AWG_DIR"; chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"; chmod 700 "$AWG_DIR"; cd "$AWG_DIR" || die "Cannot enter $AWG_DIR"; log "Work directory: $AWG_DIR"; check_os_version; check_free_space; local default_port=39743 default_subnet="10.9.9.1/24" config_exists=0; AWG_PORT=$default_port; AWG_TUNNEL_SUBNET=$default_subnet; ALLOWED_IPS_MODE=""; ALLOWED_IPS=""; if [[ -f "$CONFIG_FILE" ]]; then log "Loading configuration from $CONFIG_FILE..."; source "$CONFIG_FILE" 2>/dev/null || log_warn "Failed to source $CONFIG_FILE."; config_exists=1; AWG_PORT=${AWG_PORT:-$default_port}; AWG_TUNNEL_SUBNET=${AWG_TUNNEL_SUBNET:-$default_subnet}; ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE:-""}; ALLOWED_IPS=${ALLOWED_IPS:-""}; if [[ -n "$ALLOWED_IPS_MODE" && -z "$ALLOWED_IPS" ]]; then log_warn "Routing mode ($ALLOWED_IPS_MODE) loaded but IPs missing. Resetting to mode 2."; ALLOWED_IPS_MODE=2; ALLOWED_IPS="0.0.0.0/5,..."; fi; log "Configuration loaded."; else log "Configuration file not found. Requesting parameters..."; while true; do read -p "UDP Port (1024-65535) [$AWG_PORT]: " input_port < /dev/tty; input_port=${input_port:-$AWG_PORT}; if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1024 ] && [ "$input_port" -le 65535 ]; then AWG_PORT=$input_port; break; else log_error "Invalid port."; fi; done; while true; do read -p "Tunnel Subnet [$AWG_TUNNEL_SUBNET]: " input_subnet < /dev/tty; input_subnet=${input_subnet:-$AWG_TUNNEL_SUBNET}; if [[ "$input_subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then AWG_TUNNEL_SUBNET=$input_subnet; break; else log_error "Invalid subnet format."; fi; done; configure_routing_mode; fi; check_port_availability "$AWG_PORT" || die "Port $AWG_PORT/udp is in use."; log "Saving configuration to $CONFIG_FILE..."; local temp_conf; temp_conf=$(mktemp) || die "mktemp failed."; { echo "# AmneziaWG Config"; echo "export AWG_PORT=${AWG_PORT}"; echo "export AWG_TUNNEL_SUBNET='${AWG_TUNNEL_SUBNET}'"; echo "export DISABLE_IPV6=${DISABLE_IPV6}"; echo "export ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE}"; echo "export ALLOWED_IPS='${ALLOWED_IPS}'"; } > "$temp_conf" || { rm -f "$temp_conf"; die "Failed to write temp config."; }; if ! mv "$temp_conf" "$CONFIG_FILE"; then rm -f "$temp_conf"; die "Failed to save $CONFIG_FILE"; fi; chmod 600 "$CONFIG_FILE"; chown "${TARGET_USER}:${TARGET_USER}" "$CONFIG_FILE"; log "Configuration saved."; export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS; log "Parameters: Port=${AWG_PORT}, Subnet=${AWG_TUNNEL_SUBNET}, IPv6=${DISABLE_IPV6}, RouteMode=${ALLOWED_IPS_MODE}"; if [[ -f "$STATE_FILE" ]]; then current_step=$(cat "$STATE_FILE"); if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then log_warn "State file $STATE_FILE is invalid. Starting from step 1."; current_step=1; update_state 1; else log "Resuming installation from step $current_step."; fi; else log "Starting installation from step 1."; current_step=1; update_state 1; fi; log_step "--- STEP 0 Completed ---"; echo ""
}

# --- STEP 1: System Update & Kernel Params ---
step1_update_system_and_networking() {
    update_state 1; log_step "### STEP 1: System Update & Kernel Params ###"; log "Updating system packages..."; apt update -y || die "apt update failed."; if fuser /var/lib/dpkg/lock* &>/dev/null; then log_warn "dpkg lock detected. Attempting recovery..."; killall apt apt-get dpkg &>/dev/null; sleep 2; rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*; dpkg --configure -a || log_warn "dpkg --configure -a failed."; apt update -y || die "apt update retry failed."; fi; DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "apt full-upgrade failed."; log "System updated."; install_packages curl wget gpg sudo; configure_kernel_parameters; log_step "--- STEP 1 Completed ---"; request_reboot 2;
}

# --- STEP 2: Install AmneziaWG & Dependencies ---
step2_install_amnezia() {
    update_state 2; log_step "### STEP 2: Install AmneziaWG & Dependencies ###"; local sources_file="/etc/apt/sources.list.d/ubuntu.sources"; log_debug "Checking/enabling deb-src in $sources_file..."; if [ -f "$sources_file" ] && grep -q "Types: deb" "$sources_file" && ! grep -q "Types: deb deb-src" "$sources_file"; then log "Enabling deb-src..."; local bak="${sources_file}.bak-$(date +%F_%T)"; cp "$sources_file" "$bak" || log_warn "Backup $bak failed."; local tmp; tmp=$(mktemp); if sed 's/Types: deb$/Types: deb deb-src/' "$sources_file" > "$tmp"; then if mv "$tmp" "$sources_file"; then log "deb-src enabled. Updating apt..."; apt update -y || die "apt update failed."; else rm -f "$tmp"; die "Failed to move $tmp to $sources_file."; fi; else rm -f "$tmp"; log_warn "sed failed on $sources_file."; fi; elif [ -f "$sources_file" ]; then log_debug "deb-src seem enabled or file is non-standard."; else log_warn "$sources_file not found."; fi; log "Adding Amnezia PPA..."; local ppa_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).list"; local ppa_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).sources"; if [ ! -f "$ppa_list" ] && [ ! -f "$ppa_sources" ]; then log "Adding PPA..."; install_packages software-properties-common; DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:amnezia/ppa || die "Failed to add PPA."; log "PPA added. Updating apt..."; apt update -y || die "apt update failed."; else log "Amnezia PPA already exists."; apt update -y || log_warn "apt update failed."; fi; log "Installing AmneziaWG packages..."; local packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms" "build-essential" "dpkg-dev" "linux-headers-$(uname -r)" "iptables"); if ! dpkg -s "linux-headers-$(uname -r)" &> /dev/null; then log_warn "Headers for $(uname -r) not found. Installing generic..."; packages+=( "linux-headers-generic" ); fi; install_packages "${packages[@]}"; log "Checking DKMS status..."; sleep 5; local dkms_stat; dkms_stat=$(dkms status 2>&1); log_debug "DKMS output: $dkms_stat"; if echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then log "DKMS status: OK."; else log_error "DKMS status: NOT 'installed'!"; log_error "$dkms_stat"; die "AmneziaWG kernel module failed to build/install via DKMS."; fi; log_step "--- STEP 2 Completed ---"; request_reboot 3;
}

# --- STEP 3: Kernel Module Check ---
step3_check_module() {
    update_state 3; log_step "### STEP 3: Kernel Module Check ###"; sleep 2; log "Checking 'amneziawg' module..."; if lsmod | grep -q -w amneziawg; then log "Module loaded."; else log_warn "Module not loaded. Attempting modprobe..."; if modprobe amneziawg; then log "Module loaded successfully."; local mf="/etc/modules-load.d/amneziawg.conf"; mkdir -p "$(dirname "$mf")"; if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then echo "amneziawg" > "$mf" || log_warn "Failed write $mf"; log "Added to $mf for autoload."; fi; else die "modprobe amneziawg failed. Check dmesg."; fi; fi; log "Module info:"; modinfo amneziawg | grep -E "filename|version|desc|license|vermagic" | while IFS= read -r line; do log_msg "INFO" "  $line"; done; local mver; mver=$(modinfo -F vermagic amneziawg 2>/dev/null || echo "?"); local kver; kver=$(uname -r); if [[ "$mver" == "$kver"* ]]; then log "VerMagic match (OK)."; else log_warn "VerMagic MISMATCH: Module($mver) != Kernel($kver)!"; fi; log_step "--- STEP 3 Completed ---"; echo ""; update_state 5; # Skip firewall step
}

# --- STEP 5: Python Setup & Utility Download ---
step5_setup_python_and_scripts() {
    update_state 5; log_step "### STEP 5: Python Setup & Utilities ###"; install_packages python3-venv python3-pip; cd "$AWG_DIR" || die "Cannot cd to $AWG_DIR"; if [ ! -d "$PYTHON_VENV" ]; then log "Creating Python venv..."; python3 -m venv "$PYTHON_VENV" || die "venv creation failed."; chown -R "${TARGET_USER}:${TARGET_USER}" "$PYTHON_VENV"; log "Venv created."; else log "Python venv already exists."; chown -R "${TARGET_USER}:${TARGET_USER}" "$PYTHON_VENV"; fi; if [ ! -x "$PYTHON_EXEC" ]; then die "Python executable not found in venv: $PYTHON_EXEC"; fi; log "Installing qrcode[pil] in venv..."; if ! sudo -u "$TARGET_USER" "$PYTHON_EXEC" -m pip install --upgrade pip; then log_warn "pip upgrade failed."; fi; if ! sudo -u "$TARGET_USER" "$PYTHON_EXEC" -m pip install --disable-pip-version-check "qrcode[pil]"; then die "Failed to install qrcode[pil]."; fi; log "Python dependencies OK."; log "Downloading awgcfg.py..."; local awgcfg_url="https://gist.githubusercontent.com/remittor/8c3d9ff293b2ba4b13c367cc1a69f9eb/raw/awgcfg.py"; if curl -fLso "$AWGCFG_SCRIPT" "$awgcfg_url"; then log "awgcfg.py downloaded."; chmod 750 "$AWGCFG_SCRIPT"; chown "${TARGET_USER}:${TARGET_USER}" "$AWGCFG_SCRIPT"; elif [ -f "$AWGCFG_SCRIPT" ]; then log_warn "Failed to download awgcfg.py, using existing file."; chmod 750 "$AWGCFG_SCRIPT"; chown "${TARGET_USER}:${TARGET_USER}" "$AWGCFG_SCRIPT"; else die "Failed to download awgcfg.py and no existing file found."; fi; log "Downloading manage.sh..."; if curl -fLso "$MANAGE_SCRIPT_PATH" "$MANAGE_SCRIPT_URL"; then log "manage.sh downloaded."; chmod 750 "$MANAGE_SCRIPT_PATH"; chown "${TARGET_USER}:${TARGET_USER}" "$MANAGE_SCRIPT_PATH"; elif [ -f "$MANAGE_SCRIPT_PATH" ]; then log_warn "Failed to download manage.sh, using existing file."; chmod 750 "$MANAGE_SCRIPT_PATH"; chown "${TARGET_USER}:${TARGET_USER}" "$MANAGE_SCRIPT_PATH"; else log_error "Failed to download manage.sh and no existing file found."; fi; log_step "--- STEP 5 Completed ---"; echo ""; update_state 6;
}

# --- STEP 6: Configuration Generation ---
step6_generate_configs() {
    update_state 6; log_step "### STEP 6: Configuration Generation ###"; cd "$AWG_DIR" || die "Cannot cd to $AWG_DIR"; local sdir="/etc/amnezia/amneziawg"; mkdir -p "$sdir"; chmod 700 "$sdir"; log "Generating server config $SERVER_CONF_FILE..."; if ! run_awgcfg --make "$SERVER_CONF_FILE" -i "${AWG_TUNNEL_SUBNET}" -p "${AWG_PORT}"; then if grep -q 'already exists' <(eval "$PYTHON_EXEC $AWGCFG_SCRIPT --make $SERVER_CONF_FILE -i $AWG_TUNNEL_SUBNET -p $AWG_PORT" 2>&1 >/dev/null); then log_warn "Server config already exists, skipping --make."; else die "Failed to generate server config."; fi; else chmod 600 "$SERVER_CONF_FILE"; log "Server config generated."; fi; log "Configuring client template $CLIENT_TEMPLATE_FILE..."; if ! run_awgcfg --create; then log_warn "Failed to create/update $CLIENT_TEMPLATE_FILE."; touch "$CLIENT_TEMPLATE_FILE" || true; fi; log "Applying settings to template:"; local sed_failed=0; sed -i 's/^DNS = .*/DNS = 1.1.1.1/' "$CLIENT_TEMPLATE_FILE" && log " - DNS: OK" || { log_warn " - Failed to set DNS"; sed_failed=1; }; sed -i 's/^PersistentKeepalive = .*/PersistentKeepalive = 33/' "$CLIENT_TEMPLATE_FILE" && log " - Keepalive: OK" || { log_warn " - Failed to set Keepalive"; sed_failed=1; }; local escaped_ips; escaped_ips=$(echo "$ALLOWED_IPS" | sed 's/[&#/\]/\\&/g'); sed -i "s#^AllowedIPs = .*#AllowedIPs = ${escaped_ips}#" "$CLIENT_TEMPLATE_FILE" && log " - AllowedIPs: OK (Mode $ALLOWED_IPS_MODE)" || { log_warn " - Failed to set AllowedIPs"; sed_failed=1; }; if [ "$sed_failed" -eq 1 ]; then log_warn "Failed to apply all template settings."; else log "Client template configured."; fi; chown "${TARGET_USER}:${TARGET_USER}" "$CLIENT_TEMPLATE_FILE"; chmod 600 "$CLIENT_TEMPLATE_FILE"; log "Adding default clients..."; local defaults=("my_phone" "my_laptop"); for cl in "${defaults[@]}"; do if grep -q "^#_Name = ${cl}$" "$SERVER_CONF_FILE"; then log " - Client '$cl' already exists."; else log " - Adding client '$cl'..."; if run_awgcfg -a "$cl"; then log "   Client '$cl' added."; else log_error "   Failed to add client '$cl'."; fi; fi; done; log "Generating client .conf/.png files..."; local tmp_bak="${TARGET_HOME}/.${CONFIG_FILE##*/}.bak_$(date +%s)"; local mv_fail=0; if [ -f "$CONFIG_FILE" ]; then mv "$CONFIG_FILE" "$tmp_bak" || { log_warn "Workaround: Failed to move $CONFIG_FILE."; mv_fail=1; }; fi; log_debug "Workaround mv_fail=$mv_fail"; if ! run_awgcfg -c -q; then log_error "Failed to generate client files."; else log "Client files generated/updated."; ls -l "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | sed 's/^/  /' | while IFS= read -r line; do log_msg "INFO" "$line"; done; fi; if [ "$mv_fail" -eq 0 ] && [ -f "$tmp_bak" ]; then mv "$tmp_bak" "$CONFIG_FILE" || log_error "Workaround FATAL: Failed to restore $CONFIG_FILE!"; fi; rm -f "$tmp_bak"; if [ ! -f "$CONFIG_FILE" ]; then log_error "$CONFIG_FILE is missing after client generation!"; fi; secure_files; log_step "--- STEP 6 Completed ---"; echo ""; update_state 7;
}

# --- STEP 7: Start Service & Final Check ---
step7_start_service_and_final_check() {
    update_state 7; log_step "### STEP 7: Start Service & Final Check ###"; log "Enabling and starting 'awg-quick@awg0' service..."; if systemctl enable --now awg-quick@awg0; then log "'enable --now' command finished successfully."; if systemctl is-active --quiet awg-quick@awg0; then log "Service confirmed active."; else log_warn "Service did not become active immediately after start command."; fi; else log_error "Failed to enable/start 'awg-quick@awg0' service!"; systemctl status awg-quick@awg0 --no-pager -l >&2; journalctl -u awg-quick@awg0 -n 20 --no-pager --output=cat >&2; die "Service start failed."; fi; log "Waiting 5 seconds for service stabilization..."; sleep 5; check_service_status || die "Final service status check failed."; log_step "--- STEP 7 Completed ---"; echo ""; update_state 99; # Move to final step
}

# --- STEP 99: Finish ---
step99_finish() {
    log_step "### FINISHING INSTALLATION ###"; echo ""; log "==================================================================="; log " AmneziaWG Installation Completed Successfully!"; log "==================================================================="; echo ""; log "Client config files (.conf) and QR codes (.png) are in: $AWG_DIR"; log "Example command to copy .conf files: scp ${TARGET_USER}@<SERVER_IP>:${AWG_DIR}/*.conf ./"; echo ""; log "Manage clients using: sudo bash $MANAGE_SCRIPT_PATH help"; echo ""; log "Check VPN status: systemctl status awg-quick@awg0 / sudo awg show"; echo ""; if [ ! -f "$CONFIG_FILE" ]; then log_error "WARNING: Install config file $CONFIG_FILE is missing!"; fi; cleanup_apt; log "Removing setup state file..."; rm -f "$STATE_FILE" || log_warn "Failed to remove state file $STATE_FILE."; echo ""; log "Installation finished."; log "==================================================================="; echo "";
}

# --- Main Execution Logic ---
trap 'echo ""; log_error "Interrupted (SIGINT)."; exit 1' SIGINT
trap 'echo ""; log_error "Terminated (SIGTERM)."; exit 1' SIGTERM

if [ "$HELP" -eq 1 ]; then show_help; fi
if [ "$VERBOSE" -eq 1 ]; then log "Verbose mode enabled."; set -x; fi

current_step="" # Ensure it's initialized
initialize_setup # Step 0

if ! [[ "${current_step:-}" =~ ^[0-9]+$ ]]; then die "Initialization failed: current_step not set."; fi

# Installation state machine loop
while (( current_step < 99 )); do
    log_debug "Executing step $current_step...";
    case $current_step in
        1) step1_update_system_and_networking ;; # Exits via request_reboot
        2) step2_install_amnezia ;;              # Exits via request_reboot
        3) step3_check_module; current_step=5 ;;
        5) step5_setup_python_and_scripts; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service_and_final_check; current_step=99 ;;
        *) die "Unknown installation step '$current_step'." ;;
    esac
done

if (( current_step == 99 )); then step99_finish; fi
if [ "$VERBOSE" -eq 1 ]; then set +x; fi

exit 0
EOF
