#!/bin/bash

# ==============================================================================
# AmneziaWG Management Script (Azure ARM64 Interactive)
# Version: 2.3 (Final Cleaned)
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
    if [ ! -d "$TARGET_HOME" ]; then echo "[WARN] Cannot determine home for '$TARGET_USER'. Using /root." >&2; TARGET_USER="root"; TARGET_HOME="/root"; fi
else
    TARGET_USER="root"; TARGET_HOME="/root"
    if [ "$TARGET_USER" == "root" ] && [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then echo "[WARN] Running as root. Using $TARGET_HOME." >&2; fi
fi

# --- Default Paths (can be overridden) ---
DEFAULT_AWG_DIR="${TARGET_HOME}/awg"
DEFAULT_SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"

# --- Variable Initialization ---
AWG_DIR="$DEFAULT_AWG_DIR"
SERVER_CONF_FILE="$DEFAULT_SERVER_CONF_FILE"
NO_COLOR=0
VERBOSE_LIST=0
COMMAND=""
ARGS=()

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) COMMAND="help"; break ;;
        -v|--verbose) VERBOSE_LIST=1; shift ;;
        --no-color) NO_COLOR=1; shift ;;
        --conf-dir=*) AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*) SERVER_CONF_FILE="${1#*=}"; shift ;;
        --*) echo "[ERROR] Unknown option: $1" >&2; COMMAND="help"; break ;;
         *) break ;; # Stop option parsing
    esac
done
# Remaining args are command and its parameters
if [ -z "$COMMAND" ]; then COMMAND=${1:-}; if [ -n "$COMMAND" ]; then shift; fi; fi
ARGS=("$@")
CLIENT_NAME="${ARGS[0]:-}"
PARAM="${ARGS[1]:-}"
VALUE="${ARGS[2]:-}"

# --- Dependent Paths (set after option parsing) ---
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
PYTHON_VENV_PATH="$AWG_DIR/venv"
PYTHON_EXEC="$PYTHON_VENV_PATH/bin/python"
AWGCFG_SCRIPT_PATH="$AWG_DIR/awgcfg.py"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

# --- Logging Functions ---
log_msg() {
    local type="$1" msg="$2" ts entry color_start="" color_end="\033[0m" safe_msg
    ts=$(date +'%F %T'); safe_msg=$(echo "$msg" | sed 's/%/%%/g'); entry="[$ts] $type: $safe_msg"; if mkdir -p "$(dirname "$LOG_FILE")"; then echo "$entry" >> "$LOG_FILE"; chown "${TARGET_USER}:${TARGET_USER}" "$LOG_FILE" 2>/dev/null; chmod 640 "$LOG_FILE" 2>/dev/null; else echo "[$ts] ERROR: Cannot write to log $LOG_FILE" >&2; fi; if [[ "$NO_COLOR" -eq 0 ]]; then case "$type" in INFO) color_start="\033[0;32m";; WARN) color_start="\033[0;33m";; ERROR) color_start="\033[1;31m";; DEBUG) color_start="\033[0;36m";; *) color_start=""; color_end="";; esac; fi; if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then printf "${color_start}%s${color_end}\n" "$entry" >&2; elif [[ "$type" == "DEBUG" && "$VERBOSE_LIST" -eq 1 ]]; then printf "${color_start}%s${color_end}\n" "$entry" >&2; elif [[ "$type" == "INFO" ]]; then printf "${color_start}%s${color_end}\n" "$entry"; fi
}
log() { log_msg "INFO" "$1"; }; log_warn() { log_msg "WARN" "$1"; }; log_error() { log_msg "ERROR" "$1"; }; log_debug() { if [[ "$VERBOSE_LIST" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; };
die() { log_error "FATAL ERROR: $1"; log_error "Operation aborted. Log: $LOG_FILE"; exit 1; }

# --- Helper Functions ---
is_interactive() { [[ -t 0 && -t 1 ]]; }
confirm_action() {
    if ! is_interactive; then return 0; fi; local action="$1" subject="$2" confirm; read -p "Are you sure you want to ${action} ${subject}? [y/N]: " confirm < /dev/tty; if [[ "$confirm" =~ ^[YyЕе]$ ]]; then return 0; else log "Action cancelled."; return 1; fi
}
validate_client_name() {
    local name="$1"; if [[ -z "$name" ]]; then log_error "Client name cannot be empty."; return 1; fi; if [[ ${#name} -gt 63 ]]; then log_error "Client name too long (> 63 chars)."; return 1; fi; if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Client name contains invalid characters (allowed: a-z, A-Z, 0-9, _, -)."; return 1; fi; return 0
}
check_dependencies() {
    log "Checking dependencies..."; local critical_error=0; local dependencies=( "$AWG_DIR" "$CONFIG_FILE" "$PYTHON_VENV_PATH" "$PYTHON_EXEC" "$AWGCFG_SCRIPT_PATH" "$SERVER_CONF_FILE" ); for dep in "${dependencies[@]}"; do if [ ! -e "$dep" ]; then log_error " - Missing: $dep"; critical_error=1; fi; done; if [ -f "$PYTHON_EXEC" ] && [ ! -x "$PYTHON_EXEC" ]; then log_error " - Not executable: $PYTHON_EXEC"; critical_error=1; fi; if [ -f "$AWGCFG_SCRIPT_PATH" ] && [ ! -x "$AWGCFG_SCRIPT_PATH" ]; then log_error " - Not executable: $AWGCFG_SCRIPT_PATH"; critical_error=1; fi; if ! command -v awg &>/dev/null; then log_error " - Command 'awg' not found."; critical_error=1; fi; if ! command -v qrencode &>/dev/null; then log_warn " - Command 'qrencode' not found (QR codes won't update on 'modify')."; fi; if [ "$critical_error" -eq 1 ]; then die "Missing critical dependencies."; fi; log "Dependencies OK.";
}
run_awgcfg() {
    log_debug "Running awgcfg.py $*"; if [ ! -x "$PYTHON_EXEC" ] || [ ! -x "$AWGCFG_SCRIPT_PATH" ]; then log_error "Python or awgcfg.py not found/executable."; return 1; fi; if ! (cd "$AWG_DIR" && "$PYTHON_EXEC" "$AWGCFG_SCRIPT_PATH" "$@"); then log_error "awgcfg.py failed: '$PYTHON_EXEC $AWGCFG_SCRIPT_PATH $*'"; return 1; fi; chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png &>/dev/null || true; find "$AWG_DIR" -maxdepth 1 -name "*.conf" -type f -exec chmod 600 {} \; &>/dev/null; find "$AWG_DIR" -maxdepth 1 -name "*.png" -type f -exec chmod 644 {} \; &>/dev/null; log_debug "awgcfg.py '$*' completed."; return 0;
}
# Run awgcfg.py -c -q with workaround for setup.conf bug
run_awgcfg_generate_clients() {
    local temp_conf_backup="${TARGET_HOME}/.${CONFIG_FILE##*/}.bak_$(date +%s)"; local mv_failed=0 result=0; if [ -f "$CONFIG_FILE" ]; then mv "$CONFIG_FILE" "$temp_conf_backup" || { log_warn "Workaround: Failed to move $CONFIG_FILE."; mv_failed=1; }; fi; log_debug "Workaround mv_failed=$mv_failed"; if ! run_awgcfg -c -q; then log_error "awgcfg.py -c -q failed."; result=1; else log_debug "awgcfg.py -c -q completed."; fi; if [ "$mv_failed" -eq 0 ] && [ -f "$temp_conf_backup" ]; then mv "$temp_conf_backup" "$CONFIG_FILE" || log_error "Workaround FATAL: Failed to restore $CONFIG_FILE!"; fi; rm -f "$temp_conf_backup"; if [ ! -f "$CONFIG_FILE" ]; then log_error "$CONFIG_FILE is missing after client generation!"; if [ "$result" -eq 0 ]; then result=1; fi; fi; chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png &>/dev/null || true; find "$AWG_DIR" -maxdepth 1 -name "*.conf" -type f -exec chmod 600 {} \; &>/dev/null; find "$AWG_DIR" -maxdepth 1 -name "*.png" -type f -exec chmod 644 {} \; &>/dev/null; return $result
}

# --- Main Commands ---
cmd_add_client() {
    [ -z "$CLIENT_NAME" ] && die "Client name required for add."; validate_client_name "$CLIENT_NAME" || exit 1; if grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then die "Client '$CLIENT_NAME' already exists."; fi
    log "Adding client '$CLIENT_NAME'..."; if run_awgcfg -a "$CLIENT_NAME"; then log "Client '$CLIENT_NAME' added to $SERVER_CONF_FILE."; log "Generating/updating config files for all clients..."; if run_awgcfg_generate_clients; then log "Client files created/updated in $AWG_DIR."; log_warn "!!! IMPORTANT: Service restart required: sudo bash $0 restart"; else log_error "Failed to generate client files after adding."; log_warn "!!! Try running '$0 regen' and '$0 restart'"; fi; else log_error "Failed to add client '$CLIENT_NAME'."; fi
}
cmd_remove_client() {
    [ -z "$CLIENT_NAME" ] && die "Client name required for remove."; validate_client_name "$CLIENT_NAME" || exit 1; if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then die "Client '$CLIENT_NAME' not found."; fi; if ! confirm_action "remove" "client '$CLIENT_NAME' and its files"; then exit 1; fi
    log "Removing client '$CLIENT_NAME'..."; if run_awgcfg -d "$CLIENT_NAME"; then log "Client '$CLIENT_NAME' removed from $SERVER_CONF_FILE."; log "Deleting client files..."; rm -f "$AWG_DIR/$CLIENT_NAME.conf" "$AWG_DIR/$CLIENT_NAME.png"; log "Files deleted."; log_warn "!!! IMPORTANT: Service restart required: sudo bash $0 restart"; else log_error "Failed to remove client '$CLIENT_NAME'."; fi
}
cmd_list_clients() {
    log "Listing clients from $SERVER_CONF_FILE..."; local clients_list; clients_list=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort); if [ -z "$clients_list" ]; then log "No clients found."; return 0; fi; local awg_status_output; awg_status_output=$(awg show 2>/dev/null || echo ""); local total_clients active_clients=0; total_clients=$(echo "$clients_list" | wc -l); if [ "$VERBOSE_LIST" -eq 1 ]; then printf "%-20s | %-7s | %-7s | %-18s | %-15s | %s\n" "Client Name" "Conf?" "QR?" "IP Address" "Pub Key (.." "Handshake Status"; printf -- "-%.0s" {1..90}; echo ""; else printf "%-20s | %-7s | %-7s | %s\n" "Client Name" "Conf?" "QR?" "Handshake Status"; printf -- "-%.0s" {1..55}; echo ""; fi
    while IFS= read -r client_name; do client_name=$(echo "$client_name" | xargs); if [ -z "$client_name" ]; then continue; fi; local has_conf="-" has_qr="-" client_ip="-" client_pubkey_prefix="-" handshake_status="No data" color_start="\033[0m" color_end="\033[0m"; local client_conf_file="$AWG_DIR/${client_name}.conf"; local client_qr_file="$AWG_DIR/${client_name}.png"; if [ -f "$client_conf_file" ]; then has_conf="✓"; client_ip=$(grep -oP 'Address\s*=\s*\K[0-9\.\/]+' "$client_conf_file" 2>/dev/null || echo "?"); fi; if [ -f "$client_qr_file" ]; then has_qr="✓"; fi; local current_pubkey="" in_peer_block=0; while IFS= read -r line || [[ -n "$line" ]]; do if [[ "$line" == "[Peer]" && "$in_peer_block" -eq 1 ]]; then break; fi; if [[ "$line" == *"#_Name = ${client_name}"* ]]; then in_peer_block=1; fi; if [[ "$in_peer_block" -eq 1 && "$line" == "PublicKey = "* ]]; then current_pubkey=$(echo "$line" | awk '{print $3}'); break; fi; done < "$SERVER_CONF_FILE"; if [[ -n "$current_pubkey" ]]; then client_pubkey_prefix=$(echo "$current_pubkey" | head -c 10)...; if echo "$awg_status_output" | grep -qF "$current_pubkey"; then local handshake_line; handshake_line=$(echo "$awg_status_output" | grep -A 3 -F "$current_pubkey" | grep 'latest handshake:'); if [[ -n "$handshake_line" ]]; then if echo "$handshake_line" | grep -q "never"; then handshake_status="No handshake"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;37m"; fi; elif echo "$handshake_line" | grep -q "ago"; then if echo "$handshake_line" | grep -q "seconds ago"; then local seconds_ago; seconds_ago=$(echo "$handshake_line" | grep -oP '\d+(?= seconds ago)'); if [[ "$seconds_ago" -lt 180 ]]; then handshake_status="Active (${seconds_ago}s)"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;32m"; fi; ((active_clients++)); else handshake_status="Recent"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;33m"; fi; ((active_clients++)); fi; else handshake_status="Recent"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;33m"; fi; ((active_clients++)); fi; else handshake_status="Unknown"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;37m"; fi; fi; else handshake_status="No handshake"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;37m"; fi; fi; else handshake_status="Peer not active"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;31m"; fi; fi; else handshake_status="Key error"; client_pubkey_prefix="?"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;31m"; fi; fi; if [ "$VERBOSE_LIST" -eq 1 ]; then printf "%-20s | %-7s | %-7s | %-18s | %-15s | ${color_start}%s${color_end}\n" "$client_name" "$has_conf" "$has_qr" "$client_ip" "$client_pubkey_prefix" "$handshake_status"; else printf "%-20s | %-7s | %-7s | ${color_start}%s${color_end}\n" "$client_name" "$has_conf" "$has_qr" "$handshake_status"; fi; done <<< "$clients_list"; echo ""; log "Total clients in config: $total_clients"; log "Clients with recent handshake (Active/Recent): $active_clients";
}
cmd_regen_clients() {
    log "Regenerating .conf/.png files for ALL clients..."; if [ -n "$CLIENT_NAME" ]; then log_warn "Argument '$CLIENT_NAME' ignored for 'regen'."; fi; if run_awgcfg_generate_clients; then log "Client files regenerated in $AWG_DIR."; ls -l "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | sed 's/^/  /' | while IFS= read -r line; do log_msg "INFO" "$line"; done; else log_error "Failed to regenerate client files."; fi
}
cmd_modify_client() {
    local name="$1" param_key="$2" new_value="$3"; if [[ -z "$name" || -z "$param_key" || -z "$new_value" ]]; then log_error "Usage: $0 modify <name> <parameter> <value>"; return 1; fi; validate_client_name "$name" || return 1; if ! grep -q "^#_Name = ${name}$" "$SERVER_CONF_FILE"; then log_error "Client '$name' not found in $SERVER_CONF_FILE."; return 1; fi; local client_conf_file="$AWG_DIR/$name.conf"; if [ ! -f "$client_conf_file" ]; then log_error "File '$client_conf_file' not found. Run '$0 regen'?"; return 1; fi; if ! grep -q -E "^${param_key}\s*=" "$client_conf_file"; then log_error "Parameter '$param_key' not found in $client_conf_file."; return 1; fi
    log "Modifying '$param_key' to '$new_value' for '$name' in $client_conf_file..."; local backup_file="${client_conf_file}.bak_$(date +%s)"; cp "$client_conf_file" "$backup_file" || { log_error "Backup failed for $backup_file."; return 1; }; log_debug "Backup created: $backup_file"; chown "${TARGET_USER}:${TARGET_USER}" "$backup_file" 2>/dev/null; chmod 600 "$backup_file" 2>/dev/null; local escaped_new_value; escaped_new_value=$(echo "$new_value" | sed 's/[&/\]/\\&/g'); if ! sed -i "s#^${param_key}\s*=.*#${param_key} = ${escaped_new_value}#" "$client_conf_file"; then log_error "sed command failed. Restoring backup..."; cp "$backup_file" "$client_conf_file" || log_warn "Failed to restore backup!"; return 1; fi
    log "Parameter '$param_key' modified."; chown "${TARGET_USER}:${TARGET_USER}" "$client_conf_file"; chmod 600 "$client_conf_file"; local client_qr_file="$AWG_DIR/$name.png"; if command -v qrencode &>/dev/null; then if qrencode -o "$client_qr_file" < "$client_conf_file"; then log "QR code '$client_qr_file' updated."; chown "${TARGET_USER}:${TARGET_USER}" "$client_qr_file"; chmod 644 "$client_qr_file"; else log_error "qrencode failed for $client_qr_file."; fi; else log_warn "qrencode not found. QR code not updated."; fi; return 0
}
cmd_check_server() {
    log "Checking AmneziaWG server status..."; local overall_status=0; log "--- Systemd Service (awg-quick@awg0) ---"; if ! systemctl status awg-quick@awg0 --no-pager; then overall_status=1; fi; echo ""; log "--- Network Interface (awg0) ---"; if ! ip addr show awg0 &>/dev/null; then log_error "'awg0' interface NOT found!"; overall_status=1; else log "'awg0' interface found:"; ip addr show awg0 | sed 's/^/  /' | log_msg "INFO"; fi; echo ""; log "--- UDP Port Listening ---"; local listen_port=0; if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE" &>/dev/null; listen_port=${AWG_PORT:-0}; fi; if [ "$listen_port" -ne 0 ]; then log "Expected port: ${listen_port}/udp"; if ss -lunp | grep -q ":${listen_port} "; then log "Port ${listen_port}/udp listening (OK)."; else log_error "Port ${listen_port}/udp NOT listening!"; overall_status=1; fi; else log_warn "Could not determine expected port from $CONFIG_FILE."; fi; echo ""; log "--- Kernel Parameters (sysctl) ---"; local ipv4_fwd; ipv4_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null); log "net.ipv4.ip_forward = $ipv4_fwd"; if [[ "$ipv4_fwd" != "1" ]]; then log_error "IPv4 Forwarding DISABLED!"; overall_status=1; fi; local ipv6_dis; ipv6_dis=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null); log "net.ipv6.conf.all.disable_ipv6 = $ipv6_dis"; if [[ "$ipv6_dis" != "1" ]]; then log_warn "IPv6 Disabling INACTIVE!"; fi; echo ""; log "--- AmneziaWG Status (awg show) ---"; if ! awg show; then log_error "'awg show' command failed."; overall_status=1; fi; echo ""; log "--- Check Summary ---"; if [ "$overall_status" -eq 0 ]; then log "Status check PASSED."; else log_error "Status check FAILED!"; fi; return $overall_status
}
cmd_show_status() { log "Running 'awg show'... "; echo "-------------------------------------"; if ! awg show; then log_error "'awg show' command failed."; fi; echo "-------------------------------------"; }
cmd_restart_service() {
    log "Restarting AmneziaWG service (awg-quick@awg0)..."; if ! confirm_action "restart" "AmneziaWG service"; then exit 1; fi
    log "Stopping service..."; systemctl stop awg-quick@awg0 || log_warn "Failed to stop service (may already be stopped)."; sleep 1; log "Starting service..."; if ! systemctl start awg-quick@awg0; then log_error "Failed to start service!"; systemctl status awg-quick@awg0 --no-pager -l >&2; exit 1; fi
    log "Service restarted."; sleep 2; log "Quick status check after restart:"; cmd_check_server > /dev/null || log_warn "Problems detected after restart. Use '$0 check' for details.";
}
usage() {
    exec >&2; echo ""; echo "AmneziaWG Management Script (v2.3)"; echo "=================================="; echo "Usage: sudo bash $0 [OPTIONS] <COMMAND> [ARGS]"; echo "Options:"; echo "  -h, --help         Help"; echo "  -v, --verbose      Verbose 'list'"; echo "  --no-color         Disable color"; echo "  --conf-dir=PATH    AWG dir (Default: $DEFAULT_AWG_DIR)"; echo "  --server-conf=PATH WG server config (Default: $DEFAULT_SERVER_CONF_FILE)"; echo ""; echo "Commands:"; echo "  add <name>           Add client (+regen, requires restart)"; echo "  remove <name>        Remove client (requires restart)"; echo "  list [-v]            List clients"; echo "  regen                Regenerate all client .conf/.png files"; echo "  modify <n> <p> <v>   Modify client param (DNS, AllowedIPs...)"; echo "  check | status       Check server health"; echo "  show                 Run 'awg show'"; echo "  restart              Restart awg-quick@awg0 service"; echo "  help                 This help"; echo ""; echo "Restart required after 'add'/'remove': sudo bash $0 restart"; echo "Log: $LOG_FILE"; echo ""; exit 1;
}

# --- Main Logic ---
trap 'echo ""; log_error "Interrupted (SIGINT)."; exit 1' SIGINT
trap 'echo ""; log_error "Terminated (SIGTERM)."; exit 1' SIGTERM

if [[ "$COMMAND" != "help" ]]; then check_dependencies || exit 1; cd "$AWG_DIR" || die "Cannot cd to $AWG_DIR"; fi
log_debug "Running command '$COMMAND' with args: ${ARGS[*]}"

case $COMMAND in
    add)     cmd_add_client ;;
    remove)  cmd_remove_client ;;
    list)    cmd_list_clients ;;
    regen)   cmd_regen_clients ;;
    modify)  cmd_modify_client "$CLIENT_NAME" "$PARAM" "$VALUE" ;;
    check|status) cmd_check_server ;;
    show)    cmd_show_status ;;
    restart) cmd_restart_service ;;
    help)    usage ;;
    "")      log_error "No command specified."; usage ;;
    *)       log_error "Unknown command: '$COMMAND'"; usage ;;
esac

log "Management script '$0' finished."
exit ${?} # Exit with status of last command
