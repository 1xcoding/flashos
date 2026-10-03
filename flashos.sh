#!/usr/bin/env bash

# ============================================================
# FlashOS Manager
# Version 0.3.0
#
# SINGLE FILE EDITION
#
# Repository:
# https://github.com/lionsuperpromax/flashos
#
# Возможности:
#   - Поиск USB
#   - Обнаружение FlashOS
#   - Установка FlashOS
#   - Форматирование exFAT
#   - Главный пароль FlashOS
#   - Зашифрованное хранилище
#   - Vault Mode
#   - Backup
#   - Diagnostics
#   - Settings
#   - GitHub Update
#   - Remove FlashOS
#   - Arrow-key TUI
# ============================================================

set -u

# ============================================================
# CONFIG
# ============================================================

APP_NAME="FlashOS Manager"
FLASHOS_VERSION="0.3.0"

GITHUB_RAW_URL="https://raw.githubusercontent.com/lionsuperpromax/flashos/main/flashos.sh"

RUNTIME_BASE="${XDG_RUNTIME_DIR:-/tmp}/flashos-${UID}"

MAIN_MOUNT="$RUNTIME_BASE/main"
VAULT_MOUNT="$RUNTIME_BASE/vault"

DEVICE=""
DEVICE_MOUNT=""
FLASHOS_DIR=""

CURRENT_VAULT=""

mkdir -p "$RUNTIME_BASE"

# ============================================================
# COLORS
# ============================================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
WHITE='\033[37m'

BOLD='\033[1m'
DIM='\033[2m'

RESET='\033[0m'

# ============================================================
# UI HELPERS
# ============================================================

tty_print() {
    printf '%b\n' "$1" > /dev/tty
}

clear_screen() {
    clear > /dev/tty 2>/dev/null || true
}

info() {
    tty_print "${BLUE}ℹ $1${RESET}"
}

success() {
    tty_print "${GREEN}✅ $1${RESET}"
}

warn() {
    tty_print "${YELLOW}⚠ $1${RESET}"
}

error_msg() {
    tty_print "${RED}❌ $1${RESET}"
}

pause_screen() {
    echo > /dev/tty
    read -rp "Нажми Enter для продолжения..." < /dev/tty
}

header() {

    clear_screen

    echo -e "${CYAN}${BOLD}" > /dev/tty

    echo "╔══════════════════════════════════════════════════════╗" > /dev/tty
    printf "║ %-52s ║\n" "FLASHOS MANAGER" > /dev/tty
    echo "╠══════════════════════════════════════════════════════╣" > /dev/tty
    printf "║ %-52s ║\n" "Version: $FLASHOS_VERSION" > /dev/tty
    echo "╚══════════════════════════════════════════════════════╝" > /dev/tty

    echo -e "${RESET}" > /dev/tty
}

# ============================================================
# ARROW MENU
# ============================================================

arrow_menu() {

    local title="$1"

    shift

    local options=("$@")

    local selected=0
    local key=""
    local sequence=""
    local i

    while true; do

        clear_screen

        echo -e "${CYAN}${BOLD}$title${RESET}" > /dev/tty

        echo > /dev/tty

        for i in "${!options[@]}"; do

            if (( i == selected )); then

                echo -e "  ${CYAN}${BOLD}❯ ${options[$i]}${RESET}" > /dev/tty

            else

                echo -e "    ${options[$i]}" > /dev/tty

            fi

        done

        echo > /dev/tty

        echo -e \
            "${DIM}↑ ↓${RESET} выбор   ${DIM}Enter${RESET} открыть   ${DIM}Esc${RESET} назад" \
            > /dev/tty

        IFS= read -rsn1 key < /dev/tty

        case "$key" in

            "")
                printf '%s\n' "$selected"
                return 0
                ;;

            $'\x1b')

                sequence=""

                IFS= read -rsn2 -t 0.1 sequence < /dev/tty || true

                case "$sequence" in

                    "[A")
                        ((selected--))
                        ;;

                    "[B")
                        ((selected++))
                        ;;

                    *)
                        return 255
                        ;;

                esac
                ;;

            q|Q)

                return 255
                ;;

        esac

        if (( selected < 0 )); then
            selected=$((${#options[@]} - 1))
        fi

        if (( selected >= ${#options[@]} )); then
            selected=0
        fi

    done
}

# ============================================================
# DEPENDENCIES
# ============================================================

check_dependencies() {

    local missing=()

    local cmd

    for cmd in \
        lsblk \
        findmnt \
        udisksctl \
        gocryptfs \
        fusermount3 \
        mkfs.exfat \
        curl \
        bash \
        sort
    do

        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi

    done

    if (( ${#missing[@]} > 0 )); then

        header

        error_msg "Не хватает зависимостей."

        echo > /dev/tty

        for cmd in "${missing[@]}"; do
            echo "  - $cmd" > /dev/tty
        done

        echo > /dev/tty

        echo "Для CachyOS / Arch Linux:" > /dev/tty

        echo \
            "sudo pacman -S udisks2 gocryptfs fuse3 exfatprogs curl" \
            > /dev/tty

        exit 1
    fi
}

# ============================================================
# USB DETECTION
# ============================================================

is_removable_partition() {

    local dev="$1"

    [[ -b "$dev" ]] || return 1

    local type

    type=$(lsblk -ndo TYPE "$dev" 2>/dev/null || true)

    [[ "$type" == "part" ]] || return 1

    local parent

    parent=$(lsblk -no PKNAME "$dev" 2>/dev/null \
        | head -n1 || true)

    [[ -n "$parent" ]] || return 1

    local removable

    removable=$(cat \
        "/sys/class/block/$parent/removable" \
        2>/dev/null || echo 0)

    [[ "$removable" == "1" ]]
}

get_usb_partitions() {

    local dev

    while read -r dev; do

        [[ -n "$dev" ]] || continue

        if is_removable_partition "$dev"; then
            printf '%s\n' "$dev"
        fi

    done < <(lsblk -nrpo NAME)
}

mount_usb() {

    local dev="$1"

    local mountpoint

    mountpoint=$(findmnt \
        -rn \
        -S "$dev" \
        -o TARGET \
        2>/dev/null || true)

    if [[ -n "$mountpoint" ]]; then

        printf '%s|%s\n' \
            "$dev" \
            "$mountpoint"

        return 0
    fi

    if udisksctl mount \
        -b "$dev" \
        >/dev/null 2>&1
    then

        mountpoint=$(findmnt \
            -rn \
            -S "$dev" \
            -o TARGET \
            2>/dev/null || true)

        if [[ -n "$mountpoint" ]]; then

            printf '%s|%s\n' \
                "$dev" \
                "$mountpoint"

            return 0
        fi
    fi

    return 1
}

# ============================================================
# FLASHOS DETECTION
# ============================================================

detect_flashos() {

    DEVICE=""
    DEVICE_MOUNT=""
    FLASHOS_DIR=""

    local dev
    local result

    while read -r dev; do

        [[ -n "$dev" ]] || continue

        if ! is_removable_partition "$dev"; then
            continue
        fi

        result=$(mount_usb "$dev" 2>/dev/null || true)

        [[ -n "$result" ]] || continue

        IFS='|' read -r \
            DEVICE \
            DEVICE_MOUNT <<< "$result"

        if [[ -f "$DEVICE_MOUNT/.flashos/manifest" ]]; then

            FLASHOS_DIR="$DEVICE_MOUNT/.flashos"

            return 0
        fi

    done < <(get_usb_partitions)

    return 1
}

# ============================================================
# MANIFEST
# ============================================================

get_manifest() {

    local key="$1"

    [[ -f "$FLASHOS_DIR/manifest" ]] || return 0

    grep -m1 \
        "^${key}=" \
        "$FLASHOS_DIR/manifest" \
        2>/dev/null \
        | cut -d= -f2-
}

write_manifest() {

    local name="$1"
    local version="$2"

    cat > "$FLASHOS_DIR/manifest" <<EOF_MANIFEST
FLASHOS_FORMAT=FlashOS
FLASHOS_VERSION=$version
DEVICE_NAME=$name
FILESYSTEM=exFAT
SECURITY=gocryptfs
MANAGER=flashos.sh
MANAGER_SOURCE=$GITHUB_RAW_URL
UPDATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF_MANIFEST
}

# ============================================================
# FORMAT CONFIRMATION
# ============================================================

confirm_format() {

    local target="$1"

    local size
    local model
    local filesystem
    local label
    local parent

    size=$(lsblk -ndo SIZE "$target" \
        2>/dev/null || echo "?")

    model=$(lsblk -ndo MODEL "$target" \
        2>/dev/null || echo "?")

    filesystem=$(lsblk -ndo FSTYPE "$target" \
        2>/dev/null || echo "?")

    label=$(lsblk -ndo LABEL "$target" \
        2>/dev/null || echo "")

    parent=$(lsblk -no PKNAME "$target" \
        2>/dev/null \
        | head -n1 || echo "?")

    header

    echo -e \
        "${RED}${BOLD}⚠ ОПАСНАЯ ОПЕРАЦИЯ: ФОРМАТИРОВАНИЕ${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo "Раздел:      $target" > /dev/tty
    echo "Диск:        /dev/${parent:-?}" > /dev/tty
    echo "Размер:      $size" > /dev/tty
    echo "Модель:      ${model:-?}" > /dev/tty
    echo "FS сейчас:   ${filesystem:-?}" > /dev/tty
    echo "Label:       ${label:-<none>}" > /dev/tty

    echo > /dev/tty

    echo -e \
        "${RED}${BOLD}ВСЕ ДАННЫЕ НА ЭТОМ РАЗДЕЛЕ БУДУТ УДАЛЕНЫ.${RESET}" \
        > /dev/tty

    echo > /dev/tty

    read -rp \
        "Введи FORMAT: " \
        answer < /dev/tty

    [[ "$answer" == "FORMAT" ]] || return 1

    echo > /dev/tty

    read -rp \
        "Введи FLASHOS-YES: " \
        answer2 < /dev/tty

    [[ "$answer2" == "FLASHOS-YES" ]]
}

# ============================================================
# FORMAT USB
# ============================================================

format_usb() {

    local target="$1"
    local label="$2"

    header

    echo -e "${BOLD}💿 FORMAT USB${RESET}" > /dev/tty

    echo > /dev/tty

    info "Размонтирую $target..."

    udisksctl unmount \
        -b "$target" \
        >/dev/null 2>&1 || true

    local mounted

    mounted=$(findmnt \
        -rn \
        -S "$target" \
        -o TARGET \
        2>/dev/null || true)

    if [[ -n "$mounted" ]]; then

        sudo umount "$mounted" \
            >/dev/null 2>&1 || true
    fi

    mounted=$(findmnt \
        -rn \
        -S "$target" \
        -o TARGET \
        2>/dev/null || true)

    if [[ -n "$mounted" ]]; then

        error_msg \
            "Не удалось размонтировать $target."

        return 1
    fi

    echo > /dev/tty

    echo "Форматирование в exFAT..." > /dev/tty

    if sudo mkfs.exfat \
        -F \
        -n "$label" \
        "$target"
    then

        sync

        echo > /dev/tty

        success "Форматирование завершено."

        return 0
    fi

    error_msg "Форматирование не удалось."

    return 1
}

# ============================================================
# INSTALL FLASHOS
# ============================================================

install_flashos() {

    header

    echo -e "${BOLD}🚀 УСТАНОВКА FLASHOS${RESET}" > /dev/tty

    echo > /dev/tty

    local devices=()
    local dev

    while read -r dev; do

        [[ -n "$dev" ]] || continue

        devices+=("$dev")

    done < <(get_usb_partitions)

    if (( ${#devices[@]} == 0 )); then

        error_msg "USB-флешка не найдена."

        pause_screen

        return
    fi

    local options=()

    local size
    local filesystem
    local label
    local model

    for dev in "${devices[@]}"; do

        size=$(lsblk \
            -ndo SIZE \
            "$dev" \
            2>/dev/null || echo "?")

        filesystem=$(lsblk \
            -ndo FSTYPE \
            "$dev" \
            2>/dev/null || echo "?")

        label=$(lsblk \
            -ndo LABEL \
            "$dev" \
            2>/dev/null || echo "")

        model=$(lsblk \
            -ndo MODEL \
            "$dev" \
            2>/dev/null || echo "")

        options+=(
            "$dev | $size | ${label:-no-label} | ${filesystem:-unknown} | ${model:-USB}"
        )

    done

    options+=("Отмена")

    local selected

    selected=$(arrow_menu \
        "💾 ВЫБЕРИ ФЛЕШКУ" \
        "${options[@]}")

    [[ "$selected" != "255" ]] || return

    if (( selected >= ${#devices[@]} )); then
        return
    fi

    DEVICE="${devices[$selected]}"

    if ! confirm_format "$DEVICE"; then

        warn "Установка отменена."

        pause_screen

        return
    fi

    header

    local device_name

    read -rp \
        "Имя FlashOS [FLASHOS]: " \
        device_name < /dev/tty

    [[ -n "$device_name" ]] || device_name="FLASHOS"

    device_name="${device_name//\//_}"
    device_name="${device_name:0:15}"

    [[ -n "$device_name" ]] || device_name="FLASHOS"

    if ! format_usb \
        "$DEVICE" \
        "$device_name"
    then

        pause_screen

        return
    fi

    info "Подключаю новую файловую систему..."

    if ! udisksctl mount \
        -b "$DEVICE" \
        >/dev/null 2>&1
    then

        error_msg \
            "Не удалось подключить флешку."

        pause_screen

        return
    fi

    DEVICE_MOUNT=$(findmnt \
        -rn \
        -S "$DEVICE" \
        -o TARGET \
        2>/dev/null || true)

    if [[ -z "$DEVICE_MOUNT" ]]; then

        error_msg "Mount point не найден."

        pause_screen

        return
    fi

    FLASHOS_DIR="$DEVICE_MOUNT/.flashos"

    header

    echo -e \
        "${CYAN}${BOLD}TRANSFORMATION OF USB${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo "[1/8] System" > /dev/tty

    mkdir -p \
        "$FLASHOS_DIR/system"

    echo "[2/8] Packages" > /dev/tty

    mkdir -p \
        "$FLASHOS_DIR/packages" \
        "$FLASHOS_DIR/packages/installed" \
        "$FLASHOS_DIR/packages/cache" \
        "$FLASHOS_DIR/packages/repository"

    echo "[3/8] Recovery" > /dev/tty

    mkdir -p \
        "$FLASHOS_DIR/recovery"

    echo "[4/8] Logs" > /dev/tty

    mkdir -p \
        "$FLASHOS_DIR/logs"

    echo "[5/8] Vaults" > /dev/tty

    mkdir -p \
        "$FLASHOS_DIR/vaults"

    echo "[6/8] Encrypted storage" > /dev/tty

    mkdir -p \
        "$FLASHOS_DIR/data"

    echo > /dev/tty

    echo -e \
        "${YELLOW}${BOLD}🔐 СОЗДАНИЕ ГЛАВНОГО ПАРОЛЯ FLASHOS${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Этот пароль будет использоваться на других ПК." \
        > /dev/tty

    echo > /dev/tty

    if ! gocryptfs -init \
        "$FLASHOS_DIR/data"
    then

        error_msg \
            "Не удалось создать зашифрованное хранилище."

        pause_screen

        return
    fi

    echo "[7/8] Manifest" > /dev/tty

    write_manifest \
        "$device_name" \
        "$FLASHOS_VERSION"

    echo "[8/8] FlashOS Manager" > /dev/tty

    # Кладём единственный менеджер на саму FlashOS.
    cp -- \
        "$0" \
        "$FLASHOS_DIR/flashos.sh"

    chmod 755 \
        "$FLASHOS_DIR/flashos.sh"

    cat > "$FLASHOS_DIR/readme.txt" <<EOF_README
FlashOS
=======

Device: $device_name
Version: $FLASHOS_VERSION

Use FlashOS Manager.

The .flashos directory contains the FlashOS system.
Do not modify it manually.
EOF_README

    sync

    echo > /dev/tty

    success "FlashOS установлен."

    echo "Имя:          $device_name" > /dev/tty
    echo "Version:      $FLASHOS_VERSION" > /dev/tty
    echo "Filesystem:   exFAT" > /dev/tty
    echo "Encryption:   gocryptfs" > /dev/tty

    pause_screen
}

# ============================================================
# FLASHOS UNLOCK
# ============================================================

unlock_flashos() {

    mkdir -p "$MAIN_MOUNT"

    if mountpoint -q "$MAIN_MOUNT" 2>/dev/null; then

        return 0
    fi

    if [[ ! -f \
        "$FLASHOS_DIR/data/gocryptfs.conf"
    ]]; then

        error_msg \
            "Зашифрованное хранилище не найдено."

        return 1
    fi

    header

    echo -e \
        "${BOLD}🔐 FLASHOS LOCKED${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "FlashOS: $(get_manifest DEVICE_NAME)" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Введите главный пароль FlashOS." \
        > /dev/tty

    echo > /dev/tty

    if gocryptfs \
        "$FLASHOS_DIR/data" \
        "$MAIN_MOUNT"
    then

        success "FlashOS разблокирован."

        return 0
    fi

    error_msg \
        "Неверный пароль или повреждённое хранилище."

    return 1
}

# ============================================================
# LOCK
# ============================================================

lock_flashos() {

    if mountpoint -q \
        "$VAULT_MOUNT" \
        2>/dev/null
    then

        fusermount3 \
            -u \
            "$VAULT_MOUNT" \
            >/dev/null 2>&1 || true

    fi

    if mountpoint -q \
        "$MAIN_MOUNT" \
        2>/dev/null
    then

        fusermount3 \
            -u \
            "$MAIN_MOUNT" \
            >/dev/null 2>&1 || true

    fi

    rm -rf \
        "$VAULT_MOUNT" \
        "$MAIN_MOUNT"

    CURRENT_VAULT=""
}

# ============================================================
# FILES
# ============================================================

files_menu() {

    while true; do

        local selected

        selected=$(arrow_menu \
            "📁 FILES" \
            "📂 Открыть хранилище" \
            "📄 Показать содержимое" \
            "⬅ Назад")

        case "$selected" in

            0)

                if command -v xdg-open \
                    >/dev/null 2>&1
                then

                    xdg-open \
                        "$MAIN_MOUNT" \
                        >/dev/null 2>&1 &

                fi
                ;;

            1)

                header

                echo -e \
                    "${BOLD}📁 FLASHOS STORAGE${RESET}" \
                    > /dev/tty

                echo > /dev/tty

                find \
                    "$MAIN_MOUNT" \
                    -maxdepth 2 \
                    -mindepth 1 \
                    -print \
                    2>/dev/null \
                    > /dev/tty

                pause_screen
                ;;

            2|255)

                return
                ;;

        esac

    done
}

# ============================================================
# VAULT
# ============================================================

list_vaults() {

    mkdir -p \
        "$MAIN_MOUNT/vaults"

    find \
        "$MAIN_MOUNT/vaults" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name "*.vault" \
        -printf "%f\n" \
        2>/dev/null \
        | sed 's/\.vault$//'
}

create_vault() {

    header

    echo -e \
        "${BOLD}🔐 CREATE VAULT${RESET}" \
        > /dev/tty

    echo > /dev/tty

    local name

    read -rp \
        "Название Vault: " \
        name < /dev/tty

    [[ -n "$name" ]] || return

    name="${name// /_}"
    name="${name//\//_}"

    local cipher

    cipher="$MAIN_MOUNT/vaults/${name}.vault"

    mkdir -p \
        "$MAIN_MOUNT/vaults"

    if [[ -e "$cipher" ]]; then

        error_msg \
            "Такой Vault уже существует."

        pause_screen

        return
    fi

    mkdir -p "$cipher"

    echo > /dev/tty

    echo \
        "Придумай пароль Vault." \
        > /dev/tty

    echo > /dev/tty

    if ! gocryptfs \
        -init \
        "$cipher"
    then

        error_msg \
            "Не удалось создать Vault."

        rm -rf "$cipher"

        pause_screen

        return
    fi

    success "Vault создан."

    echo > /dev/tty

    local source

    read -rp \
        "Папка для переноса (Enter = пропустить): " \
        source < /dev/tty

    if [[ -n "$source" ]]; then

        if [[ ! -d "$source" ]]; then

            error_msg "Папка не найдена."

            pause_screen

            return
        fi

        rm -rf \
            "$VAULT_MOUNT"

        mkdir -p \
            "$VAULT_MOUNT"

        echo \
            "🔓 Открываю Vault..." \
            > /dev/tty

        if gocryptfs \
            "$cipher" \
            "$VAULT_MOUNT"
        then

            echo \
                "📦 Копирую данные..." \
                > /dev/tty

            if cp -a \
                "$source" \
                "$VAULT_MOUNT/"
            then

                success \
                    "Папка скопирована и зашифрована."

            else

                error_msg \
                    "Ошибка копирования."

            fi

            sync

            fusermount3 \
                -u \
                "$VAULT_MOUNT" \
                >/dev/null 2>&1 || true

            rm -rf \
                "$VAULT_MOUNT"

        else

            error_msg \
                "Не удалось открыть Vault."

        fi

    fi

    pause_screen
}

open_vault() {

    local vaults

    vaults=$(list_vaults)

    if [[ -z "$vaults" ]]; then

        warn "Vault пока нет."

        pause_screen

        return
    fi

    local options=()
    local vault

    while read -r vault; do

        [[ -n "$vault" ]] || continue

        options+=(
            "🔐 $vault"
        )

    done <<< "$vaults"

    options+=(
        "⬅ Назад"
    )

    local selected

    selected=$(arrow_menu \
        "🔐 VAULTS" \
        "${options[@]}")

    [[ "$selected" != "255" ]] || return

    if (( selected >= ${#options[@]} - 1 )); then
        return
    fi

    local selected_vault

    selected_vault=$(printf '%s\n' "$vaults" \
        | sed -n "$((selected + 1))p")

    local cipher

    cipher="$MAIN_MOUNT/vaults/${selected_vault}.vault"

    rm -rf "$VAULT_MOUNT"

    mkdir -p "$VAULT_MOUNT"

    header

    echo -e \
        "${BOLD}🔐 OPEN VAULT: $selected_vault${RESET}" \
        > /dev/tty

    echo > /dev/tty

    if ! gocryptfs \
        "$cipher" \
        "$VAULT_MOUNT"
    then

        error_msg \
            "Неверный пароль или повреждённый Vault."

        rm -rf "$VAULT_MOUNT"

        pause_screen

        return
    fi

    success "Vault открыт."

    while true; do

        local action

        action=$(arrow_menu \
            "🔐 VAULT: $selected_vault" \
            "📂 Открыть" \
            "📄 Показать содержимое" \
            "🔒 Закрыть Vault")

        case "$action" in

            0)

                if command -v xdg-open \
                    >/dev/null 2>&1
                then

                    xdg-open \
                        "$VAULT_MOUNT" \
                        >/dev/null 2>&1 &

                fi
                ;;

            1)

                header

                find \
                    "$VAULT_MOUNT" \
                    -maxdepth 2 \
                    -mindepth 1 \
                    -print \
                    2>/dev/null \
                    > /dev/tty

                pause_screen
                ;;

            2|255)

                fusermount3 \
                    -u \
                    "$VAULT_MOUNT" \
                    >/dev/null 2>&1 || true

                rm -rf \
                    "$VAULT_MOUNT"

                success \
                    "Vault закрыт."

                pause_screen

                return
                ;;

        esac

    done
}

vault_menu() {

    while true; do

        local selected

        selected=$(arrow_menu \
            "🔐 VAULT MODE" \
            "Создать Vault" \
            "Открыть Vault" \
            "Назад")

        case "$selected" in

            0)
                create_vault
                ;;

            1)
                open_vault
                ;;

            2|255)
                return
                ;;

        esac

    done
}

# ============================================================
# BACKUP
# ============================================================

backup_menu() {

    mkdir -p \
        "$MAIN_MOUNT/Backups"

    while true; do

        local selected

        selected=$(arrow_menu \
            "💾 BACKUP" \
            "Создать Backup" \
            "Показать Backup" \
            "Назад")

        case "$selected" in

            0)

                header

                local source

                read -rp \
                    "Путь к папке: " \
                    source < /dev/tty

                if [[ ! -d "$source" ]]; then

                    error_msg \
                        "Папка не найдена."

                    pause_screen

                    continue
                fi

                local timestamp

                timestamp=$(date \
                    '+%Y-%m-%d_%H-%M-%S')

                local destination

                destination="$MAIN_MOUNT/Backups/$timestamp"

                mkdir -p \
                    "$destination"

                if cp -a \
                    "$source" \
                    "$destination/"
                then

                    success \
                        "Backup создан."

                else

                    error_msg \
                        "Ошибка Backup."

                fi

                sync

                pause_screen

                ;;

            1)

                header

                find \
                    "$MAIN_MOUNT/Backups" \
                    -maxdepth 3 \
                    -mindepth 1 \
                    -type d \
                    2>/dev/null \
                    > /dev/tty

                pause_screen

                ;;

            2|255)

                return
                ;;

        esac

    done
}

# ============================================================
# DIAGNOSTICS
# ============================================================

diagnostics_menu() {

    while true; do

        local selected

        selected=$(arrow_menu \
            "🩺 DIAGNOSTICS" \
            "Информация об устройстве" \
            "Проверить структуру FlashOS" \
            "Показать место" \
            "Назад")

        case "$selected" in

            0)

                header

                echo "Device:      $DEVICE" > /dev/tty
                echo "Mount:       $DEVICE_MOUNT" > /dev/tty

                echo > /dev/tty

                echo "Size:        $(lsblk -ndo SIZE "$DEVICE" 2>/dev/null)" \
                    > /dev/tty

                echo "Filesystem:  $(lsblk -ndo FSTYPE "$DEVICE" 2>/dev/null)" \
                    > /dev/tty

                echo "Label:       $(lsblk -ndo LABEL "$DEVICE" 2>/dev/null)" \
                    > /dev/tty

                echo "Model:       $(lsblk -ndo MODEL "$DEVICE" 2>/dev/null)" \
                    > /dev/tty

                echo > /dev/tty

                echo "FlashOS:     $(get_manifest DEVICE_NAME)" > /dev/tty
                echo "Version:     $(get_manifest FLASHOS_VERSION)" > /dev/tty
                echo "Security:    $(get_manifest SECURITY)" > /dev/tty

                pause_screen

                ;;

            1)

                header

                local path

                local required_paths=(

                    "$FLASHOS_DIR/manifest"
                    "$FLASHOS_DIR/system"
                    "$FLASHOS_DIR/packages"
                    "$FLASHOS_DIR/recovery"
                    "$FLASHOS_DIR/logs"
                    "$FLASHOS_DIR/vaults"
                    "$FLASHOS_DIR/data"
                    "$FLASHOS_DIR/flashos.sh"

                )

                for path in "${required_paths[@]}"; do

                    if [[ -e "$path" ]]; then
                        success "$path"
                    else
                        error_msg "Missing: $path"
                    fi

                done

                pause_screen

                ;;

            2)

                header

                df -h \
                    "$DEVICE_MOUNT" \
                    > /dev/tty

                echo > /dev/tty

                du -sh \
                    "$FLASHOS_DIR" \
                    2>/dev/null \
                    > /dev/tty || true

                pause_screen

                ;;

            3|255)

                return
                ;;

        esac

    done
}

# ============================================================
# SETTINGS
# ============================================================

settings_menu() {

    while true; do

        local selected

        selected=$(arrow_menu \
            "⚙ SETTINGS" \
            "Изменить имя FlashOS" \
            "Показать manifest" \
            "Назад")

        case "$selected" in

            0)

                header

                local new_name

                read -rp \
                    "Новое имя: " \
                    new_name < /dev/tty

                if [[ -n "$new_name" ]]; then

                    new_name="${new_name//\//_}"
                    new_name="${new_name:0:15}"

                    write_manifest \
                        "$new_name" \
                        "$(get_manifest FLASHOS_VERSION)"

                    success \
                        "Имя изменено на $new_name."
                fi

                pause_screen

                ;;

            1)

                header

                cat \
                    "$FLASHOS_DIR/manifest" \
                    > /dev/tty

                pause_screen

                ;;

            2|255)

                return
                ;;

        esac

    done
}

# ============================================================
# GITHUB UPDATE
# ============================================================

get_remote_version() {

    curl \
        -fsSL \
        --connect-timeout 8 \
        --max-time 20 \
        "$GITHUB_RAW_URL" \
        2>/dev/null \
        | sed \
            -n \
            's/^FLASHOS_VERSION="\([0-9][0-9.]*\)"/\1/p' \
        | head -n1
}

version_gt() {

    local a="$1"
    local b="$2"

    [[ "$a" != "$b" ]] || return 1

    [[ \
        "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" \
        == "$a"
    ]]
}

download_update() {

    local output="$1"

    curl \
        -fL \
        --connect-timeout 8 \
        --max-time 60 \
        --progress-bar \
        "$GITHUB_RAW_URL" \
        -o "$output"
}

update_flashos() {

    header

    echo -e \
        "${BOLD}🔄 FLASHOS UPDATE${RESET}" \
        > /dev/tty

    echo > /dev/tty

    info "Проверяю GitHub..."

    local remote_version

    remote_version=$(get_remote_version || true)

    local local_version

    local_version=$(get_manifest FLASHOS_VERSION)

    if [[ -z "$remote_version" ]]; then

        error_msg \
            "Не удалось получить версию с GitHub."

        pause_screen

        return
    fi

    echo \
        "Установлено: $local_version" \
        > /dev/tty

    echo \
        "GitHub:      $remote_version" \
        > /dev/tty

    echo > /dev/tty

    if [[ "$local_version" == "$remote_version" ]]; then

        success \
            "FlashOS уже последней версии."

        pause_screen

        return
    fi

    if ! version_gt \
        "$remote_version" \
        "$local_version"
    then

        warn \
            "GitHub-версия не новее текущей."

        pause_screen

        return
    fi

    warn \
        "Доступно обновление: $local_version → $remote_version"

    echo > /dev/tty

    echo \
        "Обновляется только системный manager." \
        > /dev/tty

    echo \
        "Зашифрованные данные, Vault и Backup не заменяются." \
        > /dev/tty

    echo > /dev/tty

    read -rp \
        "Продолжить? [y/N]: " \
        answer < /dev/tty

    [[ "${answer,,}" == "y" ]] || return

    local temp_file

    temp_file="$RUNTIME_BASE/flashos-update.sh"

    rm -f "$temp_file"

    echo > /dev/tty

    echo \
        "⬇ Скачиваю flashos.sh..." \
        > /dev/tty

    if ! download_update \
        "$temp_file"
    then

        error_msg \
            "Не удалось скачать обновление."

        rm -f "$temp_file"

        pause_screen

        return
    fi

    echo > /dev/tty

    echo \
        "🧪 Проверяю Bash syntax..." \
        > /dev/tty

    if ! bash -n \
        "$temp_file"
    then

        error_msg \
            "Скачанный файл не прошёл syntax check."

        rm -f "$temp_file"

        pause_screen

        return
    fi

    local downloaded_version

    downloaded_version=$(sed \
        -n \
        's/^FLASHOS_VERSION="\([0-9][0-9.]*\)"/\1/p' \
        "$temp_file" \
        | head -n1)

    if [[ \
        "$downloaded_version" != \
        "$remote_version"
    ]]; then

        error_msg \
            "Версия скачанного файла не совпала с GitHub."

        rm -f "$temp_file"

        pause_screen

        return
    fi

    local backup_dir

    backup_dir="$FLASHOS_DIR/recovery/manager-backups"

    mkdir -p \
        "$backup_dir"

    if [[ \
        -f "$FLASHOS_DIR/flashos.sh"
    ]]; then

        cp -a \
            "$FLASHOS_DIR/flashos.sh" \
            "$backup_dir/flashos-${local_version}-$(date '+%Y%m%d-%H%M%S').sh"

    fi

    chmod 755 \
        "$temp_file"

    mv -f \
        "$temp_file" \
        "$FLASHOS_DIR/flashos.sh"

    chmod 755 \
        "$FLASHOS_DIR/flashos.sh"

    write_manifest \
        "$(get_manifest DEVICE_NAME)" \
        "$remote_version"

    sync

    echo > /dev/tty

    success \
        "FlashOS обновлён до версии $remote_version."

    echo > /dev/tty

    read -rp \
        "Запустить новую версию сейчас? [Y/n]: " \
        restart < /dev/tty

    if [[ \
        -z "$restart" || \
        "${restart,,}" == "y"
    ]]; then

        exec bash \
            "$FLASHOS_DIR/flashos.sh"

    fi

    pause_screen
}

# ============================================================
# REMOVE FLASHOS
# ============================================================

remove_flashos() {

    header

    echo -e \
        "${RED}${BOLD}🗑 REMOVE FLASHOS${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Будет полностью очищен раздел:" \
        > /dev/tty

    echo \
        "$DEVICE" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Будут удалены:" \
        > /dev/tty

    echo \
        "  • FlashOS" \
        > /dev/tty

    echo \
        "  • зашифрованные данные" \
        > /dev/tty

    echo \
        "  • Vault" \
        > /dev/tty

    echo \
        "  • Backup" \
        > /dev/tty

    echo > /dev/tty

    echo -e \
        "${RED}${BOLD}ВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ.${RESET}" \
        > /dev/tty

    echo > /dev/tty

    local first

    read -rp \
        "Введи REMOVE FLASHOS: " \
        first < /dev/tty

    if [[ "$first" != "REMOVE FLASHOS" ]]; then

        warn "Удаление отменено."

        pause_screen

        return
    fi

    local second

    read -rp \
        "Введи DELETE-ALL: " \
        second < /dev/tty

    if [[ "$second" != "DELETE-ALL" ]]; then

        warn "Удаление отменено."

        pause_screen

        return
    fi

    lock_flashos

    if ! format_usb \
        "$DEVICE" \
        "USB"
    then

        pause_screen

        return
    fi

    success \
        "FlashOS удалён."

    success \
        "Флешка очищена и отформатирована в exFAT."

    pause_screen
}

# ============================================================
# WORK MENU
# ============================================================

work_menu() {

    if ! unlock_flashos; then

        pause_screen

        return
    fi

    while true; do

        local name

        name=$(get_manifest DEVICE_NAME)

        local selected

        selected=$(arrow_menu \
            "💾 FLASHOS: ${name:-FLASHOS}" \
            "📁 Files" \
            "🔐 Vault Mode" \
            "💾 Backup" \
            "🩺 Diagnostics" \
            "⚙ Settings" \
            "🔄 Update FlashOS" \
            "🔒 Lock FlashOS")

        case "$selected" in

            0)
                files_menu
                ;;

            1)
                vault_menu
                ;;

            2)
                backup_menu
                ;;

            3)
                diagnostics_menu
                ;;

            4)
                settings_menu
                ;;

            5)
                update_flashos
                ;;

            6|255)

                lock_flashos

                return
                ;;

        esac

    done
}

# ============================================================
# FLASHOS FOUND MENU
# ============================================================

flashos_found_menu() {

    while true; do

        local name

        name=$(get_manifest DEVICE_NAME)

        local selected

        selected=$(arrow_menu \
            "💾 FLASHOS: ${name:-FLASHOS}" \
            "🚀 Работать с FlashOS" \
            "🔄 Обновить FlashOS с GitHub" \
            "🗑 Удалить FlashOS" \
            "ℹ Информация" \
            "🔌 Сменить USB" \
            "❌ Выход")

        case "$selected" in

            0)

                work_menu
                ;;

            1)

                update_flashos
                ;;

            2)

                remove_flashos

                return
                ;;

            3)

                diagnostics_menu
                ;;

            4)

                return
                ;;

            5)

                return
                ;;

            6|255)

                return
                ;;

        esac

    done
}

# ============================================================
# CLEANUP
# ============================================================

cleanup() {

    if mountpoint -q \
        "$VAULT_MOUNT" \
        2>/dev/null
    then

        fusermount3 \
            -u \
            "$VAULT_MOUNT" \
            >/dev/null 2>&1 || true
    fi

    if mountpoint -q \
        "$MAIN_MOUNT" \
        2>/dev/null
    then

        fusermount3 \
            -u \
            "$MAIN_MOUNT" \
            >/dev/null 2>&1 || true
    fi

    rm -rf \
        "$VAULT_MOUNT" \
        "$MAIN_MOUNT"

    rmdir \
        "$RUNTIME_BASE" \
        2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ============================================================
# MAIN
# ============================================================

main() {

    check_dependencies

    while true; do

        header

        echo -e \
            "${CYAN}🔍 Поиск USB-устройств...${RESET}" \
            > /dev/tty

        sleep 0.5

        if detect_flashos; then

            echo > /dev/tty

            success "Флешка найдена."

            echo \
                "Device:  $DEVICE" \
                > /dev/tty

            echo \
                "Name:    $(get_manifest DEVICE_NAME)" \
                > /dev/tty

            echo \
                "Version: $(get_manifest FLASHOS_VERSION)" \
                > /dev/tty

            sleep 0.6

            flashos_found_menu

            return
        fi

        echo > /dev/tty

        warn \
            "FlashOS на подключённой флешке не найден."

        echo > /dev/tty

        local selected

        selected=$(arrow_menu \
            "FLASHOS NOT FOUND" \
            "🚀 Установить FlashOS" \
            "🔄 Повторить поиск" \
            "❌ Выход")

        case "$selected" in

            0)

                install_flashos
                ;;

            1)

                continue
                ;;

            2|255)

                return
                ;;

        esac

    done
}

# ============================================================
# START
# ============================================================

main
