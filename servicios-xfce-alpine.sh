#!/bin/sh
# ==============================================================================
# Script de configuración post-instalación para entorno XFCE en Alpine Linux
# Compatible con: ash (BusyBox) - shell por defecto de Alpine Linux
# ==============================================================================

set -eu

LOG_FILE="/var/log/xfce-postinstall.log"

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
            log_warn "Nouveau se usa por compatibilidad con musl libc; para el driver propietario revisa 'testing' o 'nvidia-open'."
            ;;
        amd)
            log_info "Instalando firmware y Vulkan para AMD/Radeon..."
            install_pkg "linux-firmware-amdgpu"
            install_pkg "linux-firmware-radeon"
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
# BLOQUE 6: Idioma español para el sistema y XFCE
# ------------------------------------------------------------------------------
# NOTA: musl no tiene locale "es_MX.UTF-8"; se usa "es_ES.UTF-8", que es
# funcionalmente idéntico para la traducción de interfaz (gettext no separa
# variantes regionales de español en estos proyectos).
#
# NOTA 2: en vez de adivinar nombres de paquetes "-lang" uno por uno, se usa
# el metapaquete oficial "lang". Cada paquete con traducciones tiene una
# regla install_if que lo activa automáticamente cuando "lang" Y el propio
# paquete base ya están instalados — así apk resuelve por sí solo qué
# "-lang" corresponden a lo que ya tienes en el sistema (XFCE, thunar,
# network-manager-applet, gtk, etc.), sin listas hardcodeadas que puedan
# quedar desactualizadas o mal escritas.
setup_locale_es() {
    log_info "== Configurando idioma español para el sistema y XFCE =="

    install_pkg "musl-locales"
    install_pkg "musl-locales-lang"

    if [ -f /etc/rc.conf ] && ! grep -q '^unicode="YES"' /etc/rc.conf; then
        sed -i 's/#unicode="NO"/#unicode="NO"\nunicode="YES"/' /etc/rc.conf 2>/dev/null || true
    fi

    cat > /etc/profile.d/lang-es.sh <<'EOF'
# Configuración de idioma español (Latinoamérica) - generado por script post-install
export LANG="es_ES.UTF-8"
export LC_ALL="es_ES.UTF-8"
export LC_MESSAGES="es_ES.UTF-8"
EOF
    chmod +x /etc/profile.d/lang-es.sh
    log_ok "Variables de idioma escritas en /etc/profile.d/lang-es.sh"

    # Dispara automáticamente todos los "-lang" de paquetes ya instalados
    # (XFCE, GTK, NetworkManager applet, etc.) vía la regla install_if de apk.
    log_info "Instalando traducciones para todo el software ya presente en el sistema..."
    install_pkg "lang"

    log_ok "Idioma español configurado. Aplica los cambios cerrando sesión (o reiniciando)."
}

# ------------------------------------------------------------------------------
# BLOQUE 7: Tipografías base (antes de LibreOffice)
# ------------------------------------------------------------------------------
# font-liberation es el nombre vigente (ttf-liberation quedó como alias
# "deprecated" que solo reenvía a este). Se usa el actual para no depender
# de un paquete de transición.
install_fonts() {
    log_info "== Instalando tipografías base =="
    install_pkg "ttf-dejavu"
    install_pkg "font-liberation"          # Métricamente compatible con Arial/Times/Courier — clave para .docx
    install_pkg "font-liberation-sans-narrow"
    install_pkg "font-noto"
    log_ok "Tipografías base instaladas."
}

# ------------------------------------------------------------------------------
# BLOQUE 8: LibreOffice + paquete de idioma español
# ------------------------------------------------------------------------------
install_libreoffice() {
    log_info "== Instalando LibreOffice (español) =="
    install_pkg "libreoffice"
    install_pkg "libreoffice-lang-es"
    log_ok "LibreOffice instalado con soporte de idioma español."
}

# ------------------------------------------------------------------------------
# BLOQUE 9: Flatpak + Flathub (OnlyOffice y Google Chrome, opcionales)
# ------------------------------------------------------------------------------
setup_flatpak() {
    log_info "== Configurando Flatpak y repositorio Flathub =="

    # 'dbus' (no 'dbus-x11') trae 'dbus-run-session', suficiente para dar
    # un bus de sesión desechable a un comando puntual sin depender de X11.
    install_pkg "dbus"
    install_pkg "flatpak"
    install_pkg "xdg-desktop-portal"
    install_pkg "xdg-desktop-portal-gtk"

    if ! command -v flatpak >/dev/null 2>&1; then
        log_error "flatpak no quedó instalado. Verifica que el repositorio 'community' esté habilitado en /etc/apk/repositories. Se omite esta sección."
        return 0
    fi

    # Si se ejecuta desde una TTY pura (sin sesión gráfica aún iniciada),
    # flatpak puede advertir que no encuentra el bus de sesión D-Bus.
    # dbus-run-session le da uno temporal solo para este comando.
    if command -v dbus-run-session >/dev/null 2>&1; then
        remote_add_cmd="dbus-run-session -- flatpak"
    else
        log_warn "'dbus-run-session' no disponible; se ejecuta flatpak sin bus de sesión (puede mostrar un warning inofensivo)."
        remote_add_cmd="flatpak"
    fi

    if $remote_add_cmd remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
        log_ok "Repositorio Flathub agregado (o ya existía)."
    else
        log_warn "No se pudo agregar el repositorio Flathub. Revisa tu conexión a internet."
        return 0
    fi

    if ask_yes_no "¿Deseas instalar OnlyOffice Desktop Editors vía Flatpak?"; then
        if $remote_add_cmd install -y flathub org.onlyoffice.desktopeditors; then
            log_ok "OnlyOffice instalado vía Flatpak."
        else
            log_warn "Fallo al instalar OnlyOffice vía Flatpak."
        fi
    else
        log_info "Se omite la instalación de OnlyOffice."
    fi

    # 'com.google.Chrome' en Flathub es un wrapper mantenido por la
    # comunidad, no publicado ni verificado directamente por Google.
    if ask_yes_no "¿Deseas instalar Google Chrome vía Flatpak (paquete comunitario, no oficial de Google)?"; then
        if $remote_add_cmd install -y flathub com.google.Chrome; then
            log_ok "Google Chrome instalado vía Flatpak."
        else
            log_warn "Fallo al instalar Google Chrome vía Flatpak."
        fi
    else
        log_info "Se omite la instalación de Google Chrome."
    fi

    log_info "Los accesos directos de Flatpak aparecerán tras cerrar sesión y volver a entrar a XFCE."
}

# ------------------------------------------------------------------------------
# BLOQUE 10: Permisos de grupo para Audio/Video (usuario real vía doas)
# ------------------------------------------------------------------------------
setup_user_groups() {
    log_info "== Configurando permisos de grupo (audio/video) =="

    target_user="${DOAS_USER:-}"
    [ -z "$target_user" ] && target_user="$(logname 2>/dev/null || true)"

    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        log_warn "No se pudo determinar un usuario estándar vía doas ni logname."
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
# BLOQUE 11: Función principal
# ------------------------------------------------------------------------------
main() {
    log_info "===== Iniciando configuración post-instalación de XFCE en Alpine Linux ====="

    check_root
    update_system
    setup_applets
    detect_hardware
    install_drivers
    setup_locale_es
    install_fonts
    install_libreoffice
    setup_flatpak
    setup_user_groups

    log_ok "===== Proceso completado exitosamente ====="
    log_info "Recuerda cerrar sesión (o reiniciar) para que el idioma, los grupos y los drivers surtan efecto."

    trap - EXIT INT TERM
}

main "$@"
