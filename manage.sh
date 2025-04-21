#!/bin/bash

# ==============================================================================
# Скрипт для управления пользователями (пирами) AmneziaWG
# Версия Azure ARM64 Interactive - Refined
# Автор: @bivlked & Gemini
# Версия: 2.1
# Дата: 2025-04-21
# Репозиторий: https://github.com/bivlked/azure
# ==============================================================================

# --- Режим Безопасности и Константы ---
set -o pipefail
set -o nounset
# set -o errexit

# --- Определение Пользователя и Домашнего Каталога ---
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [ ! -d "$TARGET_HOME" ]; then echo "[WARN] Не удалось определить дом. директорию для '$TARGET_USER'. Используется /root." >&2; TARGET_USER="root"; TARGET_HOME="/root"; fi
else
    TARGET_USER="root"; TARGET_HOME="/root"
    if [ "$TARGET_USER" == "root" ]; then echo "[WARN] Запуск от root. Используется $TARGET_HOME." >&2; fi
fi

# --- Пути по Умолчанию ---
DEFAULT_AWG_DIR="${TARGET_HOME}/awg"
DEFAULT_SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"

# --- Инициализация Переменных ---
AWG_DIR="$DEFAULT_AWG_DIR"
SERVER_CONF_FILE="$DEFAULT_SERVER_CONF_FILE"
NO_COLOR=0
VERBOSE_LIST=0
COMMAND=""
ARGS=()

# --- Обработка Аргументов ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) COMMAND="help"; break ;;
        -v|--verbose) VERBOSE_LIST=1; shift ;;
        --no-color) NO_COLOR=1; shift ;;
        --conf-dir=*) AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*) SERVER_CONF_FILE="${1#*=}"; shift ;;
        --*) echo "[ERROR] Неизвестная опция: $1" >&2; COMMAND="help"; break ;;
         *) break ;; # Встретили команду или ее аргумент
    esac
done
# Оставшиеся аргументы - команда и ее параметры
if [ -z "$COMMAND" ]; then COMMAND=${1:-}; if [ -n "$COMMAND" ]; then shift; fi; fi
ARGS=("$@")
CLIENT_NAME="${ARGS[0]:-}"
PARAM="${ARGS[1]:-}"
VALUE="${ARGS[2]:-}"

# --- Зависимые Пути (после парсинга опций) ---
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" # Файл конфигурации установки
PYTHON_VENV_PATH="$AWG_DIR/venv"         # Каталог venv
PYTHON_EXEC="$PYTHON_VENV_PATH/bin/python" # Python в venv
AWGCFG_SCRIPT_PATH="$AWG_DIR/awgcfg.py"     # Скрипт генерации
LOG_FILE="$AWG_DIR/manage_amneziawg.log"    # Лог файл управления

# --- Функции Логирования ---
log_msg() {
    local type="$1" msg="$2" ts entry color_start="" color_end="\033[0m" safe_msg
    ts=$(date +'%F %T'); safe_msg=$(echo "$msg" | sed 's/%/%%/g'); entry="[$ts] $type: $safe_msg"
    # Запись в лог-файл
    if mkdir -p "$(dirname "$LOG_FILE")"; then echo "$entry" >> "$LOG_FILE"; chown "${TARGET_USER}:${TARGET_USER}" "$LOG_FILE" 2>/dev/null; chmod 640 "$LOG_FILE" 2>/dev/null; else echo "[$ts] ERROR: Не удалось записать в лог $LOG_FILE" >&2; fi
    # Вывод на экран
    if [[ "$NO_COLOR" -eq 0 ]]; then case "$type" in INFO) color_start="\033[0;32m";; WARN) color_start="\033[0;33m";; ERROR) color_start="\033[1;31m";; DEBUG) color_start="\033[0;36m";; *) color_start=""; color_end="";; esac; fi
    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then printf "${color_start}%s${color_end}\n" "$entry" >&2;
    elif [[ "$type" == "DEBUG" && "$VERBOSE_LIST" -eq 1 ]]; then printf "${color_start}%s${color_end}\n" "$entry" >&2;
    elif [[ "$type" == "INFO" ]]; then printf "${color_start}%s${color_end}\n" "$entry"; fi
}
log() { log_msg "INFO" "$1"; }; log_warn() { log_msg "WARN" "$1"; }; log_error() { log_msg "ERROR" "$1"; }; log_debug() { if [[ "$VERBOSE_LIST" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; };
die() { log_error "КРИТИЧЕСКАЯ ОШИБКА: $1"; log_error "Операция прервана. Подробности в логе: $LOG_FILE"; exit 1; }

# --- Вспомогательные Функции ---
is_interactive() { [[ -t 0 && -t 1 ]]; }
confirm_action() {
    if ! is_interactive; then return 0; fi # Автоподтверждение для неинтерактивных сессий
    local action="$1" subject="$2" confirm
    read -p "Вы действительно хотите ${action} ${subject}? [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[YyЕе]$ ]]; then return 0; else log "Действие отменено."; return 1; fi
}
validate_client_name() {
    local name="$1"
    if [[ -z "$name" ]]; then log_error "Имя клиента не может быть пустым."; return 1; fi
    if [[ ${#name} -gt 63 ]]; then log_error "Имя клиента слишком длинное (> 63 симв.)."; return 1; fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Имя клиента содержит недопустимые символы (разрешены: a-z, A-Z, 0-9, _, -)."; return 1; fi
    return 0
}
check_dependencies() {
    log "Проверка зависимостей..."
    local critical_error=0
    local dependencies=( "$AWG_DIR" "$CONFIG_FILE" "$PYTHON_VENV_PATH" "$PYTHON_EXEC" "$AWGCFG_SCRIPT_PATH" "$SERVER_CONF_FILE" )
    for dep in "${dependencies[@]}"; do if [ ! -e "$dep" ]; then log_error " - Не найден: $dep"; critical_error=1; fi; done
    if [ -f "$PYTHON_EXEC" ] && [ ! -x "$PYTHON_EXEC" ]; then log_error " - Не исполняемый: $PYTHON_EXEC"; critical_error=1; fi
    if [ -f "$AWGCFG_SCRIPT_PATH" ] && [ ! -x "$AWGCFG_SCRIPT_PATH" ]; then log_error " - Не исполняемый: $AWGCFG_SCRIPT_PATH"; critical_error=1; fi
    if ! command -v awg &>/dev/null; then log_error " - Команда 'awg' не найдена."; critical_error=1; fi
    if ! command -v qrencode &>/dev/null; then log_warn " - Команда 'qrencode' не найдена (QR-коды не будут обновляться при 'modify')."; fi # Не критично
    if [ "$critical_error" -eq 1 ]; then die "Отсутствуют критические зависимости."; fi
    log "Зависимости в порядке."
}
run_awgcfg() {
    log_debug "Запуск awgcfg.py из '$AWG_DIR' с аргументами: $*"
    if [ ! -x "$PYTHON_EXEC" ] || [ ! -x "$AWGCFG_SCRIPT_PATH" ]; then log_error "Python или awgcfg.py не найдены/не исполняемы."; return 1; fi
    if ! (cd "$AWG_DIR" && "$PYTHON_EXEC" "$AWGCFG_SCRIPT_PATH" "$@"); then log_error "Ошибка выполнения: '$PYTHON_EXEC $AWGCFG_SCRIPT_PATH $*'"; return 1; fi
    # Установка владельца/прав
    chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null || true
    find "$AWG_DIR" -maxdepth 1 -name "*.conf" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -maxdepth 1 -name "*.png" -type f -exec chmod 644 {} \; 2>/dev/null
    log_debug "Команда awgcfg.py '$*' выполнена."
    return 0
}
# Запуск awgcfg.py -c -q с Workaround
run_awgcfg_generate_clients() {
    local temp_conf_backup="${TARGET_HOME}/.${CONFIG_FILE##*/}.bak_$(date +%s)"
    local mv_failed=0 result=0
    if [ -f "$CONFIG_FILE" ]; then mv "$CONFIG_FILE" "$temp_conf_backup" || { log_warn "Workaround: Не удалось переместить $CONFIG_FILE."; mv_failed=1; }; fi
    log_debug "Workaround: mv_failed=$mv_failed"

    if ! run_awgcfg -c -q; then log_error "Ошибка выполнения awgcfg.py -c -q."; result=1; else log_debug "awgcfg.py -c -q выполнен."; fi

    if [ "$mv_failed" -eq 0 ] && [ -f "$temp_conf_backup" ]; then mv "$temp_conf_backup" "$CONFIG_FILE" || log_error "Workaround: КРИТИЧЕСКАЯ ОШИБКА! Не удалось вернуть $CONFIG_FILE!"; fi
    rm -f "$temp_conf_backup"
    if [ ! -f "$CONFIG_FILE" ]; then log_error "Файл конфигурации $CONFIG_FILE отсутствует после генерации!"; if [ "$result" -eq 0 ]; then result=1; fi; fi

    # Установка владельца/прав (повторно)
    chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null || true
    find "$AWG_DIR" -maxdepth 1 -name "*.conf" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -maxdepth 1 -name "*.png" -type f -exec chmod 644 {} \; 2>/dev/null
    return $result
}

# --- Основные Команды ---
cmd_add_client() {
    [ -z "$CLIENT_NAME" ] && die "Не указано имя клиента для добавления."
    validate_client_name "$CLIENT_NAME" || exit 1
    if grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then die "Клиент '$CLIENT_NAME' уже существует."; fi

    log "Добавление клиента '$CLIENT_NAME'..."
    if run_awgcfg -a "$CLIENT_NAME"; then
        log "Клиент '$CLIENT_NAME' добавлен в $SERVER_CONF_FILE."
        log "Генерация/обновление файлов .conf/.png для всех клиентов..."
        # Вызов regen (-c -q) необходим, т.к. awgcfg.py -a не создает файлы клиента
        if run_awgcfg_generate_clients; then
            log "Файлы для клиентов созданы/обновлены в $AWG_DIR."
            log_warn "!!! ВАЖНО: Требуется перезапуск сервиса: sudo bash $0 restart"
        else
            log_error "Ошибка генерации файлов клиентов после добавления '$CLIENT_NAME'."
            log_warn "!!! Попробуйте выполнить '$0 regen' и '$0 restart'"
        fi
    else
        log_error "Ошибка добавления клиента '$CLIENT_NAME'."
    fi
}
cmd_remove_client() {
    [ -z "$CLIENT_NAME" ] && die "Не указано имя клиента для удаления."
    validate_client_name "$CLIENT_NAME" || exit 1
    if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then die "Клиент '$CLIENT_NAME' не найден."; fi
    if ! confirm_action "удалить" "клиента '$CLIENT_NAME' и его файлы"; then exit 1; fi

    log "Удаление клиента '$CLIENT_NAME'..."
    if run_awgcfg -d "$CLIENT_NAME"; then
        log "Клиент '$CLIENT_NAME' удален из $SERVER_CONF_FILE."
        log "Удаление файлов клиента..."
        rm -f "$AWG_DIR/$CLIENT_NAME.conf" "$AWG_DIR/$CLIENT_NAME.png"
        log "Файлы удалены."
        log_warn "!!! ВАЖНО: Требуется перезапуск сервиса: sudo bash $0 restart"
    else
        log_error "Ошибка удаления клиента '$CLIENT_NAME'."
    fi
}
cmd_list_clients() {
    log "Получение списка клиентов из $SERVER_CONF_FILE..."
    local clients_list; clients_list=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort)
    if [ -z "$clients_list" ]; then log "Клиенты не найдены."; return 0; fi

    local awg_status_output; awg_status_output=$(awg show 2>/dev/null || echo "")
    local total_clients=0 active_clients=0

    # Заголовок таблицы
    if [ "$VERBOSE_LIST" -eq 1 ]; then
        printf "%-20s | %-7s | %-7s | %-18s | %-15s | %s\n" "Имя клиента" "Файл?" "QR?" "IP Адрес" "Ключ (нач.)" "Статус Handshake"
        printf -- "-%.0s" {1..90}; echo ""
    else
        printf "%-20s | %-7s | %-7s | %s\n" "Имя клиента" "Файл?" "QR?" "Статус Handshake"
        printf -- "-%.0s" {1..55}; echo ""
    fi

    echo "$clients_list" | while IFS= read -r client_name; do
        client_name=$(echo "$client_name" | xargs); if [ -z "$client_name" ]; then continue; fi
        ((total_clients++))
        local has_conf="-" has_qr="-" client_ip="-" client_pubkey_prefix="-" handshake_status="Нет данных" color_start="\033[0m" color_end="\033[0m"
        local client_conf_file="$AWG_DIR/${client_name}.conf"; local client_qr_file="$AWG_DIR/${client_name}.png"
        if [ -f "$client_conf_file" ]; then has_conf="✓"; client_ip=$(grep -oP 'Address\s*=\s*\K[0-9\.\/]+' "$client_conf_file" 2>/dev/null || echo "?"); fi
        if [ -f "$client_qr_file" ]; then has_qr="✓"; fi

        local current_pubkey="" in_peer_block=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "[Peer]" && "$in_peer_block" -eq 1 ]]; then break; fi
            if [[ "$line" == *"#_Name = ${client_name}"* ]]; then in_peer_block=1; fi
            if [[ "$in_peer_block" -eq 1 && "$line" == "PublicKey = "* ]]; then current_pubkey=$(echo "$line" | awk '{print $3}'); break; fi
        done < "$SERVER_CONF_FILE"

        if [[ -n "$current_pubkey" ]]; then
            client_pubkey_prefix=$(echo "$current_pubkey" | head -c 10)...
            if echo "$awg_status_output" | grep -qF "$current_pubkey"; then
                 local handshake_line; handshake_line=$(echo "$awg_status_output" | grep -A 3 -F "$current_pubkey" | grep 'latest handshake:')
                 if [[ -n "$handshake_line" ]]; then
                     if echo "$handshake_line" | grep -q "never"; then handshake_status="Нет handshake"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;37m"; fi
                     elif echo "$handshake_line" | grep -q "ago"; then
                         if echo "$handshake_line" | grep -q "seconds ago"; then
                             local seconds_ago; seconds_ago=$(echo "$handshake_line" | grep -oP '\d+(?= seconds ago)')
                             if [[ "$seconds_ago" -lt 180 ]]; then handshake_status="Активен (${seconds_ago}s)"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;32m"; fi; ((active_clients++));
                             else handshake_status="Недавно"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;33m"; fi; ((active_clients++)); fi
                         else handshake_status="Недавно"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;33m"; fi; ((active_clients++)); fi
                     else handshake_status="Неизвестно"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;37m"; fi; fi
                 else handshake_status="Нет handshake"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;37m"; fi; fi
            else handshake_status="Не в 'awg show'"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;31m"; fi; fi
        else handshake_status="Ошибка ключа"; client_pubkey_prefix="?"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;31m"; fi; fi

        # Вывод строки
        if [ "$VERBOSE_LIST" -eq 1 ]; then printf "%-20s | %-7s | %-7s | %-18s | %-15s | ${color_start}%s${color_end}\n" "$client_name" "$has_conf" "$has_qr" "$client_ip" "$client_pubkey_prefix" "$handshake_status";
        else printf "%-20s | %-7s | %-7s | ${color_start}%s${color_end}\n" "$client_name" "$has_conf" "$has_qr" "$handshake_status"; fi
    done
    echo ""; log "Всего клиентов: $total_clients, Активных/Недавних: $active_clients";
}
cmd_regen_clients() {
    log "Перегенерация файлов .conf и .png для ВСЕХ клиентов..."
    if [ -n "$CLIENT_NAME" ]; then log_warn "Аргумент '$CLIENT_NAME' для 'regen' игнорируется."; fi
    if run_awgcfg_generate_clients; then
        log "Файлы для всех клиентов перегенерированы в $AWG_DIR."
        ls -l "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | sed 's/^/  /' | log_msg "INFO"
    else
        log_error "Ошибка во время перегенерации файлов клиентов."
    fi
}
cmd_modify_client() {
    local name="$1" param_key="$2" new_value="$3"
    if [[ -z "$name" || -z "$param_key" || -z "$new_value" ]]; then log_error "Использование: $0 modify <имя> <параметр> <значение>"; return 1; fi
    validate_client_name "$name" || return 1

    if ! grep -q "^#_Name = ${name}$" "$SERVER_CONF_FILE"; then log_error "Клиент '$name' не найден в $SERVER_CONF_FILE."; return 1; fi
    local client_conf_file="$AWG_DIR/$name.conf"
    if [ ! -f "$client_conf_file" ]; then log_error "Файл '$client_conf_file' не найден. Выполните '$0 regen'."; return 1; fi
    if ! grep -q -E "^${param_key}\s*=" "$client_conf_file"; then log_error "Параметр '$param_key' не найден в $client_conf_file."; return 1; fi

    log "Изменение '$param_key' на '$new_value' для '$name' в $client_conf_file..."
    local backup_file="${client_conf_file}.bak_$(date +%s)"
    cp "$client_conf_file" "$backup_file" || { log_error "Не удалось создать бэкап $backup_file."; return 1; }
    log_debug "Создан бэкап: $backup_file"; chown "${TARGET_USER}:${TARGET_USER}" "$backup_file" 2>/dev/null; chmod 600 "$backup_file" 2>/dev/null

    # Используем # как разделитель sed и экранируем значение
    local escaped_new_value; escaped_new_value=$(echo "$new_value" | sed 's/[&/\]/\\&/g')
    if ! sed -i "s#^${param_key}\s*=.*#${param_key} = ${escaped_new_value}#" "$client_conf_file"; then
        log_error "Ошибка sed при изменении $client_conf_file. Восстановление..."; cp "$backup_file" "$client_conf_file" || log_warn "Ошибка восстановления!"; return 1;
    fi

    log "Параметр '$param_key' изменен."; chown "${TARGET_USER}:${TARGET_USER}" "$client_conf_file"; chmod 600 "$client_conf_file"

    # Обновление QR-кода
    local client_qr_file="$AWG_DIR/$name.png"
    if command -v qrencode &>/dev/null; then
        if qrencode -o "$client_qr_file" < "$client_conf_file"; then log "QR-код '$client_qr_file' обновлен."; chown "${TARGET_USER}:${TARGET_USER}" "$client_qr_file"; chmod 644 "$client_qr_file";
        else log_error "Ошибка qrencode при обновлении $client_qr_file."; fi
    else log_warn "qrencode не найден. QR-код не обновлен."; fi
    return 0
}
cmd_check_server() {
    log "Проверка состояния сервера AmneziaWG..."
    local overall_status=0
    log "--- Статус сервиса (awg-quick@awg0) ---"; if ! systemctl status awg-quick@awg0 --no-pager; then overall_status=1; fi; echo ""
    log "--- Сетевой интерфейс (awg0) ---"; if ! ip addr show awg0 &>/dev/null; then log_error "Интерфейс 'awg0' НЕ найден!"; overall_status=1; else log "Интерфейс 'awg0' найден:"; ip addr show awg0 | sed 's/^/  /' | log_msg "INFO"; fi; echo ""
    log "--- Прослушивание UDP порта ---"
    local listen_port=0; if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE" &>/dev/null; listen_port=${AWG_PORT:-0}; fi
    if [ "$listen_port" -ne 0 ]; then log "Ожидаемый порт: ${listen_port}/udp"; if ss -lunp | grep -q ":${listen_port} "; then log "Порт ${listen_port}/udp прослушивается (OK)."; else log_error "Порт ${listen_port}/udp НЕ прослушивается!"; overall_status=1; fi; else log_warn "Не удалось определить порт из $CONFIG_FILE."; fi; echo ""
    log "--- Параметры ядра (sysctl) ---"
    local ipv4_fwd; ipv4_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null); log "net.ipv4.ip_forward = $ipv4_fwd"; if [[ "$ipv4_fwd" != "1" ]]; then log_error "IP Forwarding IPv4 ВЫКЛЮЧЕН!"; overall_status=1; fi
    local ipv6_dis; ipv6_dis=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null); log "net.ipv6.conf.all.disable_ipv6 = $ipv6_dis"; if [[ "$ipv6_dis" != "1" ]]; then log_warn "Отключение IPv6 НЕ активно!"; fi; echo ""
    log "--- Статус AmneziaWG (awg show) ---"; if ! awg show; then log_error "Ошибка 'awg show'."; overall_status=1; fi; echo ""
    log "--- Итог проверки ---"
    if [ "$overall_status" -eq 0 ]; then log "Проверка завершена: OK."; else log_error "Проверка завершена: ОБНАРУЖЕНЫ ПРОБЛЕМЫ!"; fi
    return $overall_status
}
cmd_show_status() {
    log "Выполнение 'awg show'..."; echo "-------------------------------------"
    if ! awg show; then log_error "Ошибка при выполнении 'awg show'."; fi; echo "-------------------------------------"
}
cmd_restart_service() {
    log "Перезапуск сервиса AmneziaWG (awg-quick@awg0)..."
    if ! confirm_action "перезапустить" "сервис AmneziaWG"; then exit 1; fi
    log "Остановка сервиса..."; systemctl stop awg-quick@awg0 || log_warn "Не удалось остановить сервис."
    sleep 1; log "Запуск сервиса..."
    if ! systemctl start awg-quick@awg0; then log_error "Ошибка запуска сервиса!"; systemctl status awg-quick@awg0 --no-pager -l >&2; exit 1; fi
    log "Сервис перезапущен."; sleep 2; log "Быстрая проверка статуса:"; cmd_check_server > /dev/null || log_warn "Обнаружены проблемы после перезапуска.";
}
usage() {
    exec >&2; echo ""; echo "Скрипт Управления AmneziaWG (v2.1)"; echo "================================="
    echo "Использование: sudo bash $0 [ОПЦИИ] <КОМАНДА> [АРГУМЕНТЫ]"
    echo "Опции:"; echo "  -h, --help            Справка"; echo "  -v, --verbose         Расширенный вывод для 'list'"; echo "  --no-color            Отключить цвет"; echo "  --conf-dir=ПУТЬ       Каталог AWG (умолч: $DEFAULT_AWG_DIR)"; echo "  --server-conf=ПУТЬ    Файл конфига сервера WG (умолч: $DEFAULT_SERVER_CONF_FILE)"; echo ""
    echo "Команды:"; echo "  add <имя>             Добавить клиента (+ regen, требует restart)"; echo "  remove <имя>          Удалить клиента (требует restart)"; echo "  list [-v]             Список клиентов"; echo "  regen                 Перегенерировать файлы .conf/.png для ВСЕХ клиентов"; echo "  modify <имя> <пар> <зн> Изменить параметр клиента (DNS, AllowedIPs, Keepalive...)"; echo "  check | status        Проверить состояние сервера"; echo "  show                  Выполнить 'awg show'"; echo "  restart               Перезапустить сервис awg-quick@awg0"; echo "  help                  Эта справка"; echo ""
    echo "Перезапуск сервиса нужен после 'add' и 'remove': sudo bash $0 restart"; echo "Лог: $LOG_FILE"; echo ""; exit 1;
}

# --- Основная Логика ---
trap 'echo ""; log_error "Скрипт прерван (SIGINT)."; exit 1' SIGINT
trap 'echo ""; log_error "Скрипт прерван (SIGTERM)."; exit 1' SIGTERM

if [[ "$COMMAND" != "help" ]]; then
    check_dependencies || exit 1
    cd "$AWG_DIR" || die "Не удалось перейти в $AWG_DIR"
fi

log_debug "Запуск команды '$COMMAND' с аргументами: ${ARGS[*]}"

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
    "")      log_error "Команда не указана."; usage ;;
    *)       log_error "Неизвестная команда: '$COMMAND'"; usage ;;
esac

log "Скрипт управления '$0' завершил работу."
exit ${?} # Выход с кодом последней выполненной команды
