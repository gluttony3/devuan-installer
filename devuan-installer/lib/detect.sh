#!/usr/bin/env bash
# =============================================================================
# lib/detect.sh — Визначення заліза: UEFI/BIOS, CPU, GPU, RAM
# =============================================================================

detect_boot_mode() {
    if [[ -d /sys/firmware/efi/efivars ]]; then
        BOOT_MODE="UEFI"
    else
        BOOT_MODE="BIOS"
    fi
    info "Режим завантаження:  ${BOLD}${BOOT_MODE}${NC}"
}

detect_cpu() {
    local vendor
    vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)

    case "$vendor" in
        GenuineIntel) CPU_TYPE="intel"; CPU_MICROCODE="intel-microcode" ;;
        AuthenticAMD)  CPU_TYPE="amd";   CPU_MICROCODE="amd64-microcode" ;;
        *)             CPU_TYPE="unknown"; CPU_MICROCODE="" ;;
    esac

    info "CPU:                 ${BOLD}${CPU_MODEL}${NC}"
    info "Мікрокод:            ${CPU_MICROCODE:-не визначено}"
}

detect_gpu() {
    local pci_info
    pci_info=$(lspci 2>/dev/null | grep -iE "vga|3d controller|display" || true)

    NVIDIA_FOUND=false
    AMD_GPU_FOUND=false
    INTEL_GPU_FOUND=false
    GPU_TYPE="unknown"

    echo "$pci_info" | grep -qi "nvidia"                        && NVIDIA_FOUND=true
    echo "$pci_info" | grep -qi "amd\|radeon\|advanced micro"   && AMD_GPU_FOUND=true
    echo "$pci_info" | grep -qi "intel"                         && INTEL_GPU_FOUND=true

    # Визначаємо тип конфігурації
    if $NVIDIA_FOUND && $INTEL_GPU_FOUND; then
        GPU_TYPE="hybrid-nvidia-intel"   # Optimus
    elif $NVIDIA_FOUND && $AMD_GPU_FOUND; then
        GPU_TYPE="hybrid-nvidia-amd"
    elif $NVIDIA_FOUND; then
        GPU_TYPE="nvidia"
    elif $AMD_GPU_FOUND; then
        GPU_TYPE="amd"
    elif $INTEL_GPU_FOUND; then
        GPU_TYPE="intel"
    fi

    info "GPU тип:             ${BOLD}${GPU_TYPE}${NC}"
    [[ -n "$pci_info" ]] && info "GPU деталі:          $(echo "$pci_info" | head -2 | tr '\n' '|')"
}

detect_ram() {
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_GB=$(( ram_kb / 1024 / 1024 ))
    [[ $RAM_GB -eq 0 ]] && RAM_GB=1

    # SWAP = розмір RAM, але не більше 8 GB
    SWAP_GB=$(( RAM_GB > 8 ? 8 : RAM_GB ))

    info "RAM:                 ${BOLD}${RAM_GB} GB${NC} → SWAP: ${SWAP_GB} GB"
}

detect_disk_type() {
    local disk_name
    disk_name=$(basename "$INSTALL_DISK")
    local rot
    rot=$(cat "/sys/block/${disk_name}/queue/rotational" 2>/dev/null || echo "1")
    [[ "$rot" == "0" ]] && DISK_TYPE="SSD" || DISK_TYPE="HDD"
}

run_detection() {
    section "Визначення заліза"
    detect_boot_mode
    detect_cpu
    detect_gpu
    detect_ram
}
