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
# BLOQUE 4: Detección multiparadigma del entorno de escritorio
# ------------------------------------------------------------------------------
DE_XFCE="no"
DE_PLASMA="no"
DE_GNOME="no"
DE_MATE="no"
DE_LXQT="no"

detect_desktop_environment() {
    log_info "== Detectando entorno de escritorio instalado =="

    apk info -e xfce4-session >/dev/null 2>&1 && { DE_XFCE="yes"; log_ok "XFCE detectado."; }
    apk info -e plasma-desktop >/dev/null 2>&1 && { DE_PLASMA="yes"; log_ok "KDE Plasma detectado."; }
    apk info -e gnome-shell >/dev/null 2>&1 && { DE_GNOME="yes"; log_ok "GNOME detectado."; }
    apk info -e mate-session-manager >/dev/null 2>&1 && { DE_MATE="yes"; log_ok "MATE detectado."; }
    apk info -e lxqt-session >/dev/null 2>&1 && { DE_LXQT="yes"; log_ok "LXQt detectado."; }

    if [ "$DE_XFCE" = "no" ] && [ "$DE_PLASMA" = "no" ] && [ "$DE_GNOME" = "no" ] && [ "$DE_MATE" = "no" ] && [ "$DE_LXQT" = "no" ]; then
        log_warn "No se detectó un entorno soportado. Se instalarán herramientas genéricas de consola."
    fi
}

# ------------------------------------------------------------------------------
# BLOQUE 5: Detección del usuario real del sistema (vía doas/logname)
# ------------------------------------------------------------------------------
TARGET_USER=""
TARGET_HOME=""

detect_target_user() {
    log_info "== Detectando usuario real del sistema =="

    TARGET_USER="${DOAS_USER:-}"
    [ -z "$TARGET_USER" ] && TARGET_USER="$(logname 2>/dev/null || true)"

    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
        log_warn "No se pudo determinar un usuario estándar vía doas ni logname."
        TARGET_USER=""
        return 0
    fi

    TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
    if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
        log_warn "No se pudo determinar el directorio home de '$TARGET_USER'."
        TARGET_HOME=""
        return 0
    fi

    log_ok "Usuario detectado: $TARGET_USER (home: $TARGET_HOME)"
}

# ------------------------------------------------------------------------------
# BLOQUE 6: Applets de red y audio (enrutamiento dinámico según DE)
# ------------------------------------------------------------------------------
setup_applets() {
    log_info "== Configurando servicios base de red y audio =="

    # Base universal independiente de la interfaz gráfica
    install_pkg "networkmanager"
    install_pkg "networkmanager-wifi"
    install_pkg "wpa_supplicant"
    install_pkg "pulseaudio"
    install_pkg "pulseaudio-alsa"

    log_info "Inyectando applets de interfaz específicos..."

    if [ "$DE_XFCE" = "yes" ]; then
        install_pkg "network-manager-applet"
        install_pkg "xfce4-pulseaudio-plugin"
    fi

    if [ "$DE_PLASMA" = "yes" ]; then
        install_pkg "plasma-nm"
        install_pkg "plasma-pa"
    fi

    if [ "$DE_GNOME" = "yes" ]; then
        # GNOME tiene estos controles incrustados en su shell de forma monolítica.
        # Instalamos pavucontrol como mezclador avanzado de respaldo.
        install_pkg "pavucontrol"
    fi

    if [ "$DE_MATE" = "yes" ]; then
        # MATE es altamente compatible con el ecosistema GTK de NM.
        install_pkg "network-manager-applet"
        install_pkg "mate-media"
    fi

    if [ "$DE_LXQT" = "yes" ]; then
        # LXQt carece de un applet propio maduro para NM, nm-applet es el estándar de facto.
        # Para audio, pavucontrol-qt es la herramienta oficial del proyecto.
        install_pkg "network-manager-applet"
        install_pkg "pavucontrol-qt"
    fi

    # NetworkManager asume el control absoluto de wpa_supplicant vía D-Bus.
    # PulseAudio no se toca aquí: OpenRC no debe arrancar audio de sistema, cada DE lo hace en su autostart.
    rc-update add networkmanager default || log_warn "No se pudo agregar 'networkmanager' al runlevel default."

    log_ok "Arquitectura de red y audio acoplada al entorno visual."
}

# ------------------------------------------------------------------------------
# BLOQUE 7: Detección de hardware gráfico (soporta configuraciones híbridas)
# ------------------------------------------------------------------------------
GPU_HAS_INTEL="no"
GPU_HAS_AMD="no"
GPU_HAS_NVIDIA="no"
GPU_HAS_VIRTUAL="no"
GPU_COUNT=0

detect_hardware() {
    log_info "== Detectando hardware gráfico =="
    command -v lspci >/dev/null 2>&1 || install_pkg "pciutils"

    if ! command -v lspci >/dev/null 2>&1; then
        log_error "No fue posible obtener 'lspci'. Se omitirá la detección automática de GPU."
        return 0
    fi

    log_info "Componentes PCI detectados:"
    lspci | tee -a "$LOG_FILE"

    vga_line="$(lspci | grep -Ei 'VGA compatible controller|3D controller' || true)"
    GPU_COUNT="$(lspci | grep -cEi 'VGA compatible controller|3D controller' || true)"

    if [ -z "$vga_line" ]; then
        log_warn "No se detectó ningún controlador de video vía lspci."
        return 0
    fi

    log_info "Controlador(es) de video encontrado(s):"
    log_info "$vga_line"

    echo "$vga_line" | grep -qi "intel" && GPU_HAS_INTEL="yes"
    echo "$vga_line" | grep -Eq "AMD|ATI|Radeon" && GPU_HAS_AMD="yes"
    echo "$vga_line" | grep -qi "nvidia" && GPU_HAS_NVIDIA="yes"
    echo "$vga_line" | grep -Eqi "virtio|vmware|virtualbox|qxl" && GPU_HAS_VIRTUAL="yes"

    log_ok "Resumen GPU -> Intel:$GPU_HAS_INTEL AMD:$GPU_HAS_AMD NVIDIA:$GPU_HAS_NVIDIA Virtual:$GPU_HAS_VIRTUAL (adaptadores detectados: $GPU_COUNT)"
}

# ------------------------------------------------------------------------------
# BLOQUE 8: Firmware y controladores de video (protección NVIDIA Legacy)
# ------------------------------------------------------------------------------
install_drivers() {
    log_info "== Instalando firmware y controladores =="

    install_pkg "linux-firmware"
    install_pkg "mesa-dri-gallium"
    install_pkg "mesa-gl"
    install_pkg "mesa-egl"

    if [ "$GPU_HAS_INTEL" = "yes" ]; then
        log_info "Instalando firmware Intel..."
        install_pkg "linux-firmware-i915"
        install_pkg "mesa-vulkan-intel"
    fi

    if [ "$GPU_HAS_AMD" = "yes" ]; then
        log_info "Instalando firmware y Vulkan para AMD/Radeon..."
        install_pkg "linux-firmware-amdgpu"
        install_pkg "linux-firmware-radeon"
        install_pkg "mesa-vulkan-ati"
        install_pkg "mesa-vulkan-radeon"
        install_pkg "vulkan-loader"
    fi

    if [ "$GPU_HAS_VIRTUAL" = "yes" ]; then
        log_info "Entorno virtualizado detectado. Instalando utilidades QEMU/KVM/VirtualBox..."
        install_pkg "xf86-video-vmware"
        install_pkg "xf86-video-qxl"
        install_pkg "spice-vdagent"
        rc-update add spice-vdagentd default || log_warn "Fallo al habilitar spice-vdagentd."
    fi

    if [ "$GPU_HAS_NVIDIA" = "yes" ]; then
        log_info "Instalando soporte NVIDIA (driver abierto Nouveau, vía Gallium)..."
        install_pkg "linux-firmware-nvidia"

        if [ "$GPU_COUNT" -gt 1 ]; then
            log_warn "Configuración híbrida detectada ($GPU_COUNT adaptadores, ej. Optimus)."
            log_warn "Aunque exista una GPU integrada de respaldo, Xorg puede seguir intentando inicializar aceleración 3D sobre nouveau y colgar el arranque en tarjetas Fermi/Kepler antiguas."
        else
            log_warn "Se detectó NVIDIA como única tarjeta gráfica (sin gráfica integrada de respaldo)."
        fi
        log_warn "En tarjetas NVIDIA antiguas (Tesla/Fermi/Kepler), Nouveau puede causar pantalla negra o cuelgues al iniciar Xorg."

        log_info "Opción 's': bloquea la NVIDIA por completo (kernel + Xorg) y usa solo la GPU restante. Modo seguro, recomendado en hardware Legacy."
        log_info "Opción 'n': deja Nouveau activo con aceleración 3D normal en la NVIDIA. Riesgo de pantalla negra/cuelgue en tarjetas antiguas."

        if ask_yes_no "¿Bloquear la NVIDIA y usar solo la GPU restante (modo seguro)?"; then
            log_info "Aplicando protección: NoAccel en Xorg + bloqueo del módulo nouveau en el kernel..."

            install_pkg "xf86-video-nouveau"
            mkdir -p /etc/X11/xorg.conf.d
            cat > /etc/X11/xorg.conf.d/20-nouveau-safe.conf <<EOF
Section "Device"
    Identifier "Nvidia Legacy Failsafe"
    Driver "nouveau"
    Option "NoAccel" "True"
EndSection
EOF

            mkdir -p /etc/modprobe.d
            cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

            log_ok "Protección aplicada: /etc/X11/xorg.conf.d/20-nouveau-safe.conf + /etc/modprobe.d/blacklist-nouveau.conf"
            log_info "La NVIDIA quedará inactiva; el sistema usará solo la(s) GPU(s) restante(s). Para revertir: borra ambos archivos y reinicia."
        else
            log_info "Se mantiene Nouveau activo sin restricciones (NVIDIA con aceleración 3D normal)."
        fi
    fi

    if [ "$GPU_HAS_INTEL" = "no" ] && [ "$GPU_HAS_AMD" = "no" ] && [ "$GPU_HAS_NVIDIA" = "no" ] && [ "$GPU_HAS_VIRTUAL" = "no" ]; then
        log_warn "GPU no identificada. mesa-dri-gallium ya cubre software rendering (llvmpipe) de respaldo."
    fi

    log_ok "Instalación de firmware y controladores finalizada."
}

# ------------------------------------------------------------------------------
# BLOQUE 9: Detección de CPU y microcódigo
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
# BLOQUE 10: zram (memoria comprimida al 100% de la RAM física)
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
# BLOQUE 11: EarlyOOM
# ------------------------------------------------------------------------------
setup_earlyoom() {
    log_info "== Configurando EarlyOOM =="
    install_pkg "earlyoom"
    install_pkg "earlyoom-openrc"
    rc-update add earlyoom default || log_warn "No se pudo agregar 'earlyoom' al runlevel default."
    log_ok "EarlyOOM configurado."
}

# ------------------------------------------------------------------------------
# BLOQUE 12: Gestión de energía básica (ACPI)
# ------------------------------------------------------------------------------
setup_power() {
    log_info "== Configurando gestión de energía (ACPI) =="
    install_pkg "acpid"
    install_pkg "acpid-openrc"
    rc-update add acpid default || log_warn "No se pudo agregar 'acpid' al runlevel default."
    log_ok "acpid configurado."
}

# ------------------------------------------------------------------------------
# BLOQUE 13: Soporte de impresión (CUPS)
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
# BLOQUE 14: Backends de compresión
# ------------------------------------------------------------------------------
# NOTA: "unrar" NO existe como paquete en Alpine (ni en main ni en
# community, verificado en v3.24) - es de licencia no-libre y Alpine no
# lo empaqueta. No se automatiza su instalación manual porque cada
# versión de rarlab.com cambia de nombre de archivo y una URL fija en
# el script quedaría rota sin previo aviso.
install_archive_tools() {
    log_info "== Instalando utilidades de compresión =="
    install_pkg "zip"
    install_pkg "unzip"
    install_pkg "p7zip"
    log_warn "'unrar' no está disponible en los repos de Alpine (licencia no-libre)."
    log_info "Para soporte de RAR, instala manualmente el binario oficial desde https://www.rarlab.com/download.htm"
    log_ok "Backends de compresión instalados (zip/unzip/7z)."
}

# ------------------------------------------------------------------------------
# BLOQUE 15: Idioma español — sistema, XFCE y propagación global a Plasma
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
    log_ok "Capa 1/3: variables de idioma escritas en /etc/profile.d/lang-es.sh"

    if [ -f /etc/environment ]; then
        sed -i '/^LANG=/d;/^LC_ALL=/d;/^LC_MESSAGES=/d' /etc/environment
    fi
    {
        echo "LANG=es_ES.UTF-8"
        echo "LC_ALL=es_ES.UTF-8"
        echo "LC_MESSAGES=es_ES.UTF-8"
    } >> /etc/environment
    log_ok "Capa 2/3: variables de idioma agregadas a /etc/environment (leído por PAM en la mayoría de gestores de sesión gráficos)."

    install_pkg "lang"

    if [ "$DE_PLASMA" = "yes" ]; then
        log_info "Reforzando traducciones específicas de Plasma..."
        install_pkg "plasma-desktop-lang"
        install_pkg "kdeplasma-addons-lang"

        mkdir -p /etc/xdg
        cat > /etc/xdg/plasma-localerc <<'EOF'
[Formats]
LANG=es_ES.UTF-8

[Translations]
LANGUAGE=es_ES:es
EOF
        log_ok "Capa 3/3: default de sistema escrito en /etc/xdg/plasma-localerc (aplica a usuarios nuevos)."

        if [ -n "$TARGET_USER" ] && [ -n "$TARGET_HOME" ]; then
            mkdir -p "$TARGET_HOME/.config"
            cat > "$TARGET_HOME/.config/plasma-localerc" <<'EOF'
[Formats]
LANG=es_ES.UTF-8

[Translations]
LANGUAGE=es_ES:es
EOF
            chown "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/plasma-localerc" 2>/dev/null || true
            log_ok "Capa 3/3: idioma de Plasma pre-configurado también para el usuario existente '$TARGET_USER'."
        else
            log_warn "No se detectó un usuario existente; solo quedó el default de sistema en /etc/xdg/plasma-localerc."
        fi
    fi

    log_ok "Idioma español configurado para el/los entorno(s) detectado(s)."
}

# ------------------------------------------------------------------------------
# BLOQUE 16: Tipografías base (antes de LibreOffice)
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
# BLOQUE 17: LibreOffice + paquete de idioma español
# ------------------------------------------------------------------------------
install_libreoffice() {
    log_info "== Instalando LibreOffice (español) =="
    install_pkg "libreoffice"
    install_pkg "libreoffice-lang-es"
    log_ok "LibreOffice instalado con soporte de idioma español."
}

# ------------------------------------------------------------------------------
# BLOQUE 18: Flatpak + Flathub (OnlyOffice y Google Chrome, opcionales)
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
# BLOQUE 19: Permisos de grupo para Audio/Video/Impresión
# ------------------------------------------------------------------------------
setup_user_groups() {
    log_info "== Configurando permisos de grupo =="

    if [ -z "$TARGET_USER" ]; then
        log_warn "No se determinó un usuario estándar. Ejecuta manualmente: adduser <usuario> audio video lpadmin"
        return 0
    fi

    for grp in audio video lpadmin; do
        adduser "$TARGET_USER" "$grp" && log_ok "Agregado a '$grp'." || log_warn "No se pudo agregar a '$grp'."
    done
}

# ------------------------------------------------------------------------------
# BLOQUE 20: Función principal
# ------------------------------------------------------------------------------
main() {
    log_info "===== Iniciando configuración post-instalación de escritorio en Alpine Linux ====="

    check_root
    update_system
    setup_keyboard_layout
    detect_desktop_environment
    detect_target_user
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
