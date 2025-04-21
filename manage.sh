#!/bin/bash

# ==============================================================================
# Скрипт управления пользователями AmneziaWG (Azure Mini Edition)
# Поддержка: Ubuntu 24.04 и 25.04, совместим с awgcfg.py и venv
# Автор: @bivlked (обновлено с поддержкой Ubuntu 25.04 и UX улучшениями)
# Версия: 1.2
# Репозиторий: https://github.com/bivlked/azure
# ==============================================================================

set -o pipefail

# Определяем пользователя и домашнюю директорию
if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME="$(eval echo ~$SUDO_USER)"
else
    TARGET_USER="root"
    TARGET_HOME="/root"
fi

AWG_DIR="$TARGET_HOME/awg"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
VENV_PY="$AWG_DIR/venv/bin/python"
AWGCFG="$AWG_DIR/awgcfg.py"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"
BACKUP_DIR="$AWG_DIR/backups"
NO_COLOR=0

log() {
    local ts="$(date +'%F %T')"
    echo -e "[$ts] $1" | tee -a "$LOG_FILE"
}

err() {
    log "\033[1;31mERROR:\033[0m $1"
    exit 1
}

check_env() {
    [[ ! -x "$VENV_PY" ]] && err "Python в venv не найден: $VENV_PY"
    [[ ! -f "$AWGCFG" ]] && err "Скрипт awgcfg.py не найден: $AWGCFG"
    [[ ! -f "$SERVER_CONF_FILE" ]] && err "Конфигурация сервера не найдена: $SERVER_CONF_FILE"
    command -v awg >/dev/null || err "Команда 'awg' не найдена в системе"
}

run_cfg() {
    cd "$AWG_DIR" || err "Ошибка cd $AWG_DIR"
    "$VENV_PY" "$AWGCFG" "$@" || err "Ошибка awgcfg $*"
}

list_clients() {
    log "Список клиентов:"
    grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort
}

add_client() {
    local name="$1"
    [[ -z "$name" ]] && err "Имя клиента не указано"
    grep -q "#_Name = $name" "$SERVER_CONF_FILE" && err "Клиент '$name' уже существует"
    run_cfg -a "$name"
    run_cfg -c -q
    log "Клиент '$name' добавлен. Перезапустите сервис: sudo systemctl restart awg-quick@awg0"
}

remove_client() {
    local name="$1"
    [[ -z "$name" ]] && err "Имя клиента не указано"
    grep -q "#_Name = $name" "$SERVER_CONF_FILE" || err "Клиент '$name' не найден"
    run_cfg -d "$name"
    rm -f "$AWG_DIR/$name.conf" "$AWG_DIR/$name.png"
    log "Клиент '$name' удалён. Перезапустите сервис."
}

backup_configs() {
    mkdir -p "$BACKUP_DIR"
    local bname="awg_backup_$(date +%F_%H%M%S).tar.gz"
    tar -czf "$BACKUP_DIR/$bname" -C "$AWG_DIR" . -C /etc/amnezia amneziawg
    log "Бэкап создан: $BACKUP_DIR/$bname"
}

restore_backup() {
    local file="$1"
    [[ -z "$file" || ! -f "$file" ]] && err "Файл бэкапа не указан или не существует"
    systemctl stop awg-quick@awg0 || true
    tar -xzf "$file" -C /
    log "Восстановление завершено. Перезапустите сервис."
}

show_status() {
    systemctl status awg-quick@awg0 --no-pager || echo "Сервис не запущен"
    awg show || echo "Команда awg не выполнена"
}

usage() {
    echo "\nAmneziaWG Management Script (v1.2)"
    echo "=================================="
    echo "Доступные команды:"
    echo "  add <имя>         — добавить клиента"
    echo "  remove <имя>      — удалить клиента"
    echo "  list              — список клиентов"
    echo "  backup            — создать бэкап"
    echo "  restore <файл>    — восстановить из бэкапа"
    echo "  status            — статус VPN-сервиса"
    echo "  help              — показать справку"
    echo "\nПример: sudo bash manage.sh add my_laptop"
}

# --- Главный блок ---
check_env
CMD="$1"; shift || true
case "$CMD" in
    add) add_client "$1" ;;
    remove) remove_client "$1" ;;
    list) list_clients ;;
    backup) backup_configs ;;
    restore) restore_backup "$1" ;;
    status|check) show_status ;;
    help|*) usage ;;
esac
exit 0
