#!/bin/bash

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG на Ubuntu 24.04 LTS Minimal
# Версия Azure Mini (для стандартного пользователя + sudo)
# Автор: @bivlked
# Версия: 1.1 (Azure Mini - Dynamic User)
# Дата: 2025-04-21
# Репозиторий: https://github.com/bivlked/azure
# ==============================================================================

# --- Безопасный режим и Константы ---
set -o pipefail

# Определяем пользователя и домашний каталог
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME=$(eval echo "~$SUDO_USER")
    if [ ! -d "$TARGET_HOME" ]; then # Проверка существования домашней директории
        echo "[ERROR] Не удалось определить домашнюю директорию для пользователя '$TARGET_USER'. Попробуйте создать ее или проверьте переменную \$HOME." >&2
        exit 1
    fi
else
    # Если SUDO_USER не определен или это root, работаем в /root
    TARGET_USER="root"
    TARGET_HOME="/root"
    echo "[WARN] Запуск от root или не удалось определить пользователя sudo. Рабочая директория: ${TARGET_HOME}/awg" >&2
fi

AWG_DIR="${TARGET_HOME}/awg" # Рабочая директория
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" # Имя файла конфигурации
STATE_FILE="$AWG_DIR/setup_state"
CLIENT_TEMPLATE_FILE="$AWG_DIR/_defclient.config"
LOG_FILE="$AWG_DIR/install_amneziawg.log"
PYTHON_VENV="$AWG_DIR/venv/bin/python" # Путь внутри AWG_DIR
AWGCFG_SCRIPT="$AWG_DIR/awgcfg.py"       # Путь внутри AWG_DIR
MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/azure/main/awgmng.sh" # URL нового скрипта управления
MANAGE_SCRIPT_PATH="$AWG_DIR/awgmng.sh"    # Путь к новому скрипту управления
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf" # Системный путь

# Опции
UNINSTALL=0; HELP=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; CLI_PORT=""; CLI_SUBNET=""; CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES="";
DISABLE_IPV6=1; # Принудительно отключаем IPv6

# --- Обработка аргументов ---
while [[ $# -gt 0 ]]; do case $1 in --uninstall) UNINSTALL=1;; --help|-h) HELP=1;; --diagnostic) DIAGNOSTIC=1;; --verbose|-v) VERBOSE=1;; --no-color) NO_COLOR=1;; --port=*) CLI_PORT="${1#*=}";; --subnet=*) CLI_SUBNET="${1#*=}";; --route-all) CLI_ROUTING_MODE=1;; --route-amnezia) CLI_ROUTING_MODE=2;; --route-custom=*) CLI_ROUTING_MODE=3; CLI_CUSTOM_ROUTES="${1#*=}";; *) echo "Неизвестный аргумент: $1"; HELP=1;; esac; shift; done

# --- Функции ---
log_msg() { local type="$1"; local msg="$2"; local ts; ts=$(date +'%F %T'); local safe_msg; safe_msg=$(echo "$msg" | sed 's/%/%%/g'); local entry="[$ts] $type: $safe_msg"; local color_start=""; local color_end="\033[0m"; if [[ "$NO_COLOR" -eq 0 ]]; then case "$type" in INFO) color_start="\033[0;32m";; WARN) color_start="\033[0;33m";; ERROR) color_start="\033[1;31m";; DEBUG) color_start="\033[0;36m";; *) color_start=""; color_end="";; esac; fi; if ! mkdir -p "$(dirname "$LOG_FILE")" || ! echo "$entry" >> "$LOG_FILE"; then echo "[$ts] ERROR: Ошибка записи лога $LOG_FILE" >&2; fi; if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then printf "${color_start}%s${color_end}\n" "$entry" >&2; elif [[ "$type" == "DEBUG" && "$VERBOSE" -eq 1 ]]; then printf "${color_start}%s${color_end}\n" "$entry" >&2; elif [[ "$type" == "INFO" ]]; then printf "${color_start}%s${color_end}\n" "$entry"; else printf "${color_start}%s${color_end}\n" "$entry"; fi; }
log() { log_msg "INFO" "$1"; }; log_warn() { log_msg "WARN" "$1"; }; log_error() { log_msg "ERROR" "$1"; }; log_debug() { if [[ "$VERBOSE" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }; die() { log_error "КРИТИЧЕСКАЯ ОШИБКА: $1"; log_error "Установка прервана. Лог: $LOG_FILE"; exit 1; }
show_help() { cat << EOF
Использование: $0 [ОПЦИИ]
Скрипт для **минимальной** установки AmneziaWG на Ubuntu 24.04 (Azure Mini).

Опции:
  -h, --help            Показать эту справку и выйти
  --uninstall           Удалить AmneziaWG
  --diagnostic          Создать диагностический отчет
  -v, --verbose         Расширенный вывод
  --no-color            Отключить цветной вывод
  --port=НОМЕР          Установить UDP порт (1024-65535) неинтерактивно
  --subnet=ПОДСЕТЬ      Установить подсеть туннеля (x.x.x.x/yy) неинтерактивно
  --route-all           Режим: Весь трафик
  --route-amnezia       Режим: Список Amnezia+DNS (умолч.)
  --route-custom=СЕТИ   Режим: Только указанные сети

Примечание: IPv6 принудительно отключается. UFW и Fail2Ban не устанавливаются.
Рабочая директория: ${TARGET_HOME}/awg
EOF
exit 0; }
update_state() { local next_step=$1; mkdir -p "$(dirname "$STATE_FILE")"; echo "$next_step" > "$STATE_FILE" || die "Ошибка записи состояния"; chown "${TARGET_USER}:${TARGET_USER}" "$STATE_FILE"; log "Состояние: следующий шаг - $next_step"; }
request_reboot() { local next_step=$1; update_state "$next_step"; echo "" >> "$LOG_FILE"; log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; log_warn "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ !!!"; log_warn "!!! После перезагрузки, запустите скрипт снова командой:"; log_warn "!!! sudo bash $0 [с теми же параметрами, если были]"; log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; echo "" >> "$LOG_FILE"; read -p "Перезагрузить сейчас? [y/N]: " confirm < /dev/tty; if [[ "$confirm" =~ ^[Yy]$ ]]; then log "Инициирована перезагрузка..."; sleep 5; if ! reboot; then die "Команда reboot не удалась."; fi; exit 1; else log "Перезагрузка отменена. Перезагрузитесь вручную и запустите скрипт снова."; exit 1; fi; }
check_os_version() { log "Проверка ОС..."; if ! command -v lsb_release &> /dev/null; then log_warn "lsb_release не найден."; return 0; fi; local os_id; os_id=$(lsb_release -si); local os_ver; os_ver=$(lsb_release -sr); if [[ "$os_id" != "Ubuntu" || "$os_ver" != "24.04" ]]; then log_warn "Обнаружена $os_id $os_ver. Скрипт для Ubuntu 24.04."; read -p "Продолжить? [y/N]: " confirm < /dev/tty; if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Отмена."; fi; else log "ОС: Ubuntu $os_ver (OK)"; fi; }
check_free_space() { log "Проверка места..."; local req=1024; local avail; avail=$(df -m / | awk 'NR==2 {print $4}'); if [[ -z "$avail" ]]; then log_warn "Не удалось определить свободное место."; return 0; fi; if [ "$avail" -lt "$req" ]; then log_warn "Доступно $avail МБ. Рекомендуется >= $req МБ."; read -p "Продолжить? [y/N]: " confirm < /dev/tty; if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Отмена."; fi; else log "Свободно: $avail МБ (OK)"; fi; }
check_port_availability() { local port=$1; log "Проверка порта $port..."; local proc; proc=$(ss -lunp | grep ":${port} "); if [[ -n "$proc" ]]; then log_error "Порт ${port}/udp уже используется! Процесс: $proc"; return 1; else log "Порт $port/udp свободен."; return 0; fi; }
install_packages() { local packages=("$@"); local to_install=(); local pkg; log "Проверка пакетов: ${packages[*]}..."; for pkg in "${packages[@]}"; do if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then to_install+=("$pkg"); fi; done; if [ ${#to_install[@]} -eq 0 ]; then log "Все пакеты уже установлены."; return 0; fi; log "Установка: ${to_install[*]}..."; apt update -y || log_warn "Не удалось обновить apt."; DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}" || die "Ошибка установки пакетов."; log "Пакеты установлены."; }
cleanup_apt() { log "Очистка apt..."; apt-get clean || log_warn "Ошибка apt-get clean"; rm -rf /var/lib/apt/lists/* || log_warn "Ошибка rm /var/lib/apt/lists/*"; log "Кэш apt очищен."; }
# configure_ipv6() { ... } # Функция удалена
configure_routing_mode() { if [[ "$CLI_ROUTING_MODE" != "default" ]]; then ALLOWED_IPS_MODE=$CLI_ROUTING_MODE; if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then ALLOWED_IPS=$CLI_CUSTOM_ROUTES; if [ -z "$ALLOWED_IPS" ]; then die "Не указаны сети для --route-custom."; fi; fi; log "Режим маршрутизации из CLI: $ALLOWED_IPS_MODE"; else echo ""; log "Выберите режим маршрутизации (AllowedIPs клиента):"; echo "  1) Весь трафик (0.0.0.0/0)"; echo "  2) Список Amnezia+DNS (умолч.)"; echo "  3) Только указанные сети"; read -p "Ваш выбор [2]: " r_mode < /dev/tty; ALLOWED_IPS_MODE=${r_mode:-2}; fi; case "$ALLOWED_IPS_MODE" in 1) ALLOWED_IPS="0.0.0.0/0"; log "Выбран режим: Весь трафик.";; 3) if [[ -z "$CLI_CUSTOM_ROUTES" ]]; then read -p "Введите сети (a.b.c.d/xx,...): " custom < /dev/tty; ALLOWED_IPS=$custom; else ALLOWED_IPS=$CLI_CUSTOM_ROUTES; fi; if ! echo "$ALLOWED_IPS" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}(,([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2})*$'; then log_warn "Формат сетей ('$ALLOWED_IPS') некорректен."; fi; log "Выбран режим: Пользовательский ($ALLOWED_IPS)";; *) ALLOWED_IPS_MODE=2; ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"; log "Выбран режим: Список Amnezia+DNS.";; esac; if [ -z "$ALLOWED_IPS" ]; then die "Не удалось определить AllowedIPs."; fi; if [[ "$ALLOWED_IPS_MODE" -eq 3 ]]; then ALLOWED_IPS_SAVE=$(echo "$ALLOWED_IPS" | sed 's/,/\\,/g'); else ALLOWED_IPS_SAVE="$ALLOWED_IPS"; fi; export ALLOWED_IPS_MODE ALLOWED_IPS ALLOWED_IPS_SAVE; }
run_awgcfg() { log_debug "Вызов run_awgcfg из $AWG_DIR: $*"; # Уточнили CWD
    # Запускаем от имени целевого пользователя? Нет, основной скрипт уже под sudo.
    # Важно, чтобы venv и сам скрипт были доступны root, но файлы создавались в $AWG_DIR
    if [ ! -x "$PYTHON_VENV" ] || [ ! -x "$AWGCFG_SCRIPT" ]; then log_error "Python venv или awgcfg.py недоступен."; return 1; fi;
    if ! (cd "$AWG_DIR" && "$PYTHON_VENV" "$AWGCFG_SCRIPT" "$@"); then log_error "Ошибка выполнения awgcfg.py $*"; return 1; fi;
    # Устанавливаем владельца на файлы, созданные awgcfg.py (на всякий случай)
    chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null || true
    log_debug "awgcfg.py $* выполнен успешно."; return 0;
 }
check_service_status() { log "Проверка статуса сервиса..."; local ok=1; if ! systemctl is-active --quiet awg-quick@awg0 && ! systemctl is-failed --quiet awg-quick@awg0; then local state; state=$(systemctl show -p SubState --value awg-quick@awg0 2>/dev/null) || state="unknown"; if [[ "$state" != "exited" ]]; then log_warn "Статус сервиса: $state"; fi; fi; if systemctl is-failed --quiet awg-quick@awg0; then log_error "Сервис FAILED!"; ok=0; fi; if ! ip addr show awg0 &>/dev/null; then log_error "Интерфейс awg0 не найден!"; ok=0; fi; if ! awg show | grep -q "interface: awg0"; then log_error "awg show не видит интерфейс!"; ok=0; fi; local port_check=${AWG_PORT:-0}; if [ "$port_check" -eq 0 ] && [ -f "$CONFIG_FILE" ]; then port_check=$(cat "$CONFIG_FILE" | grep AWG_PORT | cut -d'=' -f2); port_check=${port_check:-0}; fi; if [ "$port_check" -ne 0 ]; then if ! ss -lunp | grep -q ":${port_check} "; then log_error "Порт $port_check/udp не прослушивается!"; ok=0; fi; else log_warn "Не удалось проверить порт."; fi; if [ "$ok" -eq 1 ]; then log "Статус сервиса и интерфейса OK."; return 0; else return 1; fi; }
setup_advanced_sysctl() { log "Настройка sysctl (форвардинг и ОТКЛЮЧЕНИЕ IPv6)..."; local f="/etc/sysctl.d/99-amneziawg-vpn.conf"; { echo "# AmneziaWG VPN Settings - $(date)"; echo "net.ipv4.ip_forward = 1"; echo "# Force disable IPv6"; echo "net.ipv6.conf.all.disable_ipv6 = 1"; echo "net.ipv6.conf.default.disable_ipv6 = 1"; echo "net.ipv6.conf.lo.disable_ipv6 = 1"; } > "$f" || die "Ошибка записи в $f"; log "Применение sysctl..."; if ! sysctl -p "$f" > /dev/null; then log_warn "Не удалось применить $f."; fi; }
# setup_improved_firewall() { ... } # Функция удалена
secure_files() { log "Установка прав доступа..."; chmod 700 "$AWG_DIR" &>/dev/null; chown -R "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR" || log_warn "Не удалось сменить владельца $AWG_DIR"; chmod 700 /etc/amnezia &>/dev/null; chmod 700 /etc/amnezia/amneziawg &>/dev/null; chmod 600 /etc/amnezia/amneziawg/*.conf &>/dev/null; find "$AWG_DIR" -name "*.conf" -type f -exec chmod 600 {} \; &>/dev/null; find "$AWG_DIR" -name "*.png" -type f -exec chmod 644 {} \; &>/dev/null; if [ -f "$CONFIG_FILE" ]; then chmod 600 "$CONFIG_FILE"; chown "${TARGET_USER}:${TARGET_USER}" "$CONFIG_FILE"; fi; if [ -f "$LOG_FILE" ]; then chmod 640 "$LOG_FILE"; chown "${TARGET_USER}:${TARGET_USER}" "$LOG_FILE"; fi; if [ -f "$MANAGE_SCRIPT_PATH" ]; then chmod 750 "$MANAGE_SCRIPT_PATH"; chown "${TARGET_USER}:${TARGET_USER}" "$MANAGE_SCRIPT_PATH"; fi; log "Права доступа установлены."; }
# setup_fail2ban() { ... } # Функция удалена
create_diagnostic_report() { log "Создание диагностики..."; local rf="$AWG_DIR/diag_$(date +%F_%T).txt"; { echo "=== AMNEZIAWG DIAG REPORT (Azure Mini) ==="; date; hostname; echo "--- OS ---"; lsb_release -ds; uname -a; echo ""; echo "--- Configuration ($CONFIG_FILE) ---"; cat "$CONFIG_FILE" 2>/dev/null || echo "File not found"; echo ""; echo "--- Service Status ---"; systemctl status awg-quick@awg0 --no-pager -l; echo ""; echo "--- Network Interfaces ---"; ip a; echo ""; echo "--- AWG Status ---"; awg show; echo ""; echo "--- Listening Ports ---"; ss -lunp; echo ""; echo "--- Routing Table ---"; ip route; echo ""; echo "--- Kernel Params ---"; sysctl net.ipv4.ip_forward net.ipv6.conf.all.disable_ipv6 2>/dev/null; echo ""; echo "--- AWG Journal (last 50) ---"; journalctl -u awg-quick@awg0 -n 50 --no-pager --output=cat; echo ""; echo "--- Client List ---"; grep "^#_Name = " "$SERVER_CONF_FILE" | sed 's/^#_Name = //' || echo "N/A"; echo ""; echo "--- DKMS Status ---"; dkms status 2>/dev/null || echo "N/A"; echo ""; echo "--- Module Info ---"; modinfo amneziawg 2>/dev/null || echo "N/A"; echo ""; echo "=== END ==="; } > "$rf" || log_error "Ошибка записи отчета."; chown "${TARGET_USER}:${TARGET_USER}" "$rf"; chmod 600 "$rf" || log_warn "Ошибка chmod отчета."; log "Отчет: $rf"; }

# --- Шаг 0: Инициализация ---
initialize_setup() {
    # Создаем директорию и устанавливаем владельца сразу
    mkdir -p "$AWG_DIR" || die "Ошибка создания $AWG_DIR"; chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR" || die "Ошибка смены владельца $AWG_DIR"; chmod 700 "$AWG_DIR";
    # Создаем лог и устанавливаем владельца
    touch "$LOG_FILE" || die "Не удалось создать лог-файл $LOG_FILE"; chown "${TARGET_USER}:${TARGET_USER}" "$LOG_FILE"; chmod 640 "$LOG_FILE";

    log "--- НАЧАЛО УСТАНОВКИ / ПРОВЕРКА СОСТОЯНИЯ ---"; log "### ШАГ 0: Инициализация и проверка параметров ###";
    if [ "$(id -u)" -ne 0 ]; then die "Запустите скрипт через sudo (sudo bash $0)."; fi
    # Переходим в рабочую директорию пользователя
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"; log "Рабочая директория: $AWG_DIR"; log "Лог файл: $LOG_FILE";
    PYTHON_VENV="$AWG_DIR/venv/bin/python"; AWGCFG_SCRIPT="$AWG_DIR/awgcfg.py";

    # Проверки системы
    check_os_version; check_free_space;

    local default_port=39743; local default_subnet="10.9.9.1/24"; local config_exists=0;
    # Инициализация переменных
    AWG_PORT=$default_port; AWG_TUNNEL_SUBNET=$default_subnet;
    # IPv6 отключаем принудительно, переменная устанавливается в начале
    ALLOWED_IPS_MODE="default"; ALLOWED_IPS="";

    # Загрузка конфига
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Найден файл конфигурации $CONFIG_FILE. Загрузка настроек..."; config_exists=1;
        source "$CONFIG_FILE" || log_warn "Не удалось полностью загрузить настройки из $CONFIG_FILE.";
        AWG_PORT=${AWG_PORT:-$default_port}; AWG_TUNNEL_SUBNET=${AWG_TUNNEL_SUBNET:-$default_subnet};
        ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE:-2}; ALLOWED_IPS=${ALLOWED_IPS:-""};
        log "Настройки из файла загружены.";
    else
        log "Файл конфигурации $CONFIG_FILE не найден.";
        ALLOWED_IPS_MODE="default";
    fi

    # Переопределение из CLI
    AWG_PORT=${CLI_PORT:-$AWG_PORT}; AWG_TUNNEL_SUBNET=${CLI_SUBNET:-$AWG_TUNNEL_SUBNET};
    # IPv6 не переопределяется, всегда отключен
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then ALLOWED_IPS_MODE=$CLI_ROUTING_MODE; if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then ALLOWED_IPS=$CLI_CUSTOM_ROUTES; fi; fi

    # Запрашиваем у пользователя ТОЛЬКО ЕСЛИ конфига НЕ БЫЛО
    if [[ "$config_exists" -eq 0 ]]; then
         log "Запрос настроек у пользователя (первый запуск).";
         read -p "Введите UDP порт AmneziaWG (1024-65535) [${AWG_PORT}]: " input_port < /dev/tty; if [[ -n "$input_port" ]]; then AWG_PORT=$input_port; fi; if ! [[ "$AWG_PORT" =~ ^[0-9]+$ ]] || [ "$AWG_PORT" -lt 1024 ] || [ "$AWG_PORT" -gt 65535 ]; then die "Некорректный порт."; fi
         read -p "Введите подсеть туннеля [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty; if [[ -n "$input_subnet" ]]; then AWG_TUNNEL_SUBNET=$input_subnet; fi; if ! [[ "$AWG_TUNNEL_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then printf "ERROR: Некорр. подсеть: '$AWG_TUNNEL_SUBNET'.\n">&2; exit 1; fi
         # Запрашиваем режим маршрутизации, если не задан через CLI
         if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then configure_routing_mode; fi
    else
         log "Используются настройки из $CONFIG_FILE (переопределенные CLI, если были).";
    fi
    # Убедимся, что режим маршрутизации установлен
    if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then ALLOWED_IPS_MODE=2; fi
    # Пересчитаем ALLOWED_IPS на основе режима, если он пуст или если режим был переопределен CLI
    if [[ -z "$ALLOWED_IPS" || "$CLI_ROUTING_MODE" != "default" ]]; then
        configure_routing_mode; # Вызовет с уже установленным ALLOWED_IPS_MODE
    fi

    # Финальная проверка порта
    check_port_availability "$AWG_PORT" || die "Выбранный порт $AWG_PORT/udp занят.";

    # Гарантированное сохранение/перезапись awgsetup_cfg.init
    log "Сохранение/Обновление настроек в $CONFIG_FILE..."; local temp_conf; temp_conf=$(mktemp) || die "Ошибка mktemp.";
    printf "%s\n" "# Конфигурация установки AmneziaWG (Авто)" > "$temp_conf" || die "Ошибка записи"; printf "%s\n" "# Используется скриптом управления" >> "$temp_conf";
    printf "export AWG_PORT=%s\n" "${AWG_PORT}" >> "$temp_conf"; printf "export AWG_TUNNEL_SUBNET='%s'\n" "${AWG_TUNNEL_SUBNET}" >> "$temp_conf";
    printf "export DISABLE_IPV6=%s\n" "${DISABLE_IPV6}" >> "$temp_conf"; printf "export ALLOWED_IPS_MODE=%s\n" "${ALLOWED_IPS_MODE}" >> "$temp_conf";
    local saved_ips; saved_ips=$(echo "$ALLOWED_IPS" | sed 's/\\,/,/g'); printf "export ALLOWED_IPS='%s'\n" "${saved_ips}" >> "$temp_conf";
    if ! mv "$temp_conf" "$CONFIG_FILE"; then rm -f "$temp_conf"; die "Ошибка сохранения $CONFIG_FILE"; fi; chmod 600 "$CONFIG_FILE" || log_warn "Ошибка chmod $CONFIG_FILE"; chown "${TARGET_USER}:${TARGET_USER}" "$CONFIG_FILE"; log "Настройки сохранены.";
    export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS;
    log "Порт: ${AWG_PORT}/udp"; log "Подсеть: ${AWG_TUNNEL_SUBNET}"; log "Откл. IPv6: $DISABLE_IPV6"; log "Режим AllowedIPs: $ALLOWED_IPS_MODE";

    # Загрузка состояния
    if [[ -f "$STATE_FILE" ]]; then current_step=$(cat "$STATE_FILE"); if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then log_warn "$STATE_FILE поврежден."; current_step=1; update_state 1; else log "Продолжение с шага $current_step."; fi; else current_step=1; log "Начало с шага 1."; update_state 1; fi
    log "Шаг 0 завершен.";
}

# --- Функции для шагов установки ---

# ШАГ 1: Обновление системы и настройка ядра
step1_update_system_and_networking() {
    update_state 1; log "### ШАГ 1: Обновление и настройка ядра ###";
    log "Обновление списка пакетов..."; apt update -y || die "Ошибка apt update.";
    log "Разблокировка dpkg..."; if fuser /var/lib/dpkg/lock* &>/dev/null; then log_warn "dpkg заблокирован..."; DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."; fi
    log "Обновление системы..."; DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "Ошибка apt full-upgrade."; log "Система обновлена.";
    # Убрали net-tools
    install_packages curl wget gpg sudo; setup_advanced_sysctl;
    log "Шаг 1 успешно завершен."; request_reboot 2;
}

# ШАГ 2: Установка AmneziaWG и зависимостей
step2_install_amnezia() {
    update_state 2; log "### ШАГ 2: Установка AmneziaWG и зависимостей ###"; local sources_file="/etc/apt/sources.list.d/ubuntu.sources";
    log "Проверка/включение deb-src..."; if [ ! -f "$sources_file" ]; then die "$sources_file не найден."; fi;
    if grep -q "^Types: deb$" "$sources_file"; then log "Включение deb-src..."; local bak="${sources_file}.bak-$(date +%F_%T)"; cp "$sources_file" "$bak" || log_warn "Ошибка бэкапа"; local tmp_sed; tmp_sed=$(mktemp); sed '/^Types: deb$/s/Types: deb/Types: deb deb-src/' "$sources_file" > "$tmp_sed" || { rm -f "$tmp_sed"; die "Ошибка sed."; }; if ! mv "$tmp_sed" "$sources_file"; then rm -f "$tmp_sed"; die "Ошибка mv $sources_file"; fi; if grep -q "^Types: deb$" "$sources_file"; then log_warn "Не удалось включить deb-src."; else log "deb-src добавлены."; fi; apt update -y || die "Ошибка apt update.";
    elif ! grep -q "Types: deb deb-src" "$sources_file"; then log_warn "Структура $sources_file нестандартная."; apt update -y || die "Ошибка apt update."; else log "deb-src включены."; apt update -y; fi
    log "Добавление PPA Amnezia..."; local ppa_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).list"; local ppa_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).sources"; if [ ! -f "$ppa_list" ] && [ ! -f "$ppa_sources" ]; then DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:amnezia/ppa || die "Ошибка PPA."; log "PPA добавлен."; apt update -y || die "Ошибка apt update."; else log "PPA уже добавлен."; apt update -y || die "Ошибка apt update."; fi
    log "Установка пакетов AmneziaWG..."; local packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms" "linux-headers-$(uname -r)" "build-essential" "dpkg-dev"); if ! dpkg -s "linux-headers-$(uname -r)" &> /dev/null; then log_warn "Нет headers для $(uname -r)..."; packages+=( "linux-headers-generic" ); fi; install_packages "${packages[@]}";
    log "Проверка статуса DKMS..."; local dkms_stat; dkms_stat=$(dkms status 2>&1); if ! echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then log_warn "DKMS статус не OK."; log_msg "WARN" "$dkms_stat"; else log "DKMS статус OK."; fi
    log "Шаг 2 завершен."; request_reboot 3;
}

# ШАГ 3: Проверка загрузки модуля ядра
step3_check_module() {
    update_state 3; log "### ШАГ 3: Проверка модуля ядра ###"; sleep 2;
    if ! lsmod | grep -q -w amneziawg; then log "Модуль не загружен. Загрузка..."; modprobe amneziawg || die "Ошибка modprobe amneziawg."; log "Модуль загружен."; local mf="/etc/modules-load.d/amneziawg.conf"; mkdir -p "$(dirname "$mf")"; if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then echo "amneziawg" > "$mf" || log_warn "Ошибка записи $mf"; log "Добавлено в $mf."; fi; else log "Модуль amneziawg загружен."; fi
    log "Информация о модуле:"; modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" | log_msg "INFO"; local cv; cv=$(modinfo amneziawg | grep vermagic | awk '{print $2}') || cv="?"; local kr; kr=$(uname -r); if [[ "$cv" != "$kr" ]]; then log_warn "VerMagic НЕ совпадает: Модуль($cv) != Ядро($kr)!"; else log "VerMagic совпадает."; fi
    # Переход к Шагу 5, т.к. Шаг 4 удален
    log "Шаг 3 завершен."; update_state 5;
}

# ШАГ 4: Настройка фаервола (UFW) - УДАЛЕН

# ШАГ 5: Python, утилиты, скрипт управления
step5_setup_python() {
    update_state 5; log "### ШАГ 5: Python, утилиты, скрипт управления ###";
    install_packages python3-venv python3-pip;
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"
    if [ ! -d "venv" ]; then log "Создание venv..."; python3 -m venv venv || die "Ошибка создания venv."; log "Venv создано."; else log "Venv уже существует."; fi
    chown -R "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR/venv" # Устанавливаем владельца для venv
    log "Установка qrcode[pil] в venv..."; if [ ! -x "$PYTHON_VENV" ]; then die "Нет $PYTHON_VENV"; fi
    # Запускаем pip от имени пользователя
    sudo -u "$TARGET_USER" "$PYTHON_VENV" -m pip install -U pip || die "Ошибка обновления pip.";
    sudo -u "$TARGET_USER" "$PYTHON_VENV" -m pip install qrcode[pil] || die "Ошибка установки qrcode[pil].";
    log "Зависимости Python установлены."
    if [ ! -f "$AWGCFG_SCRIPT" ]; then log "Скачивание $AWGCFG_SCRIPT..."; curl -fLso "$AWGCFG_SCRIPT" https://gist.githubusercontent.com/remittor/8c3d9ff293b2ba4b13c367cc1a69f9eb/raw/awgcfg.py || die "Ошибка скачивания $AWGCFG_SCRIPT."; chmod +x "$AWGCFG_SCRIPT" || die "Ошибка chmod."; chown "${TARGET_USER}:${TARGET_USER}" "$AWGCFG_SCRIPT"; log "$AWGCFG_SCRIPT скачан."; elif [ ! -x "$AWGCFG_SCRIPT" ]; then chmod +x "$AWGCFG_SCRIPT" || die "Ошибка chmod."; log "$AWGCFG_SCRIPT исполняемый."; else log "$AWGCFG_SCRIPT существует."; fi
    # Скачиваем в awgmng.sh
    log "Скачивание $MANAGE_SCRIPT_PATH..."; if curl -fLso "$MANAGE_SCRIPT_PATH" "$MANAGE_SCRIPT_URL"; then chmod +x "$MANAGE_SCRIPT_PATH" || die "Ошибка chmod."; chown "${TARGET_USER}:${TARGET_USER}" "$MANAGE_SCRIPT_PATH"; log "$MANAGE_SCRIPT_PATH скачан."; else log_error "Ошибка скачивания $MANAGE_SCRIPT_PATH"; fi
    log "Шаг 5 завершен."; update_state 6;
}

# ШАГ 6: Генерация конфигураций (с Workaround для setup.conf)
step6_generate_configs() {
    update_state 6; log "### ШАГ 6: Генерация конфигураций ###"; cd "$AWG_DIR" || die "Ошибка cd $AWG_DIR";
    local s_dir="/etc/amnezia/amneziawg"; local s_file="$s_dir/awg0.conf"; mkdir -p "$s_dir" || die "Ошибка mkdir $s_dir";
    log "Генерация конфига сервера..."; run_awgcfg --make "$s_file" -i "${AWG_TUNNEL_SUBNET}" -p "${AWG_PORT}" || die "Ошибка генерации конфига сервера."; log "Конфиг сервера сгенерирован."
    local s_bak="${s_file}.bak-$(date +%F_%T)"; cp "$s_file" "$s_bak" || log_warn "Ошибка бэкапа $s_bak"; log "Создан бэкап $s_bak";
    log "Кастомизация шаблона $CLIENT_TEMPLATE_FILE..."; if [ ! -f "$CLIENT_TEMPLATE_FILE" ]; then log "Создание шаблона..."; run_awgcfg --create || die "Ошибка создания шаблона."; log "Шаблон создан."; else log "Шаблон существует."; local t_bak="${CLIENT_TEMPLATE_FILE}.bak-$(date +%F_%T)"; cp "$CLIENT_TEMPLATE_FILE" "$t_bak" || log_warn "Ошибка бэкапа шаблона."; fi
    log "Применение настроек к шаблону:"; local sed_fail=0;
    local sed_allowed_ips; sed_allowed_ips=$(echo "$ALLOWED_IPS" | sed 's/\\,/,/g');
    sed -i 's/^DNS = .*/DNS = 1.1.1.1/' "$CLIENT_TEMPLATE_FILE" && log " - DNS: 1.1.1.1" || { log_warn "Ошибка sed DNS."; sed_fail=1; };
    sed -i 's/^PersistentKeepalive = .*/PersistentKeepalive = 33/' "$CLIENT_TEMPLATE_FILE" && log " - Keepalive: 33" || { log_warn "Ошибка sed Keepalive."; sed_fail=1; };
    sed -i "s#^AllowedIPs = .*#AllowedIPs = ${sed_allowed_ips}#" "$CLIENT_TEMPLATE_FILE" && log " - AllowedIPs: Mode $ALLOWED_IPS_MODE" || { log_warn "Ошибка sed AllowedIPs."; sed_fail=1; };
    if [ "$sed_fail" -eq 1 ]; then log_warn "Не все настройки шаблона применены."; fi; log "Шаблон кастомизирован."
    log "Добавление клиентов по умолчанию..."; if ! grep -q "^#_Name = my_phone$" "$s_file"; then run_awgcfg -a "my_phone" || log_warn "Ошибка add my_phone."; else log "Клиент my_phone существует."; fi; if ! grep -q "^#_Name = my_laptop$" "$s_file"; then run_awgcfg -a "my_laptop" || log_warn "Ошибка add my_laptop."; else log "Клиент my_laptop существует."; fi;

    # Workaround: Перемещаем setup.conf перед вызовом awgcfg -c -q
    local temp_conf_path="${TARGET_HOME}/${CONFIG_FILE##*/}.tmp"
    log "Временно перемещаем $CONFIG_FILE в $temp_conf_path...";
    if [ -f "$CONFIG_FILE" ]; then mv "$CONFIG_FILE" "$temp_conf_path" || log_warn "Не удалось временно переместить $CONFIG_FILE"; else log_warn "$CONFIG_FILE не найден перед перемещением!"; fi

    log "Генерация клиентских файлов...";
    run_awgcfg -c -q || die "Ошибка генерации клиентских файлов.";

    # Workaround: Возвращаем setup.conf обратно
    log "Возвращаем $CONFIG_FILE...";
    if [ -f "$temp_conf_path" ]; then
        mv "$temp_conf_path" "$CONFIG_FILE" || log_error "Не удалось вернуть $CONFIG_FILE!";
    elif [ ! -f "$CONFIG_FILE" ]; then
         log_error "Файл $CONFIG_FILE отсутствует и не может быть восстановлен из временного файла!";
    fi
    rm -f "$temp_conf_path" # Удаляем временный файл в любом случае
    if [ ! -f "$CONFIG_FILE" ]; then log_error "Файл $CONFIG_FILE все еще отсутствует после попытки возврата!"; fi

    log "Клиентские файлы созданы/обновлены в $AWG_DIR:"; ls -l "$AWG_DIR"/*.conf "$AWG_DIR"/*.png | log_msg "INFO";
    # Устанавливаем права и владельца на все файлы в директории
    secure_files;
    log "Шаг 6 завершен."; update_state 7;
}

# ШАГ 7: Запуск сервиса (Упрощенная версия)
step7_start_service_and_extras() {
    update_state 7; log "### ШАГ 7: Запуск сервиса ###";
    log "Включение и запуск awg-quick@awg0..."; systemctl enable --now awg-quick@awg0 || die "Ошибка enable --now."; log "Сервис включен и запущен."
    log "Проверка статуса сервиса..."; sleep 3; check_service_status || die "Проверка статуса сервиса не пройдена.";
    log "Шаг 7 успешно завершен."; update_state 99;
}

# ШАГ 99: Завершение
step99_finish() {
    log "### ЗАВЕРШЕНИЕ УСТАНОВКИ ###"; log "=============================================================================="; log "Установка и настройка AmneziaWG УСПЕШНО ЗАВЕРШЕНА!"; log " ";
    log "КЛИЕНТСКИЕ ФАЙЛЫ:"; log "  Конфиги (.conf) и QR-коды (.png) в: $AWG_DIR"; log "  Скопируйте их безопасным способом."; log "  Пример (на вашем ПК):"; log "    scp ${TARGET_USER}@<IP_СЕРВЕРА>:$AWG_DIR/*.conf ./"; log " ";
    log "ПОЛЕЗНЫЕ КОМАНДЫ:"; log "  sudo bash $MANAGE_SCRIPT_PATH help # Управление клиентами"; log "  systemctl status awg-quick@awg0  # Статус VPN"; log "  awg show                         # Статус WG"; log " ";
    log "Очистка apt..."; cleanup_apt; log " ";
    if [ -f "$CONFIG_FILE" ]; then log "Файл настроек $CONFIG_FILE существует."; else log_error "Файл настроек $CONFIG_FILE ОТСУТСТВУЕТ!"; fi
    log "Удаление файла состояния установки..."; rm -f "$STATE_FILE" || log_warn "Не удалось удалить $STATE_FILE";
    log "Установка полностью завершена. Лог: $LOG_FILE"; log "==============================================================================";
}

# Функция деинсталляции
step_uninstall() {
    log "### ДЕИНСТАЛЛЯЦИЯ AMNEZIAWG ###";
    echo ""; echo "ВНИМАНИЕ! Полное удаление AmneziaWG и конфигураций."; echo "Процесс необратим!"; echo "";
    read -p "Уверены? (введите 'yes'): " confirm < /dev/tty; if [[ "$confirm" != "yes" ]]; then log "Деинсталляция отменена."; exit 1; fi;
    read -p "Создать бэкап перед удалением? [Y/n]: " backup < /dev/tty;
    if [[ -z "$backup" || "$backup" =~ ^[Yy]$ ]]; then
         local bf="${TARGET_HOME}/awg_uninstall_backup_$(date +%F_%T).tar.gz"; log "Создание бэкапа: $bf";
         tar -czf "$bf" -C / etc/amnezia --exclude=venv "$AWG_DIR" --ignore-failed-read 2>/dev/null || log_warn "Ошибка создания бэкапа $bf";
         chown "${TARGET_USER}:${TARGET_USER}" "$bf"; chmod 600 "$bf" || log_warn "Ошибка chmod бэкапа"; log "Бэкап создан: $bf";
    fi
    log "Остановка сервиса..."; systemctl stop awg-quick@awg0 &>/dev/null; systemctl disable awg-quick@awg0 &>/dev/null;
    # UFW удален
    log "Удаление пакетов AmneziaWG..."; DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools &>/dev/null || log_warn "Ошибка purge."; DEBIAN_FRONTEND=noninteractive apt-get autoremove -y &>/dev/null || log_warn "Ошибка autoremove.";
    log "Удаление файлов..."; rm -rf /etc/amnezia "$AWG_DIR" /etc/modules-load.d/amneziawg.conf /etc/sysctl.d/99-amneziawg-vpn.conf || log_warn "Ошибка удаления файлов.";
    log "Удаление DKMS..."; rm -rf /var/lib/dkms/amneziawg* || log_warn "Ошибка удаления DKMS.";
    log "Восстановление sysctl..."; if grep -q "disable_ipv6" /etc/sysctl.conf; then sed -i '/disable_ipv6/d' /etc/sysctl.conf || log_warn "Ошибка sed sysctl.conf"; fi; sysctl -p --system &>/dev/null;
    # Cron удален
    # Временный файл конфига
    rm -f "${TARGET_HOME}/${CONFIG_FILE##*/}.tmp"
    log "=== ДЕИНСТАЛЛЯЦИЯ ЗАВЕРШЕНА ==="; exit 0;
}
# Дополнительные функции (определения)
setup_advanced_sysctl() { log "Настройка sysctl (форвардинг и ОТКЛЮЧЕНИЕ IPv6)..."; local f="/etc/sysctl.d/99-amneziawg-vpn.conf"; { echo "# AmneziaWG VPN Settings - $(date)"; echo "net.ipv4.ip_forward = 1"; echo "# Force disable IPv6"; echo "net.ipv6.conf.all.disable_ipv6 = 1"; echo "net.ipv6.conf.default.disable_ipv6 = 1"; echo "net.ipv6.conf.lo.disable_ipv6 = 1"; } > "$f" || die "Ошибка записи в $f"; log "Применение sysctl..."; if ! sysctl -p "$f" > /dev/null; then log_warn "Не удалось применить $f."; fi; }
# setup_improved_firewall() { ... } # Удалена
secure_files() { log "Установка прав доступа..."; chmod 700 "$AWG_DIR" &>/dev/null; chown -R "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR" || log_warn "Не удалось сменить владельца $AWG_DIR"; chmod 700 /etc/amnezia &>/dev/null; chmod 700 /etc/amnezia/amneziawg &>/dev/null; chmod 600 /etc/amnezia/amneziawg/*.conf &>/dev/null; find "$AWG_DIR" -name "*.conf" -type f -exec chmod 600 {} \; &>/dev/null; find "$AWG_DIR" -name "*.png" -type f -exec chmod 644 {} \; &>/dev/null; if [ -f "$CONFIG_FILE" ]; then chmod 600 "$CONFIG_FILE"; chown "${TARGET_USER}:${TARGET_USER}" "$CONFIG_FILE"; fi; if [ -f "$LOG_FILE" ]; then chmod 640 "$LOG_FILE"; chown "${TARGET_USER}:${TARGET_USER}" "$LOG_FILE"; fi; if [ -f "$MANAGE_SCRIPT_PATH" ]; then chmod 750 "$MANAGE_SCRIPT_PATH"; chown "${TARGET_USER}:${TARGET_USER}" "$MANAGE_SCRIPT_PATH"; fi; log "Права доступа установлены."; }
create_diagnostic_report() { log "Создание диагностики..."; local rf="$AWG_DIR/diag_$(date +%F_%T).txt"; { echo "=== AMNEZIAWG DIAG REPORT (Azure Mini) ==="; date; hostname; echo "--- OS ---"; lsb_release -ds; uname -a; echo ""; echo "--- Configuration ($CONFIG_FILE) ---"; cat "$CONFIG_FILE" 2>/dev/null || echo "File not found"; echo ""; echo "--- Service Status ---"; systemctl status awg-quick@awg0 --no-pager -l; echo ""; echo "--- Network Interfaces ---"; ip a; echo ""; echo "--- AWG Status ---"; awg show; echo ""; echo "--- Listening Ports ---"; ss -lunp; echo ""; echo "--- Routing Table ---"; ip route; echo ""; echo "--- Kernel Params ---"; sysctl net.ipv4.ip_forward net.ipv6.conf.all.disable_ipv6 2>/dev/null; echo ""; echo "--- AWG Journal (last 50) ---"; journalctl -u awg-quick@awg0 -n 50 --no-pager --output=cat; echo ""; echo "--- Client List ---"; grep "^#_Name = " "$SERVER_CONF_FILE" | sed 's/^#_Name = //' || echo "N/A"; echo ""; echo "--- DKMS Status ---"; dkms status 2>/dev/null || echo "N/A"; echo ""; echo "--- Module Info ---"; modinfo amneziawg 2>/dev/null || echo "N/A"; echo ""; echo "=== END ==="; } > "$rf" || log_error "Ошибка записи отчета."; chown "${TARGET_USER}:${TARGET_USER}" "$rf"; chmod 600 "$rf" || log_warn "Ошибка chmod отчета."; log "Отчет: $rf"; }

# --- Основной цикл выполнения ---
if [ "$HELP" -eq 1 ]; then show_help; fi
if [ "$UNINSTALL" -eq 1 ]; then step_uninstall; fi
if [ "$DIAGNOSTIC" -eq 1 ]; then create_diagnostic_report; exit 0; fi
if [ "$VERBOSE" -eq 1 ]; then set -x; fi

initialize_setup # Инициализация
current_step=0 # Переопределяем после initialize_setup
if [[ -f "$STATE_FILE" ]]; then current_step=$(cat "$STATE_FILE"); fi
if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then current_step=1; fi

while (( current_step < 99 )); do
    log "Выполнение шага $current_step...";
    case $current_step in
        1) step1_update_system_and_networking ;;
        2) step2_install_amnezia ;;
        3) step3_check_module; current_step=5 ;; # Пропускаем Шаг 4
        # Шаг 4 удален
        5) step5_setup_python; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service_and_extras; current_step=99 ;; # Шаг 7 упрощен
        *) die "Ошибка: Неизвестный шаг $current_step.";;
    esac
done
if (( current_step == 99 )); then step99_finish; fi
exit 0
