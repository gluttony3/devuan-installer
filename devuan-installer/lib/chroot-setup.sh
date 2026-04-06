#!/usr/bin/env bash
# =============================================================================
# lib/chroot-setup.sh — Виконується ВСЕРЕДИНІ chroot
# Цей файл НЕ запускається напряму — тільки через configure.sh → run_chroot()
# =============================================================================
set -euo pipefail

LOG=/tmp/chroot-setup.log
exec > >(tee -a "$LOG") 2>&1

RED='\033[0;31m'  GREEN='\033[0;32m'  YELLOW='\033[1;33m'
CYAN='\033[0;36m' BOLD='\033[1m'      NC='\033[0m'

info()    { echo -e "${CYAN}[chroot INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[chroot  OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[chroot WARN]${NC}  $*"; }
error()   { echo -e "${RED}[chroot ERR ]${NC}  $*"; exit 1; }
section() { echo ""; echo -e "${BOLD}${CYAN}── $* ──────────────────────────────────────────${NC}"; }

# Завантажуємо конфіг переданий з основного скрипта
[[ -f /tmp/install.conf ]] || error "/tmp/install.conf не знайдено"
# shellcheck source=/dev/null
source /tmp/install.conf

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -q --no-install-recommends"
APT_FULL="apt-get -y -q"

# =============================================================================
# 1. РЕПОЗИТОРІЇ APT — freia + ceres (rolling)
# =============================================================================
section "Репозиторії APT (freia + ceres)"

cat > /etc/apt/sources.list << 'EOF'
# Devuan GNU/Linux — ceres (rolling, unstable)
deb http://pkgmaster.devuan.org/merged ceres main contrib non-free non-free-firmware
deb-src http://pkgmaster.devuan.org/merged ceres main contrib non-free non-free-firmware

# Devuan freia (stable base)
deb http://pkgmaster.devuan.org/merged freia main contrib non-free non-free-firmware
deb-src http://pkgmaster.devuan.org/merged freia main contrib non-free non-free-firmware
EOF

# Пріоритети: ceres > freia (rolling поведінка)
mkdir -p /etc/apt/preferences.d
cat > /etc/apt/preferences.d/devuan-rolling.pref << 'EOF'
Package: *
Pin: release o=Devuan,n=ceres
Pin-Priority: 900

Package: *
Pin: release o=Devuan,n=freia
Pin-Priority: 800
EOF

info "Оновлення списків пакунків..."
apt-get update -q
apt-get -y -q full-upgrade
ok "Репозиторії: freia (base) + ceres (rolling)"

# =============================================================================
# 2. ВСТАНОВЛЕННЯ ПАКУНКІВ
# =============================================================================
section "Встановлення пакунків"

# Читаємо список пакунків з файлу
mapfile -t PKGS < /tmp/packages.list

info "Встановлення ${#PKGS[@]} пакунків..."
# Встановлюємо пачками по 20 щоб бачити прогрес і не падати на одному пакунку
BATCH=20
for (( i=0; i<${#PKGS[@]}; i+=BATCH )); do
    slice=( "${PKGS[@]:$i:$BATCH}" )
    $APT_FULL install "${slice[@]}" 2>/dev/null || \
        warn "Деякі пакунки з батчу $((i/BATCH+1)) не встановились, продовжуємо..."
done
ok "Пакунки встановлені"

# =============================================================================
# 3. ЛОКАЛЬ
# =============================================================================
section "Локаль та часовий пояс"

info "Налаштування локалі: ${LOCALE}"
# Додаємо en_US.UTF-8 завжди як запасну
{
    echo "${LOCALE_GEN}"
    echo "en_US.UTF-8 UTF-8"
} >> /etc/locale.gen
locale-gen

cat > /etc/locale.conf << EOF
LANG=${LOCALE}
LC_TIME=${LOCALE}
LC_MESSAGES=en_US.UTF-8
EOF

# Symlink для сумісності з Debian
ln -sf /etc/locale.conf /etc/default/locale 2>/dev/null || true

ok "Локаль: ${LOCALE}"

# =============================================================================
# 4. ЧАСОВИЙ ПОЯС
# =============================================================================
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
hwclock --systohc 2>/dev/null || true
ok "Часовий пояс: ${TIMEZONE}"

# =============================================================================
# 5. КЛАВІАТУРА
# =============================================================================
section "Клавіатура"

# Консоль
cat > /etc/default/keyboard << EOF
XKBMODEL="pc105"
XKBLAYOUT="${XKB_LAYOUT}"
XKBVARIANT=""
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
EOF

# vconsole
cat > /etc/vconsole.conf << EOF
KEYMAP=${KEYMAP}
FONT=ter-v16n
EOF

# Встановлюємо шрифти для консолі
$APT install console-setup kbd terminus-font 2>/dev/null || true
setupcon --save 2>/dev/null || true
ok "Клавіатура: ${KEYMAP} / ${XKB_LAYOUT}"

# =============================================================================
# 6. HOSTNAME та /etc/hosts
# =============================================================================
section "Hostname"

echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
127.0.1.1       ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

ok "Hostname: ${HOSTNAME}"

# =============================================================================
# 7. OPENRC — конфігурація init системи
# =============================================================================
section "OpenRC"

# Переконуємось що OpenRC встановлений і є головним init
if command -v openrc &>/dev/null; then
    # Видаляємо sysvinit-core якщо є (конфлікт)
    $APT install openrc 2>/dev/null || true
    apt-get -y -q remove --purge sysvinit-core 2>/dev/null || true

    ok "OpenRC встановлений як init система"
else
    warn "openrc не знайдено, встановлюємо..."
    $APT install openrc elogind libpam-elogind
fi

# /etc/inittab — якщо потрібен (для деяких конфігурацій OpenRC)
[[ -f /etc/inittab ]] || cat > /etc/inittab << 'EOF'
# /etc/inittab — OpenRC
id:3:initdefault:
si::sysinit:/sbin/openrc sysinit
rc::bootwait:/sbin/openrc boot
l3:3:wait:/sbin/openrc default
z6:6:respawn:/sbin/sulogin
EOF

# =============================================================================
# 8. OPENRC — СЛУЖБИ
# =============================================================================
section "Служби OpenRC"

enable_service() {
    local svc="$1" lvl="${2:-default}"
    if [[ -f "/etc/init.d/${svc}" ]]; then
        rc-update add "$svc" "$lvl" 2>/dev/null && ok "  OpenRC: ${svc} → ${lvl}" || \
            warn "  Служба вже додана або помилка: ${svc}"
    else
        warn "  Служба не знайдена: ${svc}"
    fi
}

# Boot runlevel (ранній старт)
enable_service "elogind"       "boot"
enable_service "dbus"          "boot"
enable_service "udev"          "sysinit"
enable_service "devfs"         "sysinit"

# Default runlevel (нормальна робота)
enable_service "NetworkManager" "default"
enable_service "bluetooth"      "default"
enable_service "cups"           "default"
enable_service "cronie"         "default"
enable_service "sshd"           "default"
enable_service "apparmor"       "default"

# SDDM — дисплейний менеджер
if [[ -f /etc/init.d/sddm ]]; then
    enable_service "sddm" "default"
    ok "SDDM як дисплейний менеджер"
fi

# =============================================================================
# 9. КОРИСТУВАЧ та ПАРОЛІ
# =============================================================================
section "Користувачі"

# Root пароль
echo "root:${ROOT_PASSWORD}" | chpasswd
ok "Пароль root встановлено"

# Створення звичайного користувача
if id "$USERNAME" &>/dev/null; then
    warn "Користувач ${USERNAME} вже існує, оновлюємо..."
else
    useradd -m \
        -G wheel,audio,video,plugdev,netdev,bluetooth,cdrom,floppy,sudo,users \
        -s /bin/bash \
        "$USERNAME"
    ok "Користувач ${USERNAME} створений"
fi

echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
ok "Пароль для ${USERNAME} встановлено"

# sudo без пароля для wheel групи
sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
# Або через sudoers.d
echo "%sudo ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
ok "sudo налаштовано для wheel/sudo групи"

# =============================================================================
# 10. SDDM — Дисплейний менеджер (Wayland)
# =============================================================================
section "SDDM (KDE Wayland)"

mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/devuan.conf << 'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Theme]
Current=breeze

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts

[Users]
RememberLastUser=true
RememberLastSession=true
EOF
ok "SDDM налаштований для Wayland"

# =============================================================================
# 11. PIPEWIRE — автозапуск через XDG (без systemd user session)
# =============================================================================
section "PipeWire (OpenRC-сумісний автозапуск)"

# Видаляємо PulseAudio якщо є
apt-get -y -q remove --purge pulseaudio pulseaudio-utils 2>/dev/null || true

mkdir -p /etc/xdg/autostart

cat > /etc/xdg/autostart/pipewire.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Comment=PipeWire multimedia framework
Exec=/usr/bin/pipewire
TryExec=/usr/bin/pipewire
NoDisplay=true
X-KDE-autostart-phase=1
X-KDE-autostart-after=dbus
X-GNOME-Autostart-Phase=Initialization
EOF

cat > /etc/xdg/autostart/wireplumber.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=WirePlumber
Comment=PipeWire session manager
Exec=/usr/bin/wireplumber
TryExec=/usr/bin/wireplumber
NoDisplay=true
X-KDE-autostart-phase=1
X-KDE-autostart-after=pipewire
EOF

cat > /etc/xdg/autostart/pipewire-pulse.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire PulseAudio
Comment=PipeWire PulseAudio compatibility daemon
Exec=/usr/bin/pipewire-pulse
TryExec=/usr/bin/pipewire-pulse
NoDisplay=true
X-KDE-autostart-phase=1
X-KDE-autostart-after=wireplumber
EOF

# ALSA через PipeWire
cat > /etc/asound.conf << 'EOF'
defaults.pcm.card 0
defaults.ctl.card 0
EOF

ok "PipeWire + WirePlumber автозапуск налаштований"

# =============================================================================
# 12. GPU ДРАЙВЕРИ — специфічна конфігурація
# =============================================================================
section "Конфігурація GPU"

if [[ "$NVIDIA_FOUND" == "true" ]]; then
    info "NVIDIA: конфігурація для Wayland..."

    # Blacklist nouveau
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF

    # Env для NVIDIA + Wayland
    cat >> /etc/environment << 'EOF'

# NVIDIA Wayland
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
WLR_NO_HARDWARE_CURSORS=1
LIBVA_DRIVER_NAME=nvidia
EOF

    # DKMS збірка модулів
    dkms autoinstall 2>/dev/null || warn "DKMS autoinstall: попередження (нормально при першому старті)"
    ok "NVIDIA: nouveau заблокований, Wayland env налаштований"

    # SDDM для NVIDIA
    cat > /etc/sddm.conf.d/nvidia.conf << 'EOF'
[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen
EOF
fi

if [[ "$AMD_GPU_FOUND" == "true" ]]; then
    info "AMD: увімкнення amdgpu DC..."
    cat > /etc/modprobe.d/amdgpu.conf << 'EOF'
options amdgpu dc=1
options amdgpu si_support=1
options amdgpu cik_support=1
EOF
    ok "AMD: amdgpu налаштований"
fi

# Vulkan ICD для всіх GPU
if [[ "$INTEL_GPU_FOUND" == "true" ]]; then
    info "Intel: vulkan ICD..."
    $APT install vulkan-tools mesa-vulkan-drivers 2>/dev/null || true
fi

# =============================================================================
# 13. ОПТИМІЗАЦІЯ SSD
# =============================================================================
section "Оптимізація диску (${DISK_TYPE})"

if [[ "$DISK_TYPE" == "SSD" ]]; then
    # Щотижневий TRIM
    cat > /etc/cron.weekly/fstrim << 'EOF'
#!/bin/sh
/sbin/fstrim --all --verbose 2>/dev/null || true
EOF
    chmod +x /etc/cron.weekly/fstrim

    # I/O планировщик через udev
    cat > /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
# NVMe — none (апаратна черга)
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
# SSD SATA — mq-deadline
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# HDD SATA — bfq
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1",  ATTR{queue/scheduler}="bfq"
EOF

    # sysctl
    cat > /etc/sysctl.d/99-ssd.conf << 'EOF'
vm.swappiness=10
vm.dirty_ratio=5
vm.dirty_background_ratio=2
EOF
    ok "SSD: TRIM, планировщик mq-deadline, swappiness=10"
else
    cat > /etc/sysctl.d/99-hdd.conf << 'EOF'
vm.swappiness=60
vm.dirty_ratio=20
vm.dirty_background_ratio=10
EOF
    ok "HDD: swappiness=60"
fi

# =============================================================================
# 14. GRUB — завантажувач
# =============================================================================
section "GRUB (${BOOT_MODE})"

# Параметри ядра
GRUB_PARAMS="quiet splash"
[[ "$NVIDIA_FOUND" == "true" ]] && GRUB_PARAMS="$GRUB_PARAMS nvidia-drm.modeset=1"
[[ "$AMD_GPU_FOUND" == "true" ]] && GRUB_PARAMS="$GRUB_PARAMS amdgpu.dc=1"
GRUB_PARAMS="$GRUB_PARAMS mem_sleep_default=deep"

cat > /etc/default/grub << EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Devuan GNU/Linux"
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_PARAMS}"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL_OUTPUT="console"
GRUB_GFXMODE=auto
GRUB_DISABLE_OS_PROBER=false
EOF

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    info "Встановлення GRUB (UEFI/GPT)..."
    grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id="Devuan" \
        --recheck \
        --removable 2>/dev/null || \
    grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id="Devuan" \
        --recheck
else
    info "Встановлення GRUB (BIOS/MBR)..."
    grub-install --target=i386-pc --recheck "$INSTALL_DISK"
fi

update-grub
ok "GRUB встановлений та налаштований"

# =============================================================================
# 15. INITRAMFS
# =============================================================================
section "initramfs"

update-initramfs -u -k all
ok "initramfs оновлено"

# =============================================================================
# 16. МЕРЕЖА — NetworkManager як основний
# =============================================================================
section "Мережа"

# Прибираємо /etc/network/interfaces щоб NM керував усім
cat > /etc/network/interfaces << 'EOF'
# Цим файлом керує NetworkManager
# Ручні налаштування не додавати
auto lo
iface lo inet loopback
EOF

# NM конфіг
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/00-managed.conf << 'EOF'
[main]
plugins=ifupdown,keyfile
dhcp=internal

[ifupdown]
managed=true

[device]
wifi.backend=wpa_supplicant
EOF

ok "NetworkManager налаштований"

# =============================================================================
# 17. FLATPAK — Flathub
# =============================================================================
section "Flatpak"

if command -v flatpak &>/dev/null; then
    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || \
        warn "Не вдалось додати Flathub (перевірте після перезавантаження)"
    ok "Flathub додано"
fi

# =============================================================================
# 18. ЗАВЕРШЕННЯ
# =============================================================================
section "Фінальне очищення"

apt-get -y -q autoremove
apt-get -y -q autoclean
apt-get clean
rm -f /etc/resolv.conf  # буде відновлено NM після першого старту

ok "Chroot налаштування завершено успішно!"
echo ""
echo -e "  Лог збережений: /tmp/chroot-setup.log (скопіюється в /var/log/)"
cp "$LOG" /var/log/devuan-install.log 2>/dev/null || true
