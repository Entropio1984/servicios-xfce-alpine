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

            gpu_count="$(lspci | grep -cEi 'VGA compatible controller|3D controller' || true)"

            if [ "$gpu_count" -eq 1 ]; then
                log_warn "Se detectó NVIDIA como única tarjeta gráfica (sin gráfica integrada de respaldo)."
                log_warn "En tarjetas NVIDIA antiguas (Legacy), Nouveau puede causar pantalla negra o cuelgues al iniciar Xorg."

                if ask_yes_no "¿Es hardware Legacy o deseas deshabilitar la aceleración por hardware para garantizar que inicie el video?"; then
                    log_info "Aplicando configuración segura (Failsafe) para Xorg..."
                    install_pkg "xf86-video-nouveau"
                    mkdir -p /etc/X11/xorg.conf.d
                    cat > /etc/X11/xorg.conf.d/20-nouveau-safe.conf <<EOF
Section "Device"
    Identifier "Nvidia Legacy Failsafe"
    Driver "nouveau"
    Option "NoAccel" "True"
EndSection
EOF
                    log_ok "Protección aplicada: /etc/X11/xorg.conf.d/20-nouveau-safe.conf"
                else
                    log_info "Se mantiene la configuración por defecto de Nouveau."
                fi
            else
                log_warn "Nouveau se usa por compatibilidad con musl libc. (Se detectaron $gpu_count GPUs)."
            fi
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
# BLOQUE 8: Detección de CPU y microcódigo
# ------------------------------------------------------------------------------
CPU_VENDOR=""

detect_cpu() {
    log_info "== Detectando fabricante de CPU =="
    if grep -qi "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="intel"
    elif grep -qi "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="amd"
    else
        CPU_VENDOR="desconocido"
    fi
    log_ok "CPU clasificada como: $CPU_VENDOR"
}

install_microcode() {
    log_info "== Instalando microcódigo de CPU =="
    case "$CPU_VENDOR" in
        intel)
            install_pkg "intel-ucode"
            ;;
        amd)
            install_pkg "linux-firmware-amd"
            log_info "AMD no tiene paquete 'amd-ucode' en Alpine; el microcódigo viene en linux-firmware-amd*."
            ;;
        *)
            log_warn "Fabricante de CPU no identificado. Se omite instalación de microcódigo."
            ;;
    esac
    log_warn "Verifica que se cargó en el arranque con: dmesg | grep -i microcode"
}

# ------------------------------------------------------------------------------
# BLOQUE 9: zram (memoria comprimida al 100% de la RAM física)
# ------------------------------------------------------------------------------
setup_zram() {
    log_info "== Configurando zram =="
    install_pkg "zram-init"
    install_pkg "zram-init-openrc"

    ram_total_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    ram_total_mb=$((ram_total_kb / 1024))

    log_info "RAM física detectada: ${ram_total_mb}MB. Configurando zram al 100% de ese valor."

    cat > /etc/conf.d/zram-init <<EOF
load_on_start=yes
unload_on_stop=yes
num_devices=1
type0=swap
size0=${ram_total_mb}
algo0=zstd
EOF

    if ! grep -q "^vm.swappiness=100" /etc/sysctl.conf 2>/dev/null; then
        {
            echo "vm.swappiness=100"
            echo "vm.page-cluster=0"
        } >> /etc/sysctl.conf
    fi

    rc-update add zram-init default || log_warn "No se pudo agregar 'zram-init' al runlevel default."

    log_ok "zram configurado (swap comprimido = 100% de la RAM, algoritmo zstd)."
}

# ------------------------------------------------------------------------------
# BLOQUE 10: EarlyOOM
# ------------------------------------------------------------------------------
setup_earlyoom() {
    log_info "== Configurando EarlyOOM =="
    install_pkg "earlyoom"
    install_pkg "earlyoom-openrc"
    rc-update add earlyoom default || log_warn "No se pudo agregar 'earlyoom' al runlevel default."
    log_ok "EarlyOOM configurado."
}

# ------------------------------------------------------------------------------
# BLOQUE 11: Gestión de energía básica (ACPI)
# ------------------------------------------------------------------------------
setup_power() {
    log_info "== Configurando gestión de energía (ACPI) =="
    install_pkg "acpid"
    install_pkg "acpid-openrc"
    rc-update add acpid default || log_warn "No se pudo agregar 'acpid' al runlevel default."
    log_ok "acpid configurado."
}

# ------------------------------------------------------------------------------
# BLOQUE 12: Soporte de impresión (CUPS)
# ------------------------------------------------------------------------------
setup_printing() {
    log_info "== Configurando soporte de impresión (CUPS) =="
    install_pkg "cups"
    install_pkg "cups-openrc"
    install_pkg "cups-filters"
    install_pkg "system-config-printer"
    rc-update add cupsd default || log_warn "No se pudo agregar 'cupsd' al runlevel default."
    log_ok "CUPS configurado. Interfaz web disponible en http://localhost:631"
}

# ------------------------------------------------------------------------------
# BLOQUE 13: Backends de compresión
# ------------------------------------------------------------------------------
install_archive_tools() {
    log_info "== Instalando utilidades de compresión =="
    install_pkg "zip"
    install_pkg "unzip"
    install_pkg "p7zip"
    install_pkg "unrar"
    log_ok "Backends de compresión instalados."
}

# ------------------------------------------------------------------------------
# BLOQUE 14: Idioma español (XFCE y/o Plasma, según lo detectado)
# ------------------------------------------------------------------------------
setup_locale_es() {
    log_info "== Configurando idioma español para el sistema =="

    install_pkg "musl-locales"
    install_pkg "musl-locales-lang"

    if [ -f /etc/rc.conf ] && ! grep -q '^unicode="YES"' /etc/rc.conf; then
        sed -i 's/#unicode="NO"/#unicode="NO"\nunicode="YES"/' /etc/rc.conf 2>/dev/null || true
    fi

    cat > /etc/profile.d/lang-es.sh <<'EOF'
export LANG="es_ES.UTF-8"
export LC_ALL="es_ES.UTF-8"
export LC_MESSAGES="es_ES.UTF-8"
EOF
    chmod +x /etc/profile.d/lang-es.sh

    install_pkg "lang"

    if [ "$DE_PLASMA" = "yes" ]; then
        log_info "Reforzando traducciones específicas de Plasma..."
        install_pkg "plasma-desktop-lang"
        install_pkg "kdeplasma-addons-lang"
    fi

    log_ok "Idioma español configurado para el/los entorno(s) detectado(s)."
}

# ------------------------------------------------------------------------------
# BLOQUE 15: Tipografías base (antes de LibreOffice)
# ------------------------------------------------------------------------------
install_fonts() {
    log_info "== Instalando tipografías base =="
    install_pkg "ttf-dejavu"
    install_pkg "font-liberation"
    install_pkg "font-liberation-sans-narrow"
    install_pkg "font-noto"
    log_ok "Tipografías base instaladas."
}

# ------------------------------------------------------------------------------
# BLOQUE 16: LibreOffice + paquete de idioma español
# ------------------------------------------------------------------------------
install_libreoffice() {
    log_info "== Instalando LibreOffice (español) =="
    install_pkg "libreoffice"
    install_pkg "libreoffice-lang-es"
    log_ok "LibreOffice instalado con soporte de idioma español."
}

# ------------------------------------------------------------------------------
# BLOQUE 17: Flatpak + Flathub (OnlyOffice y Google Chrome, opcionales)
# ------------------------------------------------------------------------------
setup_flatpak() {
    log_info "== Configurando Flatpak y repositorio Flathub =="

    install_pkg "dbus"
    install_pkg "flatpak"
    install_pkg "xdg-desktop-portal"
    install_pkg "xdg-desktop-portal-gtk"

    if ! command -v flatpak >/dev/null 2>&1; then
        log_error "flatpak no quedó instalado. Verifica el repositorio 'community'. Se omite esta sección."
        return 0
    fi

    if command -v dbus-run-session >/dev/null 2>&1; then
        remote_add_cmd="dbus-run-session -- flatpak"
    else
        log_warn "'dbus-run-session' no disponible; se ejecuta flatpak sin bus de sesión."
        remote_add_cmd="flatpak"
    fi

    if $remote_add_cmd remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
        log_ok "Repositorio Flathub agregado (o ya existía)."
    else
        log_warn "No se pudo agregar el repositorio Flathub."
        return 0
    fi

    if ask_yes_no "¿Deseas instalar OnlyOffice Desktop Editors vía Flatpak?"; then
        $remote_add_cmd install -y flathub org.onlyoffice.desktopeditors && log_ok "OnlyOffice instalado." || log_warn "Fallo al instalar OnlyOffice."
    else
        log_info "Se omite OnlyOffice."
    fi

    if ask_yes_no "¿Deseas instalar Google Chrome vía Flatpak (paquete comunitario, no oficial de Google)?"; then
        $remote_add_cmd install -y flathub com.google.Chrome && log_ok "Google Chrome instalado." || log_warn "Fallo al instalar Google Chrome."
    else
        log_info "Se omite Google Chrome."
    fi
}

# ------------------------------------------------------------------------------
# BLOQUE 18: Permisos de grupo para Audio/Video/Impresión (usuario vía doas)
# ------------------------------------------------------------------------------
setup_user_groups() {
    log_info "== Configurando permisos de grupo =="

    target_user="${DOAS_USER:-}"
    [ -z "$target_user" ] && target_user="$(logname 2>/dev/null || true)"

    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        log_warn "No se pudo determinar un usuario estándar. Ejecuta manualmente: adduser <usuario> audio video lpadmin"
        return 0
    fi

    log_info "Usuario detectado: $target_user"

    for grp in audio video lpadmin; do
        adduser "$target_user" "$grp" && log_ok "Agregado a '$grp'." || log_warn "No se pudo agregar a '$grp'."
    done
}

# ------------------------------------------------------------------------------
# BLOQUE 19: Función principal
# ------------------------------------------------------------------------------
main() {
    log_info "===== Iniciando configuración post-instalación de escritorio en Alpine Linux ====="

    check_root
    update_system
    setup_keyboard_layout
    detect_desktop_environment
    setup_applets
    detect_hardware
    install_drivers
    detect_cpu
    install_microcode
    setup_zram
    setup_earlyoom
    setup_power
    setup_printing
    install_archive_tools
    setup_locale_es
    install_fonts
    install_libreoffice
    setup_flatpak
    setup_user_groups

    log_ok "===== Proceso completado exitosamente ====="
    log_info "Reinicia el sistema para que todos los cambios surtan efecto."

    trap - EXIT INT TERM
}

main "$@"
