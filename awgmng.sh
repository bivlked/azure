#!/bin/bash

# ==============================================================================
# Скрипт для управления пользователями (пирами) AmneziaWG
# Azure Mini Версия
# Автор: @bivlked
# Версия: 1.1 (Azure Mini - Dynamic User + Workaround)
# Дата: 2025-04-21
# Репозиторий: https://github.com/bivlked/azure
# ==============================================================================

# --- Безопасный режим и Константы ---
set -o pipefail

# Определяем пользователя и домашний каталог (так как скрипт тоже запускается с sudo)
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME=$(eval echo "~$SUDO_USER")
    if [ ! -d "$TARGET_HOME" ]; then
        echo "[WARN] Не удалось определить домашнюю директорию для пользователя sudo '$TARGET_USER'. Используется /root." >&2
        TARGET_USER="root"
        TARGET_HOME="/root"
    fi
else
    TARGET_USER="root"
    TARGET_HOME="/root"
fi

AWG_DIR="${TARGET_HOME}/awg"; # Рабочая директория пользователя
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf";
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"; # Имя файла конфигурации
SETUP_CONFIG_FILE="$CONFIG_FILE" # Используется для совместимости в check_server
PYTHON_VENV_PATH="$AWG_DIR/venv/bin/python"; AWGCFG_SCRIPT_PATH="$AWG_DIR/awgcfg.py"; LOG_FILE="$AWG_DIR/manage_amneziawg.log";
NO_COLOR=0; VERBOSE_LIST=0;

# --- Обработка аргументов ---
COMMAND=""; ARGS=();
while [[ $# -gt 0 ]]; do case $1 in -h|--help) COMMAND="help"; break ;; -v|--verbose) VERBOSE_LIST=1; shift ;; --no-color) NO_COLOR=1; shift ;; --conf-dir=*) AWG_DIR="${1#*=}"; shift ;; --server-conf=*) SERVER_CONF_FILE="${1#*=}"; shift ;; --*) echo "Неизвестная опция: $1" >&2; COMMAND="help"; break ;; *) if [ -z "$COMMAND" ]; then COMMAND=$1; else ARGS+=("$1"); fi; shift ;; esac; done
ARGS+=("$@"); CLIENT_NAME="${ARGS[0]}"; PARAM="${ARGS[1]}"; VALUE="${ARGS[2]}";
# Обновляем пути с учетом возможного --conf-dir
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"; SETUP_CONFIG_FILE="$CONFIG_FILE"; PYTHON_VENV_PATH="$AWG_DIR/venv/bin/python"; AWGCFG_SCRIPT_PATH="$AWG_DIR/awgcfg.py"; LOG_FILE="$AWG_DIR/manage_amneziawg.log";

# --- Функции ---
log_msg() { local type="$1"; local msg="$2"; local ts; ts=$(date +'%F %T'); local safe_msg; safe_msg=$(echo "$msg" | sed 's/%/%%/g'); local entry="[$ts] $type: $safe_msg"; local color_start=""; local color_end="\033[0m"; if [[ "$NO_COLOR" -eq 0 ]]; then case "$type" in INFO) color_start="\033[0;32m";; WARN) color_start="\033[0;33m";; ERROR) color_start="\033[1;31m";; DEBUG) color_start="\033[0;36m";; *) color_start=""; color_end="";; esac; fi; if ! mkdir -p "$(dirname "$LOG_FILE")" || ! echo "$entry" >> "$LOG_FILE"; then echo "[$ts] ERROR: Ошибка записи лога $LOG_FILE" >&2; fi; chown "${TARGET_USER}:${TARGET_USER}" "$LOG_FILE" 2>/dev/null; chmod 640 "$LOG_FILE" 2>/dev/null; if [[ "$type" == "ERROR" ]]; then printf "${color_start}%s${color_end}\n" "$entry" >&2; else printf "${color_start}%s${color_end}\n" "$entry"; fi; }
log() { log_msg "INFO" "$1"; }; log_warn() { log_msg "WARN" "$1"; }; log_error() { log_msg "ERROR" "$1"; }; log_debug() { if [[ "$VERBOSE_LIST" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }; die() { log_error "$1"; exit 1; }
is_interactive() { [[ -t 0 && -t 1 ]]; }
confirm_action() { if ! is_interactive; then return 0; fi; local action="$1"; local subject="$2"; read -p "Вы действительно хотите $action $subject? [y/N]: " confirm < /dev/tty; if [[ "$confirm" =~ ^[Yy]$ ]]; then return 0; else log "Действие отменено."; return 1; fi; }
validate_client_name() { local name="$1"; if [[ -z "$name" ]]; then log_error "Имя пустое."; return 1; fi; if [[ ${#name} -gt 63 ]]; then log_error "Имя > 63 симв."; return 1; fi; if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Имя содержит недоп. символы."; return 1; fi; return 0; }
check_dependencies() { log "Проверка зависимостей..."; local ok=1; if [ ! -f "$CONFIG_FILE" ]; then log_error " - $CONFIG_FILE"; ok=0; fi; if [ ! -d "$AWG_DIR/venv" ]; then log_error " - $AWG_DIR/venv"; ok=0; fi; if [ ! -f "$AWGCFG_SCRIPT_PATH" ]; then log_error " - $AWGCFG_SCRIPT_PATH"; ok=0; fi; if [ ! -f "$SERVER_CONF_FILE" ]; then log_error " - $SERVER_CONF_FILE"; ok=0; fi; if [ "$ok" -eq 0 ]; then die "Не найдены файлы установки."; fi; if ! command -v awg &>/dev/null; then die "'awg' не найден."; fi; if [ ! -x "$AWGCFG_SCRIPT_PATH" ]; then die "$AWGCFG_SCRIPT_PATH не найден/не исполняемый."; fi; if [ ! -x "$PYTHON_VENV_PATH" ]; then die "$PYTHON_VENV_PATH не найден/не исполняемый."; fi; log "Зависимости OK."; }
run_awgcfg() { log_debug "Вызов run_awgcfg из $(pwd): $*"; # Запускаем от root
    if ! (cd "$AWG_DIR" && "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" "$@"); then log_error "Ошибка выполнения awgcfg.py $*"; return 1; fi;
    # Устанавливаем владельца после возможного создания файлов утилитой
    chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null || true
    log_debug "awgcfg.py $* выполнен успешно."; return 0; }
# Workaround для awgcfg.py -c -q
run_awgcfg_generate_clients() {
    local temp_conf_path="${TARGET_HOME}/${CONFIG_FILE##*/}.tmp"
    log_debug "Workaround: Перемещаем $CONFIG_FILE в $temp_conf_path...";
    if [ -f "$CONFIG_FILE" ]; then mv "$CONFIG_FILE" "$temp_conf_path" || log_warn "Workaround: Не удалось переместить $CONFIG_FILE"; else log_warn "Workaround: $CONFIG_FILE не найден перед перемещением!"; fi
    log_debug "Вызов run_awgcfg из $(pwd): -c -q"; local result=0
    if ! (cd "$AWG_DIR" && "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -c -q); then log_error "Ошибка выполнения awgcfg.py -c -q"; result=1; fi
    log_debug "awgcfg.py -c -q выполнен с кодом: $result.";
    log_debug "Workaround: Возвращаем $CONFIG_FILE...";
    if [ -f "$temp_conf_path" ]; then mv "$temp_conf_path" "$CONFIG_FILE" || log_error "Workaround: Не удалось вернуть $CONFIG_FILE!";
    elif [ ! -f "$CONFIG_FILE" ]; then log_error "Workaround: $CONFIG_FILE отсутствует и не может быть восстановлен!"; fi
    rm -f "$temp_conf_path";
    if [ ! -f "$CONFIG_FILE" ]; then log_error "Файл $CONFIG_FILE все еще отсутствует после попытки возврата!"; fi
    # Устанавливаем владельца на новые файлы
    chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null || true
    return $result
}
backup_configs() { log "Создание бэкапа..."; local bd="$AWG_DIR/backups"; mkdir -p "$bd" || die "Ошибка mkdir $bd"; chown "${TARGET_USER}:${TARGET_USER}" "$bd"; chmod 700 "$bd"; local ts; ts=$(date +%F_%T); local bf="$bd/awg_backup_${ts}.tar.gz"; local td; td=$(mktemp -d); mkdir -p "$td/server" "$td/clients"; cp -a "$SERVER_CONF_FILE"* "$td/server/" 2>/dev/null; cp -a "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$CONFIG_FILE" "$td/clients/" 2>/dev/null||true; tar -czf "$bf" -C "$td" . || { rm -rf "$td"; die "Ошибка tar $bf"; }; rm -rf "$td"; chown "${TARGET_USER}:${TARGET_USER}" "$bf"; chmod 600 "$bf" || log_warn "Ошибка chmod бэкапа"; find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" -printf '%T@ %p\n'|sort -nr|tail -n +11|cut -d' ' -f2-|xargs -r rm -f || log_warn "Ошибка удаления старых бэкапов"; log "Бэкап создан: $bf"; }
restore_backup() { local bf="$1"; local bd="$AWG_DIR/backups"; if [ -z "$bf" ]; then if [ ! -d "$bd" ] || [ -z "$(ls -A "$bd" 2>/dev/null)" ]; then die "Бэкапы не найдены в $bd."; fi; local backups; backups=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | sort -r); if [ -z "$backups" ]; then die "Бэкапы не найдены."; fi; echo "Доступные бэкапы:"; local i=1; local bl=(); while IFS= read -r f; do local fd; fd=$(basename "$f" | grep -oP '\d{8}_\d{6}' | sed 's/_/ /'); echo "  $i) $(basename "$f") ($fd)"; bl[$i]="$f"; ((i++)); done <<< "$backups"; read -p "Номер для восстановления (0-отмена): " choice < /dev/tty; if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -ge "$i" ]; then log "Отмена."; return 1; fi; bf="${bl[$choice]}"; fi; if [ ! -f "$bf" ]; then die "Файл бэкапа '$bf' не найден."; fi; log "Восстановление из $bf"; if ! confirm_action "восстановить" "конфигурацию из '$bf'"; then return 1; fi; log "Создание бэкапа текущей..."; backup_configs; local td; td=$(mktemp -d); if ! tar -xzf "$bf" -C "$td"; then log_error "Ошибка tar $bf"; rm -rf "$td"; return 1; fi; log "Остановка сервиса..."; systemctl stop awg-quick@awg0 || log_warn "Сервис не остановлен."; if [ -d "$td/server" ]; then log "Восстановление конфига сервера..."; cp -a "$td/server/"* /etc/amnezia/amneziawg/ || log_error "Ошибка копирования server"; chmod 600 /etc/amnezia/amneziawg/*.conf; chmod 700 /etc/amnezia/amneziawg; fi; if [ -d "$td/clients" ]; then log "Восстановление файлов клиентов..."; cp -a "$td/clients/"* "$AWG_DIR/" || log_error "Ошибка копирования clients"; chmod 600 "$AWG_DIR"/*.conf; chmod 600 "$CONFIG_FILE"; chown -R "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"; fi; rm -rf "$td"; log "Запуск сервиса..."; if ! systemctl start awg-quick@awg0; then log_error "Ошибка запуска сервиса!"; systemctl status awg-quick@awg0 --no-pager | log_msg "ERROR"; return 1; fi; log "Восстановление завершено."; }
modify_client() { local name="$1"; local param="$2"; local value="$3"; if [ -z "$name" ] || [ -z "$param" ] || [ -z "$value" ]; then log_error "Использование: modify <имя> <параметр> <значение>"; return 1; fi; if ! grep -q "^#_Name = ${name}$" "$SERVER_CONF_FILE"; then die "Клиент '$name' не найден."; fi; local cf="$AWG_DIR/$name.conf"; if [ ! -f "$cf" ]; then die "Файл $cf не найден."; fi; if ! grep -q -E "^${param}\s*=" "$cf"; then log_error "Параметр '$param' не найден в $cf."; return 1; fi; log "Изменение '$param' на '$value' для '$name'..."; local bak="${cf}.bak-$(date +%F_%T)"; cp "$cf" "$bak" || log_warn "Ошибка бэкапа $bak"; log "Создан бэкап $bak"; chown "${TARGET_USER}:${TARGET_USER}" "$bak"; chmod 600 "$bak"; if ! sed -i "s#^${param} = .*#${param} = ${value}#" "$cf"; then log_error "Ошибка sed. Восстановление..."; cp "$bak" "$cf" || log_warn "Ошибка восстановления."; return 1; fi; log "Параметр '$param' изменен."; if [[ "$param" == "AllowedIPs" || "$param" == "Address" || "$param" == "PublicKey" || "$param" == "Endpoint" || "$param" == "PrivateKey" ]]; then log "Перегенерация QR-кода..."; if command -v qrencode &>/dev/null; then if qrencode -o "$AWG_DIR/$name.png" < "$cf"; then chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR/$name.png"; chmod 644 "$AWG_DIR/$name.png"; log "QR-код обновлен."; else log_warn "Ошибка qrencode."; fi; else log_warn "qrencode не найден."; fi; fi; return 0; }
check_server() { log "Проверка состояния сервера AmneziaWG..."; local ok=1; log "Статус сервиса:"; if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi; log "Интерфейс awg0:"; if ! ip addr show awg0 &>/dev/null; then log_error " - Интерфейс не найден!"; ok=0; else ip addr show awg0 | log_msg "INFO"; fi; log "Прослушивание порта:"; source "$CONFIG_FILE" &>/dev/null; local port=${AWG_PORT:-0}; if [ "$port" -eq 0 ]; then log_warn " - Не удалось определить порт."; else if ! ss -lunp | grep -q ":${port} "; then log_error " - Порт ${port}/udp НЕ прослушивается!"; ok=0; else log " - Порт ${port}/udp прослушивается."; fi; fi; log "Настройки ядра:"; local fwd; fwd=$(sysctl -n net.ipv4.ip_forward); if [ "$fwd" != "1" ]; then log_error " - IP Forwarding выключен ($fwd)!"; ok=0; else log " - IP Forwarding включен."; fi; # UFW check removed
 log "Статус AmneziaWG:"; awg show | log_msg "INFO"; if [ "$ok" -eq 1 ]; then log "Проверка завершена: Состояние OK."; else log_error "Проверка завершена: ОБНАРУЖЕНЫ ПРОБЛЕМЫ!"; fi; return $ok; }
list_clients() {
    log "Получение списка клиентов..."; local clients; clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients="";
    if [ -z "$clients" ]; then log "Клиенты не найдены."; return 0; fi
    local verbose=$VERBOSE_LIST
    local awg_stat; awg_stat=$(awg show 2>/dev/null) || awg_stat=""; local act=0; local tot=0;
    if [ $verbose -eq 1 ]; then printf "%-20s | %-7s | %-7s | %-15s | %-15s | %s\n" "Имя клиента" "Conf" "QR" "IP-адрес" "Ключ (нач.)" "Статус"; printf -- "-%.0s" {1..85}; echo; else printf "%-20s | %-7s | %-7s | %s\n" "Имя клиента" "Conf" "QR" "Статус"; printf -- "-%.0s" {1..50}; echo; fi
    echo "$clients" | while IFS= read -r name; do
        name=$(echo "$name" | xargs); if [ -z "$name" ]; then continue; fi; ((tot++));
        local cf="?"; local png="?"; local pk="-"; local ip="-"; local st="Нет данных"; local color_start="\033[0m"; local color_end="\033[0m"; if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;37m"; fi;
        [ -f "$AWG_DIR/${name}.conf" ] && cf="✓"; [ -f "$AWG_DIR/${name}.png" ] && png="✓";
        if [ "$cf" = "✓" ]; then
            ip=$(grep -oP 'Address = \K[0-9\.]+' "$AWG_DIR/${name}.conf" 2>/dev/null) || ip="?"
            local peer_block_started=0; local current_pk="";
            while IFS= read -r line || [[ -n "$line" ]]; do if [[ "$line" != "#"* && "$line" != *"="* && -n "$line" && "$peer_block_started" -eq 1 && "$line" != "" ]]; then break; fi; if [[ "$line" == "[Peer]"* && "$peer_block_started" -eq 1 ]]; then break; fi; if [[ "$line" == *"#_Name = ${name}"* ]]; then peer_block_started=1; fi; if [[ "$peer_block_started" -eq 1 && "$line" == "PublicKey = "* ]]; then current_pk=$(echo "$line" | cut -d' ' -f3); break; fi; done < "$SERVER_CONF_FILE"
            if [[ -n "$current_pk" ]]; then
                pk=$(echo "$current_pk" | head -c 10)"...";
                if echo "$awg_stat" | grep -qF "$current_pk"; then
                     local handshake_line; handshake_line=$(echo "$awg_stat" | grep -A 3 -F "$current_pk" | grep 'latest handshake:');
                     if [[ -n "$handshake_line" && ! "$handshake_line" =~ "never" ]]; then if echo "$handshake_line" | grep -q "seconds ago"; then local sec; sec=$(echo "$handshake_line" | grep -oP '\d+(?= seconds ago)'); if [[ "$sec" -lt 180 ]]; then st="Активен"; color_start="\033[0;32m"; ((act++)); else st="Недавно"; color_start="\033[0;33m"; ((act++)); fi; else st="Недавно"; color_start="\033[0;33m"; ((act++)); fi; else st="Нет handshake"; color_start="\033[0;37m"; fi
                else st="Не найден"; color_start="\033[0;31m"; fi
            else pk="?"; st="ошибка ключа"; color_start="\033[0;31m"; fi
        fi
        if [ $verbose -eq 1 ]; then printf "%-20s | %-7s | %-7s | %-15s | %-15s | ${color_start}%s${color_end}\n" "$name" "$cf" "$png" "$ip" "$pk" "$st"; else printf "%-20s | %-7s | %-7s | ${color_start}%s${color_end}\n" "$name" "$cf" "$png" "$st"; fi
    done; echo ""; log "Всего клиентов: $tot, Активных/Недавно: $act";
}
usage() {
    exec >&2; echo ""; echo "Скрипт управления AmneziaWG (Azure Mini v1.1)"; echo "==================================================="; echo "Использование: $0 [ОПЦИИ] <КОМАНДА> [АРГУМЕНТЫ]"; echo "";
    echo "Опции:"; echo "  -h, --help            Показать эту справку"; echo "  -v, --verbose         Расширенный вывод (для list)"; echo "  --no-color            Отключить цветной вывод"; echo "  --conf-dir=ПУТЬ       Указать директорию AWG (умолч: $AWG_DIR)"; echo "  --server-conf=ПУТЬ    Указать файл конфига сервера (умолч: $SERVER_CONF_FILE)"; echo "";
    echo "Команды:"; echo "  add <имя>             Добавить клиента"; echo "  remove <имя>          Удалить клиента"; echo "  list [-v]             Показать список клиентов"; echo "  regen [имя]           Перегенерировать файлы клиента(ов)"; echo "  modify <имя> <пар> <зн> Изменить параметр клиента";
    echo "  backup                Создать бэкап"; echo "  restore [файл]        Восстановить из бэкапа"; echo "  check | status        Проверить состояние сервера"; echo "  show                  Показать статус \`awg show\`"; echo "  restart               Перезапустить сервис AmneziaWG"; echo "  help                  Показать эту справку"; echo "";
    echo "ВАЖНО: Перезапустите сервис после 'add', 'remove', 'restore':"; echo "  sudo systemctl restart awg-quick@awg0 (или $0 restart)"; echo ""; exit 1;
}

# --- Основная логика ---
check_dependencies || exit 1 # Проверяем зависимости
cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR" # Переходим в рабочую директорию

# Если команда не задана (после парсинга опций), показываем справку
if [ -z "$COMMAND" ]; then usage; fi

log "Запуск команды '$COMMAND'..."

case $COMMAND in
    add)
        [ -z "$CLIENT_NAME" ] && die "Не указано имя клиента."; validate_client_name "$CLIENT_NAME" || exit 1;
        if grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then die "Клиент '$CLIENT_NAME' уже существует."; fi
        log "Добавление '$CLIENT_NAME'...";
        if run_awgcfg -a "$CLIENT_NAME"; then
            log "Клиент '$CLIENT_NAME' добавлен в $SERVER_CONF_FILE.";
            log "Генерация файлов конфигурации и QR для всех клиентов...";
            # Используем workaround при вызове генерации клиентов
            if run_awgcfg_generate_clients; then
                log "Файлы для клиентов созданы/обновлены в $AWG_DIR.";
                # Устанавливаем владельца на новые файлы
                chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR/$CLIENT_NAME.conf" "$AWG_DIR/$CLIENT_NAME.png" 2>/dev/null || log_warn "Не удалось установить владельца на новые файлы клиента."
                log "ВАЖНО: Требуется перезапуск сервиса: sudo systemctl restart awg-quick@awg0";
            else
                log_error "Ошибка генерации файлов клиентов.";
                log_warn "Клиент '$CLIENT_NAME' добавлен, но файлы конфигурации могут быть неактуальны!";
            fi
        else
            log_error "Ошибка добавления клиента '$CLIENT_NAME' в $SERVER_CONF_FILE.";
        fi
        ;;
    remove)
        [ -z "$CLIENT_NAME" ] && die "Не указано имя клиента.";
        if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then die "Клиент '$CLIENT_NAME' не найден."; fi
        if ! confirm_action "удалить" "клиента '$CLIENT_NAME'"; then exit 1; fi
        log "Удаление '$CLIENT_NAME'...";
        if run_awgcfg -d "$CLIENT_NAME"; then # Вызов -d не должен удалять setup.conf
            log "Клиент '$CLIENT_NAME' удален из $SERVER_CONF_FILE.";
            log "Удаление файлов клиента..."; rm -f "$AWG_DIR/$CLIENT_NAME.conf" "$AWG_DIR/$CLIENT_NAME.png"; log "Файлы удалены.";
            log "ВАЖНО: Требуется перезапуск сервиса: sudo systemctl restart awg-quick@awg0";
        else
            log_error "Ошибка удаления клиента '$CLIENT_NAME'.";
        fi
        ;;
    list)
        list_clients "${ARGS[0]}" # Передаем первый аргумент как возможный флаг -v
        ;;
    regen)
        log "Перегенерация файлов конфигурации и QR для всех клиентов...";
        if [ -n "$CLIENT_NAME" ]; then
             log_warn "Аргумент <имя_клиента> для 'regen' игнорируется. Перегенерируются файлы ВСЕХ клиентов."
        fi
        # Используем workaround при вызове генерации клиентов
        if run_awgcfg_generate_clients; then
            log "Файлы для клиентов перегенерированы в $AWG_DIR.";
            chown -R "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR" # Устанавливаем владельца на все файлы в директории
        else
            log_error "Ошибка перегенерации файлов клиентов.";
        fi
        ;;
    modify)   modify_client "$CLIENT_NAME" "$PARAM" "$VALUE" ;;
    backup)   backup_configs ;;
    restore)  restore_backup "$CLIENT_NAME" ;; # Используем CLIENT_NAME как [файл]
    check|status) check_server ;;
    show)     log "Статус AmneziaWG..."; if ! awg show; then log_error "Ошибка awg show."; fi ;;
    restart)  log "Перезапуск сервиса..."; if ! confirm_action "перезапустить" "сервис"; then exit 1; fi; if ! systemctl restart awg-quick@awg0; then log_error "Ошибка перезапуска."; systemctl status awg-quick@awg0 --no-pager | log_msg "ERROR"; exit 1; else log "Сервис перезапущен."; fi ;;
    help)     usage ;;
    *)        log_error "Неизвестная команда: '$COMMAND'"; usage ;;
esac

log "Скрипт управления завершил работу."
exit 0
