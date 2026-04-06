#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Кольори, логування, допоміжні функції
# =============================================================================

# ── Кольори ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'   GREEN='\033[0;32m'  YELLOW='\033[1;33m'
BLUE='\033[0;34m'  CYAN='\033[0;36m'   BOLD='\033[1m'  NC='\033[0m'

# ── Логування ─────────────────────────────────────────────────────────────────
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR ]${NC}  $*"; exit 1; }

section() {
    local title="$*"
    echo ""
    echo -e "${BOLD}${BLUE}┌──────────────────────────────────────────────┐${NC}"
    printf "${BOLD}${BLUE}│  %-44s│${NC}\n" "$title"
    echo -e "${BOLD}${BLUE}└──────────────────────────────────────────────┘${NC}"
}

# ── Перевірки ─────────────────────────────────────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && error "Запустіть від root: sudo bash $0"
}

check_internet() {
    info "Перевірка підключення до інтернету..."
    if ! ping -c 1 -W 3 pkgmaster.devuan.org &>/dev/null && \
       ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        error "Немає інтернету. Підключіться та спробуйте знову."
    fi
    ok "Інтернет підключений"
}

check_deps() {
    local missing=()
    for cmd in debootstrap parted mkfs.ext4 mkfs.fat mkswap blkid lspci; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Відсутні утиліти: ${missing[*]}"
        info "Встановлення залежностей live-середовища..."
        apt-get -y -q install debootstrap parted dosfstools util-linux pciutils 2>/dev/null || \
            error "Не вдалося встановити залежності: ${missing[*]}"
    fi
}

# ── Інтерактивні функції ───────────────────────────────────────────────────────

# Так/Ні
confirm() {
    local msg="${1:-Продовжити?}"
    local default="${2:-y}"
    local prompt
    [[ "$default" == "y" ]] && prompt="${GREEN}[Y/n]${NC}" || prompt="${YELLOW}[y/N]${NC}"

    while true; do
        read -rp "$(echo -e "  ${YELLOW}${msg} ${prompt}: ${NC}")" ans
        ans="${ans:-$default}"
        case "${ans,,}" in
            y|yes|т|так) return 0 ;;
            n|no|н|ні)   return 1 ;;
            *) echo "  Введіть y або n" ;;
        esac
    done
}

# Рядок з дефолтом
ask_string() {
    local prompt="$1" default="$2" var_name="$3"
    local result

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "  ${CYAN}${prompt} [${BOLD}${default}${NC}${CYAN}]: ${NC}")" result
        result="${result:-$default}"
    else
        while [[ -z "$result" ]]; do
            read -rp "$(echo -e "  ${CYAN}${prompt}: ${NC}")" result
            [[ -z "$result" ]] && warn "  Значення не може бути порожнім"
        done
    fi
    printf -v "$var_name" '%s' "$result"
}

# Пароль з підтвердженням
ask_password() {
    local prompt="$1" var_name="$2"
    local p1 p2

    while true; do
        read -rsp "$(echo -e "  ${CYAN}${prompt}: ${NC}")" p1; echo
        read -rsp "$(echo -e "  ${CYAN}Підтвердіть пароль: ${NC}")" p2; echo
        if [[ "$p1" == "$p2" ]]; then
            [[ -z "$p1" ]] && { warn "  Пароль не може бути порожнім"; continue; }
            printf -v "$var_name" '%s' "$p1"
            break
        fi
        warn "  Паролі не співпадають, спробуйте ще раз"
    done
}

# Вибір з нумерованого списку
pick_from_list() {
    local prompt="$1" default="$2" var_name="$3"
    shift 3
    local items=("$@")
    local i choice

    echo -e "  ${CYAN}${prompt}:${NC}"
    for i in "${!items[@]}"; do
        local num=$(( i + 1 ))
        if [[ "$num" == "$default" ]]; then
            echo -e "    ${BOLD}${GREEN}${num}) ${items[$i]} ◄ за замовчуванням${NC}"
        else
            echo -e "    ${num}) ${items[$i]}"
        fi
    done

    while true; do
        read -rp "$(echo -e "  ${CYAN}Оберіть [${default}]: ${NC}")" choice
        choice="${choice:-$default}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#items[@]} )); then
            printf -v "$var_name" '%s' "${items[$(( choice - 1 ))]}"
            break
        fi
        warn "  Введіть число від 1 до ${#items[@]}"
    done
}

# ── Банер ─────────────────────────────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${BOLD}${BLUE}"
    cat << 'BANNER'
  ╔═══════════════════════════════════════════════════════════════╗
  ║          Devuan GNU/Linux — Повний Інсталятор                ║
  ║     OpenRC · KDE Plasma (Wayland) · PipeWire · GRUB         ║
  ║          freia/ceres (rolling) · Auto-detect HW             ║
  ╚═══════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    echo -e "  ${YELLOW}${BOLD}УВАГА: Вибраний диск буде повністю і незворотньо стертий!${NC}"
    echo ""
}
