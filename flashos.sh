#!/usr/bin/env bash

# ============================================================
# FlashOS Manager
# Version 0.2.0
#
# Linux MVP
#
# ВАЖНО:
# Установка FlashOS ФОРМАТИРУЕТ выбранную USB-флешку.
#
# Формат: exFAT
# Шифрование: gocryptfs
# Интерфейс: ↑ ↓ Enter Esc
# ============================================================

set -u

APP_NAME="FlashOS Manager"
FLASHOS_VERSION="0.2.0"

BASE_RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/flashos-$UID"

MAIN_MOUNT="$BASE_RUNTIME/main"
VAULT_MOUNT="$BASE_RUNTIME/vault"

DEVICE=""
DEVICE_MOUNT=""
FLASHOS_DIR=""
CURRENT_VAULT=""

mkdir -p "$BASE_RUNTIME"

# ============================================================
# COLORS
# ============================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
WHITE="\033[37m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

# ============================================================
# OUTPUT
# ============================================================

tty_print() {
    printf '%b\n' "$1" > /dev/tty
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

clear_screen() {
    clear > /dev/tty 2>/dev/null || true
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
# DEPENDENCIES
# ============================================================

check_dependencies() {

    local missing=()

    command -v lsblk >/dev/null 2>&1 || missing+=("util-linux")
    command -v findmnt >/dev/null 2>&1 || missing+=("util-linux")
    command -v udisksctl >/dev/null 2>&1 || missing+=("udisks2")
    command -v gocryptfs >/dev/null 2>&1 || missing+=("gocryptfs")
    command -v fusermount3 >/dev/null 2>&1 || missing+=("fuse3")
    command -v mkfs.exfat >/dev/null 2>&1 || missing+=("exfatprogs")

    if (( ${#missing[@]} > 0 )); then

        header

        error_msg "Не хватает зависимостей:"
        echo > /dev/tty

        for package in "${missing[@]}"; do
            echo "  - $package" > /dev/tty
        done

        echo > /dev/tty

        echo "Для CachyOS / Arch Linux:" > /dev/tty
        echo "sudo pacman -S udisks2 gocryptfs fuse3 exfatprogs" > /dev/tty

        echo > /dev/tty

        exit 1
    fi
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

        echo -e "${DIM}↑ ↓${RESET} выбор   ${DIM}Enter${RESET} открыть   ${DIM}Esc${RESET} назад" > /dev/tty

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
                printf '%s\n' "$selected"
                return 0
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
# USB DETECTION
# ============================================================

is_removable_partition() {

    local dev="$1"

    [[ -b "$dev" ]] || return 1

    local type
    type=$(lsblk -ndo TYPE "$dev" 2>/dev/null || true)

    [[ "$type" == "part" ]] || return 1

    local parent
    parent=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1 || true)

    [[ -n "$parent" ]] || return 1

    local removable
    removable=$(cat "/sys/class/block/$parent/removable" 2>/dev/null || echo 0)

    [[ "$removable" == "1" ]]
}

get_usb_partitions() {

    while read -r dev; do

        [[ -z "$dev" ]] && continue

        if is_removable_partition "$dev"; then
            printf '%s\n' "$dev"
        fi

    done < <(lsblk -nrpo NAME)
}

# ============================================================
# FIND MOUNTED FLASHOS
# ============================================================

find_mounted_flashos() {

    while read -r source target; do

        [[ -z "$source" ]] && continue
        [[ -z "$target" ]] && continue

        if is_removable_partition "$source"; then

            if [[ -f "$target/.flashos/manifest" ]]; then

                printf '%s|%s\n' "$source" "$target"
                return 0

            fi
        fi

    done < <(findmnt -rn -o SOURCE,TARGET)

    return 1
}

# ============================================================
# MOUNT USB
# ============================================================

mount_first_usb() {

    local dev
    local target

    while read -r dev; do

        [[ -z "$dev" ]] && continue

        if ! is_removable_partition "$dev"; then
            continue
        fi

        target=$(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)

        if [[ -n "$target" ]]; then

            printf '%s|%s\n' "$dev" "$target"
            return 0

        fi

        info "Обнаружена USB-флешка: $dev"
        info "Подключаю..."

        if udisksctl mount -b "$dev" >/dev/null 2>&1; then

            target=$(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)

            if [[ -n "$target" ]]; then

                success "Флешка подключена."

                printf '%s|%s\n' "$dev" "$target"
                return 0

            fi

        fi

    done < <(lsblk -nrpo NAME)

    return 1
}

# ============================================================
# FLASHOS DETECTION
# ============================================================

detect_flashos() {

    DEVICE=""
    DEVICE_MOUNT=""
    FLASHOS_DIR=""

    local result

    result=$(find_mounted_flashos 2>/dev/null || true)

    if [[ -n "$result" ]]; then

        IFS='|' read -r DEVICE DEVICE_MOUNT <<< "$result"

        FLASHOS_DIR="$DEVICE_MOUNT/.flashos"

        return 0
    fi

    result=$(mount_first_usb 2>/dev/null || true)

    if [[ -z "$result" ]]; then
        return 1
    fi

    IFS='|' read -r DEVICE DEVICE_MOUNT <<< "$result"

    if [[ -f "$DEVICE_MOUNT/.flashos/manifest" ]]; then

        FLASHOS_DIR="$DEVICE_MOUNT/.flashos"

        return 0
    fi

    return 1
}

# ============================================================
# MANIFEST
# ============================================================

write_manifest() {

    local device_name="$1"

    mkdir -p "$FLASHOS_DIR"

    cat > "$FLASHOS_DIR/manifest" <<EOF
FLASHOS_FORMAT=FlashOS
FLASHOS_VERSION=$FLASHOS_VERSION
DEVICE_NAME=$device_name
FILESYSTEM=exFAT
SECURITY=gocryptfs
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
}

get_manifest_value() {

    local key="$1"

    [[ -f "$FLASHOS_DIR/manifest" ]] || return 0

    grep "^${key}=" "$FLASHOS_DIR/manifest" 2>/dev/null \
        | head -n1 \
        | cut -d= -f2-
}

# ============================================================
# FORMAT CONFIRMATION
# ============================================================

confirm_format() {

    local target="$1"

    local size
    local model
    local current_fs
    local current_label

    size=$(lsblk -ndo SIZE "$target" 2>/dev/null || echo "unknown")
    model=$(lsblk -ndo MODEL "$target" 2>/dev/null || echo "unknown")
    current_fs=$(lsblk -ndo FSTYPE "$target" 2>/dev/null || echo "unknown")
    current_label=$(lsblk -ndo LABEL "$target" 2>/dev/null || echo "")

    header

    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}" > /dev/tty
    echo -e "${RED}${BOLD}║              ⚠️  ОПАСНАЯ ОПЕРАЦИЯ                  ║${RESET}" > /dev/tty
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}" > /dev/tty

    echo > /dev/tty

    echo -e "${BOLD}Сейчас будет ОТФОРМАТИРОВАНО:${RESET}" > /dev/tty
    echo > /dev/tty

    echo "Device:       $target" > /dev/tty
    echo "Size:         $size" > /dev/tty
    echo "Model:        ${model:-unknown}" > /dev/tty
    echo "Filesystem:   ${current_fs:-unknown}" > /dev/tty
    echo "Label:        ${current_label:-<none>}" > /dev/tty

    echo > /dev/tty

    echo -e "${RED}${BOLD}ВСЕ ФАЙЛЫ НА ЭТОМ РАЗДЕЛЕ БУДУТ УДАЛЕНЫ.${RESET}" > /dev/tty
    echo > /dev/tty

    echo "После форматирования будет создан новый FlashOS." > /dev/tty
    echo "Новый формат файловой системы: exFAT." > /dev/tty

    echo > /dev/tty

    read -rp "Для продолжения введи FORMAT: " confirmation < /dev/tty

    if [[ "$confirmation" != "FORMAT" ]]; then

        echo > /dev/tty
        warn "Форматирование отменено."

        return 1
    fi

    echo > /dev/tty

    echo -e "${RED}${BOLD}Последнее предупреждение!${RESET}" > /dev/tty
    echo "Будут удалены ВСЕ данные с $target." > /dev/tty
    echo > /dev/tty

    read -rp "Введите FLASHOS-YES для окончательного подтверждения: " final_confirmation < /dev/tty

    if [[ "$final_confirmation" != "FLASHOS-YES" ]]; then

        echo > /dev/tty
        warn "Форматирование отменено."

        return 1
    fi

    return 0
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

    # Сначала пробуем через udisks
    udisksctl unmount -b "$target" >/dev/null 2>&1 || true

    # Дополнительно проверяем, не остался ли раздел смонтированным
    local mounted
    mounted=$(findmnt -rn -S "$target" -o TARGET 2>/dev/null || true)

    if [[ -n "$mounted" ]]; then
        info "Раздел всё ещё подключён: $mounted"
        info "Принудительно отключаю..."

        sudo umount "$mounted" >/dev/null 2>&1 || true
    fi

    sleep 0.5

    # Проверяем ещё раз
    mounted=$(findmnt -rn -S "$target" -o TARGET 2>/dev/null || true)

    if [[ -n "$mounted" ]]; then
        error_msg "Не удалось размонтировать $target."
        return 1
    fi

    echo > /dev/tty
    echo "Форматирование в exFAT..." > /dev/tty
    echo > /dev/tty

    # -F = force, разрешает перезаписать старую сигнатуру
    if sudo mkfs.exfat -F -n "$label" "$target"; then

        echo > /dev/tty
        success "Форматирование завершено."

        return 0

    fi

    echo > /dev/tty
    error_msg "Не удалось отформатировать флешку."

    return 1
}

# ============================================================
# INSTALL FLASHOS
# ============================================================

install_flashos() {

    header

    echo -e "${BOLD}🚀 TRANSFORMATION OF USB${RESET}" > /dev/tty
    echo > /dev/tty

    local usb_devices=()
    local dev

    while read -r dev; do

        [[ -z "$dev" ]] && continue

        usb_devices+=("$dev")

    done < <(get_usb_partitions)

    if (( ${#usb_devices[@]} == 0 )); then

        error_msg "Съёмная USB-флешка не найдена."

        echo > /dev/tty
        info "Подключи флешку и повтори поиск."

        pause_screen
        return
    fi

    local options=()

    local size
    local fs
    local label
    local model

    for dev in "${usb_devices[@]}"; do

        size=$(lsblk -ndo SIZE "$dev" 2>/dev/null || echo "?")
        fs=$(lsblk -ndo FSTYPE "$dev" 2>/dev/null || echo "?")
        label=$(lsblk -ndo LABEL "$dev" 2>/dev/null || echo "")
        model=$(lsblk -ndo MODEL "$dev" 2>/dev/null || echo "")

        options+=("$dev | $size | ${label:-no-label} | ${fs:-unknown} | ${model:-USB}")
    done

    options+=("Отмена")

    local selected

    selected=$(arrow_menu \
        "💾 ВЫБЕРИ ФЛЕШКУ ДЛЯ FLASHOS" \
        "${options[@]}")

    if [[ "$selected" == "255" ]]; then
        return
    fi

    if (( selected >= ${#usb_devices[@]} )); then
        return
    fi

    DEVICE="${usb_devices[$selected]}"

    # --------------------------------------------------------
    # CRITICAL WARNING
    # --------------------------------------------------------

    if ! confirm_format "$DEVICE"; then
        pause_screen
        return
    fi

    # --------------------------------------------------------
    # Ask FlashOS name BEFORE formatting
    # --------------------------------------------------------

    header

    echo -e "${BOLD}🏷️ FLASHOS DEVICE NAME${RESET}" > /dev/tty
    echo > /dev/tty

    echo "Придумай имя для своей FlashOS-флешки." > /dev/tty
    echo "Для exFAT лучше использовать короткое имя." > /dev/tty
    echo > /dev/tty

    local device_name

    read -rp "Имя [FLASHOS]: " device_name < /dev/tty

    [[ -z "$device_name" ]] && device_name="FLASHOS"

    # Безопасный label для exFAT
    device_name="${device_name//\//_}"
    device_name="${device_name:0:15}"

    if [[ -z "$device_name" ]]; then
        device_name="FLASHOS"
    fi

    # --------------------------------------------------------
    # FORMAT
    # --------------------------------------------------------

    if ! format_usb "$DEVICE" "$device_name"; then

        pause_screen
        return
    fi

    # --------------------------------------------------------
    # Mount freshly formatted filesystem
    # --------------------------------------------------------

    info "Подключаю новую FlashOS-флешку..."

    sleep 1

    if ! udisksctl mount -b "$DEVICE" >/dev/null 2>&1; then

        error_msg "Не удалось снова подключить флешку."

        pause_screen
        return
    fi

    DEVICE_MOUNT=$(findmnt -rn -S "$DEVICE" -o TARGET 2>/dev/null || true)

    if [[ -z "$DEVICE_MOUNT" ]]; then

        error_msg "Не найден mount point."

        pause_screen
        return
    fi

    FLASHOS_DIR="$DEVICE_MOUNT/.flashos"

    # --------------------------------------------------------
    # Create FlashOS structure
    # --------------------------------------------------------

    header

    echo -e "${CYAN}${BOLD}TRANSFORMATION OF USB${RESET}" > /dev/tty
    echo > /dev/tty

    echo "  [1/8] Создание .flashos..." > /dev/tty
    mkdir -p "$FLASHOS_DIR"

    echo "  [2/8] Создание system..." > /dev/tty
    mkdir -p "$FLASHOS_DIR/system"

    echo "  [3/8] Создание packages..." > /dev/tty
    mkdir -p "$FLASHOS_DIR/packages"
    mkdir -p "$FLASHOS_DIR/packages/installed"
    mkdir -p "$FLASHOS_DIR/packages/cache"
    mkdir -p "$FLASHOS_DIR/packages/repository"

    echo "  [4/8] Создание recovery..." > /dev/tty
    mkdir -p "$FLASHOS_DIR/recovery"

    echo "  [5/8] Создание logs..." > /dev/tty
    mkdir -p "$FLASHOS_DIR/logs"

    echo "  [6/8] Создание encrypted storage..." > /dev/tty
    mkdir -p "$FLASHOS_DIR/data"

    echo "  [7/8] Создание главного пароля..." > /dev/tty

    echo > /dev/tty

    echo -e "${YELLOW}${BOLD}🔐 СОЗДАНИЕ ГЛАВНОГО ПАРОЛЯ FLASHOS${RESET}" > /dev/tty
    echo > /dev/tty

    echo "Этот пароль понадобится при подключении" > /dev/tty
    echo "FlashOS к другому компьютеру." > /dev/tty

    echo > /dev/tty

    if ! gocryptfs -init "$FLASHOS_DIR/data"; then

        error_msg "Не удалось создать зашифрованное хранилище."

        pause_screen
        return
    fi

    # --------------------------------------------------------
    # Manifest
    # --------------------------------------------------------

    echo "  [8/8] Создание manifest..." > /dev/tty

    write_manifest "$device_name"

    cat > "$FLASHOS_DIR/readme.txt" <<EOF
FlashOS USB
===========

Device: $device_name
Version: $FLASHOS_VERSION

Эта флешка управляется через FlashOS Manager.

Не изменяй содержимое каталога .flashos вручную.
EOF

    cat > "$FLASHOS_DIR/device.info" <<EOF
DEVICE_NAME=$device_name
FLASHOS_VERSION=$FLASHOS_VERSION
FILESYSTEM=exFAT
SECURITY=gocryptfs
EOF

    sync

    echo > /dev/tty

    success "FlashOS успешно установлен."

    echo > /dev/tty

    echo "Имя:        $device_name" > /dev/tty
    echo "Устройство: $DEVICE" > /dev/tty
    echo "Файловая система: exFAT" > /dev/tty
    echo "Шифрование: gocryptfs" > /dev/tty

    echo > /dev/tty

    success "Трансформация флешки завершена."

    pause_screen
}

# ============================================================
# UNLOCK
# ============================================================

unlock_flashos() {

    mkdir -p "$MAIN_MOUNT"

    if mountpoint -q "$MAIN_MOUNT" 2>/dev/null; then
        return 0
    fi

    if [[ ! -f "$FLASHOS_DIR/data/gocryptfs.conf" ]]; then

        error_msg "Зашифрованное хранилище FlashOS не найдено."

        return 1
    fi

    header

    echo -e "${BOLD}🔐 FLASHOS LOCKED${RESET}" > /dev/tty
    echo > /dev/tty

    echo "FlashOS: $(get_manifest_value DEVICE_NAME)" > /dev/tty
    echo > /dev/tty

    echo "Для показа содержимого нужен пароль." > /dev/tty
    echo > /dev/tty

    if gocryptfs "$FLASHOS_DIR/data" "$MAIN_MOUNT"; then

        echo > /dev/tty

        success "FlashOS разблокирован."

        return 0

    fi

    echo > /dev/tty

    error_msg "Неверный пароль или ошибка хранилища."

    return 1
}

# ============================================================
# LOCK
# ============================================================

lock_flashos() {

    if mountpoint -q "$VAULT_MOUNT" 2>/dev/null; then

        fusermount3 -u "$VAULT_MOUNT" 2>/dev/null || true

    fi

    if mountpoint -q "$MAIN_MOUNT" 2>/dev/null; then

        fusermount3 -u "$MAIN_MOUNT" 2>/dev/null || true

    fi

    rm -rf "$VAULT_MOUNT"
    rm -rf "$MAIN_MOUNT"

    CURRENT_VAULT=""

    success "FlashOS заблокирован."
}

# ============================================================
# FILES
# ============================================================

files_menu() {

    if ! mountpoint -q "$MAIN_MOUNT" 2>/dev/null; then

        if ! unlock_flashos; then
            pause_screen
            return
        fi
    fi

    while true; do

        local selected

        selected=$(arrow_menu \
            "📁 FILES" \
            "Открыть хранилище в файловом менеджере" \
            "Показать файлы" \
            "Назад")

        case "$selected" in

            0)

                if command -v xdg-open >/dev/null 2>&1; then
                    xdg-open "$MAIN_MOUNT" >/dev/null 2>&1 &
                fi
                ;;

            1)

                header

                echo -e "${BOLD}📁 FLASHOS STORAGE${RESET}" > /dev/tty
                echo > /dev/tty

                ls -lah "$MAIN_MOUNT" > /dev/tty

                pause_screen
                ;;

            2|255)

                return
                ;;

        esac
    done
}

# ============================================================
# CREATE VAULT
# ============================================================

create_vault() {

    if ! mountpoint -q "$MAIN_MOUNT" 2>/dev/null; then

        if ! unlock_flashos; then
            return
        fi
    fi

    header

    echo -e "${BOLD}🔐 CREATE VAULT${RESET}" > /dev/tty
    echo > /dev/tty

    read -rp "Название Vault: " vault_name < /dev/tty

    [[ -z "$vault_name" ]] && return

    vault_name="${vault_name// /_}"
    vault_name="${vault_name//\//_}"

    local vault_root="$MAIN_MOUNT/.vaults"
    local cipher_dir="$vault_root/${vault_name}.vault"

    mkdir -p "$vault_root"

    if [[ -e "$cipher_dir" ]]; then

        error_msg "Такой Vault уже существует."

        pause_screen
        return
    fi

    mkdir -p "$cipher_dir"

    echo > /dev/tty
    echo -e "${YELLOW}${BOLD}🔑 Пароль нового Vault${RESET}" > /dev/tty
    echo > /dev/tty

    if ! gocryptfs -init "$cipher_dir"; then

        error_msg "Не удалось создать Vault."

        rm -rf "$cipher_dir"

        pause_screen
        return
    fi

    success "Vault создан."

    echo > /dev/tty

    read -rp "Путь к папке для копирования (Enter = пропустить): " source < /dev/tty

    if [[ -n "$source" ]]; then

        if [[ ! -d "$source" ]]; then

            error_msg "Папка не найдена."

            pause_screen
            return
        fi

        rm -rf "$VAULT_MOUNT"
        mkdir -p "$VAULT_MOUNT"

        echo > /dev/tty
        echo "🔓 Открываю Vault..." > /dev/tty

        if gocryptfs "$cipher_dir" "$VAULT_MOUNT"; then

            echo "📦 Копирую папку..." > /dev/tty

            if cp -a "$source" "$VAULT_MOUNT/"; then
                success "Папка скопирована в Vault."
            else
                error_msg "Ошибка копирования."
            fi

            sync

            fusermount3 -u "$VAULT_MOUNT" 2>/dev/null || true

            rm -rf "$VAULT_MOUNT"

        else

            error_msg "Не удалось открыть Vault."

            rm -rf "$VAULT_MOUNT"
        fi
    fi

    pause_screen
}

# ============================================================
# LIST VAULTS
# ============================================================

list_vaults() {

    local vault_root="$MAIN_MOUNT/.vaults"

    mkdir -p "$vault_root"

    find "$vault_root" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name "*.vault" \
        -printf "%f\n" 2>/dev/null \
        | sed 's/\.vault$//'
}

# ============================================================
# OPEN VAULT
# ============================================================

open_vault() {

    local vaults

    vaults=$(list_vaults)

    if [[ -z "$vaults" ]]; then

        warn "Vault пока нет."

        pause_screen
        return
    fi

    local options=()

    while read -r vault; do

        [[ -z "$vault" ]] && continue

        options+=("🔐 $vault")

    done <<< "$vaults"

    options+=("Назад")

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

    local cipher_dir="$MAIN_MOUNT/.vaults/${selected_vault}.vault"

    rm -rf "$VAULT_MOUNT"
    mkdir -p "$VAULT_MOUNT"

    header

    echo -e "${BOLD}🔐 OPEN VAULT: $selected_vault${RESET}" > /dev/tty
    echo > /dev/tty

    if gocryptfs "$cipher_dir" "$VAULT_MOUNT"; then

        CURRENT_VAULT="$selected_vault"

        success "Vault разблокирован."

        while true; do

            local action

            action=$(arrow_menu \
                "🔐 VAULT: $CURRENT_VAULT" \
                "Открыть в файловом менеджере" \
                "Показать содержимое" \
                "Закрыть Vault")

            case "$action" in

                0)

                    if command -v xdg-open >/dev/null 2>&1; then
                        xdg-open "$VAULT_MOUNT" >/dev/null 2>&1 &
                    fi
                    ;;

                1)

                    header

                    echo -e "${BOLD}📁 VAULT CONTENT${RESET}" > /dev/tty
                    echo > /dev/tty

                    ls -lah "$VAULT_MOUNT" > /dev/tty

                    pause_screen
                    ;;

                2|255)

                    fusermount3 -u "$VAULT_MOUNT" 2>/dev/null || true

                    rm -rf "$VAULT_MOUNT"

                    CURRENT_VAULT=""

                    success "Vault закрыт."

                    pause_screen

                    return
                    ;;

            esac

        done

    else

        error_msg "Не удалось открыть Vault."

        rm -rf "$VAULT_MOUNT"

        pause_screen
    fi
}

# ============================================================
# VAULT MENU
# ============================================================

vault_menu() {

    if ! mountpoint -q "$MAIN_MOUNT" 2>/dev/null; then

        if ! unlock_flashos; then
            pause_screen
            return
        fi
    fi

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

    if ! mountpoint -q "$MAIN_MOUNT" 2>/dev/null; then

        if ! unlock_flashos; then
            return
        fi
    fi

    mkdir -p "$MAIN_MOUNT/Backups"

    while true; do

        local selected

        selected=$(arrow_menu \
            "💾 BACKUP" \
            "Создать резервную копию папки" \
            "Показать Backup" \
            "Назад")

        case "$selected" in

            0)

                header

                echo -e "${BOLD}💾 CREATE BACKUP${RESET}" > /dev/tty
                echo > /dev/tty

                read -rp "Путь к папке: " source < /dev/tty

                if [[ ! -d "$source" ]]; then

                    error_msg "Папка не найдена."

                    pause_screen
                    continue
                fi

                local name
                name=$(basename "$source")

                local timestamp
                timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

                local backup_dir="$MAIN_MOUNT/Backups/$timestamp"

                mkdir -p "$backup_dir"

                echo > /dev/tty
                echo "Копирование..." > /dev/tty

                if cp -a "$source" "$backup_dir/"; then

                    success "Backup создан."
                    echo "$backup_dir/$name" > /dev/tty

                else

                    error_msg "Ошибка создания Backup."

                fi

                pause_screen
                ;;

            1)

                header

                echo -e "${BOLD}💾 BACKUPS${RESET}" > /dev/tty
                echo > /dev/tty

                find "$MAIN_MOUNT/Backups" \
                    -maxdepth 2 \
                    -mindepth 1 \
                    -type d \
                    2>/dev/null > /dev/tty

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
            "Показать использование места" \
            "Назад")

        case "$selected" in

            0)

                show_device_info
                ;;

            1)

                header

                echo -e "${BOLD}🩺 FLASHOS STRUCTURE CHECK${RESET}" > /dev/tty
                echo > /dev/tty

                local paths=(
                    "$FLASHOS_DIR"
                    "$FLASHOS_DIR/manifest"
                    "$FLASHOS_DIR/system"
                    "$FLASHOS_DIR/packages"
                    "$FLASHOS_DIR/packages/installed"
                    "$FLASHOS_DIR/packages/cache"
                    "$FLASHOS_DIR/packages/repository"
                    "$FLASHOS_DIR/recovery"
                    "$FLASHOS_DIR/logs"
                    "$FLASHOS_DIR/data"
                )

                local path

                for path in "${paths[@]}"; do

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

                echo -e "${BOLD}📊 STORAGE${RESET}" > /dev/tty
                echo > /dev/tty

                df -h "$DEVICE_MOUNT" > /dev/tty

                echo > /dev/tty

                du -sh "$FLASHOS_DIR" \
                    2>/dev/null > /dev/tty || true

                pause_screen
                ;;

            3|255)

                return
                ;;

        esac
    done
}

# ============================================================
# SHOW DEVICE INFO
# ============================================================

show_device_info() {

    header

    echo -e "${BOLD}Устройство${RESET}" > /dev/tty
    echo "────────────────────────────────────────────────────" > /dev/tty

    echo "Device:       ${DEVICE:-unknown}" > /dev/tty
    echo "Mount point:  ${DEVICE_MOUNT:-unknown}" > /dev/tty

    if [[ -n "$DEVICE" ]]; then

        echo "Size:         $(lsblk -ndo SIZE "$DEVICE" 2>/dev/null)" > /dev/tty
        echo "Filesystem:   $(lsblk -ndo FSTYPE "$DEVICE" 2>/dev/null)" > /dev/tty
        echo "USB label:    $(lsblk -ndo LABEL "$DEVICE" 2>/dev/null)" > /dev/tty
        echo "Model:        $(lsblk -ndo MODEL "$DEVICE" 2>/dev/null)" > /dev/tty

    fi

    echo > /dev/tty

    echo -e "${BOLD}FlashOS${RESET}" > /dev/tty
    echo "────────────────────────────────────────────────────" > /dev/tty

    echo "Name:         $(get_manifest_value DEVICE_NAME)" > /dev/tty
    echo "Version:      $(get_manifest_value FLASHOS_VERSION)" > /dev/tty
    echo "Filesystem:   $(get_manifest_value FILESYSTEM)" > /dev/tty
    echo "Security:     $(get_manifest_value SECURITY)" > /dev/tty
    echo "Created:      $(get_manifest_value CREATED)" > /dev/tty

    pause_screen
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

                echo -e "${BOLD}🏷️ DEVICE NAME${RESET}" > /dev/tty
                echo > /dev/tty

                local new_name

                read -rp "Новое имя: " new_name < /dev/tty

                if [[ -n "$new_name" ]]; then

                    new_name="${new_name//\//_}"
                    new_name="${new_name:0:15}"

                    write_manifest "$new_name"

                    success "Имя изменено на: $new_name"
                fi

                pause_screen
                ;;

            1)

                header

                echo -e "${BOLD}📄 MANIFEST${RESET}" > /dev/tty
                echo > /dev/tty

                cat "$FLASHOS_DIR/manifest" > /dev/tty

                pause_screen
                ;;

            2|255)

                return
                ;;

        esac
    done
}

# ============================================================
# MAIN PANEL
# ============================================================

main_panel() {

    while true; do

        local device_name

        device_name=$(get_manifest_value DEVICE_NAME)

        local selected

        selected=$(arrow_menu \
            "💾 FLASHOS: ${device_name:-FLASHOS}" \
            "📁 Files" \
            "🔐 Vault Mode" \
            "💾 Backup" \
            "🩺 Diagnostics" \
            "⚙ Settings" \
            "🔒 Lock FlashOS" \
            "❌ Exit")

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

                lock_flashos

                pause_screen

                return
                ;;

            6|255)

                return
                ;;

        esac
    done
}

# ============================================================
# STARTUP
# ============================================================

startup() {

    check_dependencies

    while true; do

        header

        echo -e "${CYAN}🔍 Поиск флешки...${RESET}" > /dev/tty

        sleep 0.5

        if detect_flashos; then

            echo > /dev/tty

            success "Флешка найдена."

            echo "Device: $DEVICE" > /dev/tty
            echo "Mount:  $DEVICE_MOUNT" > /dev/tty

            echo > /dev/tty

            success "FlashOS найден."

            echo "Name:    $(get_manifest_value DEVICE_NAME)" > /dev/tty
            echo "Version: $(get_manifest_value FLASHOS_VERSION)" > /dev/tty

            sleep 0.7

            if unlock_flashos; then

                main_panel

                lock_flashos

                echo > /dev/tty
                success "Сессия FlashOS завершена."

                sleep 0.5

                return

            else

                pause_screen
                return
            fi

        else

            echo > /dev/tty

            warn "FlashOS на подключённой флешке не найден."

            echo > /dev/tty

            local selected

            selected=$(arrow_menu \
                "FLASHOS NOT FOUND" \
                "🚀 Установить FlashOS на флешку" \
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
        fi

    done
}

# ============================================================
# CLEANUP
# ============================================================

cleanup() {

    if mountpoint -q "$VAULT_MOUNT" 2>/dev/null; then
        fusermount3 -u "$VAULT_MOUNT" 2>/dev/null || true
    fi

    if mountpoint -q "$MAIN_MOUNT" 2>/dev/null; then
        fusermount3 -u "$MAIN_MOUNT" 2>/dev/null || true
    fi

    rm -rf "$VAULT_MOUNT"
    rm -rf "$MAIN_MOUNT"

    rmdir "$BASE_RUNTIME" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ============================================================
# RUN
# ============================================================

startup