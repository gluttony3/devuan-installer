#!/usr/bin/env bash
set -e

# Перевірка на root
if [[ $EUID -ne 0 ]]; then
   echo "Цей скрипт треба запускати від root (sudo)"
   exit 1
fi

echo "--- Налаштування репозиторіїв (додавання contrib non-free) ---"
sed -i 's/main$/main contrib non-free non-free-firmware/g' /etc/apt/sources.list
apt update

echo "--- Встановлення мінімального KDE Plasma (Wayland) ---"
# plasma-desktop — це найменший набір пакетів для робочого столу
# plasma-workspace-wayland — підтримка сесії Wayland
apt install -y --no-install-recommends \
    plasma-desktop \
    plasma-workspace-wayland \
    kwin-wayland \
    sddm \
    plasma-nm \
    plasma-pa \
    konsole \
    dolphin \
    dbus-x11 \
    elogind \
    libpam-elogind

echo "--- Встановлення PipeWire ---"
apt install -y --no-install-recommends \
    pipewire \
    pipewire-pulse \
    wireplumber \
    pavucontrol-qt

echo "--- Налаштування автозапуску PipeWire для OpenRC ---"
# Оскільки systemd user sessions немає, використовуємо XDG Autostart
mkdir -p /etc/xdg/autostart

cat <<EOF > /etc/xdg/autostart/pipewire.desktop
[Desktop Entry]
Version=1.0
Name=PipeWire
Comment=PipeWire Media Service
Exec=pipewire
Terminal=false
Type=Application
X-KDE-autostart-phase=1
EOF

cat <<EOF > /etc/xdg/autostart/pipewire-pulse.desktop
[Desktop Entry]
Version=1.0
Name=PipeWire PulseAudio
Comment=PipeWire PulseAudio Compatibility
Exec=pipewire-pulse
Terminal=false
Type=Application
X-KDE-autostart-phase=1
EOF

cat <<EOF > /etc/xdg/autostart/wireplumber.desktop
[Desktop Entry]
Version=1.0
Name=WirePlumber
Comment=PipeWire Session Manager
Exec=wireplumber
Terminal=false
Type=Application
X-KDE-autostart-phase=1
EOF

echo "--- Налаштування сервісів OpenRC ---"
rc-update add dbus default
rc-update add elogind default
rc-update add sddm default

echo "--- Налаштування SDDM для Wayland за замовчуванням ---"
mkdir -p /etc/sddm.conf.d
cat <<EOF > /etc/sddm.conf.d/wayland.conf
[General]
DisplayServer=wayland
EOF

echo "--- Готово! Можна перезавантажуватись ---"
