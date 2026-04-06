#!/usr/bin/env bash
# =============================================================================
# lib/disk.sh — Вибір диску, розбивка, форматування, монтування
# =============================================================================

get_disk() {
    section "Вибір диску для встановлення"

    local names sizes models disks=() display=()

    # Отримуємо тільки фізичні диски (не loop, не rom)
    while read -r name type hotplug size model; do
        [[ "$type" != "disk" ]] && continue
        [[ "$hotplug" == "1" && "$name" == loop* ]] && continue
        disks+=("$name")
        display+=("/dev/${name}  ${size}  ${model:-невідомо}")
    done < <(lsblk -dno NAME,TYPE,HOTPLUG,SIZE,MODEL 2>/dev/null)

    [[ ${#disks[@]} -eq 0 ]] && error "Жодного диску не знайдено!"

    echo ""
    local i choice
    for i in "${!disks[@]}"; do
        echo -e "    $((i+1))) ${display[$i]}"
    done
    echo ""

    while true; do
        read -rp "$(echo -e "  ${CYAN}Оберіть диск [1]: ${NC}")" choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disks[@]} )); then
            INSTALL_DISK="/dev/${disks[$(( choice - 1 ))]}"
            break
        fi
        warn "  Невірний вибір"
    done

    # Prefix для розділів (nvme0n1 → nvme0n1p1, sda → sda1)
    if [[ "$INSTALL_DISK" == *"nvme"* ]] || [[ "$INSTALL_DISK" == *"mmcblk"* ]]; then
        PART_PREFIX="${INSTALL_DISK}p"
    else
        PART_PREFIX="${INSTALL_DISK}"
    fi

    # SSD чи HDD?
    detect_disk_type

    echo ""
    warn "  !! ДИСК ${INSTALL_DISK} (${DISK_TYPE}) БУДЕ ПОВНІСТЮ СТЕРТИЙ !!"
    echo ""
    confirm "Підтвердіть знищення всіх даних на ${INSTALL_DISK}" "n" || \
        error "Відмінено користувачем"

    ok "Вибраний диск: ${INSTALL_DISK} (${DISK_TYPE})"
}

partition_disk() {
    section "Розбивка диску (${BOOT_MODE})"

    info "Очищення диску ${INSTALL_DISK}..."
    wipefs -af "$INSTALL_DISK" >/dev/null 2>&1
    dd if=/dev/zero of="$INSTALL_DISK" bs=1M count=10 &>/dev/null
    sync
    sleep 1

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        # GPT: ESP (512 MB) + SWAP + ROOT
        local swap_end=$(( SWAP_GB * 1024 + 513 ))
        info "Створення GPT (EFI + SWAP + ROOT)..."

        parted -s "$INSTALL_DISK" mklabel gpt
        parted -s "$INSTALL_DISK" mkpart ESP  fat32    1MiB      513MiB
        parted -s "$INSTALL_DISK" set 1 esp on
        parted -s "$INSTALL_DISK" mkpart SWAP linux-swap 513MiB  "${swap_end}MiB"
        parted -s "$INSTALL_DISK" mkpart ROOT ext4    "${swap_end}MiB" 100%

        EFI_PART="${PART_PREFIX}1"
        SWAP_PART="${PART_PREFIX}2"
        ROOT_PART="${PART_PREFIX}3"

        ok "EFI:  ${EFI_PART}  →  512 MB  (FAT32)"
        ok "SWAP: ${SWAP_PART}  →  ${SWAP_GB} GB"
        ok "ROOT: ${ROOT_PART}  →  решта  (ext4)"

    else
        # MBR: SWAP + ROOT (з boot-прапором)
        local swap_end=$(( SWAP_GB * 1024 + 1 ))
        info "Створення MBR (SWAP + ROOT)..."

        parted -s "$INSTALL_DISK" mklabel msdos
        parted -s "$INSTALL_DISK" mkpart primary linux-swap  1MiB  "${swap_end}MiB"
        parted -s "$INSTALL_DISK" mkpart primary ext4  "${swap_end}MiB"  100%
        parted -s "$INSTALL_DISK" set 2 boot on

        EFI_PART=""
        SWAP_PART="${PART_PREFIX}1"
        ROOT_PART="${PART_PREFIX}2"

        ok "SWAP: ${SWAP_PART}  →  ${SWAP_GB} GB"
        ok "ROOT: ${ROOT_PART}  →  решта  (ext4, boot)"
    fi

    partprobe "$INSTALL_DISK" 2>/dev/null || true
    sleep 2
}

format_partitions() {
    section "Форматування розділів"

    info "Форматування ROOT (ext4)..."
    mkfs.ext4 -F -L "Devuan" "$ROOT_PART" >/dev/null
    ok "ROOT → ext4  [${ROOT_PART}]"

    info "Форматування SWAP..."
    mkswap -L "swap" "$SWAP_PART" >/dev/null
    ok "SWAP  [${SWAP_PART}]"

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        info "Форматування EFI (FAT32)..."
        mkfs.fat -F32 -n "EFI" "$EFI_PART" >/dev/null
        ok "EFI  → FAT32  [${EFI_PART}]"
    fi

    # Зберігаємо UUID для fstab
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")
    [[ "$BOOT_MODE" == "UEFI" ]] && EFI_UUID=$(blkid -s UUID -o value "$EFI_PART") || EFI_UUID=""
}

mount_partitions() {
    section "Монтування розділів"

    mount "$ROOT_PART" /mnt
    ok "ROOT → /mnt"

    swapon "$SWAP_PART"
    ok "SWAP активовано"

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        mkdir -p /mnt/boot/efi
        mount "$EFI_PART" /mnt/boot/efi
        ok "EFI  → /mnt/boot/efi"
    fi
}
