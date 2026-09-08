#!/bin/sh
# ==============================================================================
# Script de configuración post-instalación para entorno de escritorio en Alpine
# Compatible con: ash (BusyBox) - shell por defecto de Alpine Linux
# ==============================================================================

set -eu

LOG_FILE="/var/log/desktop-postinstall.log"

log_info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$1" | tee -a "$LOG_FILE"; }
log_ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$1" | tee -a "$LOG_FILE"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$1" | tee -a "$LOG_FILE"; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$1" | tee -a "$LOG_FILE"; }

trap 'log_error "Ocurrió un error inesperado. Abortando script."; exit 1' EXIT INT TERM

ask_yes_no() {
    prompt="$1"
    printf '%s [s/N]: ' "$prompt"
    if ! read -r resp; then
        resp=""
    fi
    case "$resp" in
        [sSyY]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# BLOQUE 1: Validación de permisos de superusuario
# ------------------------------------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Este script debe ejecutarse como root."
        exit 1
    fi
    log_ok "Permisos de superusuario verificados."
}

# ------------------------------------------------------------------------------
# BLOQUE 2: Actualización de repositorios
# ------------------------------------------------------------------------------
update_system() {
    log_info "Actualizando índice de paquetes..."
    apk update || { log_error "Fallo al actualizar apk."; exit 1; }
}

install_pkg() {
    pkg="$1"
    log_info "Instalando: $pkg"
    if apk add --no-cache "$pkg" >/dev/null 2>&1; then
        log_ok "'$pkg' instalado."
    else
        log_warn "Fallo al instalar '$pkg' (puede no existir en tu rama/arquitectura)."
    fi
}

# ------------------------------------------------------------------------------
# BLOQUE 3: Distribución de teclado a "latam" (consola + sesión gráfica)
# ------------------------------------------------------------------------------
# Cubre dos capas independientes:
#   1. Consola de texto (TTY) -> servicio OpenRC "loadkmap"
#   2. Sesión gráfica (Xorg, usada por XFCE y Plasma) -> XkbLayout
# Pasar LAYOUT y VARIANT como argumentos evita el menú interactivo de
# setup-keymap. El único prompt restante es la confirmación de OpenRC por
# tocar un servicio del runlevel "boot", que se responde con 'yes |'.
setup_keyboard_layout() {
    log_info "== Configurando distribución de teclado a 'latam' =="

    if command -v setup-keymap >/dev/null 2>&1; then
        if yes | setup-keymap latam latam >>"$LOG_FILE" 2>&1; then
            log_ok "Teclado de consola (TTY) configurado a 'latam'."
        else
            log_warn "No se pudo configurar el teclado de consola automáticamente. Ejecuta manualmente: setup-keymap latam latam"
        fi
    else
        log_warn "'setup-keymap' no disponible (paquete alpine-conf). Se omite la configuración de consola."
    fi

    # La sesión gráfica no hereda el layout de la consola; hay que
    # indicárselo a Xorg explícitamente para XFCE y Plasma.
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'EOF'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "latam"
EndSection
EOF
    log_ok "Teclado de sesión gráfica (Xorg) configurado a 'latam' en /etc/X11/xorg.conf.d/00-keyboard.conf"
}

# ------------------------------------------------------------------------------
# BLOQUE 4: Detección del entorno de escritorio instalado
# ------------------------------------------------------------------------------
DE_XFCE="no"
DE_PLASMA="no"

detect_desktop_environment() {
    log_info "== Detectando entorno de escritorio instalado =="

    if apk info -e xfce4-session >/dev/null 2>&1; then
        DE_XFCE="yes"
        log_ok "XFCE detectado."
    fi

    if apk info -e plasma-desktop-meta >/dev/null 2>&1 || apk info -e plasma-desktop >/dev/null 2>&1; then
        DE_PLASMA="yes"
        log_ok "KDE Plasma detectado."
    fi

    if [ "$DE_XFCE" = "no" ] && [ "$DE_PLASMA" = "no" ]; then
        log_warn "No se detectó XFCE ni Plasma instalados."
    fi
}

# ------------------------------------------------------------------------------
# BLOQUE 5: Applets de red y audio (adaptados al entorno detectado)
# ------------------------------------------------------------------------------
setup_applets() {
    log_info "== Configurando applets de red y audio =="

    install_pkg "networkmanager"
    install_pkg "networkmanager-wifi"
    install_pkg "wpa_supplicant"
    install_pkg "pulseaudio"
    install_pkg "pulseaudio-alsa"

    if [ "$DE_XFCE" = "yes" ]; then
        log_info "Instalando applets nativos de XFCE (GTK)..."
        install_pkg "network-manager-applet"
        install_pkg "xfce4-pulseaudio-plugin"
    fi

    if [ "$DE_PLASMA" = "yes" ]; then
        log_info "Plasma detectado: usará sus widgets nativos (plasma-nm / plasma-pa)."
    fi

    rc-update add networkmanager default || log_warn "No se pudo agregar 'networkmanager' al runlevel default."

    log_ok "Applets configurados según el entorno detectado."
}

# ------------------------------------------------------------------------------
# BLOQUE 6: Detección de hardware (GPU)
# ------------------------------------------------------------------------------
GPU_VENDOR=""
vga_line=""

detect_hardware() {
    log_info "== Detectando hardware (GPU) =="
    command -v lspci >/dev/null 2>&1 || install_pkg "pciutils"

    if ! command -v lspci >/dev/null 2>&1; then
        log_error "No fue posible obtener 'lspci'. Se omitirá la detección automática de GPU."
        GPU_VENDOR="desconocido"
        return 0
    fi

    log_info "Componentes PCI detectados:"
    lspci | tee -a "$LOG_FILE"

    vga_line="$(lspci | grep -Ei 'VGA compatible controller|3D controller' || true)"

    if [ -z "$vga_line" ]; then
        log_warn "No se detectó ningún controlador de video vía lspci."
        GPU_VENDOR="desconocido"
        return 0
    fi

    log_info "Controlador de video encontrado: $vga_line"

    if echo "$vga_line" | grep -qi "nvidia"; then
        GPU_VENDOR="nvidia"
    elif echo "$vga_line" | grep -qi "amd\|ati\|radeon"; then
        GPU_VENDOR="amd"
    elif echo "$vga_line" | grep -qi "intel"; then
        GPU_VENDOR="intel"
    elif echo "$vga_line" | grep -qi "virtio\|vmware\|virtualbox\|qxl"; then
        GPU_VENDOR="virtual"
    else
        GPU_VENDOR="desconocido"
    fi

    log_ok "GPU clasificada como: $GPU_VENDOR"
}

# ------------------------------------------------------------------------------
# BLOQUE 7: Firmware y controladores de video (con protección NVIDIA Legacy)
# ------------------------------------------------------------------------------
install_drivers() {
    log_info "== Instalando firmware y controladores =="

    install_pkg "linux-firmware"
    install_pkg "mesa-dri-gallium"
    install_pkg "mesa-gl"
    install_pkg "mesa-egl"

    case "$GPU_VENDOR" in
        nvidia)
            log_info "Instalando soporte NVIDIA (driver abierto Nouveau, vía Gallium)..."
            install_pkg "linux-firmware-nvidia"

            gpu_count="$(lspci | grep -cEi 'VGA
