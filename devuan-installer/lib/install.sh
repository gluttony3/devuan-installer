#!/usr/bin/env bash
# =============================================================================
# lib/install.sh — Складання списку пакунків та запуск debootstrap
# =============================================================================

build_package_list() {
    # ── Базові пакунки ─────────────────────────────────────────────────────────
    BASE_PKGS=(
        # Ядро та прошивка
        linux-image-amd64
        linux-headers-amd64
        linux-firmware
        firmware-linux
        firmware-linux-nonfree
        # Init система
        openrc
        elogind
        libpam-elogind
        # DKMS для модулів ядра
        dkms
        build-essential
        # Базові системні пакунки
        base-files
        base-passwd
        bash
        coreutils
        util-linux
        systemd-sysv   # тільки sysvinit-utils, НЕ systemd — для compatibility
        # Засоби
        apt
        apt-utils
        ca-certificates
        gnupg2
        locales
        sudo
        vim
        nano
        wget
        curl
        git
        rsync
        # Мережа
        iproute2
        iputils-ping
        net-tools
        # Апаратура
        pciutils
        usbutils
        dmidecode
        lshw
        htop
        # Файлові системи
        dosfstools
        ntfs-3g
        exfat-fuse
        btrfs-progs
        e2fsprogs
    )

    # ── Пакунки для встановлення в chroot через apt ────────────────────────────
    CHROOT_PKGS=(
        # ── Завантажувач ──────────────────────────────────────────────────────
        grub2-common
        grub-pc-bin
        os-prober

        # ── Мережа ────────────────────────────────────────────────────────────
        network-manager
        network-manager-gnome
        network-manager-openvpn
        bluetooth
        blueman

        # ── Аудіо: PipeWire ───────────────────────────────────────────────────
        pipewire
        pipewire-audio
        pipewire-alsa
        pipewire-pulse
        pipewire-jack
        wireplumber
        libspa-0.2-bluetooth
        pavucontrol-qt
        alsa-utils

        # ── KDE Plasma (мінімальний, Wayland) ─────────────────────────────────
        kde-plasma-desktop
        plasma-workspace-wayland
        plasma-wayland-protocols
        sddm
        kde-gtk-config
        breeze
        breeze-gtk-theme
        breeze-icon-theme
        # KDE додатки
        dolphin
        konsole
        kate
        ark
        spectacle
        gwenview
        okular
        plasma-nm
        plasma-pa
        plasma-systemmonitor
        kscreen
        powerdevil
        bluedevil
        kinfocenter
        partitionmanager
        # Портали та інтеграція
        xdg-desktop-portal
        xdg-desktop-portal-kde
        xdg-utils
        xdg-user-dirs
        xdg-user-dirs-gtk
        # XWayland (зворотна сумісність)
        xwayland

        # ── Шрифти ────────────────────────────────────────────────────────────
        fonts-noto
        fonts-noto-cjk
        fonts-noto-color-emoji
        fonts-liberation
        fonts-dejavu-core

        # ── Медіа та кодеки ───────────────────────────────────────────────────
        gstreamer1.0-plugins-good
        gstreamer1.0-plugins-bad
        gstreamer1.0-plugins-ugly
        gstreamer1.0-libav
        gstreamer1.0-vaapi
        ffmpeg

        # ── Archiver ──────────────────────────────────────────────────────────
        zip
        unzip
        p7zip-full

        # ── Системні утиліти ──────────────────────────────────────────────────
        cups
        cups-pdf
        flatpak
        fuse3
        udisks2
        gvfs
        gvfs-backends
        apparmor
        apparmor-utils
        bash-completion
        command-not-found
        man-db
        less
    )

    # ── UEFI ──────────────────────────────────────────────────────────────────
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        CHROOT_PKGS+=( grub-efi-amd64 efibootmgr )
    fi

    # ── Мікрокод CPU ──────────────────────────────────────────────────────────
    [[ -n "$CPU_MICROCODE" ]] && CHROOT_PKGS+=( "$CPU_MICROCODE" )

    # ── Драйвери GPU ──────────────────────────────────────────────────────────
    if $INTEL_GPU_FOUND; then
        CHROOT_PKGS+=(
            xserver-xorg-video-intel
            intel-media-va-driver
            i965-va-driver
            libva-drm2 libva-x11-2
            mesa-vulkan-drivers
            libgl1-mesa-dri
        )
    fi

    if $AMD_GPU_FOUND; then
        CHROOT_PKGS+=(
            firmware-amd-graphics
            xserver-xorg-video-amdgpu
            mesa-vulkan-drivers
            libgl1-mesa-dri
            mesa-va-drivers
            mesa-vdpau-drivers
            libva-drm2 libva-x11-2
        )
    fi

    if $NVIDIA_FOUND; then
        CHROOT_PKGS+=(
            nvidia-driver
            nvidia-driver-libs
            nvidia-kernel-dkms
            nvidia-settings
            libgles2
            libvulkan1
        )
        # Hybrid Intel+NVIDIA (Optimus)
        $INTEL_GPU_FOUND && CHROOT_PKGS+=( nvidia-prime )
    fi
}

run_debootstrap() {
    section "Встановлення базової системи (debootstrap)"

    info "Ініціалізація GPG ключів..."
    apt-get -y -q install debootstrap debian-keyring devuan-keyring 2>/dev/null || true

    # Деякі пакунки краще ввімкнути одразу в debootstrap
    local INCLUDE_BASE
    INCLUDE_BASE=$(IFS=,; echo "${BASE_PKGS[*]}")

    info "Запуск debootstrap freia → /mnt  (може зайняти 5–10 хвилин)..."
    if ! debootstrap \
        --arch=amd64 \
        --variant=minbase \
        --include="$INCLUDE_BASE" \
        --keyring=/usr/share/keyrings/devuan-archive-keyring.gpg \
        freia \
        /mnt \
        http://pkgmaster.devuan.org/merged; then
        # Запасний дзеркало
        warn "Основне дзеркало недоступне, пробуємо запасне..."
        debootstrap \
            --arch=amd64 \
            --variant=minbase \
            --include="$INCLUDE_BASE" \
            freia \
            /mnt \
            http://auto.mirror.devuan.org/merged || \
            error "debootstrap завершився з помилкою"
    fi

    ok "Базова система встановлена в /mnt"
}
