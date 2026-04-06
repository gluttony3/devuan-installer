#!/usr/bin/env bash
# =============================================================================
# devuan-installer.sh — Головний файл інсталятора Devuan GNU/Linux
#
# Використання:
#   sudo bash devuan-installer.sh
#
# Вимоги:
#   - Завантажений з Devuan live ISO (будь-який варіант)
#   - Підключення до інтернету
#   - Цільовий диск буде повністю стертий
#
# Стек:
#   Init:       OpenRC + elogind
#   Робочий стіл: KDE Plasma (Wayland, мінімальний)
#   Аудіо:      PipeWire + WirePlumber
#   Мережа:     NetworkManager
#   Завантажувач: GRUB (UEFI та BIOS)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Підключаємо всі модулі
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/detect.sh"
source "${SCRIPT_DIR}/lib/disk.sh"
source "${SCRIPT_DIR}/lib/install.sh"
source "${SCRIPT_DIR}/lib/configure.sh"

# Лог-файл загальний
LOG=/tmp/devuan-installer.log
exec > >(tee -a "$LOG") 2>&1

# =============================================================================
# ЗБІР КОНФІГУРАЦІЇ ВІД КОРИСТУВАЧА
# =============================================================================
get_user_config() {
    section "Конфігурація системи"

    # ── Hostname ───────────────────────────────────────────────────────────────
    ask_string "Ім'я комп'ютера (hostname)" "devuan-pc" HOSTNAME
    while [[ ! "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; do
        warn "  Hostname: лише латинські літери, цифри та дефіс"
        ask_string "Ім'я комп'ютера (hostname)" "devuan-pc" HOSTNAME
    done

    # ── Username ───────────────────────────────────────────────────────────────
    ask_string "Ім'я користувача" "user" USERNAME
    while [[ ! "$USERNAME" =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; do
        warn "  Ім'я: лише малі латинські літери, цифри, _ та -"
        ask_string "Ім'я користувача" "user" USERNAME
    done

    # ── Паролі ────────────────────────────────────────────────────────────────
    echo ""
    ask_password "Пароль root" ROOT_PASSWORD
    ask_password "Пароль для ${USERNAME}" USER_PASSWORD

    # ── Часовий пояс ──────────────────────────────────────────────────────────
    echo ""
    local TZ_OPTIONS=(
        "Europe/Kyiv    — Київ (Україна)"
        "Europe/Warsaw  — Варшава (Польща)"
        "Europe/Berlin  — Берлін (Німеччина)"
        "Europe/Moscow  — Москва"
        "Europe/London  — Лондон"
        "America/New_York — Нью-Йорк"
        "Asia/Tokyo     — Токіо"
        "UTC            — UTC"
        "Ввести вручну"
    )
    local tz_choice
    pick_from_list "Часовий пояс" "1" tz_choice "${TZ_OPTIONS[@]}"

    case "$tz_choice" in
        *"Kyiv"*)     TIMEZONE="Europe/Kyiv" ;;
        *"Warsaw"*)   TIMEZONE="Europe/Warsaw" ;;
        *"Berlin"*)   TIMEZONE="Europe/Berlin" ;;
        *"Moscow"*)   TIMEZONE="Europe/Moscow" ;;
        *"London"*)   TIMEZONE="Europe/London" ;;
        *"New_York"*) TIMEZONE="America/New_York" ;;
        *"Tokyo"*)    TIMEZONE="Asia/Tokyo" ;;
        *"UTC"*)      TIMEZONE="UTC" ;;
        *)
            ask_string "Часовий пояс (напр. Europe/Kyiv)" "Europe/Kyiv" TIMEZONE
            while [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; do
                warn "  Не знайдено: /usr/share/zoneinfo/${TIMEZONE}"
                ask_string "Часовий пояс" "Europe/Kyiv" TIMEZONE
            done
            ;;
    esac

    # ── Мова системи (locale) ─────────────────────────────────────────────────
    echo ""
    local LOCALE_OPTIONS=(
        "uk_UA.UTF-8   — Українська"
        "en_US.UTF-8   — English (US)"
        "ru_RU.UTF-8   — Русский"
        "pl_PL.UTF-8   — Polski"
        "de_DE.UTF-8   — Deutsch"
        "fr_FR.UTF-8   — Français"
        "es_ES.UTF-8   — Español"
        "Ввести вручну"
    )
    local locale_choice
    pick_from_list "Мова системи (locale)" "1" locale_choice "${LOCALE_OPTIONS[@]}"

    case "$locale_choice" in
        *"uk_UA"*) LOCALE="uk_UA.UTF-8"; LOCALE_GEN="uk_UA.UTF-8 UTF-8"; XKB_LAYOUT="ua" ;;
        *"en_US"*) LOCALE="en_US.UTF-8"; LOCALE_GEN="en_US.UTF-8 UTF-8"; XKB_LAYOUT="us" ;;
        *"ru_RU"*) LOCALE="ru_RU.UTF-8"; LOCALE_GEN="ru_RU.UTF-8 UTF-8"; XKB_LAYOUT="ru" ;;
        *"pl_PL"*) LOCALE="pl_PL.UTF-8"; LOCALE_GEN="pl_PL.UTF-8 UTF-8"; XKB_LAYOUT="pl" ;;
        *"de_DE"*) LOCALE="de_DE.UTF-8"; LOCALE_GEN="de_DE.UTF-8 UTF-8"; XKB_LAYOUT="de" ;;
        *"fr_FR"*) LOCALE="fr_FR.UTF-8"; LOCALE_GEN="fr_FR.UTF-8 UTF-8"; XKB_LAYOUT="fr" ;;
        *"es_ES"*) LOCALE="es_ES.UTF-8"; LOCALE_GEN="es_ES.UTF-8 UTF-8"; XKB_LAYOUT="es" ;;
        *)
            ask_string "Locale (напр. uk_UA.UTF-8)" "uk_UA.UTF-8" LOCALE
            LOCALE_GEN="${LOCALE} UTF-8"
            ask_string "XKB розкладка (напр. ua)" "ua" XKB_LAYOUT
            ;;
    esac

    # ── Розкладка клавіатури (vconsole) ───────────────────────────────────────
    echo ""
    local KEYMAP_OPTIONS=(
        "ua         — Українська (за замовчуванням)"
        "us         — English (US)"
        "ru         — Русский"
        "pl2        — Polski"
        "de-latin1  — Deutsch"
        "fr         — Français"
        "Ввести вручну"
    )
    local keymap_choice
    pick_from_list "Розкладка консолі (vconsole)" "1" keymap_choice "${KEYMAP_OPTIONS[@]}"

    case "$keymap_choice" in
        *"ua"*)        KEYMAP="ua" ;;
        *"us"*)        KEYMAP="us" ;;
        *"ru"*)        KEYMAP="ru" ;;
        *"pl2"*)       KEYMAP="pl2" ;;
        *"de-latin1"*) KEYMAP="de-latin1" ;;
        *"fr"*)        KEYMAP="fr" ;;
        *) ask_string "Keymap" "ua" KEYMAP ;;
    esac
}

# =============================================================================
# ПІДСУМОК ПЕРЕД ВСТАНОВЛЕННЯМ
# =============================================================================
show_summary() {
    section "Підсумок — перевірте перед встановленням"

    echo ""
    echo -e "  ${BOLD}Залізо:${NC}"
    printf "    %-22s ${CYAN}%s${NC}\n" "Завантаження:"   "$BOOT_MODE"
    printf "    %-22s ${CYAN}%s${NC}\n" "CPU:"             "$CPU_MODEL"
    printf "    %-22s ${CYAN}%s${NC}\n" "Мікрокод:"        "${CPU_MICROCODE:-—}"
    printf "    %-22s ${CYAN}%s${NC}\n" "GPU:"             "$GPU_TYPE"
    printf "    %-22s ${CYAN}%s${NC}\n" "Диск:"            "${INSTALL_DISK} (${DISK_TYPE})"
    printf "    %-22s ${CYAN}%s GB${NC}\n" "RAM:"           "$RAM_GB"
    echo ""
    echo -e "  ${BOLD}Конфігурація:${NC}"
    printf "    %-22s ${CYAN}%s${NC}\n" "Hostname:"        "$HOSTNAME"
    printf "    %-22s ${CYAN}%s${NC}\n" "Користувач:"      "$USERNAME"
    printf "    %-22s ${CYAN}%s${NC}\n" "Часовий пояс:"    "$TIMEZONE"
    printf "    %-22s ${CYAN}%s${NC}\n" "Locale:"          "$LOCALE"
    printf "    %-22s ${CYAN}%s${NC}\n" "Клавіатура:"      "${KEYMAP} / ${XKB_LAYOUT}"
    echo ""
    echo -e "  ${BOLD}Розбивка (${INSTALL_DISK}):${NC}"
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        printf "    %-14s %s\n" "${PART_PREFIX}1" "512 MB   EFI (FAT32)"
        printf "    %-14s %s\n" "${PART_PREFIX}2" "${SWAP_GB} GB    SWAP"
        printf "    %-14s %s\n" "${PART_PREFIX}3" "решта   ROOT (ext4)"
    else
        printf "    %-14s %s\n" "${PART_PREFIX}1" "${SWAP_GB} GB    SWAP"
        printf "    %-14s %s\n" "${PART_PREFIX}2" "решта   ROOT (ext4, boot)"
    fi
    echo ""
    echo -e "  ${BOLD}Програмне забезпечення:${NC}"
    printf "    %-22s ${CYAN}%s${NC}\n" "Init:"            "OpenRC + elogind"
    printf "    %-22s ${CYAN}%s${NC}\n" "Репозиторій:"     "Devuan freia/ceres (rolling)"
    printf "    %-22s ${CYAN}%s${NC}\n" "Робочий стіл:"    "KDE Plasma (Wayland)"
    printf "    %-22s ${CYAN}%s${NC}\n" "Аудіо:"           "PipeWire + WirePlumber"
    printf "    %-22s ${CYAN}%s${NC}\n" "Завантажувач:"    "GRUB"
    $INTEL_GPU_FOUND && printf "    %-22s ${CYAN}%s${NC}\n" "Драйвер Intel:" "mesa + vulkan-intel"
    $AMD_GPU_FOUND   && printf "    %-22s ${CYAN}%s${NC}\n" "Драйвер AMD:"   "mesa + firmware-amd-graphics"
    $NVIDIA_FOUND    && printf "    %-22s ${CYAN}%s${NC}\n" "Драйвер NVIDIA:" "nvidia-driver + nvidia-dkms"
    echo ""
}

# =============================================================================
# ФІНАЛ
# =============================================================================
finish() {
    section "Встановлення завершено"

    # Розмонтовуємо всі розділи
    info "Розмонтування розділів..."
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        umount /mnt/boot/efi 2>/dev/null || true
    fi
    umount -R /mnt 2>/dev/null || true
    swapoff "$SWAP_PART" 2>/dev/null || true

    echo ""
    echo -e "${BOLD}${GREEN}"
    echo -e "  ╔═══════════════════════════════════════════════════╗"
    echo -e "  ║                                                   ║"
    echo -e "  ║   Devuan GNU/Linux успішно встановлений!         ║"
    echo -e "  ║                                                   ║"
    echo -e "  ║   При вході до SDDM оберіть:                     ║"
    echo -e "  ║   «Plasma (Wayland)» зі списку сесій             ║"
    echo -e "  ║                                                   ║"
    echo -e "  ╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  Загальний лог: ${CYAN}${LOG}${NC}"
    echo -e "  Лог chroot:    ${CYAN}/var/log/devuan-install.log${NC} (після перезавантаження)"
    echo ""
    echo -e "  ${YELLOW}Видаліть інсталяційний носій та перезавантажте систему.${NC}"
    echo ""

    confirm "Перезавантажити зараз?" "y" && reboot || true
}

# =============================================================================
# ГОЛОВНА ФУНКЦІЯ
# =============================================================================
main() {
    # ── Перевірки ──────────────────────────────────────────────────────────────
    check_root
    show_banner
    check_internet
    check_deps

    # ── Визначення заліза ──────────────────────────────────────────────────────
    run_detection

    # ── Збір конфігурації ──────────────────────────────────────────────────────
    get_disk          # disk.sh: вибір та визначення типу диску
    get_user_config   # hostname, user, locale, timezone, keymap

    # ── Підсумок та підтвердження ──────────────────────────────────────────────
    show_summary
    echo -e "  ${RED}${BOLD}Це остання можливість скасувати! Всі дані на ${INSTALL_DISK} будуть знищені!${NC}"
    echo ""
    confirm "Розпочати встановлення?" "n" || { info "Відмінено."; exit 0; }

    # ── Побудова списку пакунків ───────────────────────────────────────────────
    build_package_list   # install.sh

    # ── Диск: розбивка, форматування, монтування ───────────────────────────────
    partition_disk       # disk.sh
    format_partitions    # disk.sh
    mount_partitions     # disk.sh

    # ── Встановлення базової системи ───────────────────────────────────────────
    run_debootstrap      # install.sh

    # ── Генерація fstab та запуск chroot ──────────────────────────────────────
    generate_fstab       # configure.sh
    write_install_conf   # configure.sh
    run_chroot           # configure.sh → lib/chroot-setup.sh

    # ── Готово ────────────────────────────────────────────────────────────────
    finish
}

main "$@"
