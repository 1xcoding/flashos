#!/usr/bin/env bash

# ============================================================
#                    FLASHOS MANAGER
# ============================================================
#
# Version: 0.4.0
#
# GitHub:
# https://github.com/1xcoding/flashos
#
# SINGLE FILE EDITION
#
# ============================================================
# FEATURES
# ============================================================
#
# - USB detection
# - FlashOS detection
# - FlashOS installation
# - exFAT formatting
# - Main encrypted storage
# - Main FlashOS password
# - Vault Mode
# - Vault passwords
# - Backup
# - Diagnostics
# - Settings
# - GitHub Latest Release updater
# - Release notes
# - FlashOS removal
# - Arrow key interface
#
# New in 0.4.0:
#
# - Auto-lock on inactivity + instant lock key (L)
# - Event log
# - Recovery: key backup, key restore, storage check (fsck)
# - Password change (main storage and Vault)
# - Vault management (rename, size, delete)
# - Verified backups (SHA-256), restore, delete
# - Files: search, import, disk usage
# - Several FlashOS drives, working "Switch USB", safe eject
# - Update notification, manager rollback
# - Command line options (--help)
#
# ============================================================

set -u

# ============================================================
# CONFIGURATION
# ============================================================

APP_NAME="FlashOS Manager"

FLASHOS_VERSION="0.4.0"

GITHUB_REPO="1xcoding/flashos"

GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

RUNTIME_BASE="${XDG_RUNTIME_DIR:-/tmp}/flashos-${UID}"

MAIN_MOUNT="$RUNTIME_BASE/main"

VAULT_MOUNT="$RUNTIME_BASE/vault"

# Сообщение о блокировке сеанса для главного меню
NOTICE_FILE="$RUNTIME_BASE/lock.notice"

# Имя файла контрольных сумм внутри каждого Backup
CHECKSUM_FILE=".flashos-checksums.sha256"

# Журнал событий: после этого размера старый журнал уходит в flashos.log.1
LOG_MAX_BYTES=262144

# Как часто проверять наличие новой версии при запуске (секунды)
UPDATE_CHECK_INTERVAL=86400

REQUIRED_COMMANDS=(
    lsblk
    findmnt
    udisksctl
    gocryptfs
    fusermount3
    mkfs.exfat
    curl
    bash
    jq
)

DEVICE=""

DEVICE_MOUNT=""

FLASHOS_DIR=""

CURRENT_VAULT=""

FOUND_DEVICES=()

FOUND_MOUNTS=()

CHOSEN_ITEM=""

# Раздел, который нужно извлечь сразу после запуска (см. eject_flashos)
EJECT_ON_START=""

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

disable_colors() {

    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    WHITE=''

    BOLD=''
    DIM=''

    RESET=''

}

# https://no-color.org
if [[ -n "${NO_COLOR:-}" ]]; then

    disable_colors

fi

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

# Ждёт Enter. Если включена автоблокировка и сеанс открыт,
# по истечении времени блокирует FlashOS и очищает экран.
pause_screen() {

    local timeout
    local status

    echo > /dev/tty

    printf '%s' "Нажми Enter для продолжения..." > /dev/tty

    while true; do

        timeout=$(idle_timeout_seconds)

        if (( timeout > 0 )); then

            read -rs -t "$timeout" < /dev/tty

        else

            read -rs < /dev/tty

        fi

        status=$?

        if (( status > 128 )); then

            if end_session idle; then

                clear_screen

                return

            fi

            # Хранилище занято — блокировка отложена, ждём дальше
            continue

        fi

        echo > /dev/tty

        return

    done

}

# Ввод строки с учётом автоблокировки.
#
#   ask ИМЯ_ПЕРЕМЕННОЙ "Текст: "
#
# Возвращает 1, если ввод не получен (сеанс заблокирован по
# бездействию или терминал закрыт).
ask() {

    local __name="$1"
    local __timeout
    local __status

    printf '%s' "$2" > /dev/tty

    while true; do

        __timeout=$(idle_timeout_seconds)

        if (( __timeout > 0 )); then

            IFS= read -r -t "$__timeout" < /dev/tty

        else

            IFS= read -r < /dev/tty

        fi

        __status=$?

        if (( __status == 0 )); then

            printf -v "$__name" '%s' "$REPLY"

            return 0

        fi

        if (( __status > 128 )) && ! end_session idle; then

            # Хранилище занято — блокировка отложена, ждём дальше
            continue

        fi

        printf -v "$__name" '%s' ""

        flush_tty_input

        clear_screen

        return 1

    done

}

# Выбрасывает то, что было набрано, но не отправлено Enter'ом,
# чтобы эти символы не сработали как нажатия в следующем меню.
flush_tty_input() {

    while IFS= read -rs -t 0.05 -n 256 < /dev/tty; do

        :

    done

}

# Приводит введённый путь к рабочему виду: убирает кавычки
# (их добавляет перетаскивание из файлового менеджера), пробелы
# по краям, завершающие слэши и раскрывает ~.
expand_path() {

    local path="$1"

    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"

    if (( ${#path} >= 2 )); then

        if [[ "$path" == \'*\' || "$path" == \"*\" ]]; then

            path="${path:1:${#path}-2}"

        fi

    fi

    case "$path" in

        \~)
            path="$HOME"
            ;;

        \~/*)
            path="$HOME/${path:2}"
            ;;

    esac

    while [[ "$path" == */ && "$path" != "/" ]]; do

        path="${path%/}"

    done

    printf '%s\n' "$path"

}

# Килобайты → человекочитаемый размер
human_kb() {

    numfmt --to=iec --from-unit=1024 "$1" 2>/dev/null \
        || printf '%s КБ\n' "$1"

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
#
# Печатает номер выбранного пункта. При Esc / Q, блокировке
# сеанса или закрытом терминале печатает 255 и возвращает 255.

arrow_menu() {

    local title="$1"

    shift

    local options=("$@")

    local selected=0

    local key=""

    local sequence=""

    local hint=""

    local timeout

    local status

    local i

    local was_active=1

    session_active && was_active=0

    while true; do

        clear_screen

        echo -e "${CYAN}${BOLD}$title${RESET}" > /dev/tty

        echo > /dev/tty

        for i in "${!options[@]}"; do

            if (( i == selected )); then

                echo -e \
                    "  ${CYAN}${BOLD}❯ ${options[$i]}${RESET}" \
                    > /dev/tty

            else

                echo -e \
                    "    ${options[$i]}" \
                    > /dev/tty

            fi

        done

        echo > /dev/tty

        hint="${DIM}↑ ↓${RESET} выбор   ${DIM}Enter${RESET} открыть   ${DIM}Esc${RESET} назад"

        if session_active; then

            hint+="   ${DIM}L${RESET} блокировка"

        fi

        echo -e "$hint" > /dev/tty

        timeout=$(idle_timeout_seconds)

        if (( timeout > 0 )); then

            IFS= read -rsn1 -t "$timeout" key < /dev/tty

        else

            IFS= read -rsn1 key < /dev/tty

        fi

        status=$?

        if (( status > 128 )); then

            # Бездействие: блокируем. Если хранилище занято,
            # блокировка откладывается и отсчёт начинается заново.
            if end_session idle; then

                printf '255\n'

                return 255

            fi

            continue

        fi

        if (( status != 0 )); then

            # Терминал закрыт
            printf '255\n'

            return 255

        fi

        if (( was_active == 0 )) && ! session_active; then

            # Пока меню ждало, хранилище заблокировали снаружи
            # (flashos.sh --lock) — пункты этого меню уже неприменимы.
            printf '255\n'

            return 255

        fi

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

                    "")
                        printf '255\n'

                        return 255
                        ;;

                esac

                ;;

            q|Q)

                printf '255\n'

                return 255

                ;;

            l|L)

                if session_active && end_session hotkey; then

                    printf '255\n'

                    return 255

                fi

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

# Команда установки зависимостей для текущего дистрибутива
install_hint() {

    local packages="udisks2 gocryptfs fuse3 exfatprogs curl jq"

    local ids=""

    if [[ -r /etc/os-release ]]; then

        ids=$(
            # shellcheck disable=SC1091
            . /etc/os-release 2>/dev/null
            printf '%s %s' "${ID:-}" "${ID_LIKE:-}"
        )

    fi

    case " $ids " in

        *" arch "*|*" cachyos "*|*" manjaro "*)
            printf 'sudo pacman -S %s\n' "$packages"
            ;;

        *" debian "*|*" ubuntu "*)
            printf 'sudo apt install %s\n' "$packages"
            ;;

        *" fedora "*|*" rhel "*)
            printf 'sudo dnf install %s\n' "$packages"
            ;;

        *" suse "*|*" opensuse "*|*opensuse-*)
            printf 'sudo zypper install %s\n' "$packages"
            ;;

        *)
            printf 'Установи пакеты: %s\n' "$packages"
            ;;

    esac

}

missing_dependencies() {

    local command_name

    for command_name in "${REQUIRED_COMMANDS[@]}"; do

        if ! command -v "$command_name" >/dev/null 2>&1; then

            printf '%s\n' "$command_name"

        fi

    done

}

check_dependencies() {

    [[ -n "$(missing_dependencies)" ]] || return 0

    header

    error_msg "Не хватает зависимостей."

    echo > /dev/tty

    missing_dependencies \
        | sed 's/^/  - /' \
        > /dev/tty

    echo > /dev/tty

    echo "Установка:" > /dev/tty

    install_hint > /dev/tty

    echo > /dev/tty

    exit 1

}

# ============================================================
# USB DETECTION
# ============================================================

is_removable_partition() {

    local dev="$1"

    [[ -b "$dev" ]] || return 1

    local type

    type=$(lsblk \
        -ndo TYPE \
        "$dev" \
        2>/dev/null || true)

    [[ "$type" == "part" ]] || return 1

    local parent

    parent=$(lsblk \
        -no PKNAME \
        "$dev" \
        2>/dev/null \
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

# ============================================================
# MOUNT USB
# ============================================================

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

    info "Подключаю $dev..."

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

            success "USB подключена."

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

# Значение ключа из произвольного файла вида KEY=VALUE
file_value() {

    local file="$1"

    local key="$2"

    [[ -f "$file" ]] || return 0

    grep -m1 \
        "^${key}=" \
        "$file" \
        2>/dev/null \
        | cut -d= -f2-

}

# Находит все подключённые флешки с FlashOS
find_flashos_devices() {

    FOUND_DEVICES=()

    FOUND_MOUNTS=()

    local dev

    local result

    local found_device

    local found_mount

    while read -r dev; do

        [[ -n "$dev" ]] || continue

        if ! is_removable_partition "$dev"; then

            continue

        fi

        result=$(mount_usb "$dev" 2>/dev/null || true)

        [[ -n "$result" ]] || continue

        IFS='|' read -r \
            found_device \
            found_mount <<< "$result"

        if [[ \
            -f "$found_mount/.flashos/manifest"
        ]]; then

            FOUND_DEVICES+=("$found_device")

            FOUND_MOUNTS+=("$found_mount")

        fi

    done < <(get_usb_partitions)

}

# 0 — FlashOS выбран, 1 — не найден, 2 — найдено несколько,
# но пользователь не выбрал ни одного
detect_flashos() {

    DEVICE=""

    DEVICE_MOUNT=""

    FLASHOS_DIR=""

    find_flashos_devices

    local count=${#FOUND_DEVICES[@]}

    local index=0

    (( count > 0 )) || return 1

    if (( count > 1 )); then

        local options=()

        local manifest

        local i

        for i in "${!FOUND_DEVICES[@]}"; do

            manifest="${FOUND_MOUNTS[$i]}/.flashos/manifest"

            options+=(
                "💾 $(file_value "$manifest" DEVICE_NAME) | ${FOUND_DEVICES[$i]} | $(file_value "$manifest" FLASHOS_VERSION)"
            )

        done

        index=$(arrow_menu \
            "💾 НАЙДЕНО НЕСКОЛЬКО FLASHOS — ВЫБЕРИ" \
            "${options[@]}")

        [[ "$index" =~ ^[0-9]+$ ]] || return 2

        (( index < count )) || return 2

    fi

    DEVICE="${FOUND_DEVICES[$index]}"

    DEVICE_MOUNT="${FOUND_MOUNTS[$index]}"

    FLASHOS_DIR="$DEVICE_MOUNT/.flashos"

    return 0

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

    cat > "$FLASHOS_DIR/manifest" <<EOF
FLASHOS_FORMAT=FlashOS
FLASHOS_VERSION=$version
DEVICE_NAME=$name
FILESYSTEM=exFAT
SECURITY=gocryptfs
MANAGER=flashos.sh
GITHUB_REPO=$GITHUB_REPO
UPDATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF

}

# ============================================================
# DEVICE SETTINGS
# ============================================================
#
# Настройки хранятся на самой флешке: .flashos/system/settings

get_setting() {

    local key="$1"

    local default="${2:-}"

    local value=""

    if [[ -n "$FLASHOS_DIR" ]]; then

        value=$(file_value "$FLASHOS_DIR/system/settings" "$key")

    fi

    printf '%s\n' "${value:-$default}"

}

set_setting() {

    local key="$1"

    local value="$2"

    local file="$FLASHOS_DIR/system/settings"

    mkdir -p "$FLASHOS_DIR/system" || return 1

    {
        if [[ -f "$file" ]]; then

            grep -v "^${key}=" "$file"

        fi

        printf '%s=%s\n' "$key" "$value"

    } > "$file.tmp" || return 1

    mv -f "$file.tmp" "$file"

}

toggle_setting() {

    local key="$1"

    local default="$2"

    if [[ "$(get_setting "$key" "$default")" == "1" ]]; then

        set_setting "$key" 0

    else

        set_setting "$key" 1

    fi

}

on_off() {

    if [[ "$1" == "1" ]]; then

        printf 'вкл\n'

    else

        printf 'выкл\n'

    fi

}

# ============================================================
# EVENT LOG
# ============================================================
#
# .flashos/logs/flashos.log лежит в незашифрованной части флешки,
# поэтому в журнал пишутся только время и тип события — без имён
# Vault, файлов и путей.

log_event() {

    [[ -n "$FLASHOS_DIR" && -d "$FLASHOS_DIR" ]] || return 0

    [[ "$(get_setting LOG_ENABLED 1)" == "1" ]] || return 0

    local file="$FLASHOS_DIR/logs/flashos.log"

    local size

    mkdir -p "$FLASHOS_DIR/logs" 2>/dev/null || return 0

    printf '%s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" \
        >> "$file" 2>/dev/null || return 0

    size=$(stat -c %s "$file" 2>/dev/null || echo 0)

    if (( size > LOG_MAX_BYTES )); then

        mv -f "$file" "$file.1" 2>/dev/null || true

    fi

    return 0

}

# Сколько раз вводили неверный пароль после последнего удачного входа
count_failed_unlocks() {

    local file="$FLASHOS_DIR/logs/flashos.log"

    if [[ ! -f "$file" ]]; then

        echo 0

        return

    fi

    awk -F' [|] ' '
        $2 == "UNLOCK_OK"   { n = 0 }
        $2 == "UNLOCK_FAIL" { n++ }
        END { print n + 0 }
    ' "$file" 2>/dev/null || echo 0

}

show_log() {

    local file="$FLASHOS_DIR/logs/flashos.log"

    header

    echo -e \
        "${BOLD}📜 ЖУРНАЛ СОБЫТИЙ${RESET}" \
        > /dev/tty

    echo > /dev/tty

    if [[ "$(get_setting LOG_ENABLED 1)" != "1" ]]; then

        warn "Журнал выключен в настройках."

    fi

    if [[ -s "$file" ]]; then

        tail -n 40 "$file" > /dev/tty

        echo > /dev/tty

        echo "Показаны последние записи. Файл: $file" > /dev/tty

    else

        echo "Журнал пуст." > /dev/tty

    fi

    pause_screen

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

    size=$(lsblk \
        -ndo SIZE \
        "$target" \
        2>/dev/null || echo "?")

    model=$(lsblk \
        -ndo MODEL \
        "$target" \
        2>/dev/null || echo "?")

    filesystem=$(lsblk \
        -ndo FSTYPE \
        "$target" \
        2>/dev/null || echo "?")

    label=$(lsblk \
        -ndo LABEL \
        "$target" \
        2>/dev/null || echo "")

    parent=$(lsblk \
        -no PKNAME \
        "$target" \
        2>/dev/null \
        | head -n1 || echo "?")

    header

    echo -e \
        "${RED}${BOLD}⚠ ОПАСНАЯ ОПЕРАЦИЯ${RESET}" \
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

    echo -e \
        "${BOLD}💿 FORMAT USB${RESET}" \
        > /dev/tty

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

        sudo umount \
            "$mounted" \
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

    echo \
        "Форматирование в exFAT..." \
        > /dev/tty

    echo > /dev/tty

    if sudo mkfs.exfat \
        -F \
        -n "$label" \
        "$target"
    then

        sync

        echo > /dev/tty

        success \
            "Форматирование завершено."

        return 0

    fi

    error_msg \
        "Форматирование не удалось."

    return 1

}

# ============================================================
# INSTALL FLASHOS
# ============================================================

install_flashos() {

    header

    echo -e \
        "${BOLD}🚀 УСТАНОВКА FLASHOS${RESET}" \
        > /dev/tty

    echo > /dev/tty

    local devices=()

    local dev

    while read -r dev; do

        [[ -n "$dev" ]] || continue

        devices+=("$dev")

    done < <(get_usb_partitions)

    if (( ${#devices[@]} == 0 )); then

        error_msg \
            "USB-флешка не найдена."

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

        warn \
            "Установка отменена."

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

    info \
        "Подключаю новую файловую систему..."

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

        error_msg \
            "Mount point не найден."

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

    echo "[7/8] Main password" > /dev/tty

    echo > /dev/tty

    echo -e \
        "${YELLOW}${BOLD}🔐 СОЗДАНИЕ ГЛАВНОГО ПАРОЛЯ FLASHOS${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Этот пароль понадобится на других компьютерах." \
        > /dev/tty

    echo > /dev/tty

    if ! gocryptfs \
        -init \
        "$FLASHOS_DIR/data"
    then

        error_msg \
            "Не удалось создать зашифрованное хранилище."

        pause_screen

        return

    fi

    echo "[8/8] Manifest + Manager" > /dev/tty

    write_manifest \
        "$device_name" \
        "$FLASHOS_VERSION"

    backup_keys || true

    log_event "INSTALL $FLASHOS_VERSION"

    # Копируем этот же единый flashos.sh на FlashOS
    cp -- \
        "$0" \
        "$FLASHOS_DIR/flashos.sh"

    chmod 755 \
        "$FLASHOS_DIR/flashos.sh"

    cat > "$FLASHOS_DIR/readme.txt" <<EOF
FlashOS
=======

Device: $device_name
Version: $FLASHOS_VERSION

GitHub:
https://github.com/$GITHUB_REPO

Use FlashOS Manager.

Do not modify .flashos manually.
EOF

    sync

    echo > /dev/tty

    success \
        "FlashOS установлен."

    echo \
        "Имя:        $device_name" \
        > /dev/tty

    echo \
        "Версия:     $FLASHOS_VERSION" \
        > /dev/tty

    echo \
        "Filesystem: exFAT" \
        > /dev/tty

    echo \
        "Security:   gocryptfs" \
        > /dev/tty

    pause_screen

}

# ============================================================
# UNLOCK
# ============================================================

unlock_flashos() {

    mkdir -p "$MAIN_MOUNT"

    if mountpoint -q \
        "$MAIN_MOUNT" \
        2>/dev/null
    then

        return 0

    fi

    if [[ \
        ! -f "$FLASHOS_DIR/data/gocryptfs.conf"
    ]]; then

        error_msg \
            "Главное хранилище FlashOS не найдено."

        if [[ -f "$FLASHOS_DIR/recovery/keys/gocryptfs.conf" ]]; then

            info \
                "Есть копия ключей: 🛟 Recovery → Восстановить ключи из копии."

        fi

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
        "Для показа содержимого нужен пароль." \
        > /dev/tty

    echo > /dev/tty

    local status

    gocryptfs \
        "$FLASHOS_DIR/data" \
        "$MAIN_MOUNT"

    status=$?

    if (( status == 0 )); then

        local failed

        failed=$(count_failed_unlocks)

        log_event "UNLOCK_OK"

        # Пароль подошёл — значит ключи целы, можно обновить их копию
        backup_keys || true

        success \
            "FlashOS разблокирован."

        if (( failed > 0 )); then

            warn \
                "Неудачных попыток ввода пароля с прошлого входа: $failed"

            pause_screen

        fi

        return 0

    fi

    # 12 — код gocryptfs «неверный пароль»
    if (( status == 12 )); then

        log_event "UNLOCK_FAIL"

    else

        log_event "UNLOCK_ERROR code=$status"

    fi

    error_msg \
        "Неверный пароль или ошибка хранилища."

    return 1

}

# ============================================================
# LOCK
# ============================================================

session_active() {

    mountpoint -q \
        "$MAIN_MOUNT" \
        2>/dev/null

}

# Через сколько секунд бездействия блокировать (0 — никогда).
# Автоблокировка работает только пока хранилище открыто.
idle_timeout_seconds() {

    local seconds

    if ! session_active; then

        echo 0

        return

    fi

    seconds=$(get_setting AUTOLOCK_SECONDS 0)

    [[ "$seconds" =~ ^[0-9]{1,6}$ ]] || seconds=0

    echo "$((10#$seconds))"

}

# unmount_point ТОЧКА [force]
#
#   0 — размонтировано (или не было смонтировано)
#   1 — занято, осталось смонтированным
#   2 — было занято, отключено принудительно (lazy unmount)
unmount_point() {

    local target="$1"

    local mode="${2:-}"

    mountpoint -q "$target" 2>/dev/null || return 0

    sync

    fusermount3 \
        -u \
        "$target" \
        >/dev/null 2>&1 || true

    mountpoint -q "$target" 2>/dev/null || return 0

    [[ "$mode" == "force" ]] || return 1

    fusermount3 \
        -u \
        -z \
        "$target" \
        >/dev/null 2>&1 || true

    if mountpoint -q "$target" 2>/dev/null; then

        return 1

    fi

    return 2

}

# Удаляет пустую точку монтирования. Никогда не удаляет содержимое:
# если хранилище не удалось размонтировать, рекурсивное удаление
# стёрло бы сами файлы пользователя.
remove_mount_dir() {

    local target="$1"

    [[ -d "$target" ]] || return 0

    if mountpoint -q "$target" 2>/dev/null; then

        return 1

    fi

    rmdir "$target" 2>/dev/null || true

}

# lock_flashos [force]
#
# Коды возврата те же, что у unmount_point.
lock_flashos() {

    local mode="${1:-}"

    local status

    local result=0

    unmount_point "$VAULT_MOUNT" "$mode"

    status=$?

    (( status != 1 )) || return 1

    (( status != 2 )) || result=2

    remove_mount_dir "$VAULT_MOUNT"

    unmount_point "$MAIN_MOUNT" "$mode"

    status=$?

    (( status != 1 )) || return 1

    (( status != 2 )) || result=2

    remove_mount_dir "$MAIN_MOUNT"

    CURRENT_VAULT=""

    return "$result"

}

# Завершает открытый сеанс и оставляет заметку для главного меню.
#
#   manual / hotkey — блокировать сейчас, даже если хранилище занято
#   idle            — автоблокировка; занятое хранилище не трогаем
#
# Возвращает 1, если заблокировать не удалось.
end_session() {

    local reason="$1"

    local mode="force"

    local status

    [[ "$reason" != "idle" ]] || mode=""

    lock_flashos "$mode"

    status=$?

    (( status != 1 )) || return 1

    if [[ "$reason" == "idle" ]]; then

        log_event "AUTOLOCK"

        printf 'idle\n' > "$NOTICE_FILE"

    elif (( status == 2 )); then

        log_event "LOCK forced"

        printf 'forced\n' > "$NOTICE_FILE"

    else

        log_event "LOCK"

    fi

    return 0

}

# Показывает, почему сеанс был закрыт (если есть что сказать)
show_lock_notice() {

    local notice

    [[ -f "$NOTICE_FILE" ]] || return 0

    notice=$(head -n1 "$NOTICE_FILE" 2>/dev/null)

    rm -f "$NOTICE_FILE"

    header

    case "$notice" in

        idle)

            info \
                "🔒 FlashOS заблокирован из-за бездействия."

            ;;

        forced)

            warn \
                "Хранилище было занято и отключено принудительно."

            echo > /dev/tty

            echo \
                "Закрой программы, которые работали с файлами FlashOS," \
                > /dev/tty

            echo \
                "прежде чем вынимать флешку." \
                > /dev/tty

            ;;

        *)
            return 0
            ;;

    esac

    pause_screen

}

# ============================================================
# RECOVERY
# ============================================================
#
# gocryptfs.conf содержит мастер-ключ, зашифрованный паролем.
# Если этот файл на флешке повредится, данные не открыть даже с
# верным паролем — поэтому менеджер хранит его копию в
# .flashos/recovery/keys. Копия защищена тем же паролем.

KEY_FILES=(
    gocryptfs.conf
    gocryptfs.diriv
)

# Обновляет копию ключей. Вызывать только когда известно, что
# текущие ключи исправны (после удачного входа или смены пароля).
backup_keys() {

    local source="$FLASHOS_DIR/data"

    local target="$FLASHOS_DIR/recovery/keys"

    local name

    [[ -f "$source/gocryptfs.conf" ]] || return 1

    mkdir -p "$target" 2>/dev/null || return 1

    for name in "${KEY_FILES[@]}"; do

        [[ -f "$source/$name" ]] || continue

        if cmp -s "$source/$name" "$target/$name"; then

            continue

        fi

        cp -f -- "$source/$name" "$target/$name.tmp" || return 1

        mv -f -- "$target/$name.tmp" "$target/$name" || return 1

    done

    sync

    return 0

}

# ok — копия совпадает, missing — копии нет, differs — отличается
keys_backup_state() {

    local source="$FLASHOS_DIR/data"

    local target="$FLASHOS_DIR/recovery/keys"

    local name

    [[ -f "$target/gocryptfs.conf" ]] || {
        echo "missing"
        return
    }

    for name in "${KEY_FILES[@]}"; do

        [[ -f "$target/$name" ]] || continue

        if ! cmp -s "$source/$name" "$target/$name"; then

            echo "differs"

            return

        fi

    done

    echo "ok"

}

keys_backup_label() {

    case "$(keys_backup_state)" in

        ok)
            printf 'актуальна\n'
            ;;

        missing)
            printf 'отсутствует\n'
            ;;

        *)
            printf 'отличается от ключей хранилища\n'
            ;;

    esac

}

show_keys_status() {

    local target="$FLASHOS_DIR/recovery/keys"

    header

    echo -e \
        "${BOLD}🔑 КОПИЯ КЛЮЧЕЙ ШИФРОВАНИЯ${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo "Состояние: $(keys_backup_label)" > /dev/tty

    echo "Папка:     $target" > /dev/tty

    if [[ -f "$target/gocryptfs.conf" ]]; then

        echo \
            "Создана:   $(date -r "$target/gocryptfs.conf" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" \
            > /dev/tty

    fi

    echo > /dev/tty

    echo "Копия обновляется сама после каждого удачного входа" > /dev/tty

    echo "и после смены главного пароля. Она зашифрована тем же" > /dev/tty

    echo "паролем и не позволяет открыть данные без него." > /dev/tty

    if [[ "$(keys_backup_state)" == "missing" ]]; then

        echo > /dev/tty

        info "Копия появится после первого удачного входа."

    fi

    pause_screen

}

restore_keys() {

    local source="$FLASHOS_DIR/recovery/keys"

    local target="$FLASHOS_DIR/data"

    local damaged

    local answer

    local name

    header

    echo -e \
        "${BOLD}♻ ВОССТАНОВЛЕНИЕ КЛЮЧЕЙ${RESET}" \
        > /dev/tty

    echo > /dev/tty

    if session_active; then

        error_msg "Сначала заблокируй FlashOS."

        pause_screen

        return

    fi

    case "$(keys_backup_state)" in

        missing)

            error_msg "Копия ключей не найдена."

            pause_screen

            return

            ;;

        ok)

            success "Ключи хранилища совпадают с копией."

            echo > /dev/tty

            echo "Восстановление не требуется." > /dev/tty

            pause_screen

            return

            ;;

    esac

    warn "Ключи хранилища отличаются от сохранённой копии."

    echo > /dev/tty

    echo "Так бывает, если файл ключей повреждён или удалён." > /dev/tty

    echo "После восстановления будет действовать пароль, который" > /dev/tty

    echo "был у FlashOS в момент создания копии." > /dev/tty

    echo > /dev/tty

    echo "Текущие файлы ключей не удаляются — они будут отложены" > /dev/tty

    echo "в папку recovery/keys/damaged-*." > /dev/tty

    echo > /dev/tty

    read -rp \
        "Введи RESTORE-KEYS: " \
        answer < /dev/tty

    if [[ "$answer" != "RESTORE-KEYS" ]]; then

        warn "Восстановление отменено."

        pause_screen

        return

    fi

    damaged="$source/damaged-$(date '+%Y%m%d-%H%M%S')"

    mkdir -p "$damaged" "$target" || {

        error_msg "Не удалось подготовить папки."

        pause_screen

        return

    }

    for name in "${KEY_FILES[@]}"; do

        [[ -f "$source/$name" ]] || continue

        if [[ -f "$target/$name" ]]; then

            mv -f -- "$target/$name" "$damaged/$name" || {

                error_msg "Не удалось отложить $name."

                pause_screen

                return

            }

        fi

        cp -f -- "$source/$name" "$target/$name" || {

            error_msg "Не удалось восстановить $name."

            pause_screen

            return

        }

    done

    rmdir "$damaged" 2>/dev/null || true

    sync

    log_event "KEYS_RESTORED"

    success "Ключи восстановлены из копии."

    echo > /dev/tty

    echo "Теперь попробуй открыть FlashOS своим паролем." > /dev/tty

    pause_screen

}

# Проверка шифрованного хранилища средствами gocryptfs
fsck_storage() {

    local status

    header

    echo -e \
        "${BOLD}🧪 ПРОВЕРКА ШИФРОВАННОГО ХРАНИЛИЩА${RESET}" \
        > /dev/tty

    echo > /dev/tty

    if [[ ! -f "$FLASHOS_DIR/data/gocryptfs.conf" ]]; then

        error_msg "Главное хранилище FlashOS не найдено."

        pause_screen

        return

    fi

    echo "gocryptfs прочитает все файлы и проверит их целостность." > /dev/tty

    echo "Данные не изменяются. Понадобится главный пароль." > /dev/tty

    echo > /dev/tty

    gocryptfs \
        -fsck \
        "$FLASHOS_DIR/data"

    status=$?

    echo > /dev/tty

    log_event "FSCK code=$status"

    # 26 — код gocryptfs «fsck нашёл ошибки»
    case "$status" in

        0)
            success "Повреждений не найдено."
            ;;

        26)
            error_msg "Найдены повреждённые файлы (список выше)."
            ;;

        12)
            error_msg "Неверный пароль — проверка не выполнена."
            ;;

        *)
            error_msg "Проверка не выполнена (код gocryptfs: $status)."
            ;;

    esac

    pause_screen

}

# Возврат к версии менеджера, сохранённой при обновлении
rollback_manager() {

    local backup_dir="$FLASHOS_DIR/recovery/manager-backups"

    local files=()

    local options=()

    local file

    local version

    while IFS= read -r file; do

        [[ -n "$file" ]] || continue

        version=$(get_script_version "$file")

        files+=("$file")

        options+=("${version:-?}  ($(basename -- "$file"))")

    done < <(
        find "$backup_dir" \
            -maxdepth 1 \
            -type f \
            -name 'flashos-*.sh' \
            -printf '%T@ %p\n' \
            2>/dev/null \
            | sort -rn \
            | cut -d' ' -f2-
    )

    if (( ${#files[@]} == 0 )); then

        header

        warn "Сохранённых версий менеджера нет."

        echo > /dev/tty

        echo "Они появляются после обновления FlashOS." > /dev/tty

        pause_screen

        return

    fi

    local index

    index=$(arrow_menu \
        "⏪ ОТКАТ МЕНЕДЖЕРА — ВЫБЕРИ ВЕРСИЮ" \
        "${options[@]}" \
        "⬅ Назад")

    [[ "$index" =~ ^[0-9]+$ ]] || return

    (( index < ${#files[@]} )) || return

    file="${files[$index]}"

    version=$(get_script_version "$file")

    header

    if [[ -z "$version" ]] || ! bash -n "$file" 2>/dev/null; then

        error_msg "Сохранённый файл повреждён — откат отменён."

        pause_screen

        return

    fi

    local current_version

    current_version=$(get_manifest FLASHOS_VERSION)

    local confirm

    confirm=$(arrow_menu \
        "⏪ ОТКАТ ${current_version:-?} → $version" \
        "⏪ Откатить менеджер" \
        "❌ Отмена")

    [[ "$confirm" == "0" ]] || return

    header

    if [[ -f "$FLASHOS_DIR/flashos.sh" ]]; then

        cp -a -- \
            "$FLASHOS_DIR/flashos.sh" \
            "$backup_dir/flashos-${current_version:-unknown}-$(date '+%Y%m%d-%H%M%S').sh"

    fi

    if ! cp -f -- "$file" "$FLASHOS_DIR/flashos.sh.tmp" \
        || ! mv -f -- "$FLASHOS_DIR/flashos.sh.tmp" "$FLASHOS_DIR/flashos.sh"
    then

        error_msg "Не удалось записать менеджер."

        pause_screen

        return

    fi

    chmod 755 "$FLASHOS_DIR/flashos.sh" 2>/dev/null || true

    write_manifest \
        "$(get_manifest DEVICE_NAME)" \
        "$version"

    rm -f "$FLASHOS_DIR/system/update-check"

    sync

    log_event "ROLLBACK ${current_version:-?} -> $version"

    success "Менеджер на флешке возвращён к версии $version."

    echo > /dev/tty

    echo "Данные, Vault и Backup не изменялись." > /dev/tty

    pause_screen

    local restart

    restart=$(arrow_menu \
        "ROLLBACK COMPLETE" \
        "🔄 Запустить версию $version" \
        "✅ Остаться")

    if [[ "$restart" == "0" ]]; then

        exec bash \
            "$FLASHOS_DIR/flashos.sh"

    fi

}

recovery_menu() {

    while true; do

        local selected

        selected=$(arrow_menu \
            "🛟 RECOVERY" \
            "🔑 Копия ключей: $(keys_backup_label)" \
            "♻ Восстановить ключи из копии" \
            "🧪 Проверить шифрованное хранилище (fsck)" \
            "⏪ Откатить менеджер на прошлую версию" \
            "⬅ Назад")

        case "$selected" in

            0)
                show_keys_status
                ;;

            1)
                restore_keys
                ;;

            2)
                fsck_storage
                ;;

            3)
                rollback_manager
                ;;

            4|255)
                return
                ;;

        esac

    done

}

# ============================================================
# FILES
# ============================================================

# Истина, если копирование этой папки в хранилище зациклится:
# это корень, сама флешка FlashOS или папка, внутри которой она
# (либо открытое хранилище) находится.
path_contains_storage() {

    local path="$1"

    local guarded

    [[ "$path" != "/" ]] || return 0

    for guarded in "$RUNTIME_BASE" "$MAIN_MOUNT" "$FLASHOS_DIR"; do

        [[ -n "$guarded" ]] || continue

        if [[ "$guarded/" == "$path/"* ]]; then

            return 0

        fi

    done

    [[ -n "$FLASHOS_DIR" && "$path/" == "$FLASHOS_DIR/"* ]]

}

# Хватит ли на флешке места для копирования $1
has_free_space() {

    local need

    local available

    need=$(du -sk -- "$1" 2>/dev/null | cut -f1)

    available=$(df -Pk -- "$DEVICE_MOUNT" 2>/dev/null \
        | awk 'NR == 2 { print $4 }')

    # Не удалось оценить — не мешаем пользователю
    [[ "$need" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] || return 0

    if (( need >= available )); then

        error_msg \
            "Недостаточно места: нужно $(human_kb "$need"), свободно $(human_kb "$available")."

        return 1

    fi

    return 0

}

files_search() {

    local query

    local results

    local count

    header

    echo -e \
        "${BOLD}🔎 ПОИСК ПО ИМЕНИ${RESET}" \
        > /dev/tty

    echo > /dev/tty

    ask query "Что искать (часть имени): " || return

    [[ -n "$query" ]] || return

    # Содержимое закрытых Vault зашифровано, искать в нём бессмысленно
    results=$(find \
        "$MAIN_MOUNT" \
        -mindepth 1 \
        -path "$MAIN_MOUNT/vaults" -prune \
        -o \
        -iname "*${query}*" \
        -printf '%P\n' \
        2>/dev/null \
        | sort)

    echo > /dev/tty

    if [[ -z "$results" ]]; then

        warn "Ничего не найдено."

        pause_screen

        return

    fi

    count=$(grep -c '' <<< "$results")

    head -n 200 <<< "$results" > /dev/tty

    echo > /dev/tty

    if (( count > 200 )); then

        echo "Найдено: $count (показаны первые 200)" > /dev/tty

    else

        echo "Найдено: $count" > /dev/tty

    fi

    pause_screen

}

files_import() {

    local source

    local target

    header

    echo -e \
        "${BOLD}📥 ИМПОРТ В ХРАНИЛИЩЕ${RESET}" \
        > /dev/tty

    echo > /dev/tty

    ask source "Путь к файлу или папке: " || return

    source=$(expand_path "$source")

    [[ -n "$source" ]] || return

    if [[ ! -e "$source" ]]; then

        error_msg "Файл или папка не найдены."

        pause_screen

        return

    fi

    source=$(realpath -- "$source")

    if path_contains_storage "$source"; then

        error_msg "Этот путь нельзя импортировать: он содержит саму флешку FlashOS."

        pause_screen

        return

    fi

    target="$MAIN_MOUNT/$(basename -- "$source")"

    if [[ -e "$target" ]]; then

        error_msg "В хранилище уже есть «$(basename -- "$source")»."

        pause_screen

        return

    fi

    if ! has_free_space "$source"; then

        pause_screen

        return

    fi

    echo > /dev/tty

    echo "📦 Копирую и шифрую..." > /dev/tty

    if cp -a -- "$source" "$MAIN_MOUNT/"; then

        success "Импорт завершён."

        echo > /dev/tty

        echo "Оригинал остался на месте — удали его сам, если он больше не нужен." > /dev/tty

        log_event "IMPORT"

    else

        error_msg "Ошибка копирования."

        log_event "IMPORT_FAIL"

    fi

    sync

    pause_screen

}

files_usage() {

    local usage

    header

    echo -e \
        "${BOLD}📊 ЧТО ЗАНИМАЕТ МЕСТО${RESET}" \
        > /dev/tty

    echo > /dev/tty

    usage=$(
        cd "$MAIN_MOUNT" 2>/dev/null \
            && find . -mindepth 1 -maxdepth 1 -print0 2>/dev/null \
                | xargs -0 -r du -sh -- 2>/dev/null \
                | sort -rh \
                | head -n 15 \
                | sed 's|\t\./|\t|'
    )

    if [[ -n "$usage" ]]; then

        printf '%s\n' "$usage" > /dev/tty

    else

        echo "Хранилище пусто." > /dev/tty

    fi

    echo > /dev/tty

    df -h \
        "$DEVICE_MOUNT" \
        > /dev/tty

    pause_screen

}

files_menu() {

    while true; do

        session_active || return

        local selected

        selected=$(arrow_menu \
            "📁 FILES" \
            "📂 Открыть хранилище" \
            "📄 Показать содержимое" \
            "🔎 Поиск по имени" \
            "📥 Импорт файла или папки" \
            "📊 Что занимает место" \
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

            2)
                files_search
                ;;

            3)
                files_import
                ;;

            4)
                files_usage
                ;;

            5|255)

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

# Закрывает открытый Vault. Коды возврата — как у unmount_point:
# 1 означает, что Vault занят и остался открытым.
close_vault() {

    local status

    unmount_point "$VAULT_MOUNT" force

    status=$?

    (( status == 1 )) || remove_mount_dir "$VAULT_MOUNT"

    return "$status"

}

create_vault() {

    header

    echo -e \
        "${BOLD}🔐 CREATE VAULT${RESET}" \
        > /dev/tty

    echo > /dev/tty

    local name

    ask name "Название Vault: " || return

    name=$(sanitize_vault_name "$name")

    [[ -n "$name" ]] || return

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

    mkdir -p \
        "$cipher"

    echo > /dev/tty

    echo \
        "Создай пароль Vault." \
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

    log_event "VAULT_CREATE"

    success \
        "Vault создан."

    echo > /dev/tty

    local source

    ask source "Папка для переноса (Enter = пропустить): " || return

    source=$(expand_path "$source")

    if [[ -n "$source" ]]; then

        if [[ ! -d "$source" ]]; then

            error_msg \
                "Папка не найдена."

            pause_screen

            return

        fi

        source=$(realpath -- "$source")

        if path_contains_storage "$source"; then

            error_msg \
                "Эту папку нельзя копировать: она содержит саму флешку FlashOS."

            pause_screen

            return

        fi

        if ! has_free_space "$source"; then

            pause_screen

            return

        fi

        close_vault

        if (( $? == 1 )); then

            error_msg \
                "Не удалось закрыть ранее открытый Vault: он занят."

            pause_screen

            return

        fi

        mkdir -p \
            "$VAULT_MOUNT"

        if gocryptfs \
            "$cipher" \
            "$VAULT_MOUNT"
        then

            echo \
                "📦 Копирую данные..." \
                > /dev/tty

            if cp -a -- \
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

            close_vault

            if (( $? == 1 )); then

                warn \
                    "Vault занят и остался открытым."

            fi

        else

            error_msg \
                "Не удалось открыть Vault."

            remove_mount_dir "$VAULT_MOUNT"

        fi

    fi

    pause_screen

}

open_vault() {

    local vaults

    vaults=$(list_vaults)

    if [[ -z "$vaults" ]]; then

        warn \
            "Vault пока нет."

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

    close_vault

    if (( $? == 1 )); then

        error_msg \
            "Не удалось закрыть ранее открытый Vault: он занят."

        pause_screen

        return

    fi

    mkdir -p \
        "$VAULT_MOUNT"

    header

    echo \
        "🔐 Vault: $selected_vault" \
        > /dev/tty

    echo > /dev/tty

    local status

    gocryptfs \
        "$cipher" \
        "$VAULT_MOUNT"

    status=$?

    if (( status != 0 )); then

        # 12 — код gocryptfs «неверный пароль»
        if (( status == 12 )); then

            log_event "VAULT_OPEN_FAIL"

        else

            log_event "VAULT_OPEN_ERROR code=$status"

        fi

        error_msg \
            "Неверный пароль или повреждённый Vault."

        remove_mount_dir "$VAULT_MOUNT"

        pause_screen

        return

    fi

    log_event "VAULT_OPEN"

    success \
        "Vault открыт."

    while true; do

        # Vault мог быть закрыт автоблокировкой или клавишей L
        mountpoint -q "$VAULT_MOUNT" 2>/dev/null || return

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

                mountpoint -q "$VAULT_MOUNT" 2>/dev/null || return

                close_vault

                case "$?" in

                    0)

                        success \
                            "Vault закрыт."

                        ;;

                    2)

                        warn \
                            "Vault был занят и отключён принудительно."

                        echo \
                            "Закрой программы, которые работали с его файлами." \
                            > /dev/tty

                        ;;

                    *)

                        error_msg \
                            "Не удалось закрыть Vault: он занят."

                        pause_screen

                        continue

                        ;;

                esac

                pause_screen

                return

                ;;

        esac

    done

}

sanitize_vault_name() {

    local name="$1"

    name="${name// /_}"

    name="${name//\//_}"

    # Имя не может начинаться с точки: такой Vault не виден в списке
    while [[ "$name" == .* ]]; do

        name="${name#.}"

    done

    printf '%s\n' "$name"

}

manage_vault() {

    local vaults=()

    local vault

    while IFS= read -r vault; do

        [[ -n "$vault" ]] || continue

        vaults+=("$vault")

    done < <(list_vaults)

    if (( ${#vaults[@]} == 0 )); then

        warn \
            "Vault пока нет."

        pause_screen

        return

    fi

    local index

    index=$(arrow_menu \
        "🛠 УПРАВЛЕНИЕ VAULT — ВЫБЕРИ" \
        "${vaults[@]}" \
        "⬅ Назад")

    [[ "$index" =~ ^[0-9]+$ ]] || return

    (( index < ${#vaults[@]} )) || return

    local name="${vaults[$index]}"

    local cipher

    local action

    while true; do

        session_active || return

        cipher="$MAIN_MOUNT/vaults/${name}.vault"

        action=$(arrow_menu \
            "🛠 VAULT: $name" \
            "✏ Переименовать" \
            "🔑 Сменить пароль" \
            "📊 Размер" \
            "🗑 Удалить Vault" \
            "⬅ Назад")

        case "$action" in

            0)

                header

                local new_name

                ask new_name "Новое название Vault: " || return

                new_name=$(sanitize_vault_name "$new_name")

                if [[ -z "$new_name" ]]; then

                    continue

                fi

                if [[ -e "$MAIN_MOUNT/vaults/${new_name}.vault" ]]; then

                    error_msg \
                        "Такой Vault уже существует."

                elif mv -- \
                    "$cipher" \
                    "$MAIN_MOUNT/vaults/${new_name}.vault"
                then

                    name="$new_name"

                    log_event "VAULT_RENAME"

                    success \
                        "Vault переименован в $name."

                else

                    error_msg \
                        "Не удалось переименовать Vault."

                fi

                pause_screen

                ;;

            1)

                header

                echo \
                    "🔑 Смена пароля Vault: $name" \
                    > /dev/tty

                echo > /dev/tty

                echo \
                    "Сначала введи текущий пароль, затем новый." \
                    > /dev/tty

                echo > /dev/tty

                if gocryptfs \
                    -passwd \
                    "$cipher"
                then

                    sync

                    log_event "VAULT_PASSWD"

                    success \
                        "Пароль Vault изменён."

                else

                    error_msg \
                        "Пароль не изменён."

                fi

                pause_screen

                ;;

            2)

                header

                echo \
                    "📊 Vault: $name" \
                    > /dev/tty

                echo > /dev/tty

                echo \
                    "Размер: $(du -sh -- "$cipher" 2>/dev/null | cut -f1)" \
                    > /dev/tty

                echo \
                    "Файлов: $(find "$cipher" -type f ! -name gocryptfs.conf ! -name gocryptfs.diriv ! -name '*.name' 2>/dev/null | wc -l)" \
                    > /dev/tty

                pause_screen

                ;;

            3)

                header

                echo -e \
                    "${RED}${BOLD}🗑 УДАЛЕНИЕ VAULT: $name${RESET}" \
                    > /dev/tty

                echo > /dev/tty

                echo \
                    "Все файлы внутри Vault будут удалены без возможности восстановления." \
                    > /dev/tty

                echo > /dev/tty

                local typed

                ask typed "Для подтверждения введи название Vault: " || return

                if [[ "$typed" != "$name" ]]; then

                    warn \
                        "Удаление отменено."

                    pause_screen

                    continue

                fi

                if [[ -n "$name" && -d "$cipher" ]] \
                    && rm -rf -- "$cipher"
                then

                    sync

                    log_event "VAULT_DELETE"

                    success \
                        "Vault удалён."

                    pause_screen

                    return

                fi

                error_msg \
                    "Не удалось удалить Vault."

                pause_screen

                ;;

            4|255)

                return

                ;;

        esac

    done

}

vault_menu() {

    while true; do

        session_active || return

        local selected

        selected=$(arrow_menu \
            "🔐 VAULT MODE" \
            "Создать Vault" \
            "Открыть Vault" \
            "Управление Vault" \
            "Назад")

        case "$selected" in

            0)
                create_vault
                ;;

            1)
                open_vault
                ;;

            2)
                manage_vault
                ;;

            3|255)
                return
                ;;

        esac

    done

}

# ============================================================
# BACKUP
# ============================================================
#
# Каждый Backup — папка Backups/<дата_время> в зашифрованном
# хранилище. Рядом с данными лежит файл контрольных сумм SHA-256,
# посчитанных по ОРИГИНАЛУ: по нему копию можно проверить и сразу
# после создания, и через год.

list_backups() {

    find \
        "$MAIN_MOUNT/Backups" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' \
        2>/dev/null \
        | sort -r

}

# choose_backup "ЗАГОЛОВОК"  →  имя в CHOSEN_ITEM
choose_backup() {

    local backups=()

    local backup

    CHOSEN_ITEM=""

    while IFS= read -r backup; do

        [[ -n "$backup" ]] || continue

        backups+=("$backup")

    done < <(list_backups)

    if (( ${#backups[@]} == 0 )); then

        header

        warn "Backup пока нет."

        pause_screen

        return 1

    fi

    local index

    index=$(arrow_menu \
        "$1" \
        "${backups[@]}" \
        "⬅ Назад")

    [[ "$index" =~ ^[0-9]+$ ]] || return 1

    (( index < ${#backups[@]} )) || return 1

    CHOSEN_ITEM="${backups[$index]}"

    [[ -n "$CHOSEN_ITEM" ]]

}

# Считает SHA-256 файлов оригинала и кладёт список в папку Backup
write_backup_checksums() {

    local source="$1"

    local destination="$2"

    local parent

    local base

    parent=$(dirname -- "$source")

    base=$(basename -- "$source")

    (
        cd -- "$parent" || exit 1

        set -o pipefail

        find "./$base" -type f -print0 \
            | sort -z \
            | xargs -0 -r sha256sum --
    ) > "$destination/$CHECKSUM_FILE" 2>/dev/null

}

# Сверяет файлы в папке $1 со списком контрольных сумм.
#
#   0 — всё совпало, 1 — есть расхождения (список выводится),
#   2 — у этой копии нет контрольных сумм
verify_checksums() {

    local dir="$1"

    [[ -f "$dir/$CHECKSUM_FILE" ]] || return 2

    # Пустой список — пустая папка-оригинал, сверять нечего
    [[ -s "$dir/$CHECKSUM_FILE" ]] || return 0

    (
        cd -- "$dir" || exit 1

        sha256sum --quiet -c "$CHECKSUM_FILE"
    ) > /dev/tty 2>&1

}

backup_create() {

    local source

    header

    echo -e \
        "${BOLD}💾 СОЗДАНИЕ BACKUP${RESET}" \
        > /dev/tty

    echo > /dev/tty

    ask source "Путь к папке: " || return

    source=$(expand_path "$source")

    if [[ -z "$source" || ! -d "$source" ]]; then

        error_msg \
            "Папка не найдена."

        pause_screen

        return

    fi

    source=$(realpath -- "$source")

    if path_contains_storage "$source" \
        || [[ "$MAIN_MOUNT/Backups/" == "$source/"* ]]
    then

        error_msg \
            "Эту папку нельзя копировать: она содержит саму флешку FlashOS или её Backup."

        pause_screen

        return

    fi

    if ! has_free_space "$source"; then

        pause_screen

        return

    fi

    local timestamp

    timestamp=$(date \
        '+%Y-%m-%d_%H-%M-%S')

    local destination

    destination="$MAIN_MOUNT/Backups/$timestamp"

    if ! mkdir -p "$destination"; then

        error_msg \
            "Не удалось создать папку Backup."

        pause_screen

        return

    fi

    echo > /dev/tty

    echo \
        "📦 Создание Backup..." \
        > /dev/tty

    local copied=0

    cp -a -- \
        "$source" \
        "$destination/" \
        || copied=1

    sync

    echo \
        "🧮 Проверка копии по SHA-256..." \
        > /dev/tty

    local summed=0

    write_backup_checksums "$source" "$destination" || summed=1

    echo > /dev/tty

    local verified

    verify_checksums "$destination"

    verified=$?

    if (( verified == 1 )); then

        error_msg \
            "Backup неполный: перечисленные выше файлы не совпадают с оригиналом."

        log_event "BACKUP_FAIL"

    elif (( verified == 2 )); then

        error_msg \
            "Ошибка Backup: копию не удалось проверить."

        log_event "BACKUP_FAIL"

    elif (( summed != 0 )); then

        warn \
            "Backup создан, но часть файлов оригинала не удалось прочитать."

        log_event "BACKUP_PARTIAL"

    elif (( copied != 0 )); then

        warn \
            "Все файлы скопированы и проверены, но cp сообщил об ошибках."

        echo \
            "Обычно это ссылки или права доступа, которые exFAT не хранит." \
            > /dev/tty

        log_event "BACKUP_CREATE"

    else

        success \
            "Backup создан и проверен: $timestamp"

        log_event "BACKUP_CREATE"

    fi

    sync

    pause_screen

}

backup_list() {

    local backup

    local dir

    local mark

    local found=0

    header

    echo -e \
        "${BOLD}💾 СПИСОК BACKUP${RESET}" \
        > /dev/tty

    echo > /dev/tty

    while IFS= read -r backup; do

        [[ -n "$backup" ]] || continue

        found=1

        dir="$MAIN_MOUNT/Backups/$backup"

        if [[ -f "$dir/$CHECKSUM_FILE" ]]; then

            mark="SHA-256"

        else

            mark="без контрольных сумм"

        fi

        printf '%s  %8s  %s\n' \
            "$backup" \
            "$(du -sh -- "$dir" 2>/dev/null | cut -f1)" \
            "$mark" \
            > /dev/tty

        find "$dir" \
            -mindepth 1 \
            -maxdepth 1 \
            ! -name "$CHECKSUM_FILE" \
            -printf '    └ %f\n' \
            2>/dev/null \
            > /dev/tty

    done < <(list_backups)

    if (( found == 0 )); then

        echo "Backup пока нет." > /dev/tty

    fi

    pause_screen

}

backup_verify() {

    choose_backup "🧮 ПРОВЕРИТЬ BACKUP" || return

    local name="$CHOSEN_ITEM"

    header

    echo \
        "🧮 Проверка Backup $name по SHA-256..." \
        > /dev/tty

    echo > /dev/tty

    verify_checksums "$MAIN_MOUNT/Backups/$name"

    case "$?" in

        0)

            success \
                "Backup цел: все файлы совпадают с контрольными суммами."

            log_event "BACKUP_VERIFY ok"

            ;;

        2)

            warn \
                "У этого Backup нет контрольных сумм (он создан старой версией)."

            ;;

        *)

            echo > /dev/tty

            error_msg \
                "Backup повреждён: перечисленные выше файлы не совпадают."

            log_event "BACKUP_VERIFY failed"

            ;;

    esac

    pause_screen

}

backup_restore() {

    choose_backup "♻ ВОССТАНОВИТЬ BACKUP" || return

    local name="$CHOSEN_ITEM"

    local source="$MAIN_MOUNT/Backups/$name"

    local default_target="$HOME/FlashOS-Restore"

    local target

    header

    echo \
        "♻ Восстановление Backup $name" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Файлы будут скопированы в новую папку <куда>/$name." \
        > /dev/tty

    echo \
        "Существующие файлы на компьютере не перезаписываются." \
        > /dev/tty

    echo > /dev/tty

    ask target "Куда восстановить [$default_target]: " || return

    target=$(expand_path "$target")

    [[ -n "$target" ]] || target="$default_target"

    if ! mkdir -p -- "$target"; then

        error_msg \
            "Не удалось создать папку $target."

        pause_screen

        return

    fi

    target="$(realpath -- "$target")/$name"

    if [[ "$target/" == "$MAIN_MOUNT/Backups/"* ]]; then

        error_msg \
            "Нельзя восстанавливать Backup внутрь папки Backups."

        pause_screen

        return

    fi

    if [[ -e "$target" ]]; then

        error_msg \
            "Папка $target уже существует."

        pause_screen

        return

    fi

    if ! mkdir -- "$target"; then

        error_msg \
            "Не удалось создать папку $target."

        pause_screen

        return

    fi

    echo > /dev/tty

    echo \
        "📦 Копирую..." \
        > /dev/tty

    local copied=0

    cp -a -- \
        "$source/." \
        "$target/" \
        || copied=1

    sync

    echo > /dev/tty

    verify_checksums "$target"

    case "$?" in

        0)

            success \
                "Backup восстановлен и проверен."

            log_event "BACKUP_RESTORE"

            ;;

        2)

            if (( copied == 0 )); then

                success \
                    "Backup восстановлен (без проверки: у него нет контрольных сумм)."

                log_event "BACKUP_RESTORE"

            else

                error_msg \
                    "Ошибка копирования."

                log_event "BACKUP_RESTORE_FAIL"

            fi

            ;;

        *)

            error_msg \
                "Восстановленные файлы не совпадают с контрольными суммами."

            log_event "BACKUP_RESTORE_FAIL"

            ;;

    esac

    rm -f -- "$target/$CHECKSUM_FILE"

    echo > /dev/tty

    printf '%s\n' "Папка: $target" > /dev/tty

    pause_screen

}

backup_delete() {

    choose_backup "🗑 УДАЛИТЬ BACKUP" || return

    local name="$CHOSEN_ITEM"

    local dir="$MAIN_MOUNT/Backups/$name"

    local answer

    header

    echo -e \
        "${RED}${BOLD}🗑 УДАЛЕНИЕ BACKUP: $name${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Размер: $(du -sh -- "$dir" 2>/dev/null | cut -f1)" \
        > /dev/tty

    echo > /dev/tty

    ask answer "Введи DELETE: " || return

    if [[ "$answer" != "DELETE" ]]; then

        warn \
            "Удаление отменено."

        pause_screen

        return

    fi

    if [[ -n "$name" && -d "$dir" ]] \
        && rm -rf -- "$dir"
    then

        sync

        log_event "BACKUP_DELETE"

        success \
            "Backup удалён."

    else

        error_msg \
            "Не удалось удалить Backup."

    fi

    pause_screen

}

backup_menu() {

    mkdir -p \
        "$MAIN_MOUNT/Backups"

    while true; do

        session_active || return

        local selected

        selected=$(arrow_menu \
            "💾 BACKUP" \
            "Создать Backup" \
            "Показать Backup" \
            "Проверить Backup (SHA-256)" \
            "Восстановить Backup" \
            "Удалить Backup" \
            "Назад")

        case "$selected" in

            0)
                backup_create
                ;;

            1)
                backup_list
                ;;

            2)
                backup_verify
                ;;

            3)
                backup_restore
                ;;

            4)
                backup_delete
                ;;

            5|255)
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

        session_active || return

        local selected

        selected=$(arrow_menu \
            "🩺 DIAGNOSTICS" \
            "Информация об устройстве" \
            "Проверить структуру FlashOS" \
            "Показать место" \
            "📜 Журнал событий" \
            "🧪 Проверить шифрованное хранилище (fsck)" \
            "Назад")

        case "$selected" in

            0)

                header

                echo \
                    "Device:      $DEVICE" \
                    > /dev/tty

                echo \
                    "Mount:       $DEVICE_MOUNT" \
                    > /dev/tty

                echo > /dev/tty

                echo \
                    "Size:        $(lsblk -ndo SIZE "$DEVICE" 2>/dev/null)" \
                    > /dev/tty

                echo \
                    "Filesystem:  $(lsblk -ndo FSTYPE "$DEVICE" 2>/dev/null)" \
                    > /dev/tty

                echo \
                    "Label:       $(lsblk -ndo LABEL "$DEVICE" 2>/dev/null)" \
                    > /dev/tty

                echo \
                    "Model:       $(lsblk -ndo MODEL "$DEVICE" 2>/dev/null)" \
                    > /dev/tty

                echo > /dev/tty

                echo \
                    "FlashOS:     $(get_manifest DEVICE_NAME)" \
                    > /dev/tty

                echo \
                    "Version:     $(get_manifest FLASHOS_VERSION)" \
                    > /dev/tty

                echo \
                    "Security:    $(get_manifest SECURITY)" \
                    > /dev/tty

                pause_screen

                ;;

            1)

                header

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

                local path

                for path in \
                    "${required_paths[@]}"
                do

                    if [[ -e "$path" ]]; then

                        success \
                            "$path"

                    else

                        error_msg \
                            "Missing: $path"

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

            3)
                show_log
                ;;

            4)
                fsck_storage
                ;;

            5|255)

                return

                ;;

        esac

    done

}

# ============================================================
# SETTINGS
# ============================================================

autolock_label() {

    local seconds

    seconds=$(get_setting AUTOLOCK_SECONDS 0)

    [[ "$seconds" =~ ^[0-9]{1,6}$ ]] || seconds=0

    seconds=$((10#$seconds))

    if (( seconds == 0 )); then

        printf 'выкл\n'

    elif (( seconds % 60 == 0 )); then

        printf '%s мин\n' "$((seconds / 60))"

    else

        printf '%s сек\n' "$seconds"

    fi

}

autolock_settings() {

    local selected

    selected=$(arrow_menu \
        "⏱ АВТОБЛОКИРОВКА ПРИ БЕЗДЕЙСТВИИ" \
        "Выключена" \
        "1 минута" \
        "5 минут" \
        "10 минут" \
        "30 минут" \
        "⬅ Назад")

    case "$selected" in

        0)
            set_setting AUTOLOCK_SECONDS 0
            ;;

        1)
            set_setting AUTOLOCK_SECONDS 60
            ;;

        2)
            set_setting AUTOLOCK_SECONDS 300
            ;;

        3)
            set_setting AUTOLOCK_SECONDS 600
            ;;

        4)
            set_setting AUTOLOCK_SECONDS 1800
            ;;

    esac

}

change_main_password() {

    header

    echo -e \
        "${YELLOW}${BOLD}🔑 СМЕНА ГЛАВНОГО ПАРОЛЯ FLASHOS${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Сначала введи текущий пароль, затем новый." \
        > /dev/tty

    echo \
        "Файлы не перешифровываются — это занимает секунды." \
        > /dev/tty

    echo > /dev/tty

    if gocryptfs \
        -passwd \
        "$FLASHOS_DIR/data"
    then

        # Старая копия ключей открывалась бы старым паролем
        backup_keys || true

        sync

        log_event "PASSWD_MAIN"

        success \
            "Главный пароль изменён, копия ключей обновлена."

    else

        error_msg \
            "Пароль не изменён."

    fi

    pause_screen

}

settings_menu() {

    while true; do

        session_active || return

        local selected

        selected=$(arrow_menu \
            "⚙ SETTINGS" \
            "Изменить имя FlashOS" \
            "Показать manifest" \
            "⏱ Автоблокировка: $(autolock_label)" \
            "🔑 Сменить главный пароль" \
            "📜 Журнал событий: $(on_off "$(get_setting LOG_ENABLED 1)")" \
            "🧹 Очистить журнал" \
            "🔔 Проверка обновлений при запуске: $(on_off "$(get_setting UPDATE_CHECK 1)")" \
            "Назад")

        case "$selected" in

            0)

                header

                local new_name

                ask new_name "Новое имя: " || return

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

            2)
                autolock_settings
                ;;

            3)
                change_main_password
                ;;

            4)

                # Отметка о выключении остаётся в журнале
                if [[ "$(get_setting LOG_ENABLED 1)" == "1" ]]; then

                    log_event "LOG_DISABLED"

                fi

                toggle_setting LOG_ENABLED 1

                ;;

            5)

                rm -f \
                    "$FLASHOS_DIR/logs/flashos.log" \
                    "$FLASHOS_DIR/logs/flashos.log.1"

                log_event "LOG_CLEARED"

                header

                success \
                    "Журнал очищен."

                pause_screen

                ;;

            6)
                toggle_setting UPDATE_CHECK 1
                ;;

            7|255)

                return

                ;;

        esac

    done

}

# ============================================================
# GITHUB RELEASE HELPERS
# ============================================================

get_latest_release_json() {

    curl \
        -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$GITHUB_API" \
        2>/dev/null

}

get_release_tag() {

    local json="$1"

    printf '%s' "$json" \
        | jq -r '.tag_name // empty'

}

get_release_name() {

    local json="$1"

    printf '%s' "$json" \
        | jq -r '.name // empty'

}

get_release_date() {

    local json="$1"

    printf '%s' "$json" \
        | jq -r '.published_at // empty'

}

get_release_url() {

    local json="$1"

    printf '%s' "$json" \
        | jq -r '.html_url // empty'

}

get_release_body() {

    local json="$1"

    printf '%s' "$json" \
        | jq -r '.body // empty'

}

get_tag_script_url() {

    local tag="$1"

    printf '%s\n' \
        "https://raw.githubusercontent.com/${GITHUB_REPO}/${tag}/flashos.sh"

}

get_script_version() {

    local file="$1"

    sed -n \
        's/^FLASHOS_VERSION="\([0-9][0-9.]*\)"/\1/p' \
        "$file" \
        | head -n1

}

version_is_newer() {

    local remote="$1"

    local local="$2"

    [[ "$remote" != "$local" ]] || return 1

    local newest

    newest=$(printf \
        '%s\n%s\n' \
        "$remote" \
        "$local" \
        | sort -V \
        | tail -n1)

    [[ "$newest" == "$remote" ]]

}

# ============================================================
# RELEASE NOTES
# ============================================================

show_release_notes() {

    local json="$1"

    local name

    local tag

    local published

    local url

    local body

    name=$(get_release_name "$json")

    tag=$(get_release_tag "$json")

    published=$(get_release_date "$json")

    url=$(get_release_url "$json")

    body=$(get_release_body "$json")

    header

    echo -e \
        "${BOLD}📋 GITHUB LATEST RELEASE${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Release:   ${name:-$tag}" \
        > /dev/tty

    echo \
        "Tag:       $tag" \
        > /dev/tty

    [[ -n "$published" ]] && \
        echo \
            "Published: $published" \
            > /dev/tty

    echo > /dev/tty

    echo -e \
        "${BOLD}Что нового:${RESET}" \
        > /dev/tty

    echo > /dev/tty

    if [[ -n "$body" ]]; then

        printf '%s\n' \
            "$body" \
            > /dev/tty

    else

        echo \
            "Описание релиза отсутствует." \
            > /dev/tty

    fi

    echo > /dev/tty

    if [[ -n "$url" ]]; then

        echo \
            "GitHub: $url" \
            > /dev/tty

    fi

    pause_screen

}

# ============================================================
# UPDATE NOTIFICATION
# ============================================================
#
# Раз в сутки при запуске менеджер в фоне спрашивает у GitHub
# номер последней версии и запоминает его на флешке. Интерфейс
# это не задерживает; отключается в настройках.

check_update_background() {

    [[ -n "$FLASHOS_DIR" ]] || return 0

    [[ "$(get_setting UPDATE_CHECK 1)" == "1" ]] || return 0

    local cache="$FLASHOS_DIR/system/update-check"

    local now

    local last

    now=$(date +%s)

    last=$(file_value "$cache" CHECKED)

    [[ "$last" =~ ^[0-9]{1,12}$ ]] || last=0

    (( now - 10#$last >= UPDATE_CHECK_INTERVAL )) || return 0

    (
        json=$(curl \
            -fsSL \
            --connect-timeout 4 \
            --max-time 8 \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$GITHUB_API") || exit 0

        tag=$(get_release_tag "$json")

        [[ -n "$tag" ]] || exit 0

        temp_file="$RUNTIME_BASE/update-check.$BASHPID.sh"

        if ! curl \
            -fsSL \
            --connect-timeout 4 \
            --max-time 15 \
            "$(get_tag_script_url "$tag")" \
            -o "$temp_file"
        then

            rm -f "$temp_file"

            exit 0

        fi

        version=$(get_script_version "$temp_file")

        rm -f "$temp_file"

        [[ -n "$version" ]] || exit 0

        mkdir -p "$FLASHOS_DIR/system" || exit 0

        printf 'CHECKED=%s\nLATEST_VERSION=%s\n' \
            "$now" \
            "$version" \
            > "$cache.tmp" || exit 0

        mv -f "$cache.tmp" "$cache"

    ) >/dev/null 2>&1 &

}

# Печатает номер новой версии, если она известна и новее установленной
available_update() {

    local latest

    local installed

    latest=$(file_value "$FLASHOS_DIR/system/update-check" LATEST_VERSION)

    [[ "$latest" =~ ^[0-9][0-9.]{0,20}$ ]] || return 0

    installed=$(get_manifest FLASHOS_VERSION)

    [[ -n "$installed" ]] || installed="$FLASHOS_VERSION"

    if version_is_newer "$latest" "$installed"; then

        printf '%s\n' "$latest"

    fi

}

# ============================================================
# UPDATE FLASHOS
# ============================================================

update_flashos() {

    header

    echo -e \
        "${BOLD}🔄 FLASHOS UPDATE${RESET}" \
        > /dev/tty

    echo > /dev/tty

    info \
        "Проверяю GitHub Latest Release..."

    local json

    json=$(get_latest_release_json || true)

    if [[ -z "$json" ]]; then

        error_msg \
            "Не удалось получить Latest Release."

        pause_screen

        return

    fi

    local tag

    local release_name

    local release_url

    tag=$(get_release_tag "$json")

    release_name=$(get_release_name "$json")

    release_url=$(get_release_url "$json")

    if [[ -z "$tag" ]]; then

        error_msg \
            "GitHub не вернул tag_name."

        pause_screen

        return

    fi

    local latest_url

    latest_url=$(get_tag_script_url "$tag")

    local local_version

    local_version=$(get_manifest FLASHOS_VERSION)

    [[ -n "$local_version" ]] || \
        local_version="$FLASHOS_VERSION"

    echo \
        "Installed: $local_version" \
        > /dev/tty

    echo \
        "Release:   ${release_name:-$tag}" \
        > /dev/tty

    echo \
        "Tag:       $tag" \
        > /dev/tty

    echo > /dev/tty

    local temp_file

    temp_file="$RUNTIME_BASE/flashos-update.sh"

    rm -f \
        "$temp_file"

    echo \
        "⬇ Скачиваю flashos.sh из Latest Release..." \
        > /dev/tty

    echo > /dev/tty

    if ! curl \
        -fL \
        --connect-timeout 10 \
        --max-time 60 \
        --progress-bar \
        "$latest_url" \
        -o "$temp_file"
    then

        error_msg \
            "Не удалось скачать flashos.sh."

        rm -f \
            "$temp_file"

        pause_screen

        return

    fi

    echo > /dev/tty

    echo \
        "🧪 Проверка Bash syntax..." \
        > /dev/tty

    if ! bash \
        -n \
        "$temp_file"
    then

        error_msg \
            "Скачанный файл содержит ошибку Bash syntax."

        rm -f \
            "$temp_file"

        pause_screen

        return

    fi

    local remote_version

    remote_version=$(get_script_version "$temp_file")

    if [[ -z "$remote_version" ]]; then

        error_msg \
            "Не найден FLASHOS_VERSION в скачанном файле."

        rm -f \
            "$temp_file"

        pause_screen

        return

    fi

    echo > /dev/tty

    echo \
        "Installed version: $local_version" \
        > /dev/tty

    echo \
        "Release version:   $remote_version" \
        > /dev/tty

    echo > /dev/tty

    if [[ "$local_version" == "$remote_version" ]]; then

        success \
            "FlashOS уже последней версии."

        rm -f \
            "$temp_file"

        local choice

        choice=$(arrow_menu \
            "LATEST RELEASE" \
            "📋 Посмотреть изменения" \
            "⬅ Назад")

        case "$choice" in

            0)

                show_release_notes "$json"

                ;;

        esac

        return

    fi

    if ! version_is_newer \
        "$remote_version" \
        "$local_version"
    then

        warn \
            "Версия из Latest Release не новее установленной."

        rm -f \
            "$temp_file"

        pause_screen

        return

    fi

    echo -e \
        "${YELLOW}${BOLD}⚡ Доступно обновление: $local_version → $remote_version${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Обновляется только FlashOS Manager." \
        > /dev/tty

    echo \
        "Пользовательские данные НЕ заменяются." \
        > /dev/tty

    echo \
        "Vault НЕ заменяются." \
        > /dev/tty

    echo \
        "Backup НЕ заменяются." \
        > /dev/tty

    echo > /dev/tty

    local action

    action=$(arrow_menu \
        "🔄 UPDATE $local_version → $remote_version" \
        "🚀 Установить обновление" \
        "📋 Посмотреть изменения" \
        "❌ Отмена")

    case "$action" in

        0)

            ;;

        1)

            show_release_notes "$json"

            rm -f \
                "$temp_file"

            return

            ;;

        2|255)

            rm -f \
                "$temp_file"

            return

            ;;

    esac

    # --------------------------------------------------------
    # Backup старого менеджера
    # --------------------------------------------------------

    local backup_dir

    backup_dir="$FLASHOS_DIR/recovery/manager-backups"

    mkdir -p \
        "$backup_dir"

    if [[ \
        -f "$FLASHOS_DIR/flashos.sh"
    ]]; then

        local backup_file

        backup_file="$backup_dir/flashos-${local_version}-$(date '+%Y%m%d-%H%M%S').sh"

        cp -a \
            "$FLASHOS_DIR/flashos.sh" \
            "$backup_file"

    fi

    # --------------------------------------------------------
    # Install new manager
    # --------------------------------------------------------

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

    # Сведения о «доступном обновлении» устарели
    rm -f \
        "$FLASHOS_DIR/system/update-check"

    log_event "UPDATE $local_version -> $remote_version"

    sync

    echo > /dev/tty

    success \
        "FlashOS обновлён до $remote_version."

    if [[ -n "$release_url" ]]; then

        echo \
            "Release: $release_url" \
            > /dev/tty

    fi

    echo > /dev/tty

    echo \
        "Старый manager сохранён в recovery." \
        > /dev/tty

    pause_screen

    # --------------------------------------------------------
    # Start updated manager
    # --------------------------------------------------------

    local restart

    restart=$(arrow_menu \
        "UPDATE COMPLETE" \
        "🔄 Запустить новую версию" \
        "✅ Остаться")

    case "$restart" in

        0)

            exec bash \
                "$FLASHOS_DIR/flashos.sh"

            ;;

        *)

            ;;

    esac

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
        "Устройство: $DEVICE" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Будут удалены:" \
        > /dev/tty

    echo \
        "  • FlashOS" \
        > /dev/tty

    echo \
        "  • зашифрованное хранилище" \
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

    if [[ \
        "$first" != \
        "REMOVE FLASHOS"
    ]]; then

        warn \
            "Удаление отменено."

        pause_screen

        return

    fi

    local second

    read -rp \
        "Введи DELETE-ALL: " \
        second < /dev/tty

    if [[ \
        "$second" != \
        "DELETE-ALL"
    ]]; then

        warn \
            "Удаление отменено."

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
# INFO
# ============================================================

show_flashos_info() {

    header

    echo -e \
        "${BOLD}ℹ FLASHOS INFORMATION${RESET}" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "Device:       $DEVICE" \
        > /dev/tty

    echo \
        "Name:         $(get_manifest DEVICE_NAME)" \
        > /dev/tty

    echo \
        "FlashOS:      $(get_manifest FLASHOS_VERSION)" \
        > /dev/tty

    echo \
        "Filesystem:   $(get_manifest FILESYSTEM)" \
        > /dev/tty

    echo \
        "Security:     $(get_manifest SECURITY)" \
        > /dev/tty

    echo \
        "Manager:      $(get_manifest MANAGER)" \
        > /dev/tty

    echo > /dev/tty

    echo \
        "GitHub:       https://github.com/$GITHUB_REPO" \
        > /dev/tty

    echo > /dev/tty

    df -h \
        "$DEVICE_MOUNT" \
        > /dev/tty

    pause_screen

}

# ============================================================
# SAFE EJECT
# ============================================================

# Размонтирует раздел и отключает питание флешки
eject_device() {

    local dev="$1"

    local parent

    sync

    if findmnt -rn -S "$dev" >/dev/null 2>&1; then

        if ! udisksctl unmount \
            -b "$dev" \
            >/dev/null 2>&1
        then

            error_msg \
                "Не удалось размонтировать $dev: флешка занята."

            echo > /dev/tty

            echo \
                "Закрой программы и окна, в которых открыты файлы с флешки," \
                > /dev/tty

            echo \
                "и повтори. Пока НЕ вынимай флешку." \
                > /dev/tty

            return 1

        fi

    fi

    parent=$(lsblk \
        -no PKNAME \
        "$dev" \
        2>/dev/null \
        | head -n1 || true)

    if [[ -n "$parent" ]] \
        && udisksctl power-off \
            -b "/dev/$parent" \
            >/dev/null 2>&1
    then

        success \
            "Питание флешки отключено — её можно вынимать."

    else

        success \
            "Флешка размонтирована — её можно вынимать."

    fi

    return 0

}

# Блокирует FlashOS и безопасно извлекает флешку.
# Возвращает 0, если флешка извлечена.
eject_flashos() {

    local self

    local status

    header

    echo -e \
        "${BOLD}⏏ БЕЗОПАСНОЕ ИЗВЛЕЧЕНИЕ${RESET}" \
        > /dev/tty

    echo > /dev/tty

    # Без принудительного отключения: вынимать флешку, пока
    # какая-то программа держит на ней открытые файлы, нельзя.
    if ! lock_flashos; then

        error_msg \
            "Хранилище занято: какая-то программа работает с файлами FlashOS."

        echo > /dev/tty

        echo \
            "Закрой её и повтори. Пока НЕ вынимай флешку." \
            > /dev/tty

        pause_screen

        return 1

    fi

    log_event "EJECT"

    case "$PWD/" in

        "$DEVICE_MOUNT/"*)
            cd / || true
            ;;

    esac

    # Если менеджер запущен с самой флешки, его файл держит её
    # занятой. Продолжаем работу из временной копии.
    self=$(realpath -- "$0" 2>/dev/null || true)

    if [[ "$self" == "$DEVICE_MOUNT/"* ]]; then

        if cp -f -- "$self" "$RUNTIME_BASE/flashos-eject.sh"; then

            exec bash \
                "$RUNTIME_BASE/flashos-eject.sh" \
                --eject "$DEVICE"

        fi

    fi

    eject_device "$DEVICE"

    status=$?

    pause_screen

    return "$status"

}

# ============================================================
# MAIN WORK MENU
# ============================================================

work_menu() {

    if ! unlock_flashos; then

        pause_screen

        return

    fi

    while true; do

        # Сеанс мог быть закрыт автоблокировкой или клавишей L
        session_active || return

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

                if session_active && ! end_session manual; then

                    header

                    error_msg \
                        "Не удалось заблокировать FlashOS: хранилище занято."

                    pause_screen

                    continue

                fi

                return

                ;;

        esac

    done

}

# ============================================================
# FLASHOS FOUND MENU
# ============================================================
#
# Возвращает 0 — выход из программы, 10 — искать флешку заново.

flashos_found_menu() {

    while true; do

        show_lock_notice

        local name

        name=$(get_manifest DEVICE_NAME)

        local installed_version

        installed_version=$(get_manifest FLASHOS_VERSION)

        local title="💾 FLASHOS: ${name:-FLASHOS} [$installed_version]"

        local update

        update=$(available_update)

        if [[ -n "$update" ]]; then

            title+="   ${YELLOW}⚡ доступно обновление $update${RESET}"

        fi

        local selected

        selected=$(arrow_menu \
            "$title" \
            "🚀 Работать с FlashOS" \
            "🔄 Обновить до Latest Release" \
            "📋 Посмотреть изменения Latest Release" \
            "🛟 Recovery" \
            "🗑 Удалить FlashOS" \
            "ℹ Информация" \
            "⏏ Безопасно извлечь" \
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

                local latest_json

                latest_json=$(get_latest_release_json || true)

                if [[ -n "$latest_json" ]]; then

                    show_release_notes \
                        "$latest_json"

                else

                    error_msg \
                        "Не удалось получить Latest Release."

                    pause_screen

                fi

                ;;

            3)
                recovery_menu
                ;;

            4)

                remove_flashos

                return 10

                ;;

            5)
                show_flashos_info
                ;;

            6)

                if eject_flashos; then

                    return 10

                fi

                ;;

            7)

                header

                echo \
                    "🔌 Подключи другую флешку FlashOS." \
                    > /dev/tty

                echo > /dev/tty

                echo \
                    "Если подключено несколько — после поиска можно будет выбрать." \
                    > /dev/tty

                pause_screen

                return 10

                ;;

            8|255)

                return 0

                ;;

        esac

    done

}

# ============================================================
# CLEANUP
# ============================================================

cleanup() {

    local was_active=1

    local status

    session_active && was_active=0

    # Только размонтирование и удаление ПУСТЫХ папок (см. remove_mount_dir)
    lock_flashos force

    status=$?

    if (( was_active == 0 && status != 1 )); then

        log_event "LOCK"

    fi

    if (( status == 2 )); then

        warn \
            "Хранилище было занято и отключено принудительно: закрой программы, работавшие с файлами FlashOS." \
            2>/dev/null

    elif (( status == 1 )); then

        warn \
            "Хранилище FlashOS занято и осталось открытым: $MAIN_MOUNT" \
            2>/dev/null

    fi

    rm -f \
        "$NOTICE_FILE" \
        "$RUNTIME_BASE/flashos-eject.sh" \
        "$RUNTIME_BASE/flashos-update.sh"

    rmdir \
        "$RUNTIME_BASE" \
        2>/dev/null || true

}

# ============================================================
# COMMAND LINE
# ============================================================

usage() {

    cat <<EOF
$APP_NAME $FLASHOS_VERSION

Использование:
  flashos.sh [параметры]

Без параметров запускается интерактивный менеджер.

Параметры:
  -h, --help       показать эту справку
  -V, --version    показать версию
      --status     найти подключённые флешки FlashOS и показать их состояние
                   (код возврата 0 — FlashOS найден, 1 — нет)
      --lock       немедленно заблокировать открытое хранилище и Vault
                   (можно вызвать из другого терминала или повесить на клавишу)
      --doctor     проверить зависимости и показать команду установки
      --no-color   без цветов (то же делает переменная NO_COLOR)

Клавиши в меню:
  ↑ ↓ выбор, Enter открыть, Esc или Q назад, L заблокировать FlashOS

https://github.com/$GITHUB_REPO
EOF

}

cli_status() {

    local dev

    local mountpoint

    local manifest

    local unlocked_source=""

    local found=1

    local any=1

    if session_active; then

        unlocked_source=$(findmnt -n -o SOURCE "$MAIN_MOUNT" 2>/dev/null | head -n1)

    fi

    while read -r dev; do

        [[ -n "$dev" ]] || continue

        any=0

        mountpoint=$(findmnt \
            -rn \
            -S "$dev" \
            -o TARGET \
            2>/dev/null \
            | head -n1)

        printf '%s\n' "$dev"

        if [[ -z "$mountpoint" ]]; then

            printf '  Состояние: не смонтирована\n'

            continue

        fi

        printf '  Mount:     %s\n' "$mountpoint"

        manifest="$mountpoint/.flashos/manifest"

        if [[ ! -f "$manifest" ]]; then

            printf '  FlashOS:   не установлен\n'

            continue

        fi

        found=0

        printf '  FlashOS:   %s\n' "$(file_value "$manifest" DEVICE_NAME)"

        printf '  Версия:    %s\n' "$(file_value "$manifest" FLASHOS_VERSION)"

        if [[ "$unlocked_source" == "$mountpoint/.flashos/data" ]]; then

            printf '  Состояние: разблокирован\n'

        else

            printf '  Состояние: заблокирован\n'

        fi

    done < <(get_usb_partitions)

    if (( any != 0 )); then

        printf 'USB-накопители не найдены.\n'

    fi

    return "$found"

}

cli_lock() {

    if ! session_active \
        && ! mountpoint -q "$VAULT_MOUNT" 2>/dev/null
    then

        printf 'Открытых хранилищ FlashOS нет.\n'

        return 0

    fi

    lock_flashos force

    case "$?" in

        0)
            printf 'FlashOS заблокирован.\n'
            ;;

        2)
            printf 'FlashOS заблокирован принудительно: хранилище было занято.\n'
            printf 'Закрой программы, которые работали с его файлами, прежде чем вынимать флешку.\n'
            ;;

        *)
            printf 'Не удалось заблокировать FlashOS: хранилище занято.\n' >&2
            return 1
            ;;

    esac

    return 0

}

cli_doctor() {

    local command_name

    local missing=0

    printf '%s %s\n\n' "$APP_NAME" "$FLASHOS_VERSION"

    for command_name in "${REQUIRED_COMMANDS[@]}"; do

        if command -v "$command_name" >/dev/null 2>&1; then

            printf '  [ok]  %s\n' "$command_name"

        else

            printf '  [нет] %s\n' "$command_name"

            missing=1

        fi

    done

    printf '\n'

    if (( missing == 0 )); then

        printf 'Все зависимости на месте.\n'

        return 0

    fi

    printf 'Не хватает зависимостей. Установка:\n'

    install_hint

    return 1

}

# Разбирает параметры. Команды, не требующие интерфейса,
# выполняются сразу и завершают программу.
handle_cli() {

    local action=""

    while (( $# > 0 )); do

        case "$1" in

            -h|--help)
                action="help"
                ;;

            -V|--version)
                action="version"
                ;;

            --status|--lock|--doctor)
                action="${1#--}"
                ;;

            --no-color)
                disable_colors
                ;;

            --eject)

                # Служебный параметр: см. eject_flashos
                EJECT_ON_START="${2:-}"

                shift

                ;;

            *)

                printf 'Неизвестный параметр: %s\n\n' "$1" >&2

                usage >&2

                exit 2

                ;;

        esac

        shift

    done

    [[ -n "$action" ]] || return 0

    local status=0

    case "$action" in

        help)
            usage
            ;;

        version)
            printf '%s %s\n' "$APP_NAME" "$FLASHOS_VERSION"
            ;;

        status)
            cli_status
            status=$?
            ;;

        lock)
            cli_lock
            status=$?
            ;;

        doctor)
            cli_doctor
            status=$?
            ;;

    esac

    # Папка создаётся при запуске; если в ней ничего нет, убираем
    rmdir "$RUNTIME_BASE" 2>/dev/null || true

    exit "$status"

}

# ============================================================
# STARTUP
# ============================================================

main() {

    if ! { : > /dev/tty; } 2>/dev/null; then

        printf '%s\n' \
            "FlashOS Manager — интерактивная программа, ей нужен терминал. См. --help." \
            >&2

        exit 1

    fi

    check_dependencies

    if [[ -n "$EJECT_ON_START" ]]; then

        header

        echo -e \
            "${BOLD}⏏ БЕЗОПАСНОЕ ИЗВЛЕЧЕНИЕ${RESET}" \
            > /dev/tty

        echo > /dev/tty

        if is_removable_partition "$EJECT_ON_START"; then

            eject_device "$EJECT_ON_START"

        else

            error_msg \
                "$EJECT_ON_START — не раздел USB-накопителя."

        fi

        pause_screen

    fi

    local status

    local not_found_title

    while true; do

        header

        echo -e \
            "${CYAN}🔍 Поиск USB-устройств...${RESET}" \
            > /dev/tty

        sleep 0.5

        detect_flashos

        status=$?

        if (( status == 0 )); then

            echo > /dev/tty

            success \
                "Флешка найдена."

            echo \
                "Device:  $DEVICE" \
                > /dev/tty

            echo \
                "Name:    $(get_manifest DEVICE_NAME)" \
                > /dev/tty

            echo \
                "Version: $(get_manifest FLASHOS_VERSION)" \
                > /dev/tty

            echo > /dev/tty

            success \
                "FlashOS найден."

            sleep 0.6

            check_update_background

            flashos_found_menu

            if (( $? == 10 )); then

                continue

            fi

            return 0

        fi

        echo > /dev/tty

        if (( status == 2 )); then

            not_found_title="FLASHOS НЕ ВЫБРАН"

        else

            not_found_title="FLASHOS NOT FOUND"

            warn \
                "FlashOS на подключённой флешке не найден."

            echo > /dev/tty

        fi

        local selected

        selected=$(arrow_menu \
            "$not_found_title" \
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
                return 0
                ;;

        esac

    done

}

# ============================================================
# RUN
# ============================================================

handle_cli "$@"

# Ctrl+C, закрытие терминала и kill завершают программу через
# cleanup: хранилище блокируется.
trap cleanup EXIT

trap 'exit 130' INT TERM HUP

main
