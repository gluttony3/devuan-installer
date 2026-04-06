#!/usr/bin/env bash
# =============================================================================
# lib/configure.sh — Генерація fstab, передача конфігу, запуск chroot
# =============================================================================

generate_fstab() {
    section "Генерація /etc/fstab"

    local opts_root="errors=remount-ro"
    [[ "$DISK_TYPE" == "SSD" ]] && opts_root="noatime,errors=remount-ro"

    cat > /mnt/etc/fstab << EOF
# /etc/fstab — згенеровано Devuan Installer
# <file system>          <mount point>  <type>  <options>               <dump>  <pass>
UUID=${ROOT_UUID}        /              ext4    ${opts_root}             0       1
UUID=${SWAP_UUID}        none           swap    sw                       0       0
EOF

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        echo "UUID=${EFI_UUID}         /boot/efi      vfat    umask=0077               0       2" \
            >> /mnt/etc/fstab
    fi

    # tmpfs на /tmp для SSD — зменшує зайві записи
    if [[ "$DISK_TYPE" == "SSD" ]]; then
        echo "tmpfs                    /tmp           tmpfs   nodev,nosuid,size=2G     0       0" \
            >> /mnt/etc/fstab
    fi

    ok "fstab створено"
    cat /mnt/etc/fstab
}

write_install_conf() {
    mkdir -p /mnt/tmp

    # Серіалізуємо масив пакунків у файл
    printf '%s\n' "${CHROOT_PKGS[@]}" > /mnt/tmp/packages.list

    # Конфіг з усіма змінними для chroot-setup.sh
    cat > /mnt/tmp/install.conf << EOF
HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
ROOT_PASSWORD="${ROOT_PASSWORD}"
USER_PASSWORD="${USER_PASSWORD}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
LOCALE_GEN="${LOCALE_GEN}"
KEYMAP="${KEYMAP}"
XKB_LAYOUT="${XKB_LAYOUT}"
CPU_TYPE="${CPU_TYPE}"
CPU_MICROCODE="${CPU_MICROCODE}"
GPU_TYPE="${GPU_TYPE}"
NVIDIA_FOUND=${NVIDIA_FOUND}
AMD_GPU_FOUND=${AMD_GPU_FOUND}
INTEL_GPU_FOUND=${INTEL_GPU_FOUND}
DISK_TYPE="${DISK_TYPE}"
BOOT_MODE="${BOOT_MODE}"
INSTALL_DISK="${INSTALL_DISK}"
ROOT_PART="${ROOT_PART}"
SWAP_PART="${SWAP_PART}"
EFI_PART="${EFI_PART:-}"
EOF
    chmod 600 /mnt/tmp/install.conf
}

bind_mounts() {
    info "Монтування віртуальних ФС у chroot..."
    mount --bind /proc    /mnt/proc
    mount --bind /sys     /mnt/sys
    mount --bind /dev     /mnt/dev
    mount --bind /dev/pts /mnt/dev/pts
    mount --bind /run     /mnt/run
    # Копіюємо DNS
    cp /etc/resolv.conf /mnt/etc/resolv.conf
    ok "Bind mounts готові"
}

unbind_mounts() {
    info "Розмонтування bind mounts..."
    umount -l /mnt/proc    2>/dev/null || true
    umount -l /mnt/sys     2>/dev/null || true
    umount -l /mnt/dev/pts 2>/dev/null || true
    umount -l /mnt/dev     2>/dev/null || true
    umount -l /mnt/run     2>/dev/null || true
}

run_chroot() {
    section "Налаштування системи в chroot"

    bind_mounts

    # Копіюємо скрипт в chroot
    cp "${SCRIPT_DIR}/lib/chroot-setup.sh" /mnt/tmp/chroot-setup.sh
    chmod +x /mnt/tmp/chroot-setup.sh

    info "Запуск chroot-setup.sh..."
    if ! chroot /mnt /bin/bash /tmp/chroot-setup.sh; then
        unbind_mounts
        error "chroot-setup.sh завершився з помилкою. Перевірте лог /mnt/tmp/chroot-setup.log"
    fi

    unbind_mounts

    # Очищення
    rm -f /mnt/tmp/chroot-setup.sh \
          /mnt/tmp/install.conf \
          /mnt/tmp/packages.list

    ok "Налаштування в chroot завершено"
}
