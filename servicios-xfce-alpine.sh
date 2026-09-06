#!/bin/sh
# ==============================================================================
# Script de configuración post-instalación para entorno XFCE en Alpine Linux
# Compatible con: ash (BusyBox) - shell por defecto de Alpine Linux
# Descripción: Instala y configura applets de interfaz, detecta hardware de
#              video y de red, e instala firmware/controladores adecuados.
# ==============================================================================

set -eu

LOG_FILE="/var/log/xfce-postinstall.log"

log_info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$1" | tee -a "$LOG_FILE"; }
log_ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$1" | tee -a "$LOG_FILE"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$1" | tee -a "$LOG_FILE"; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$1" | tee -a "$LOG_FILE"; }

trap 'log_error "Ocurrió un error inesperado. Abortando script."; exit 1' EXIT INT TERM

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
    # Instala un paquete; si falla, solo advierte y continúa (no aborta el script)
    pkg="$1"
    log_info "Instalando: $pkg"
    if apk add --no-cache "$pkg" >/dev/null 2>&1; then
        log_ok "'$pkg' instalado."
    else
        log_warn "Fallo al instalar '$pkg'. Verifica el nombre del paquete con 'apk search'."
    fi
}

# ------------------------------------------------------------------------------
# BLOQUE 3: Applets de red y audio (Wi-Fi + Volumen) para XFCE
# ------------------------------------------------------------------------------
setup_applets() {
    log_info "== Configurando applets de red y audio para XFCE =="

    install_pkg "networkmanager"
    install_pkg "network-manager-applet"
    install_pkg "networkmanager-wifi"
    install_pkg "wpa_supplicant"

    install_pkg "pulseaudio"
    install_pkg "pulseaudio-alsa"
    install_pkg "xfce4-pulseaudio-plugin"

    # Solo se habilita NetworkManager en OpenRC.
    # wpa_supplicant es invocado internamente por NetworkManager vía D-Bus,
    # y PulseAudio se gestiona por sesión de usuario (autostart de XFCE):
    # habilitarlos como servicios de sistema puede causar conflictos de permisos.
    rc-update add networkmanager default || log_warn "No se pudo agregar 'networkmanager' al runlevel default."

    log_ok "Applets configurados. Audio y Wi-Fi serán gestionados dinámicamente por la sesión."
}

# ------------------------------------------------------------------------------
# BLOQUE 4: Detección de hardware (GPU)
# ------------------------------------------------------------------------------
GPU_VENDOR=""

detect_hardware() {
    log_info "== Detectando hardware =="
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
# BLOQUE 5: Firmware y controladores de video
# ------------------------------------------------------------------------------
# NOTA IMPORTANTE: en Alpine, "mesa-dri-gallium" es el paquete VIGENTE para
# aceleración 3D (mesa upstream eliminó los drivers DRI "classic"; todo lo
# que queda hoy es Gallium). NO existe un paquete "mesa-dri" a secas — usarlo
# haría que 'apk add' fallara silenciosamente y el sistema cayera en
# renderizado por software. Se usa "mesa-dri-gallium" tal como aparece en
# el repositorio oficial (pkgs.alpinelinux.org).
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
            log_warn "Nouveau (incluido en mesa-dri-gallium) se usa por compatibilidad con musl libc."
            log_warn "Para el driver propietario NVIDIA revisa el repositorio 'testing' o 'nvidia-open'."
            ;;
        amd)
            log_info "Instalando firmware y Vulkan para AMD/Radeon..."
            install_pkg "linux-firmware-amdgpu"
            install_pkg "linux-firmware-radeon"
            # Aceleración Vulkan (necesaria para APUs como Ryzen 5700G y GPUs como RX 6600).
            # En Alpine 'edge' el paquete se llama 'mesa-vulkan-ati'; en algunas
            # versiones/branches puede aparecer como 'mesa-vulkan-radeon'.
            # Verifica con 'apk search vulkan' si alguno de los dos falla.
            install_pkg "mesa-vulkan-ati"
            install_pkg "mesa-vulkan-radeon"
            install_pkg "vulkan-loader"
            ;;
        intel)
            log_info "Instalando firmware Intel..."
            install_pkg "linux-firmware-i915"
            install_pkg "mesa-vulkan-intel"
            ;;
        virtual)
            log_info "Entorno virtualizado detectado. Instalando utilidades QEMU/KVM/VirtualBox..."
            install_pkg "xf86-video-vmware"
            install_pkg "xf86-video-qxl"
            install_pkg "spice-vdagent"
            rc-update add spice-vdagentd default || log_warn "Fallo al habilitar spice-vdagentd."
            ;;
        *)
            log_warn "GPU no identificada. mesa-dri-gallium ya cubre software rendering (llvmpipe) de respaldo."
            ;;
    esac

    log_ok "Instalación de firmware y controladores finalizada."
}

# ------------------------------------------------------------------------------
# BLOQUE 6: Permisos de grupo para Audio/Video (soporta doas, sudo y su)
# ------------------------------------------------------------------------------
setup_user_groups() {
    log_info "== Configurando permisos de grupo (audio/video) =="

    target_user="${DOAS_USER:-}"
    [ -z "$target_user" ] && target_user="${SUDO_USER:-}"
    [ -z "$target_user" ] && target_user="$(logname 2>/dev/null || true)"

    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        log_warn "No se pudo determinar un usuario estándar vía doas, sudo ni logname."
        log_warn "Ejecuta manualmente: adduser <tu_usuario> audio && adduser <tu_usuario> video"
        return 0
    fi

    log_info "Usuario detectado: $target_user"

    if adduser "$target_user" audio; then
        log_ok "Usuario '$target_user' agregado al grupo 'audio'."
    else
        log_warn "No se pudo agregar '$target_user' al grupo 'audio' (¿ya pertenecía?)."
    fi

    if adduser "$target_user" video; then
        log_ok "Usuario '$target_user' agregado al grupo 'video'."
    else
        log_warn "No se pudo agregar '$target_user' al grupo 'video' (¿ya pertenecía?)."
    fi
}

# ------------------------------------------------------------------------------
# BLOQUE 7: Función principal
# ------------------------------------------------------------------------------
main() {
    log_info "===== Iniciando configuración post-instalación de XFCE en Alpine Linux ====="

    check_root
    update_system
    setup_applets
    detect_hardware
    install_drivers
    setup_user_groups

    log_ok "===== Proceso completado exitosamente ====="
    log_info "Recuerda reiniciar sesión (o el sistema) para que los cambios de grupo y drivers surtan efecto."

    trap - EXIT INT TERM
}

main "$@"
