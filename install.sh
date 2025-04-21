#!/bin/bash

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG на Ubuntu 24.04 LTS Minimal (ARM64)
# Версия Azure ARM64 Interactive - Refined + Fixes v2
# Автор: @bivlked
# Версия: 2.3
# Дата: 2025-04-21
# Репозиторий: https://github.com/bivlked/azure
# ==============================================================================

# --- Режим Безопасности и Константы ---
set -o pipefail # Прерывать выполнение, если команда в пайпе завершается с ошибкой
set -o nounset  # Считать ошибкой использование неинициализированных переменных

# --- Определение Пользователя и Домашнего Каталога ---
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="<span class="math-inline">SUDO\_USER"
TARGET\_HOME\=</span>(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [ ! -d "$TARGET_HOME" ]; then echo "[ERROR] Не удалось определить дом. директорию для '$TARGET_USER'." >&2; exit 1; fi
else
    TARGET_USER="root"; TARGET_HOME="/root"
    if [ "$TARGET_USER" == "root" ]; then echo "[WARN] Запуск от root. Рабочая директория: <span class="math-inline">\{TARGET\_HOME\}/awg" \>&2; fi
fi
\# \-\-\- Основные Пути и Имена Файлов \-\-\-
AWG\_DIR\="</span>{TARGET_HOME}/awg"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
STATE_FILE="$AWG_DIR/setup_state"
CLIENT_TEMPLATE_FILE="$AWG_DIR/_defclient.config"
PYTHON_VENV="$AWG_DIR/venv"
PYTHON_EXEC="$PYTHON_VENV/bin/python"
AWGCFG_SCRIPT="$AWG_DIR/awgcfg.py"
MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/azure/main/manage.sh"
MANAGE_SCRIPT_PATH="$AWG_DIR/manage.sh"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"

# --- Опции Скрипта ---
HELP=0; VERBOSE=0; NO_COLOR=0;
DISABLE_IPV6=1;

# --- Обработка Аргументов Командной Строки ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h) HELP=1;;
        --verbose|-v) VERBOSE=1;;
        --no-color) NO_COLOR=1;;
        *) echo "[ERROR] Неизвестный аргумент: $1"; HELP=1;;
    esac
    shift
done

# --- Функции Логирования ---
log_msg() {
    local type="$1" msg="<span class="math-inline">2" ts color\_start\="" color\_end\="\\033\[0m" safe\_msg entry
ts\=</span>(date +'%F %T'); safe_msg=$(echo "$msg" | sed 's/%/%%/g'); entry="[$ts] $type: $safe_msg"
    if [[ "$NO_COLOR" -eq 0 ]]; then case "$type" in INFO) color_start="\033[0;32m";; WARN) color_start="\033[0;33m";; ERROR) color_start="\033[1;31m";; DEBUG) color_start="\033[0;36m";; STEP) color_start="\033[1;34m";; *) color_start=""; color_end="";; esac; fi
    if [[ "$type" == "ERROR" || "<span class="math-inline">type" \=\= "WARN" \]\]; then printf "</span>{color_start}%s${color_end}\n" "$entry" >&2;
    elif [[ "$type" == "DEBUG" && "<span class="math-inline">VERBOSE" \-eq 1 \]\]; then printf "</span>{color_start}%s${color_end}\n" "$entry" >&2;
    elif [[ "$type" == "INFO" || "<span class="math-inline">type" \=\= "STEP" \]\]; then printf "</span>{color_start}%s${color_end}\n" "$entry"; fi
}
log() { log_msg "INFO" "$1"; }; log_warn() { log_msg "WARN" "$1"; }; log_error() { log_msg "ERROR" "$1"; }; log_debug() { if [[ "$VERBOSE" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }; log_step() { log_msg "STEP" "$1"; };
die() { log_error "КРИТИЧЕСКАЯ ОШИБКА: $1"; log_error "Установка прервана."; exit 1; }

# --- Вспомогательные Функции ---
show_help() {
    cat << EOF
Использование: sudo bash $0 [ОПЦИИ]
Скрипт для интерактивной установки AmneziaWG на Ubuntu 24.04 Minimal (Azure ARM64).

Опции:
  -h, --help            Показать эту справку и выйти
  -v, --verbose         Расширенный вывод для отладки
  --no-color            Отключить цветной вывод

Описание:
  Проводит установку AmneziaWG, настраивает систему (отключает IPv6),
  генерирует конфигурации, запускает сервис и скачивает скрипт управления 'manage.sh'.
  Предназначен для Azure, не настраивает локальный фаервол.

Рабочая директория: ${TARGET_HOME}/awg
EOF
    exit 0
}
update_state() {
    local next_step=<span class="math-inline">1; mkdir \-p "</span>(dirname "$STATE_FILE")" || die "Ошибка создания директории для $STATE_FILE"; echo "$next_step" > "$STATE_FILE" || die "Ошибка записи в <span class="math-inline">STATE\_FILE"; chown "</span>{TARGET_USER}:${TARGET_USER}" "$STATE_FILE" || log_warn "Ошибка chown для $STATE_FILE"; log_debug "Состояние: шаг $next_step";
}
request_reboot() {
    local next_step=$1; update_state "$next_step"; log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; log_warn "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ !!!"; log_warn "!!! После перезагрузки, запустите: sudo bash $0             !!!"; log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; read -p "Перезагрузить сейчас? [y/N]: " confirm < /dev/tty; if [[ "<span class="math-inline">confirm" \=\~ ^\[YyЕе\]</span> ]]; then log "Перезагрузка..."; sleep 5; if ! reboot; then die "Ошибка reboot."; fi; exit 1; else log_warn "Перезагрузка отменена. Перезагрузитесь вручную и запустите скрипт снова."; exit 1; fi
}
check_os_version() {
    log "Проверка ОС и архитектуры..."; if ! command -v lsb_release &> /dev/null; then log_warn "'lsb_release' не найден."; else local os_id; os_id=<span class="math-inline">\(lsb\_release \-si\); local os\_ver; os\_ver\=</span>(lsb_release -sr); if [[ "$os_id" != "Ubuntu" || "$os_ver" != "24.04" ]]; then log_warn "ОС: $os_id $os_ver. Рекомендовано Ubuntu 24.04."; read -p "Продолжить? [y/N]: " confirm < /dev/tty; if ! [[ "<span class="math-inline">confirm" \=\~ ^\[YyЕе\]</span> ]]; then die "Отмена."; fi; else log "ОС: Ubuntu <span class="math-inline">os\_ver \(OK\)"; fi; fi; local arch; arch\=</span>(uname -m); if [[ "$arch" != "aarch64" ]]; then log_warn "Архитектура: $arch. Рекомендовано aarch64."; read -p "Продолжить? [y/N]: " confirm_arch < /dev/tty; if ! [[ "<span class="math-inline">confirm\_arch" \=\~ ^\[YyЕе\]</span> ]]; then die "Отмена."; fi; else log "Архитектура: <span class="math-inline">arch \(OK\)"; fi
\}
check\_free\_space\(\) \{
log "Проверка места\.\.\."; local req\=1024; local avail; avail\=</span>(df -m / | awk 'NR==2 {print $4}'); if [[ -z "$avail" ]]; then log_warn "Не удалось определить свободное место."; return 0; fi; if [[ "$avail" -lt "$req" ]]; then log_warn "Мало места: ${avail} МБ. Рекомендуется >= ${req} МБ."; read -p "Продолжить? [y/N]: " confirm < /dev/tty; if ! [[ "<span class="math-inline">confirm" \=\~ ^\[YyЕе\]</span> ]]; then die "Отмена."; fi; else log "Свободно: ${avail} МБ (OK)"; fi
}
check_port_availability() {
    local port=$1; log "Проверка порта <span class="math-inline">\{port\}/udp\.\.\."; if ss \-lunp \| grep \-q "\:</span>{port} "; then log_error "Порт <span class="math-inline">\{port\}/udp занят\:"; ss \-lunp \| grep "\:</span>{port} " | log_msg "ERROR"; return 1; else log "Порт <span class="math-inline">\{port\}/udp свободен \(OK\)\."; return 0; fi
\}
install\_packages\(\) \{
local packages\_to\_install\=\("</span>@") missing_packages=(); log_debug "Проверка пакетов: <span class="math-inline">\{packages\_to\_install\[\*\]\}"; for pkg in "</span>{packages_to_install[@]}"; do if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then missing_packages+=("$pkg"); fi; done; if [ ${#missing_packages[@]} -eq 0 ]; then log_debug "Все пакеты из списка установлены."; return 0; fi; log "Будут установлены: <span class="math-inline">\{missing\_packages\[\*\]\}"; log "Обновление apt\.\.\."; apt update \-y \|\| log\_warn "apt update не удался\."; log "Установка пакетов\.\.\."; if \! DEBIAN\_FRONTEND\=noninteractive apt install \-y "</span>{missing_packages[@]}"; then die "Ошибка установки пакетов: <span class="math-inline">\{missing\_packages\[\*\]\}"; fi; log "Пакеты установлены\.";
\}
cleanup\_apt\(\) \{ log "Очистка apt\.\.\."; apt\-get clean \|\| log\_warn "Ошибка apt\-get clean"; rm \-rf /var/lib/apt/lists/\* \|\| log\_warn "Ошибка rm /var/lib/apt/lists/\*"; log "Кэш apt очищен\."; \}
configure\_routing\_mode\(\) \{
echo ""; log "Выберите режим маршрутизации \(AllowedIPs\)\:"; echo "  1\) Весь трафик \(0\.0\.0\.0/0\)"; echo "  2\) Список Amnezia\+DNS \(умолч\.\)"; echo "  3\) Указанные сети"; read \-p "Выбор \[2\]\: " r\_mode < /dev/tty; ALLOWED\_IPS\_MODE\=</span>{r_mode:-2}; case "$ALLOWED_IPS_MODE" in 1) ALLOWED_IPS="0.0.0.0/0"; log "Режим: Весь трафик";; 3) read -p "Сети через запятую: " custom_ips < /dev/tty; if ! echo "<span class="math-inline">custom\_ips" \| grep \-qE '^\(\[0\-9\]\{1,3\}\\\.\)\{3\}\[0\-9\]\{1,3\}/\[0\-9\]\{1,2\}\(,\(\[0\-9\]\{1,3\}\\\.\)\{3\}\[0\-9\]\{1,3\}/\[0\-9\]\{1,2\}\)\*</span>'; then log_warn "Формат '$custom_ips' некорректен."; fi; ALLOWED_IPS=$custom_ips; log "Режим: Пользовательский ($ALLOWED_IPS)";; *) ALLOWED_IPS_MODE=2; ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"; log "Режим: Список Amnezia+DNS";; esac; if [ -z "$ALLOWED_IPS" ]; then die "Не удалось определить AllowedIPs."; fi; export ALLOWED_IPS_MODE ALLOWED_IPS;
}
run_awgcfg() {
    log_debug "Запуск awgcfg.py $*"; if [ ! -x "$PYTHON_EXEC" ] || [ ! -x "$AWGCFG_SCRIPT" ]; then log_error "Python или awgcfg.py не найден/исполняем."; return 1; fi; if ! (cd "$AWG_DIR" && "$PYTHON_EXEC" "<span class="math-inline">AWGCFG\_SCRIPT" "</span>@"); then log_error "Ошибка выполнения: '$PYTHON_EXEC $AWGCFG_SCRIPT <span class="math-inline">\*'"; return 1; fi; chown "</span>{TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null || true; find "$AWG_DIR" -maxdepth 1 -name "*.conf" -type f -exec chmod 600 {} \; 2>/dev/null; find "<span class="math-inline">AWG\_DIR" \-maxdepth 1 \-name "\*\.png" \-type f \-exec chmod 644 \{\} \\; 2\>/dev/null; log\_debug "awgcfg\.py '</span>*' выполнен."; return 0;
}
check_service_status() {
    log "Проверка статуса сервиса AmneziaWG..."; local all_ok=1; if systemctl is-active --quiet awg-quick@awg0; then log " - Сервис: активен"; else local state; state=$(systemctl show -p SubState --value awg-quick@awg0 2>/dev/null || echo "?"); if systemctl is-failed --quiet awg-quick@awg0; then log_error " - Сервис: FAILED ($state)"; all_ok=0; else log_warn " - Сервис: не активен (<span class="math-inline">state\)"; all\_ok\=0; fi; journalctl \-u awg\-quick@awg0 \-n 5 \-\-no\-pager \-\-output\=cat \| sed 's/^/    /' \>&2; fi; if ip addr show awg0 &\>/dev/null; then log " \- Интерфейс\: awg0 есть"; else log\_error " \- Интерфейс\: awg0 НЕТ\!"; all\_ok\=0; fi; if awg show \| grep \-q "interface\: awg0"; then log " \- 'awg show'\: видит awg0"; else log\_error " \- 'awg show'\: НЕ видит awg0\!"; all\_ok\=0; fi; local port\=</span>{AWG_PORT:-0}; if [ "$port" -eq 0 ] && [ -f "<span class="math-inline">CONFIG\_FILE" \]; then port\=</span>(grep '^export AWG_PORT=' "<span class="math-inline">CONFIG\_FILE" \| cut \-d'\=' \-f2\); port\=</span>{port:-0}; fi; if [ "<span class="math-inline">port" \-ne 0 \]; then if ss \-lunp \| grep \-q "\:</span>{port} "; then log " - Порт: ${port}/udp слушает"; else log_error " - Порт: ${port}/udp НЕ слушает!"; all_ok=0; fi; else log_warn " - Порт: Не удалось проверить."; fi; if [ "$all_ok" -eq 1 ]; then log "Статус: OK"; return 0; else log_error "Статус: ПРОБЛЕМЫ!"; return 1; fi
}
configure_kernel_parameters() {
    log "Настройка sysctl (IPv4 fw, откл IPv6)..."; local f="/etc/sysctl.d/99-amneziawg-vpn.conf"; { echo "# AmneziaWG VPN Settings - $(date)"; echo "net.ipv4.ip_forward = 1"; echo ""; echo "# Disable IPv6"; echo "net.ipv6.conf.all.disable_ipv6 = 1"; echo "net.ipv6.conf.default.disable_ipv6 = 1"; echo "net.ipv6.conf.lo.disable_ipv6 = 1"; } > "$f" || die "Ошибка записи $f"; log "Применение sysctl..."; if ! sysctl -p "$f" > /dev/null; then log_warn "Не удалось применить <span class="math-inline">f немедленно\."; else log "Настройки sysctl применены\."; fi; local v4; v4\=</span>(sysctl -n net.ipv4.ip_forward); local v6; v6=$(sysctl -n net.ipv6.conf.all.disable_ipv6); if [[ "$v4" != "1" || "$v6" != "1" ]]; then log_warn "Значения sysctl не установились немедленно. Нужна перезагрузка."; fi
}
secure_files() {
    log_debug "Установка прав..."; if [ -d "$AWG_DIR" ]; then chmod 700 "<span class="math-inline">AWG\_DIR"; chown \-R "</span>{TARGET_USER}:${TARGET_USER}" "$AWG_DIR"; find "$AWG_DIR" -type f -name "*.conf" -exec chmod 600 {} \; 2>/dev/null; find "$AWG_DIR" -type f -name "*.png" -exec chmod 644 {} \; 2>/dev/null; find "$AWG_DIR" -type f -name "*.py" -exec chmod 750 {} \; 2>/dev/null; find "$AWG_DIR" -type f -name "*.sh" -exec chmod 750 {} \; 2>/dev/null; find "$PYTHON_VENV/bin/" -type f -exec chmod 750 {} \; 2>/dev/null; fi; if [ -d "/etc/amnezia" ]; then chmod 700 "/etc/amnezia"; if [ -d "/etc/amnezia/amneziawg" ]; then chmod 700 "/etc/amnezia/amneziawg"; find "/etc/amnezia/amneziawg" -type f -name "*.conf" -exec chmod 600 {} \; 2>/dev/null; fi; fi; if [ -f "$CONFIG_FILE" ]; then chmod 600 "$CONFIG_FILE"; fi; if [ -f "$STATE_FILE" ]; then chmod 640 "<span class="math-inline">STATE\_FILE"; fi; log\_debug "Права установлены\.";
\}
\# \-\-\- ШАГ 0\: Инициализация \-\-\-
initialize\_setup\(\) \{
log\_step "\-\-\- ШАГ 0\: Инициализация и параметры \-\-\-"; if \[ "</span>(id -u)" -ne 0 ]; then die "Нужен sudo."; fi; mkdir -p "<span class="math-inline">AWG\_DIR"; chown "</span>{TARGET_USER}:${TARGET_USER}" "$AWG_DIR"; chmod 700 "$AWG_DIR"; cd "$AWG_DIR" || die "Не удалось войти в $AWG_DIR"; log "Рабочий каталог: $AWG_DIR"; check_os_version; check_free_space; local default_port=39743 default_subnet="10.9.9.1/24" config_exists=0; AWG_PORT=$default_port; AWG_TUNNEL_SUBNET=$default_subnet; ALLOWED_IPS_MODE=""; ALLOWED_IPS=""; if [[ -f "$CONFIG_FILE" ]]; then log "Загрузка из $CONFIG_FILE..."; source "$CONFIG_FILE" 2>/dev/null || log_warn "Не удалось загрузить <span class="math-inline">CONFIG\_FILE\."; config\_exists\=1; AWG\_PORT\=</span>{AWG_PORT:-<span class="math-inline">default\_port\}; AWG\_TUNNEL\_SUBNET\=</span>{AWG_TUNNEL_SUBNET:-<span class="math-inline">default\_subnet\}; ALLOWED\_IPS\_MODE\=</span>{ALLOWED_IPS_MODE:-""}; ALLOWED_IPS=${ALLOWED_IPS:-""}; if [[ -n "$ALLOWED_IPS_MODE" && -z "$ALLOWED_IPS" ]]; then log_warn "Режим ($ALLOWED_IPS_MODE) есть, IP нет. Сброс на режим 2."; ALLOWED_IPS_MODE=2; ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"; fi; log "Настройки загружены."; else log "Запрос параметров..."; while true; do read -p "Порт UDP (1024-65535) [<span class="math-inline">AWG\_PORT\]\: " input\_port < /dev/tty; input\_port\=</span>{input_port:-$AWG_PORT}; if [[ "<span class="math-inline">input\_port" \=\~ ^\[0\-9\]\+</span> ]] && [ "$input_port" -ge 1024 ] && [ "$input_port" -le 65535 ]; then AWG_PORT=$input_port; break; else log_error "Порт некорректен."; fi; done; while true; do read -p "Подсеть туннеля [<span class="math-inline">AWG\_TUNNEL\_SUBNET\]\: " input\_subnet < /dev/tty; input\_subnet\=</span>{input_subnet:-$AWG_TUNNEL_SUBNET}; if [[ "<span class="math-inline">input\_subnet" \=\~ ^\(\[0\-9\]\{1,3\}\\\.\)\{3\}\[0\-9\]\{1,3\}/\[0\-9\]\{1,2\}</span> ]]; then AWG_TUNNEL_SUBNET=$input_subnet; break; else log_error "Подсеть некорректна."; fi; done; configure_routing_mode; fi; check_port_availability "$AWG_PORT" || die "Порт $AWG_PORT/udp занят."; log "Сохранение <span class="math-inline">CONFIG\_FILE\.\.\."; local temp\_conf; temp\_conf\=</span>(mktemp) || die "Ошибка mktemp."; { echo "# AmneziaWG Config"; echo "export AWG_PORT=<span class="math-inline">\{AWG\_PORT\}"; echo "export AWG\_TUNNEL\_SUBNET\='</span>{AWG_TUNNEL_SUBNET}'"; echo "export DISABLE_IPV6=<span class="math-inline">\{DISABLE\_IPV6\}"; echo "export ALLOWED\_IPS\_MODE\=</span>{ALLOWED_IPS_MODE}"; echo "export ALLOWED_IPS='${ALLOWED_IPS}'"; } > "$temp_conf" || { rm -f "$temp_conf"; die "Ошибка записи temp."; }; if ! mv "$temp_conf" "$CONFIG_FILE"; then rm -f "$temp_conf"; die "Ошибка сохранения $CONFIG_FILE"; fi; chmod 600 "<span class="math-inline">CONFIG\_FILE"; chown "</span>{TARGET_USER}:${TARGET_USER}" "<span class="math-inline">CONFIG\_FILE"; log "Настройки сохранены\."; export AWG\_PORT AWG\_TUNNEL\_SUBNET DISABLE\_IPV6 ALLOWED\_IPS\_MODE ALLOWED\_IPS; log "Параметры\: Порт\=</span>{AWG_PORT}, Подсеть=<span class="math-inline">\{AWG\_TUNNEL\_SUBNET\}, IPv6\=</span>{DISABLE_IPV6}, Режим=${ALLOWED_IPS_MODE}"; if [[ -f "<span class="math-inline">STATE\_FILE" \]\]; then current\_step\=</span>(cat "$STATE_FILE"); if ! [[ "<span class="math-inline">current\_step" \=\~ ^\[0\-9\]\+</span> ]]; then log_warn "$STATE_FILE поврежден. Шаг 1."; current_step=1; update_state 1; else log "Продолжение с шага $current_step."; fi; else log "Начало с шага 1."; current_step=1; update_state 1; fi; log_step "--- Шаг 0 завершен ---"; echo ""
}

# --- ШАГ 1: Обновление системы и ядра ---
step1_update_system_and_networking() {
    update_state 1; log_step "### ШАГ 1: Обновление и настройка ядра ###"; log "Обновление системы..."; apt update -y || die "apt update не удался."; if fuser /var/lib/dpkg/lock* &>/dev/null; then log_warn "Блокировка dpkg..."; killall apt apt-get dpkg &>/dev/null; sleep 2; rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*; dpkg --configure -a || log_warn "dpkg --configure -a не удался."; apt update -y || die "Повторный apt update не удался."; fi; DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "apt full-upgrade не удался."; log "Система обновлена."; install_packages curl wget gpg sudo; configure_kernel_parameters; log_step "--- Шаг 1 завершен ---"; request_reboot 2;
}

# --- ШАГ 2: Установка AmneziaWG ---
step2_install_amnezia() {
    update_state 2; log_step "### ШАГ 2: Установка AmneziaWG ###"; local sources_file="/etc/apt/sources.list.d/ubuntu.sources"; log_debug "Проверка deb-src в $sources_file..."; if [ -f "$sources_file" ] && grep -q "Types: deb" "$sources_file" && ! grep -q "Types: deb deb-src" "<span class="math-inline">sources\_file"; then log "Включение deb\-src\.\.\."; local bak\="</span>{sources_file}.bak-$(date +%F_%T)"; cp "$sources_file" "$bak" || log_warn "Бэкап <span class="math-inline">bak не удался\."; local tmp; tmp\=</span>(mktemp); if sed 's/Types: deb$/Types: deb deb-src/' "$sources_file" > "$tmp"; then if mv "$tmp" "$sources_file"; then log "deb-src включены. Обновление apt..."; apt update -y || die "apt update не удался."; else rm -f "$tmp"; die "mv $tmp в $sources_file не удался."; fi; else rm -f "$tmp"; log_warn "sed $sources_file не удался."; fi; elif [ -f "$sources_file" ]; then log_debug "deb-src включены или файл нестандартный."; else log_warn "<span class="math-inline">sources\_file не найден\."; fi; log "Добавление PPA Amnezia\.\.\."; local ppa\_list\="/etc/apt/sources\.list\.d/amnezia\-ubuntu\-ppa\-</span>(lsb_release -sc).list"; local ppa_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).sources"; if [ ! -f "$ppa_list" ] && [ ! -f "<span class="math-inline">ppa\_sources" \]; then log "Добавление PPA\.\.\."; install\_packages software\-properties\-common; DEBIAN\_FRONTEND\=noninteractive add\-apt\-repository \-y ppa\:amnezia/ppa \|\| die "Не удалось добавить PPA\."; log "PPA добавлен\. Обновление apt\.\.\."; apt update \-y \|\| die "apt update не удался\."; else log "PPA Amnezia уже добавлен\."; apt update \-y \|\| log\_warn "apt update не удался\."; fi; log "Установка пакетов AmneziaWG\.\.\."; local packages\=\("amneziawg\-dkms" "amneziawg\-tools" "wireguard\-tools" "dkms" "build\-essential" "dpkg\-dev" "linux\-headers\-</span>(uname -r)" "iptables"); if ! dpkg -s "linux-headers-$(uname -r)" &> /dev/null; then log_warn "Заголовки для <span class="math-inline">\(uname \-r\) не найдены\. Установка generic\.\.\."; packages\+\=\( "linux\-headers\-generic" \); fi; install\_packages "</span>{packages[@]}"; log "Проверка DKMS статуса..."; sleep 5; local dkms_stat; dkms_stat=$(dkms status 2>&1); log_debug "DKMS: $dkms_stat"; if echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then log "DKMS статус: OK."; else log_error "DKMS статус: НЕ installed!"; log_error "<span class="math-inline">dkms\_stat"; die "Модуль AmneziaWG не собрался/установился\."; fi; log\_step "\-\-\- Шаг 2 завершен \-\-\-"; request\_reboot 3;
\}
\# \-\-\- ШАГ 3\: Проверка модуля ядра \-\-\-
step3\_check\_module\(\) \{
update\_state 3; log\_step "\#\#\# ШАГ 3\: Проверка модуля ядра \#\#\#"; sleep 2; log "Проверка загрузки 'amneziawg'\.\.\."; if lsmod \| grep \-q \-w amneziawg; then log "Модуль загружен\."; else log\_warn "Модуль не загружен\. Загрузка\.\.\."; if modprobe amneziawg; then log "Модуль загружен\."; local mf\="/etc/modules\-load\.d/amneziawg\.conf"; mkdir \-p "</span>(dirname "$mf")"; if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then echo "amneziawg" > "$mf" || log_warn "Ошибка записи $mf"; log "Добавлено в $mf."; fi; else die "modprobe amneziawg не удался."; fi; fi; log "Информация о модуле:"; modinfo amneziawg | grep -E "filename|version|description|license|vermagic" | while IFS= read -r line; do log_msg "INFO" "  <span class="math-inline">line"; done; local mver; mver\=</span>(modinfo -F vermagic amneziawg 2>/dev/null || echo "?"); local kver; kver=$(uname -r); if [[ "$mver" == "$kver"* ]]; then log "VerMagic совпадает (OK)."; else log_warn "VerMagic НЕ СОВПАДАЕТ: Модуль($mver) != Ядро($kver)!"; fi; log_step "--- Шаг 3 завершен ---"; echo ""; update_state 5;
}

# --- ШАГ 5: Python, утилиты, скрипт управления ---
step5_setup_python_and_scripts() {
    update_state 5; log_step "### ШАГ 5: Python, утилиты, скрипты ###"; install_packages python3-venv python3-pip; cd "$AWG_DIR" || die "Не войти в $AWG_DIR"; if [ ! -d "$PYTHON_VENV" ]; then log "Создание venv..."; python3 -m venv "<span class="math-inline">PYTHON\_VENV" \|\| die "Ошибка venv\."; chown \-R "</span>{TARGET_USER}:${TARGET_USER}" "<span class="math-inline">PYTHON\_VENV"; log "Venv создан\."; else log "Venv существует\."; chown \-R "</span>{TARGET_USER}:${TARGET_USER}" "$PYTHON_VENV"; fi; if [ ! -x "$PYTHON_EXEC" ]; then die "$PYTHON_EXEC не найден/исполняем."; fi; log "Установка qrcode[pil]..."; if ! sudo -u "$TARGET_USER" "$PYTHON_EXEC" -m pip install --upgrade pip; then log_warn "pip upgrade не удался."; fi; if ! sudo -u "$TARGET_USER" "$PYTHON_EXEC" -m pip install --disable-pip-version-check "qrcode[pil]"; then die "Ошибка установки qrcode[pil]."; fi; log "Зависимости Python OK."; log "Загрузка awgcfg.py..."; local awgcfg_url="https://gist.githubusercontent.com/remittor/8c3d9ff293b2ba4b13c367cc1a69f9eb/raw/awgcfg.py"; if curl -fLso "$AWGCFG_SCRIPT" "$awgcfg_url"; then log "awgcfg.py загружен."; chmod 750 "<span class="math-inline">AWGCFG\_SCRIPT"; chown "</span>{TARGET_USER}:${TARGET_USER}" "$AWGCFG_SCRIPT"; elif [ -f "$AWGCFG_SCRIPT" ]; then log_warn "Скачать awgcfg.py не удалось, но файл есть."; chmod 750 "<span class="math-inline">AWGCFG\_SCRIPT"; chown "</span>{TARGET_USER}:${TARGET_USER}" "$AWGCFG_SCRIPT"; else die "Скачать awgcfg.py не удалось."; fi; log "Загрузка manage.sh..."; if curl -fLso "$MANAGE_SCRIPT_PATH" "$MANAGE_SCRIPT_URL"; then log "manage.sh загружен."; chmod 750 "<span class="math-inline">MANAGE\_SCRIPT\_PATH"; chown "</span>{TARGET_USER}:${TARGET_USER}" "$MANAGE_SCRIPT_PATH"; elif [ -f "$MANAGE_SCRIPT_PATH" ]; then log_warn "Скачать manage.sh не удалось, но файл есть."; chmod 750 "<span class="math-inline">MANAGE\_SCRIPT\_PATH"; chown "</span>{TARGET_USER}:${TARGET_USER}" "$MANAGE_SCRIPT_PATH"; else log_error "Скачать manage.sh не удалось."; fi; log_step "--- Шаг 5 завершен ---"; echo ""; update_state 6;
}

# --- ШАГ 6: Генерация конфигураций ---
step6_generate_configs() {
    update_state 6; log_step "### ШАГ 6: Генерация конфигураций ###"; cd "$AWG_DIR" || die "Не войти в $AWG_DIR"; local sdir="/etc/amnezia/amneziawg"; mkdir -p "$sdir"; chmod 700 "$sdir"; log "Генерация конфига сервера $SERVER_CONF_FILE..."; if ! run_awgcfg --make "<span class="math-inline">SERVER\_CONF\_FILE" \-i "</span>{AWG_TUNNEL_SUBNET}" -p "${AWG_PORT}"; then die "Ошибка генерации конфига сервера."; fi; chmod 600 "$SERVER_CONF_FILE"; log "Конфиг сервера OK."; log "Настройка шаблона $CLIENT_TEMPLATE_FILE..."; if ! run_awgcfg --create; then log_warn "Не удалось создать $CLIENT_TEMPLATE_FILE."; touch "$CLIENT_TEMPLATE_FILE" || true; fi; log "Применение настроек к шаблону:"; local sed_failed=0; sed -i 's/^DNS = .*/DNS = 1.1.1.1/' "$CLIENT_TEMPLATE_FILE" && log " - DNS: 1.1.1.1" || { log_warn " - Ошибка sed DNS."; sed_failed=1; }; sed -i 's/^PersistentKeepalive = .*/PersistentKeepalive = 33/' "<span class="math-inline">CLIENT\_TEMPLATE\_FILE" && log " \- Keepalive\: 33" \|\| \{ log\_warn " \- Ошибка sed Keepalive\."; sed\_failed\=1; \}; local escaped\_ips; escaped\_ips\=</span>(echo "$ALLOWED_IPS" | sed 's/[&#/\]/\\&/g'); sed -i "s#^AllowedIPs = .*#AllowedIPs = ${escaped_ips}#" "$CLIENT_TEMPLATE_FILE" && log " - AllowedIPs: OK (Режим $ALLOWED_IPS_MODE)" || { log_warn " - Ошибка sed AllowedIPs."; sed_failed=1; }; if [ "<span class="math-inline">sed\_failed" \-eq 1 \]; then log\_warn "Не все параметры применены\."; else log "Шаблон OK\."; fi; chown "</span>{TARGET_USER}:${TARGET_USER}" "$CLIENT_TEMPLATE_FILE"; chmod 600 "<span class="math-inline">CLIENT\_TEMPLATE\_FILE"; log "Добавление клиентов по умолчанию\.\.\."; local defaults\=\("my\_phone" "my\_laptop"\); for cl in "</span>{defaults[@]}"; do if grep -q "^#_Name = <span class="math-inline">\{cl\}</span>" "$SERVER_CONF_FILE"; then log " - $cl уже есть."; else log " - Добавление $cl..."; if run_awgcfg -a "$cl"; then log "   $cl добавлен."; else log_error "   Не удалось добавить <span class="math-inline">cl\."; fi; fi; done; log "Генерация файлов клиентов \(\.conf/\.png\)\.\.\."; local tmp\_bak\="</span>{TARGET_HOME}/.<span class="math-inline">\{CONFIG\_FILE\#\#\*/\}\.bak\_</span>(date +%s)"; local mv_fail=0; if [ -f "$CONFIG_FILE" ]; then mv "$CONFIG_FILE" "$tmp_bak" || { log_warn "Workaround: mv не удался."; mv_fail=1; }; fi; log_debug "Workaround: mv_fail=$mv_fail"; if ! run_awgcfg -c -q; then log_error "Ошибка генерации файлов клиентов."; else log "Файлы клиентов OK."; ls -l "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | sed 's/^/  /' | while IFS= read -r line; do log_msg "INFO" "$line"; done; fi; if [ "$mv_fail" -eq 0 ] && [ -f "$tmp_bak" ]; then mv "$tmp_bak" "$CONFIG_FILE" || log_error "Workaround: Не удалось вернуть $CONFIG_FILE!"; fi; rm -f "$tmp_bak"; if [ ! -f "$CONFIG_FILE" ]; then log_error "$CONFIG_FILE отсутствует!"; fi; secure_files; log_step "--- Шаг 6 завершен ---"; echo ""; update_state 7;
}

# --- ШАГ 7: Запуск сервиса ---
step7_start_service_and_final_check() {
    update_state 7; log_step "### ШАГ 7: Запуск сервиса и проверка ###"; log "Запуск 'awg-quick@awg0'..."; if systemctl enable --now awg-quick@awg0; then log "Команда 'enable --now' OK."; if systemctl is-active --quiet awg-quick@awg0; then log "Сервис активен."; else log_warn "Сервис не активен сразу."; fi; else log_error "Не удалось включить/запустить сервис!"; systemctl status awg-quick@awg0 --no-pager -l >&2; journalctl -u awg-quick@awg0 -n 20 --no-pager --output=cat >&2; die "Ошибка запуска."; fi; log "Ожидание (5 сек)..."; sleep 5; check_service_status || die "Финальная проверка не пройдена."; log_step "--- Шаг 7 завершен ---"; echo ""; update_state 99;
}

# --- ШАГ 99: Завершение ---
step99_finish() {
    log_step "### ЗАВЕРШЕНИЕ УСТАНОВКИ ###"; echo ""; log "==================================================================="; log " Установка AmneziaWG УСПЕШНО ЗАВЕРШЕНА!"; log "==================================================================="; echo ""; log "Клиентские файлы (.conf/.png) в: $AWG_DIR"; log "Пример копирования: scp <span class="math-inline">\{TARGET\_USER\}@<IP\>\:</span>{AWG_DIR}/*.conf ./"; echo ""; log "Управление: sudo bash $MANAGE_SCRIPT_PATH help"; echo ""; log "Статус: systemctl status awg-quick@awg0 / sudo awg show"; echo ""; if [ ! -f "$CONFIG_FILE" ]; then log_error "ВНИМАНИЕ: $CONFIG_FILE отсутствует!"; fi; cleanup_apt; log "Удаление файла состояния..."; rm -f "$STATE_FILE" || log_warn "Не удалось удалить $STATE_FILE."; echo ""; log "Установка завершена."; log "==================================================================="; echo "";
}

# --- Основной Цикл Выполнения ---
trap 'echo ""; log_error "Прервано (SIGINT)."; exit 1' SIGINT
trap 'echo ""; log_error "Прервано (SIGTERM)."; exit 1' SIGTERM

if [ "$HELP" -eq 1 ]; then show_help; fi
if [ "<span class="math-inline">VERBOSE" \-eq 1 \]; then log "Verbose режим\."; set \-x; fi
initialize\_setup \# Шаг 0
if \! \[\[ "</span>{current_step:-}" =~ ^[0-9]+$ ]]; then die "current_step не установлен."; fi

while (( current_step < 99 )); do
    log_debug "Шаг $current_step...";
    case $current_step in
        1) step1_update_system_and_networking ;; # Выход
        2) step2_install_amnezia ;;              # Выход
        3) step3_check_module; current_step=5 ;;
        5) step5_setup_python_and_scripts; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service_and_final_check; current_step=99 ;;
        *) die "Неизвестный шаг '$current_step'." ;;
    esac
done

if (( current_step == 99 )); then step99_finish; fi
if [ "$VERBOSE" -eq 1 ]; then set +x; fi

exit 0
