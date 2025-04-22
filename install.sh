#!/bin/bash

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG на Ubuntu 24.04 LTS Minimal (ARM64)
# Версия Azure ARM64 Interactive - Refined + Fixes v3
# Автор: @bivlked & Gemini
# Версия: 2.4
# Дата: 2025-04-22
# Репозиторий: https://github.com/bivlked/azure
# ==============================================================================

# --- Режим Безопасности и Константы ---
set -o pipefail # Прерывать выполнение, если команда в пайпе завершается с ошибкой
set -o nounset  # Считать ошибкой использование неинициализированных переменных

# --- Определение Пользователя и Домашнего Каталога ---
# Скрипт должен запускаться через sudo
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="<span class="math-inline">SUDO\_USER"
\# Безопасное определение домашнего каталога через getent
TARGET\_HOME\=</span>(getent passwd "$TARGET_USER" | cut -d: -f6)
    # Проверка, что TARGET_HOME не пустой и является директорией
    if [[ -z "$TARGET_HOME" ]] || [[ ! -d "$TARGET_HOME" ]]; then
        echo "[ERROR] Не удалось определить домашнюю директорию для пользователя '<span class="math-inline">TARGET\_USER'\." \>&2
exit 1
fi
else
\# Если запуск от root или SUDO\_USER не определен
TARGET\_USER\="root"
TARGET\_HOME\="/root"
\# Выводим предупреждение только при явном запуске от root
if \[ "</span>(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
         echo "[WARN] Запуск напрямую от root. Рабочая директория: ${TARGET_HOME}/awg" >&2
    elif [ "$TARGET_USER" == "root" ]; then
         # Сюда попадаем, если sudo пользователь == root (редко)
         echo "[WARN] Запуск от пользователя sudo 'root'. Рабочая директория: <span class="math-inline">\{TARGET\_HOME\}/awg" \>&2
fi
fi
\# \-\-\- Основные Пути и Имена Файлов \-\-\-
\# Используем определенные выше TARGET\_HOME и TARGET\_USER
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
DISABLE_IPV6=1; # Принудительно отключаем IPv6

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
    local port=$1; log "Проверка порта <span class="math-inline">\{port\}/udp\.\.\."; if ss \-lunp \| grep \-q "\:</span>{port}[[:space:]]"; then log_error "Порт <span class="math-inline">\{port\}/udp уже используется процессом\:"; ss \-lunp \| grep "\:</span>{port}[[:space:]]" | log_msg "ERROR"; return 1; else log "Порт <span class="math-inline">\{port\}/udp свободен \(OK\)\."; return 0; fi
\}
\# Функция установки пакетов
\# Принимает список пакетов как аргументы
\# Обновляет apt только если есть пакеты для установки
install\_packages\(\) \{
local packages\_to\_install\=\("</span>@")
    local missing_packages=()
    log_debug "Проверка необходимости установки пакетов: <span class="math-inline">\{packages\_to\_install\[\*\]\:\-\}"
for pkg in "</span>{packages_to_install[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -eq 0 ]; then
        log_debug "Все пакеты из списка уже установлены."
        return 0
    fi

    log "Следующие пакеты будут установлены: <span class="math-inline">\{missing\_packages\[\*\]\}"
log "Обновление списка пакетов перед установкой \(apt update\)\.\.\."
apt update \-y \|\| log\_warn "Не удалось обновить список пакетов 'apt update'\. Попытка установки может завершиться ошибкой\."
log "Установка пакетов\.\.\."
if \! DEBIAN\_FRONTEND\=noninteractive apt install \-y "</span>{missing_packages[@]}"; then
         die "Ошибка при установке пакетов: <span class="math-inline">\{missing\_packages\[\*\]\}\."
fi
log "Пакеты успешно установлены\."
\}
cleanup\_apt\(\) \{ log "Очистка apt\.\.\."; apt\-get clean \|\| log\_warn "Ошибка apt\-get clean"; rm \-rf /var/lib/apt/lists/\* \|\| log\_warn "Ошибка rm /var/lib/apt/lists/\*"; log "Кэш apt очищен\."; \}
configure\_routing\_mode\(\) \{
echo ""; log "Выберите режим маршрутизации \(AllowedIPs\)\:"; echo "  1\) Весь трафик \(0\.0\.0\.0/0\)"; echo "  2\) Список Amnezia\+DNS \(умолч\.\)"; echo "  3\) Указанные сети"; read \-p "Выбор \[2\]\: " r\_mode < /dev/tty; ALLOWED\_IPS\_MODE\=</span>{r_mode:-2}; case "$ALLOWED_IPS_MODE" in 1) ALLOWED_IPS="0.0.0.0/0"; log "Режим: Весь трафик";; 3) read -p "Сети через запятую: " custom_ips < /dev/tty; if ! echo "<span class="math-inline">custom\_ips" \| grep \-qE '^\(\[0\-9\]\{1,3\}\\\.\)\{3\}\[0\-9\]\{1,3\}/\[0\-9\]\{1,2\}\(,\(\[0\-9\]\{1,3\}\\\.\)\{3\}\[0\-9\]\{1,3\}/\[0\-9\]\{1,2\}\)\*</span>'; then log_warn "Формат '$custom_ips' некорректен."; fi; ALLOWED_IPS=$custom_ips; log "Режим: Пользовательский ($ALLOWED_IPS)";; *) ALLOWED_IPS_MODE=2; ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"; log "Режим: Список Amnezia+DNS";; esac; if [ -z "$ALLOWED_IPS" ]; then die "Не удалось определить AllowedIPs."; fi; export ALLOWED_IPS_MODE ALLOWED_IPS;
}
run_awgcfg() {
    log_debug "Запуск awgcfg.py $*"; if [ ! -x "$PYTHON_EXEC" ] || [ ! -x "$AWGCFG_SCRIPT" ]; then log_error "Python или awgcfg.py не найден/исполняем."; return 1; fi; if ! (cd "$AWG_DIR" && "$PYTHON_EXEC" "<span class="math-inline">AWGCFG\_SCRIPT" "</span>@"); then log_error "Ошибка выполнения: '$PYTHON_EXEC $AWGCFG_SCRIPT <span class="math-inline">\*'"; return 1; fi; chown "</span>{TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null || true; find "$AWG_DIR" -maxdepth 1 -name "*.conf" -type f -exec chmod 600 {} \; 2>/dev/null; find "<span class="math-inline">AWG\_DIR" \-maxdepth 1 \-name "\*\.png" \-type f \-exec chmod 644 \{\} \\; 2\>/dev/null; log\_debug "awgcfg\.py '</span>*' выполнен."; return 0;
}
check_service_status() {
