#!/bin/bash

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG на Ubuntu 24.04/25.04
# Версия Azure Mini (для стандартного пользователя + sudo)
# Автор: @bivlked
# Версия: 1.2 (Azure Mini - Ubuntu 24.04+)
# Дата: 2025-04-21
# Репозиторий: https://github.com/bivlked/azure
# ==============================================================================

set -o pipefail

# --- Определение пользователя ---
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME=$(eval echo "~$SUDO_USER")
else
    TARGET_USER="root"
    TARGET_HOME="/root"
fi

AWG_DIR="$TARGET_HOME/awg"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
LOG_FILE="$AWG_DIR/install_amneziawg.log"
STATE_FILE="$AWG_DIR/setup_state"

log_msg() {
    local type="$1"; local msg="$2"; local ts=$(date +'%F %T')
    echo "[$ts] $type: $msg" | tee -a "$LOG_FILE"
}
log() { log_msg INFO "$1"; }
die() { log_msg ERROR "$1"; exit 1; }

check_os_version() {
    log "Проверка ОС..."
    if ! command -v lsb_release &> /dev/null; then
        log "lsb_release не найден. Продолжение..."
        return 0
    fi
    local os_id=$(lsb_release -si)
    local os_ver=$(lsb_release -sr)
    local os_codename=$(lsb_release -sc)
    if [[ "$os_id" != "Ubuntu" ]]; then
        log "Неподдерживаемая ОС: $os_id $os_ver"
        read -p "Продолжить? [y/N]: " confirm < /dev/tty
        [[ "$confirm" =~ ^[Yy]$ ]] || die "Отменено."
        return
    fi
    if [[ "$os_ver" != "24.04" ]]; then
        log "Обнаружена Ubuntu $os_ver ($os_codename)"
        if [[ "$os_codename" == "plucky" ]]; then
            read -p "Заменить 'plucky' на 'noble' в PPA? [y/N]: " confirm < /dev/tty
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                for f in /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.*; do
                    [[ -f "$f" ]] && sed -i 's/plucky/noble/g' "$f" && log "Обновлён: $f"
                done
                apt update -y || log "Ошибка обновления apt"
            fi
        fi
        read -p "Продолжить установку на Ubuntu $os_ver? [y/N]: " confirm2 < /dev/tty
        [[ "$confirm2" =~ ^[Yy]$ ]] || die "Отменено."
    else
        log "Ubuntu $os_ver подтверждена."
    fi
}

install_packages() {
    local packages=($@)
    local to_install=()
    for pkg in "${packages[@]}"; do
        dpkg -s "$pkg" &> /dev/null || to_install+=("$pkg")
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        log "Все пакеты уже установлены."
        return
    fi
    apt update -y
    DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}" || die "Ошибка установки пакетов: ${to_install[*]}"
}

step2_install_amnezia() {
    log "### ШАГ 2: Установка AmneziaWG ###"
    local ppa_exists=$(grep -h "amnezia" /etc/apt/sources.list.d/* 2>/dev/null | wc -l)
    if [ "$ppa_exists" -eq 0 ]; then
        add-apt-repository -y ppa:amnezia/ppa || die "Ошибка добавления PPA"
        apt update -y
    fi
    install_packages amneziawg-dkms amneziawg-tools wireguard-tools dkms linux-headers-$(uname -r) build-essential dpkg-dev

    if ! apt-cache show amneziawg-tools &>/dev/null; then
        log "Пакет 'amneziawg-tools' не найден."
        read -p "Скачать и установить вручную из Ubuntu 24.04? [y/N]: " download_confirm < /dev/tty
        if [[ "$download_confirm" =~ ^[Yy]$ ]]; then
            tmp_deb="/tmp/amneziawg-tools.deb"
            wget -O "$tmp_deb" "https://launchpad.net/~amnezia/+archive/ubuntu/ppa/+files/amneziawg-tools_1.4.6+noble_all.deb" || die "Ошибка загрузки .deb"
            dpkg -i "$tmp_deb" || die "Ошибка установки .deb"
            rm -f "$tmp_deb"
        else
            die "Невозможно продолжить без amneziawg-tools."
        fi
    fi
    log "Установка AmneziaWG завершена."
}

# --- Основной блок ---
mkdir -p "$AWG_DIR" && touch "$LOG_FILE"
check_os_version
step2_install_amnezia
log "Готово. Продолжите следующие шаги установки по скрипту."
exit 0
