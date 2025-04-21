#!/bin/bash

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG на Ubuntu 24.04 LTS Minimal (ARM64)
# Версия Azure ARM64 Interactive - Refined
# Автор: @bivlked
# Версия: 2.1
# Дата: 2025-04-21
# Репозиторий: https://github.com/bivlked/azure
# ==============================================================================

# --- Режим Безопасности и Константы ---
set -o pipefail # Прерывать выполнение, если команда в пайпе завершается с ошибкой
set -o nounset  # Считать ошибкой использование неинициализированных переменных
# set -o errexit # Не используем, т.к. обрабатываем ошибки через die() или ||

# --- Определение Пользователя и Домашнего Каталога ---
# Скрипт должен запускаться через sudo, $SUDO_USER будет установлен
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
    # Безопасное определение домашнего каталога
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [ ! -d "$TARGET_HOME" ]; then
        echo "[ERROR] Не удалось определить домашнюю директорию для пользователя '$TARGET_USER'." >&2
        exit 1
    fi
else
    TARGET_USER="root"
    TARGET_HOME="/root"
    echo "[WARN] Запуск от root или не удалось определить пользователя sudo. Рабочая директория: ${TARGET_HOME}/awg" >&2
fi

# --- Основные Пути и Имена Файлов ---
AWG_DIR="${TARGET_HOME}/awg"              # Рабочая директория
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" # Файл конфигурации установки
STATE_FILE="$AWG_DIR/setup_state"        # Файл состояния установки
CLIENT_TEMPLATE_FILE="$AWG_DIR/_defclient.config" # Шаблон клиентского конфига
PYTHON_VENV="$AWG_DIR/venv"              # Путь к каталогу venv
PYTHON_EXEC="$PYTHON_VENV/bin/python"    # Путь к Python внутри venv
AWGCFG_SCRIPT="$AWG_DIR/awgcfg.py"       # Путь к скрипту генерации конфигов
MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/azure/main/manage.sh" # URL скрипта управления
MANAGE_SCRIPT_PATH="$AWG_DIR/manage.sh"    # Путь к скачанному скрипту управления
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf" # Конфиг сервера WG

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
    local type="$1" msg="$2" ts color_start="" color_end="\033[0m" safe_msg entry
    ts=$(date +'%F %T')
    # Экранирование % для printf
    safe_msg=$(echo "$msg" | sed 's/%/%%/g')
    entry="[$ts] $type: $safe_msg"

    if [[ "$NO_COLOR" -eq 0 ]]; then
        case "$type" in
            INFO)  color_start="\033[0;32m";; # Зеленый
            WARN)  color_start="\033[0;33m";; # Желтый
            ERROR) color_start="\033[1;31m";; # Красный жирный
            DEBUG) color_start="\033[0;36m";; # Голубой
            STEP)  color_start="\033[1;34m";; # Синий жирный
            *)     color_start=""; color_end="";;
        esac
    fi

    # Вывод: Ошибки/Предупреждения/Отладка в stderr, остальное в stdout
    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "$type" == "DEBUG" && "$VERBOSE" -eq 1 ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "$type" == "INFO" || "$type" == "STEP" ]]; then
         printf "${color_start}%s${color_end}\n" "$entry"
    fi
}

log() { log_msg "INFO" "$1"; }
log_warn() { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_debug() { if [[ "$VERBOSE" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }
log_step() { log_msg "STEP" "$1"; }
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
    local next_step=$1
    mkdir -p "$(dirname "$STATE_FILE")" || die "Ошибка создания директории для файла состояния: $(dirname "$STATE_FILE")"
    echo "$next_step" > "$STATE_FILE" || die "Ошибка записи состояния в $STATE_FILE"
    chown "${TARGET_USER}:${TARGET_USER}" "$STATE_FILE" || log_warn "Не удалось сменить владельца файла состояния $STATE_FILE"
    log_debug "Состояние сохранено: следующий шаг - $next_step"
}

request_reboot() {
    local next_step=$1
    update_state "$next_step" # Сохраняем следующий шаг
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log_warn "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ ДЛЯ ПРИМЕНЕНИЯ ИЗМЕНЕНИЙ !!!"
    log_warn "!!! После перезагрузки, запустите скрипт снова командой:     !!!"
    log_warn "!!! sudo bash $0                                            !!!"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    # Читаем напрямую с терминала
    read -p "Перезагрузить систему сейчас? [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[YyЕе]$ ]]; then
        log "Инициирована перезагрузка системы..."
        sleep 5
        if ! reboot; then
             die "Команда 'reboot' не удалась. Перезагрузите систему вручную и запустите скрипт снова."
        fi
        exit 1 # Выход, даже если reboot не сработал сразу
    else
        log_warn "Перезагрузка отменена. Перезагрузитесь вручную и запустите скрипт снова."
        exit 1 # Выходим, т.к. продолжение некорректно
    fi
}

check_os_version() {
    log "Проверка ОС и архитектуры..."
    if ! command -v lsb_release &> /dev/null; then
        log_warn "'lsb_release' не найден. Проверка ОС пропускается."
    else
        local os_id; os_id=$(lsb_release -si)
        local os_ver; os_ver=$(lsb_release -sr)
        if [[ "$os_id" != "Ubuntu" || "$os_ver" != "24.04" ]]; then
            log_warn "Обнаружена ОС: $os_id $os_ver. Скрипт оптимизирован для Ubuntu 24.04 LTS."
            read -p "Продолжить установку? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[YyЕе]$ ]]; then die "Установка отменена."; fi
        else
            log "ОС: Ubuntu $os_ver (OK)"
        fi
    fi

    local arch; arch=$(uname -m)
    if [[ "$arch" != "aarch64" ]]; then
        log_warn "Обнаружена архитектура: $arch. Скрипт предназначен для ARM64 (aarch64)."
         read -p "Продолжить установку? [y/N]: " confirm_arch < /dev/tty
        if ! [[ "$confirm_arch" =~ ^[YyЕе]$ ]]; then die "Установка отменена."; fi
    else
        log "Архитектура: $arch (OK)"
    fi
}

check_free_space() {
    log "Проверка доступного дискового пространства..."
    local required_mb=1024 # 1 ГБ
    local available_mb
    available_mb=$(df -m / | awk 'NR==2 {print $4}')

    if [[ -z "$available_mb" ]]; then
        log_warn "Не удалось определить свободное место. Проверка пропускается."
        return 0
    fi

    if [[ "$available_mb" -lt "$required_mb" ]]; then
        log_warn "Недостаточно свободного места (${available_mb} МБ). Рекомендуется >= ${required_mb} МБ."
        read -p "Продолжить установку? [y/N]: " confirm < /dev/tty
        if ! [[ "$confirm" =~ ^[YyЕе]$ ]]; then die "Установка отменена."; fi
    else
        log "Свободно: ${available_mb} МБ (OK)"
    fi
}

check_port_availability() {
    local port=$1
    log "Проверка доступности порта ${port}/udp..."
    if ss -lunp | grep -q ":${port} "; then
        log_error "Порт ${port}/udp уже используется процессом:"
        ss -lunp | grep ":${port} " | log_msg "ERROR"
        return 1 # Порт занят
    else
        log "Порт ${port}/udp свободен (OK)."
        return 0 # Порт свободен
    fi
}

# Установка пакетов с однократным apt update
install_packages() {
    local packages_to_install=("$@")
    local missing_packages=()
    log_debug "Проверка необходимости установки пакетов: ${packages_to_install[*]}"

    for pkg in "${packages_to_install[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -eq 0 ]; then
        log_debug "Все пакеты из списка уже установлены."
        return 0
    fi

    log "Следующие пакеты будут установлены: ${missing_packages[*]}"
    log "Обновление списка пакетов перед установкой (apt update)..."
    apt update -y || log_warn "Не удалось обновить список пакетов 'apt update'. Попытка установки может завершиться ошибкой."

    log "Установка пакетов..."
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${missing_packages[@]}"; then
         die "Ошибка при установке пакетов: ${missing_packages[*]}."
    fi
    log "Пакеты успешно установлены."
}

cleanup_apt() {
    log "Очистка кэша apt..."
    apt-get clean || log_warn "Ошибка выполнения 'apt-get clean'"
    rm -rf /var/lib/apt/lists/* || log_warn "Ошибка удаления файлов в /var/lib/apt/lists/"
    log "Кэш apt очищен."
}

configure_routing_mode() {
    echo ""
    log "Выберите режим маршрутизации для клиентов (AllowedIPs):"
    echo "  1) Весь трафик             (0.0.0.0/0)"
    echo "  2) Список Amnezia + DNS    (Рекомендуется, по умолчанию)"
    echo "  3) Только указанные сети  (Например, 192.168.1.0/24,10.0.0.0/8)"
    read -p "Ваш выбор [2]: " r_mode < /dev/tty
    ALLOWED_IPS_MODE=${r_mode:-2}

    case "$ALLOWED_IPS_MODE" in
        1)
            ALLOWED_IPS="0.0.0.0/0"
            log "Выбран режим: Весь трафик (0.0.0.0/0)"
            ;;
        3)
            read -p "Введите целевые сети через запятую: " custom_ips < /dev/tty
            if ! echo "$custom_ips" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}(,([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2})*$'; then
                 log_warn "Формат введенных сетей ('$custom_ips') выглядит некорректно."
            fi
            ALLOWED_IPS=$custom_ips
            log "Выбран режим: Пользовательский ($ALLOWED_IPS)"
            ;;
        *) # Вариант 2 или любой некорректный ввод
            ALLOWED_IPS_MODE=2
            # Список подсетей Amnezia для обхода блокировок + популярные DNS
            ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
            log "Выбран режим: Список Amnezia + DNS (по умолчанию)"
            ;;
    esac

    if [ -z "$ALLOWED_IPS" ]; then die "Не удалось определить значение для AllowedIPs."; fi
    export ALLOWED_IPS_MODE ALLOWED_IPS
}

run_awgcfg() {
    log_debug "Запуск awgcfg.py из '$AWG_DIR' с аргументами: $*"
    if [ ! -x "$PYTHON_EXEC" ]; then die "Python '$PYTHON_EXEC' не найден или не исполняемый."; fi
    if [ ! -x "$AWGCFG_SCRIPT" ]; then die "Скрипт '$AWGCFG_SCRIPT' не найден или не исполняемый."; fi

    # Используем cd, т.к. awgcfg.py может ожидать запуска из своей директории
    if ! (cd "$AWG_DIR" && "$PYTHON_EXEC" "$AWGCFG_SCRIPT" "$@"); then
        log_error "Ошибка выполнения: '$PYTHON_EXEC $AWGCFG_SCRIPT $*'"
        return 1
    fi

    # Установка владельца/прав на файлы, которые мог создать awgcfg.py
    chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null || true
    find "$AWG_DIR" -maxdepth 1 -name "*.conf" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -maxdepth 1 -name "*.png" -type f -exec chmod 644 {} \; 2>/dev/null
    log_debug "Команда awgcfg.py '$*' выполнена."
    return 0
}

check_service_status() {
    log "Проверка статуса сервиса AmneziaWG (awg-quick@awg0)..."
    local all_ok=1

    if systemctl is-active --quiet awg-quick@awg0; then
        log " - Сервис systemd: активен (running)"
    else
        local state; state=$(systemctl show -p SubState --value awg-quick@awg0 2>/dev/null || echo "неизвестно")
        if systemctl is-failed --quiet awg-quick@awg0; then
             log_error " - Сервис systemd: FAILED (состояние: $state)"
             all_ok=0
        else
             log_warn " - Сервис systemd: не активен (состояние: $state)"
             all_ok=0
        fi
        journalctl -u awg-quick@awg0 -n 5 --no-pager --output=cat | sed 's/^/    /' >&2
    fi

    if ip addr show awg0 &>/dev/null; then log " - Сетевой интерфейс: awg0 существует"; else log_error " - Сетевой интерфейс: awg0 НЕ найден!"; all_ok=0; fi
    if awg show | grep -q "interface: awg0"; then log " - Утилита 'awg': видит интерфейс awg0"; else log_error " - Утилита 'awg': НЕ видит интерфейс awg0!"; all_ok=0; fi

    local port_to_check=${AWG_PORT:-0}
    if [ "$port_to_check" -eq 0 ] && [ -f "$CONFIG_FILE" ]; then
        port_to_check=$(grep '^export AWG_PORT=' "$CONFIG_FILE" | cut -d'=' -f2)
        port_to_check=${port_to_check:-0}
    fi
    if [ "$port_to_check" -ne 0 ]; then
        if ss -lunp | grep -q ":${port_to_check} "; then log " - Прослушивание порта: ${port_to_check}/udp (OK)"; else log_error " - Прослушивание порта: ${port_to_check}/udp НЕ обнаружено!"; all_ok=0; fi
    else
        log_warn " - Прослушивание порта: Не удалось определить порт для проверки."
    fi

    if [ "$all_ok" -eq 1 ]; then log "Статус сервиса AmneziaWG: OK"; return 0; else log_error "Обнаружены проблемы в работе AmneziaWG."; return 1; fi
}

# Настройка параметров ядра (sysctl)
configure_kernel_parameters() {
    log "Настройка параметров ядра (IPv4 форвардинг, отключение IPv6)..."
    local sysctl_conf_file="/etc/sysctl.d/99-amneziawg-vpn.conf"

    {
        echo "# AmneziaWG VPN Settings - Generated by install.sh on $(date)"
        echo "net.ipv4.ip_forward = 1"
        echo ""
        echo "# Disable IPv6 system-wide"
        echo "net.ipv6.conf.all.disable_ipv6 = 1"
        echo "net.ipv6.conf.default.disable_ipv6 = 1"
        echo "net.ipv6.conf.lo.disable_ipv6 = 1"
    } > "$sysctl_conf_file" || die "Ошибка записи конфигурации sysctl в $sysctl_conf_file"

    log "Применение настроек sysctl..."
    if ! sysctl -p "$sysctl_conf_file" > /dev/null; then
         log_warn "Не удалось применить $sysctl_conf_file немедленно. Должны примениться после перезагрузки."
    else
        log "Настройки sysctl применены."
    fi
    # Проверка значений
    local ipv4_fwd; ipv4_fwd=$(sysctl -n net.ipv4.ip_forward)
    local ipv6_dis; ipv6_dis=$(sysctl -n net.ipv6.conf.all.disable_ipv6)
    if [[ "$ipv4_fwd" != "1" || "$ipv6_dis" != "1" ]]; then
        log_warn "Одно или несколько значений sysctl не установились немедленно. Потребуется перезагрузка."
    fi
}

# Установка безопасных прав доступа
secure_files() {
    log_debug "Установка прав доступа..."

    if [ -d "$AWG_DIR" ]; then
        chmod 700 "$AWG_DIR" || log_warn "Ошибка chmod 700 для $AWG_DIR"
        chown -R "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR" || log_warn "Ошибка chown -R для $AWG_DIR"
        find "$AWG_DIR" -type f -name "*.conf" -exec chmod 600 {} \; 2>/dev/null
        find "$AWG_DIR" -type f -name "*.png" -exec chmod 644 {} \; 2>/dev/null
        find "$AWG_DIR" -type f -name "*.py" -exec chmod 750 {} \; 2>/dev/null
        find "$AWG_DIR" -type f -name "*.sh" -exec chmod 750 {} \; 2>/dev/null
        find "$PYTHON_VENV/bin/" -type f -exec chmod 750 {} \; 2>/dev/null # Права для venv executables
    fi

    if [ -d "/etc/amnezia" ]; then
        chmod 700 "/etc/amnezia" || log_warn "Ошибка chmod 700 для /etc/amnezia"
        if [ -d "/etc/amnezia/amneziawg" ]; then
             chmod 700 "/etc/amnezia/amneziawg" || log_warn "Ошибка chmod 700 для /etc/amnezia/amneziawg"
             find "/etc/amnezia/amneziawg" -type f -name "*.conf" -exec chmod 600 {} \; 2>/dev/null
        fi
    fi

    if [ -f "$CONFIG_FILE" ]; then chmod 600 "$CONFIG_FILE" || log_warn "Ошибка chmod 600 для $CONFIG_FILE"; fi
    if [ -f "$STATE_FILE" ]; then chmod 640 "$STATE_FILE" || log_warn "Ошибка chmod 640 для $STATE_FILE"; fi
    log_debug "Права доступа установлены."
}


# --- ШАГ 0: Инициализация и сбор параметров ---
initialize_setup() {
    log_step "--- ШАГ 0: Инициализация и проверка параметров ---"
    if [ "$(id -u)" -ne 0 ]; then die "Запустите скрипт через sudo (sudo bash $0)."; fi

    mkdir -p "$AWG_DIR" || die "Не удалось создать рабочую директорию $AWG_DIR"
    chown "${TARGET_USER}:${TARGET_USER}" "$AWG_DIR" || die "Не удалось установить владельца для $AWG_DIR"
    chmod 700 "$AWG_DIR"
    cd "$AWG_DIR" || die "Не удалось перейти в $AWG_DIR"
    log "Рабочая директория: $AWG_DIR (владелец: $TARGET_USER)"

    check_os_version
    check_free_space

    local default_port=39743 default_subnet="10.9.9.1/24" config_exists=0
    AWG_PORT=$default_port; AWG_TUNNEL_SUBNET=$default_subnet
    ALLOWED_IPS_MODE=""; ALLOWED_IPS=""

    if [[ -f "$CONFIG_FILE" ]]; then
        log "Найден файл конфигурации $CONFIG_FILE. Загрузка настроек..."
        source "$CONFIG_FILE" 2>/dev/null || log_warn "Не удалось полностью загрузить $CONFIG_FILE."
        config_exists=1
        AWG_PORT=${AWG_PORT:-$default_port}
        AWG_TUNNEL_SUBNET=${AWG_TUNNEL_SUBNET:-$default_subnet}
        ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE:-""}
        ALLOWED_IPS=${ALLOWED_IPS:-""}

        # Если режим загружен, а список IP нет - используем режим по умолчанию
        if [[ -n "$ALLOWED_IPS_MODE" && -z "$ALLOWED_IPS" ]]; then
            log_warn "Режим ($ALLOWED_IPS_MODE) загружен, но список IP пуст. Сброс на режим 2."
            ALLOWED_IPS_MODE=2
            ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
        fi
        log "Настройки из файла загружены."
    else
        log "Файл конфигурации '$CONFIG_FILE' не найден. Запрос параметров..."
        # Запрос порта
        while true; do
             read -p "Введите UDP порт AmneziaWG (1024-65535) [${AWG_PORT}]: " input_port < /dev/tty
             input_port=${input_port:-$AWG_PORT}
             if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1024 ] && [ "$input_port" -le 65535 ]; then AWG_PORT=$input_port; break; else log_error "Некорректный порт."; fi
        done
        # Запрос подсети
        while true; do
            read -p "Введите подсеть туннеля (например, 10.9.9.1/24) [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty
             input_subnet=${input_subnet:-$AWG_TUNNEL_SUBNET}
             if [[ "$input_subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then AWG_TUNNEL_SUBNET=$input_subnet; break; else log_error "Некорректный формат подсети."; fi
        done
        # Запрос режима маршрутизации
        configure_routing_mode # Устанавливает ALLOWED_IPS_MODE и ALLOWED_IPS
    fi

    check_port_availability "$AWG_PORT" || die "Выбранный порт $AWG_PORT/udp занят."

    log "Сохранение/Обновление файла конфигурации $CONFIG_FILE..."
    local temp_conf_file; temp_conf_file=$(mktemp) || die "Не удалось создать временный файл."
    {
        echo "# AmneziaWG Install Configuration (Auto-generated)"
        echo "export AWG_PORT=${AWG_PORT}"
        echo "export AWG_TUNNEL_SUBNET='${AWG_TUNNEL_SUBNET}'"
        echo "export DISABLE_IPV6=${DISABLE_IPV6}"
        echo "export ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE}"
        echo "export ALLOWED_IPS='${ALLOWED_IPS}'"
    } > "$temp_conf_file" || { rm -f "$temp_conf_file"; die "Ошибка записи во временный файл."; }

    if ! mv "$temp_conf_file" "$CONFIG_FILE"; then rm -f "$temp_conf_file"; die "Не удалось сохранить $CONFIG_FILE"; fi
    chmod 600 "$CONFIG_FILE" || log_warn "Ошибка chmod 600 для $CONFIG_FILE"
    chown "${TARGET_USER}:${TARGET_USER}" "$CONFIG_FILE" || log_warn "Ошибка chown для $CONFIG_FILE"
    log "Настройки сохранены."

    export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS
    log "--- Итоговые параметры ---"
    log "Порт UDP: ${AWG_PORT}, Подсеть: ${AWG_TUNNEL_SUBNET}, Откл. IPv6: ${DISABLE_IPV6}, Режим AllowedIPs: ${ALLOWED_IPS_MODE}"
    log "--------------------------"

    # Загрузка состояния установки
    if [[ -f "$STATE_FILE" ]]; then
        current_step=$(cat "$STATE_FILE")
        if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then
            log_warn "$STATE_FILE поврежден. Начинаем с шага 1."
            current_step=1; update_state 1
        else
            log "Продолжение установки с шага $current_step."
        fi
    else
        log "Начало установки с шага 1."
        current_step=1; update_state 1
    fi
    log_step "--- Шаг 0 завершен ---"; echo ""
}

# --- ШАГ 1: Обновление системы и настройка ядра ---
step1_update_system_and_networking() {
    update_state 1
    log_step "### ШАГ 1: Обновление системы и настройка ядра ###"

    # Обновляем пакеты один раз здесь
    log "Обновление списка пакетов и системы (apt update && apt full-upgrade)..."
    apt update -y || die "Ошибка 'apt update'."
    if fuser /var/lib/dpkg/lock* &>/dev/null; then
        log_warn "Обнаружена блокировка dpkg. Попытка исправить..."
        killall apt apt-get dpkg &>/dev/null; sleep 2
        rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*
        dpkg --configure -a || log_warn "dpkg --configure -a завершилась с ошибкой."
        apt update -y || die "Повторный 'apt update' не удался."
    fi
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "Ошибка 'apt full-upgrade'."
    log "Система обновлена."

    install_packages curl wget gpg sudo # Базовые утилиты
    configure_kernel_parameters # Настройка sysctl
    log_step "--- Шаг 1 успешно завершен ---"
    request_reboot 2 # Следующий шаг - 2
}

# --- ШАГ 2: Установка AmneziaWG и зависимостей ---
step2_install_amnezia() {
    update_state 2
    log_step "### ШАГ 2: Установка AmneziaWG и зависимостей ###"

    # Включение deb-src (Нужно для сборки DKMS)
    local sources_file="/etc/apt/sources.list.d/ubuntu.sources"
    log_debug "Проверка/включение deb-src в $sources_file..."
    if [ -f "$sources_file" ] && grep -q "Types: deb" "$sources_file" && ! grep -q "Types: deb deb-src" "$sources_file"; then
        log "Включение deb-src в $sources_file..."
        local sources_backup="${sources_file}.bak-$(date +%F_%T)"
        cp "$sources_file" "$sources_backup" || log_warn "Не удалось создать бэкап $sources_backup"
        local temp_sources; temp_sources=$(mktemp)
        if sed 's/Types: deb$/Types: deb deb-src/' "$sources_file" > "$temp_sources"; then
             if mv "$temp_sources" "$sources_file"; then
                  log "deb-src включены. Обновление apt..."
                  apt update -y || die "Ошибка 'apt update' после включения deb-src."
             else rm -f "$temp_sources"; die "Не удалось переместить $temp_sources в $sources_file."; fi
        else rm -f "$temp_sources"; log_warn "Ошибка sed при обработке $sources_file. Пропуск включения deb-src."; fi
    elif [ -f "$sources_file" ]; then log_debug "deb-src уже включены или структура файла нестандартная."; else log_warn "Файл $sources_file не найден."; fi

    # Добавление PPA Amnezia
    log "Добавление PPA Amnezia (ppa:amnezia/ppa)..."
    local ppa_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).list"
    local ppa_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).sources"
    if [ ! -f "$ppa_list" ] && [ ! -f "$ppa_sources" ]; then
        log "PPA не найден. Добавление..."
        install_packages software-properties-common # Для add-apt-repository
        DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:amnezia/ppa || die "Не удалось добавить PPA: ppa:amnezia/ppa."
        log "PPA добавлен. Обновление apt..."
        apt update -y || die "Ошибка 'apt update' после добавления PPA."
    else
        log "PPA Amnezia уже добавлен."
        # Обновим apt на всякий случай, если PPA обновился
        apt update -y || log_warn "'apt update' завершился ошибкой, но продолжаем..."
    fi

    # Установка пакетов AmneziaWG
    log "Установка пакетов AmneziaWG..."
    local amnezia_packages=(
        "amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms"
        "build-essential" "dpkg-dev" "linux-headers-$(uname -r)"
    )
    if ! dpkg -s "linux-headers-$(uname -r)" &> /dev/null; then
        log_warn "Заголовки для ядра $(uname -r) не найдены. Установка linux-headers-generic..."
        amnezia_packages+=( "linux-headers-generic" )
    fi
    install_packages "${amnezia_packages[@]}" # Функция install_packages сделает apt update перед установкой

    # Строгая проверка статуса DKMS
    log "Проверка статуса сборки модуля DKMS для AmneziaWG..."
    sleep 5 # Даем время на возможную сборку
    local dkms_status_output; dkms_status_output=$(dkms status 2>&1)
    log_debug "Вывод dkms status:\n$dkms_status_output"
    if echo "$dkms_status_output" | grep -q 'amneziawg.*installed'; then
        log "DKMS статус: модуль AmneziaWG успешно собран и установлен (OK)."
    else
        log_error "DKMS статус для AmneziaWG не 'installed'!"
        log_error "Вывод dkms status: $dkms_status_output"
        die "Модуль ядра AmneziaWG не смог корректно собраться/установиться через DKMS. Установка прервана."
    fi

    log_step "--- Шаг 2 завершен ---"
    request_reboot 3 # Следующий шаг - 3
}

# --- ШАГ 3: Проверка загрузки модуля ядра ---
step3_check_module() {
    update_state 3
    log_step "### ШАГ 3: Проверка загрузки модуля ядра AmneziaWG ###"
    sleep 2

    log "Проверка загрузки модуля 'amneziawg'..."
    if lsmod | grep -q -w amneziawg; then
        log "Модуль 'amneziawg' загружен (OK)."
    else
        log_warn "Модуль 'amneziawg' не загружен. Попытка загрузить вручную (modprobe)..."
        if modprobe amneziawg; then
            log "Модуль 'amneziawg' успешно загружен."
            # Добавление в автозагрузку
            local modules_file="/etc/modules-load.d/amneziawg.conf"
            mkdir -p "$(dirname "$modules_file")"
            if ! grep -qxF 'amneziawg' "$modules_file" 2>/dev/null; then
                echo "amneziawg" > "$modules_file" || log_warn "Ошибка записи в $modules_file"
                log "Модуль добавлен в $modules_file для автозагрузки."
            fi
        else
            die "Не удалось загрузить модуль ядра 'amneziawg' через modprobe. Проверьте dmesg."
        fi
    fi

    log "Информация о модуле 'amneziawg':"
    modinfo amneziawg | grep -E "filename|version|description|license|vermagic" | log_msg "INFO"
    local module_vermagic; module_vermagic=$(modinfo -F vermagic amneziawg 2>/dev/null || echo "?")
    local kernel_release; kernel_release=$(uname -r)
    if [[ "$module_vermagic" == "$kernel_release"* ]]; then
        log "Версия ядра модуля (vermagic) совпадает с текущим ядром (OK)."
    else
        log_warn "VerMagic НЕ СОВПАДАЕТ: Модуль($module_vermagic) != Ядро($kernel_release)!"
    fi

    log_step "--- Шаг 3 завершен ---"; echo ""
    update_state 5 # Переход к Шагу 5 (пропускаем Firewall)
}

# --- ШАГ 5: Настройка Python, загрузка утилит и скрипта управления ---
step5_setup_python_and_scripts() {
    update_state 5
    log_step "### ШАГ 5: Настройка Python, загрузка утилит и скрипта управления ###"

    install_packages python3-venv python3-pip
    cd "$AWG_DIR" || die "Не удалось перейти в $AWG_DIR"

    if [ ! -d "$PYTHON_VENV" ]; then
        log "Создание виртуального окружения Python в '$PYTHON_VENV'..."
        python3 -m venv "$PYTHON_VENV" || die "Не удалось создать venv."
        chown -R "${TARGET_USER}:${TARGET_USER}" "$PYTHON_VENV" || log_warn "Ошибка chown для $PYTHON_VENV"
        log "Виртуальное окружение создано."
    else
        log "Виртуальное окружение Python '$PYTHON_VENV' уже существует."
        chown -R "${TARGET_USER}:${TARGET_USER}" "$PYTHON_VENV" || log_warn "Ошибка chown для $PYTHON_VENV"
    fi

    if [ ! -x "$PYTHON_EXEC" ]; then die "Python '$PYTHON_EXEC' не найден или не исполняемый."; fi

    log "Обновление pip и установка 'qrcode[pil]' в venv (от имени $TARGET_USER)..."
    # Используем sudo -u для запуска от имени пользователя
    if ! sudo -u "$TARGET_USER" "$PYTHON_EXEC" -m pip install --upgrade pip; then log_warn "Не удалось обновить pip."; fi
    if ! sudo -u "$TARGET_USER" "$PYTHON_EXEC" -m pip install --disable-pip-version-check "qrcode[pil]"; then die "Не удалось установить 'qrcode[pil]'."; fi
    log "Зависимости Python установлены."

    log "Загрузка утилиты 'awgcfg.py'..."
    local awgcfg_url="https://gist.githubusercontent.com/remittor/8c3d9ff293b2ba4b13c367cc1a69f9eb/raw/awgcfg.py"
    if curl -fLso "$AWGCFG_SCRIPT" "$awgcfg_url"; then
        log "'awgcfg.py' загружен в $AWGCFG_SCRIPT."
        chmod 750 "$AWGCFG_SCRIPT" || log_warn "Ошибка chmod для $AWGCFG_SCRIPT"
        chown "${TARGET_USER}:${TARGET_USER}" "$AWGCFG_SCRIPT" || log_warn "Ошибка chown для $AWGCFG_SCRIPT"
    elif [ -f "$AWGCFG_SCRIPT" ]; then
         log_warn "Не удалось скачать 'awgcfg.py', но файл уже существует. Используется существующая версия."
         chmod 750 "$AWGCFG_SCRIPT" || true; chown "${TARGET_USER}:${TARGET_USER}" "$AWGCFG_SCRIPT" || true
    else
         die "Не удалось скачать 'awgcfg.py' из $awgcfg_url."
    fi

    log "Загрузка скрипта управления 'manage.sh'..."
    if curl -fLso "$MANAGE_SCRIPT_PATH" "$MANAGE_SCRIPT_URL"; then
        log "'manage.sh' загружен в $MANAGE_SCRIPT_PATH."
        chmod 750 "$MANAGE_SCRIPT_PATH" || log_warn "Ошибка chmod для $MANAGE_SCRIPT_PATH"
        chown "${TARGET_USER}:${TARGET_USER}" "$MANAGE_SCRIPT_PATH" || log_warn "Ошибка chown для $MANAGE_SCRIPT_PATH"
    elif [ -f "$MANAGE_SCRIPT_PATH" ]; then
         log_warn "Не удалось скачать 'manage.sh', но файл уже существует. Используется существующая версия."
         chmod 750 "$MANAGE_SCRIPT_PATH" || true; chown "${TARGET_USER}:${TARGET_USER}" "$MANAGE_SCRIPT_PATH" || true
    else
         # Не прерываем, но предупреждаем
         log_error "Не удалось скачать скрипт управления 'manage.sh' из $MANAGE_SCRIPT_URL."
         log_error "Управление через 'sudo bash $MANAGE_SCRIPT_PATH' будет недоступно."
    fi

    log_step "--- Шаг 5 завершен ---"; echo ""
    update_state 6 # Следующий шаг - 6
}

# --- ШАГ 6: Генерация конфигураций сервера и клиентов ---
step6_generate_configs() {
    update_state 6
    log_step "### ШАГ 6: Генерация конфигураций сервера и клиентов ###"
    cd "$AWG_DIR" || die "Не удалось перейти в $AWG_DIR"
    local server_config_dir="/etc/amnezia/amneziawg"

    mkdir -p "$server_config_dir" || die "Не удалось создать $server_config_dir"
    chmod 700 "$server_config_dir"

    log "Генерация ключей и конфигурации сервера $SERVER_CONF_FILE..."
    if ! run_awgcfg --make "$SERVER_CONF_FILE" -i "${AWG_TUNNEL_SUBNET}" -p "${AWG_PORT}"; then die "Ошибка генерации конфигурации сервера."; fi
    chmod 600 "$SERVER_CONF_FILE" || log_warn "Ошибка chmod для $SERVER_CONF_FILE"
    log "Конфигурация сервера сгенерирована."

    log "Создание/Обновление шаблона клиента '$CLIENT_TEMPLATE_FILE'..."
    if ! run_awgcfg --create; then log_warn "Не удалось создать/обновить $CLIENT_TEMPLATE_FILE."; touch "$CLIENT_TEMPLATE_FILE" || true; fi

    log "Настройка параметров в шаблоне клиента '$CLIENT_TEMPLATE_FILE':"
    local sed_failed=0
    # DNS
    sed -i 's/^DNS = .*/DNS = 1.1.1.1/' "$CLIENT_TEMPLATE_FILE" && log " - DNS: 1.1.1.1" || { log_warn " - Ошибка sed DNS."; sed_failed=1; }
    # PersistentKeepalive
    sed -i 's/^PersistentKeepalive = .*/PersistentKeepalive = 33/' "$CLIENT_TEMPLATE_FILE" && log " - Keepalive: 33" || { log_warn " - Ошибка sed Keepalive."; sed_failed=1; }
    # AllowedIPs (используем # как разделитель sed)
    local escaped_allowed_ips; escaped_allowed_ips=$(echo "$ALLOWED_IPS" | sed 's/[&#/\]/\\&/g')
    sed -i "s#^AllowedIPs = .*#AllowedIPs = ${escaped_allowed_ips}#" "$CLIENT_TEMPLATE_FILE" && log " - AllowedIPs: Установлен (Режим $ALLOWED_IPS_MODE)" || { log_warn " - Ошибка sed AllowedIPs."; sed_failed=1; }

    if [ "$sed_failed" -eq 1 ]; then log_warn "Не все параметры применены к шаблону."; else log "Шаблон клиента настроен."; fi
    chown "${TARGET_USER}:${TARGET_USER}" "$CLIENT_TEMPLATE_FILE" || log_warn "Ошибка chown для $CLIENT_TEMPLATE_FILE"
    chmod 600 "$CLIENT_TEMPLATE_FILE" || log_warn "Ошибка chmod для $CLIENT_TEMPLATE_FILE"

    log "Добавление клиентов по умолчанию (my_phone, my_laptop)..."
    local default_clients=("my_phone" "my_laptop")
    for client_name in "${default_clients[@]}"; do
        if grep -q "^#_Name = ${client_name}$" "$SERVER_CONF_FILE"; then log " - Клиент '$client_name' уже существует."; else
            log " - Добавление клиента '$client_name'..."
            if run_awgcfg -a "$client_name"; then log "   Клиент '$client_name' добавлен."; else log_error "   Не удалось добавить '$client_name'."; fi
        fi
    done

    # Генерация файлов .conf и .png для всех клиентов (с Workaround для awgcfg.py бага)
    log "Генерация файлов конфигурации (.conf) и QR-кодов (.png) для клиентов..."
    local temp_conf_backup="${TARGET_HOME}/.${CONFIG_FILE##*/}.bak_$(date +%s)" # Временное имя
    local mv_failed=0
    if [ -f "$CONFIG_FILE" ]; then mv "$CONFIG_FILE" "$temp_conf_backup" || { log_warn "Workaround: Не удалось переместить $CONFIG_FILE."; mv_failed=1; }; fi
    log_debug "Workaround: mv_failed=$mv_failed"

    if ! run_awgcfg -c -q; then log_error "Ошибка генерации клиентских файлов (.conf, .png)."; else
        log "Файлы клиентов сгенерированы/обновлены в $AWG_DIR."
        ls -l "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | sed 's/^/  /' | log_msg "INFO"
    fi

    # Workaround: Возвращаем файл конфигурации
    if [ "$mv_failed" -eq 0 ] && [ -f "$temp_conf_backup" ]; then
        mv "$temp_conf_backup" "$CONFIG_FILE" || log_error "Workaround: КРИТИЧЕСКАЯ ОШИБКА! Не удалось вернуть $CONFIG_FILE из бэкапа!"
    fi
    rm -f "$temp_conf_backup" # Удаляем временный файл
    if [ ! -f "$CONFIG_FILE" ]; then log_error "Файл конфигурации $CONFIG_FILE отсутствует после генерации клиентов!"; fi

    secure_files # Применяем права ко всем файлам
    log_step "--- Шаг 6 завершен ---"; echo ""
    update_state 7 # Следующий шаг - 7
}

# --- ШАГ 7: Запуск сервиса и финальная проверка ---
step7_start_service_and_final_check() {
    update_state 7
    log_step "### ШАГ 7: Запуск сервиса AmneziaWG и финальная проверка ###"

    log "Включение автозапуска и запуск сервиса 'awg-quick@awg0'..."
    if systemctl enable --now awg-quick@awg0; then log "Сервис 'awg-quick@awg0' включен и запущен."; else
        log_error "Не удалось включить или запустить сервис 'awg-quick@awg0'!"
        systemctl status awg-quick@awg0 --no-pager -l >&2
        journalctl -u awg-quick@awg0 -n 20 --no-pager --output=cat >&2
        die "Ошибка запуска сервиса."
    fi

    log "Ожидание инициализации сервиса (5 секунд)..."
    sleep 5
    check_service_status || die "Финальная проверка статуса AmneziaWG выявила проблемы."

    log_step "--- Шаг 7 успешно завершен ---"; echo ""
    update_state 99 # Установка завершена
}

# --- ШАГ 99: Завершение установки ---
step99_finish() {
    log_step "### ЗАВЕРШЕНИЕ УСТАНОВКИ ###"
    echo ""
    log "=============================================================================="
    log "          Установка и настройка AmneziaWG УСПЕШНО ЗАВЕРШЕНА!                  "
    log "=============================================================================="
    echo ""
    log "КЛИЕНТСКИЕ ФАЙЛЫ (.conf / .png) находятся в: $AWG_DIR"
    log "Скопируйте их на ваши устройства. Пример копирования .conf файлов:"
    log "  scp ${TARGET_USER}@<IP_СЕРВЕРА>:${AWG_DIR}/*.conf ./"
    echo ""
    log "УПРАВЛЕНИЕ КЛИЕНТАМИ:"
    log "  sudo bash $MANAGE_SCRIPT_PATH help"
    echo ""
    log "ПРОВЕРКА СТАТУСА VPN:"
    log "  systemctl status awg-quick@awg0"
    log "  sudo awg show"
    echo ""
    log "ВАЖНЫЕ ПУТИ:"
    log "  Рабочий каталог:        $AWG_DIR"
    log "  Конфиг установки:     $CONFIG_FILE"
    log "  Конфиг сервера WG:    $SERVER_CONF_FILE"
    log "  Скрипт управления:    $MANAGE_SCRIPT_PATH"
    echo ""

    if [ ! -f "$CONFIG_FILE" ]; then log_error "ВНИМАНИЕ: Файл $CONFIG_FILE отсутствует!"; fi
    cleanup_apt
    log "Удаление временного файла состояния установки ($STATE_FILE)..."
    rm -f "$STATE_FILE" || log_warn "Не удалось удалить $STATE_FILE."
    echo ""
    log "Установка полностью завершена."
    log "=============================================================================="
    echo ""
}

# --- Основной Цикл Выполнения ---
trap 'echo ""; log_error "Установка прервана пользователем (SIGINT)."; exit 1' SIGINT
trap 'echo ""; log_error "Установка прервана (SIGTERM)."; exit 1' SIGTERM

if [ "$HELP" -eq 1 ]; then show_help; fi
if [ "$VERBOSE" -eq 1 ]; then log "Включен режим подробного вывода."; set -x; fi

initialize_setup # Шаг 0, устанавливает current_step

if ! [[ "${current_step:-}" =~ ^[0-9]+$ ]]; then die "Ошибка инициализации: current_step не установлен."; fi

while (( current_step < 99 )); do
    log_debug "Выполнение шага $current_step..."
    case $current_step in
        1) step1_update_system_and_networking ;; # Выход через request_reboot
        2) step2_install_amnezia ;;              # Выход через request_reboot
        3) step3_check_module; current_step=5 ;; # Переход к шагу 5
        5) step5_setup_python_and_scripts; current_step=6 ;; # Переход к шагу 6
        6) step6_generate_configs; current_step=7 ;;         # Переход к шагу 7
        7) step7_start_service_and_final_check; current_step=99 ;; # Переход к шагу 99
        *) die "Критическая ошибка: Неизвестный шаг '$current_step'." ;;
    esac
done

if (( current_step == 99 )); then step99_finish; fi
if [ "$VERBOSE" -eq 1 ]; then set +x; fi

exit 0
