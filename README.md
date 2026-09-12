# desktop-postinstall.sh — Script de post-instalación de escritorio para Alpine Linux

Script de shell POSIX (`ash`, compatible con BusyBox) que automatiza la configuración de un entorno de escritorio recién instalado en Alpine Linux: red, audio, idioma, controladores de video, energía, impresión, ofimática y estabilidad general del sistema. Está pensado especialmente para revivir equipos antiguos o con recursos limitados (2-8 GB de RAM), pero funciona igual de bien en hardware moderno.

Detecta automáticamente qué tiene tu sistema (entorno de escritorio, GPU, CPU) y adapta lo que instala en consecuencia, en vez de asumir una configuración fija.

> ⚠️ **Problema conocido sin resolver — GPU NVIDIA.** En las pruebas realizadas hasta ahora, el modo seguro del Bloque 8 (bloqueo de `nouveau` vía Xorg + `/etc/modprobe.d`) **no ha sido suficiente en todos los casos**: tras reiniciar, el equipo puede seguir mostrando pantalla negra en hardware con tarjeta NVIDIA. Esto sigue bajo investigación y **no debe darse por resuelto** solo por haber respondido "sí" a la pregunta del Bloque 8. Ver la sección [Limitaciones conocidas](#limitaciones-conocidas) para más detalle.

---

## Tabla de contenidos

1. [Requisitos previos](#requisitos-previos)
2. [Cómo ejecutarlo](#cómo-ejecutarlo)
3. [Filosofía del script](#filosofía-del-script)
4. [Recorrido bloque por bloque](#recorrido-bloque-por-bloque)
5. [Preguntas interactivas que hará el script](#preguntas-interactivas-que-hará-el-script)
6. [Archivos que el script crea o modifica](#archivos-que-el-script-crea-o-modifica)
7. [Servicios OpenRC habilitados](#servicios-openrc-habilitados)
8. [Registro de ejecución (log)](#registro-de-ejecución-log)
9. [Reejecución / idempotencia](#reejecución--idempotencia)
10. [Limitaciones conocidas](#limitaciones-conocidas)
11. [Solución de problemas](#solución-de-problemas)
12. [Cómo revertir cambios específicos](#cómo-revertir-cambios-específicos)

---

## Requisitos previos

- Alpine Linux ya instalado (`setup-alpine` ejecutado).
- Un entorno de escritorio ya instalado mediante `setup-desktop` (XFCE, KDE Plasma, GNOME, MATE o LXQt) — el script **no instala el entorno de escritorio en sí**, solo lo complementa y corrige detalles que Alpine deja sin configurar por defecto.
- Repositorios `main` **y** `community` habilitados en `/etc/apk/repositories` (varios paquetes que el script instala, como `flatpak`, `libreoffice` o `earlyoom`, viven en `community`).
- Conexión a internet activa.
- Acceso como `root` (directamente o vía `doas`).

Puedes verificar los repositorios con:

```sh
grep -v '^#' /etc/apk/repositories
```

## Cómo ejecutarlo

```sh
doas sh desktop-postinstall.sh
```

o, si ya estás en una sesión root:

```sh
sh desktop-postinstall.sh
```

El script pedirá confirmación en un puñado de puntos (ver [sección 5](#preguntas-interactivas-que-hará-el-script)); el resto corre sin intervención. Al finalizar, **reinicia el sistema** — varios cambios (bloqueo de módulos de kernel, servicios recién habilitados, variables de idioma) no toman efecto por completo hasta el próximo arranque.

## Filosofía del script

Tres principios guían todas las decisiones de diseño:

- **Detectar antes de asumir.** El script nunca asume qué entorno de escritorio, GPU o CPU tienes — los detecta con `apk info -e`, `lspci` y `/proc/cpuinfo`, y adapta cada bloque al resultado real.
- **Nunca abortar por un paquete faltante.** Cada instalación pasa por la función `install_pkg()`, que registra un `WARN` y continúa si un paquete no existe en tu rama/arquitectura, en vez de detener todo el script (`set -e` sigue activo para errores verdaderamente graves, como quedarte sin permisos de root).
- **Honestidad sobre las limitaciones de Alpine.** Cuando algo no tiene una solución limpia en Alpine (por ejemplo, `unrar` no está empaquetado por ser de licencia no-libre, o el microcódigo de AMD no tiene paquete dedicado), el script lo dice explícitamente en el log en vez de fingir que lo resolvió.

## Recorrido bloque por bloque

El script se organiza en 21 bloques, ejecutados en este orden por la función `main()`:

### Bloque 1 — `check_root`
Verifica que el script corre como `root` (`id -u` = 0). Si no, aborta con un mensaje claro.

### Bloque 2 — `update_system` / `install_pkg`
`update_system` corre `apk update` una sola vez al principio. `install_pkg` es la función auxiliar que usan todos los demás bloques para instalar paquetes de forma segura (ver "Filosofía" arriba).

### Bloque 3 — `setup_keyboard_layout`
Configura el teclado a distribución **latam** en dos capas independientes:
- **Consola (TTY):** `setup-keymap latam latam`, ejecutado de forma no interactiva. El único prompt que sobrevive es la confirmación de OpenRC al reiniciar el servicio `loadkmap` ("you are stopping a boot service"), que se responde automáticamente vía `yes |`.
- **Sesión gráfica (Xorg):** crea `/etc/X11/xorg.conf.d/00-keyboard.conf` con `Option "XkbLayout" "latam"`, para que XFCE, Plasma, GNOME, MATE o LXQt también arranquen en ese layout (la consola y Xorg son capas separadas; una no implica la otra).

### Bloque 4 — `detect_desktop_environment`
Pregunta a `apk` (no a variables de entorno, que no existen en una shell root fuera de sesión gráfica) qué entornos están instalados: `xfce4-session`, `plasma-desktop-meta`/`plasma-desktop`, `gnome-shell`, `mate-session-manager`, `lxqt-session`. Guarda el resultado en las variables `DE_XFCE`, `DE_PLASMA`, `DE_GNOME`, `DE_MATE`, `DE_LXQT` (cada una `"yes"`/`"no"`), que usan todos los bloques posteriores para decidir qué instalar. Si tienes más de un entorno instalado simultáneamente, el script configura ambos sin conflicto.

### Bloque 5 — `detect_target_user`
Identifica al usuario real del sistema (no root) para poder aplicarle configuración de idioma y grupos más adelante. Usa `$DOAS_USER` (Alpine usa `doas`, no `sudo`) con `logname` como respaldo, y resuelve su directorio home vía `getent passwd`. Si no logra determinar un usuario, los bloques que lo necesitan simplemente avisan y continúan sin fallar.

### Bloque 6 — `setup_applets`
Instala la base de red/audio (`networkmanager`, `wpa_supplicant`, `pulseaudio`) siempre, sin importar el entorno gráfico. Luego, según las banderas `DE_*` detectadas en el Bloque 4, instala el "applet" nativo correspondiente:

| Entorno | WiFi | Volumen |
|---|---|---|
| XFCE | `network-manager-applet` | `xfce4-pulseaudio-plugin` |
| Plasma | `plasma-nm` | `plasma-pa` |
| GNOME | (incrustado en el shell) | `pavucontrol` (mezclador avanzado) |
| MATE | `network-manager-applet` | `mate-media` |
| LXQt | `network-manager-applet` | `pavucontrol-qt` (mezclador; el widget de bandeja ya viene en `lxqt-panel`) |

`wpa_supplicant` y `pulseaudio` **no** se registran como servicios OpenRC de arranque: `wpa_supplicant` lo invoca NetworkManager internamente vía D-Bus, y PulseAudio se gestiona por sesión de usuario en cada entorno, no como demonio de sistema.

### Bloque 7 — `detect_hardware`
Ejecuta `lspci` y clasifica **todos** los adaptadores de video presentes en banderas independientes: `GPU_HAS_INTEL`, `GPU_HAS_AMD`, `GPU_HAS_NVIDIA`, `GPU_HAS_VIRTUAL` (más `GPU_COUNT` con el total). Esto es deliberado: en un laptop con gráficos híbridos (Optimus, Intel+NVIDIA) `lspci` devuelve más de una línea, y el script necesita saber de **todas** las GPU presentes, no solo la primera que coincida.

### Bloque 8 — `install_drivers`
Instala controladores según las banderas del Bloque 7 (puede instalar más de un fabricante a la vez, si el hardware es híbrido):
- **Intel:** `linux-firmware-i915`, `mesa-vulkan-intel`.
- **AMD:** `linux-firmware-amdgpu`/`radeon`, `mesa-vulkan-ati`/`radeon`, `vulkan-loader`.
- **Virtual (QEMU/VMware/VirtualBox):** drivers `xf86-video-*` + `spice-vdagent`.
- **NVIDIA:** `linux-firmware-nvidia` (driver abierto `nouveau`). Aquí el script **pregunta** si quieres activar un modo seguro (ver [sección 5](#preguntas-interactivas-que-hará-el-script)) — importante en tarjetas antiguas (Tesla/Fermi/Kepler), donde `nouveau` puede colgar el arranque incluso si hay una GPU integrada de respaldo.

Si no se detecta ninguna GPU reconocida, `mesa-dri-gallium` ya deja software rendering (`llvmpipe`) como respaldo funcional.

### Bloque 9 — `detect_cpu` / `install_microcode`
Lee `/proc/cpuinfo` para clasificar el fabricante (`GenuineIntel`/`AuthenticAMD`). Para Intel instala `intel-ucode`. **Para AMD no existe un paquete `amd-ucode` en Alpine** — el microcódigo viaja dentro de `linux-firmware-amd`, que es lo que se instala en su lugar. En ambos casos se advierte que el paquete instalado no garantiza por sí solo que el microcódigo se cargue en el arranque (Alpine no lo integra automáticamente al initramfs); verificar con `dmesg | grep -i microcode` tras reiniciar.

### Bloque 10 — `setup_zram`
Calcula la RAM física total (`/proc/meminfo`) y configura `zram-init` con un dispositivo swap comprimido (algoritmo `zstd`) de tamaño igual al 100% de esa RAM. Ajusta también `vm.swappiness=100` y `vm.page-cluster=0` en `/etc/sysctl.conf` (valores recomendados para swap sobre zram). Pensado para exprimir el máximo de memoria efectiva en equipos con poca RAM física.

### Bloque 11 — `setup_earlyoom`
Instala `earlyoom` (+ su subpaquete `earlyoom-openrc`, necesario para que exista el script de arranque) y lo habilita. `earlyoom` monitorea la memoria en segundo plano y cierra el proceso responsable (ej. una pestaña de Chrome) segundos antes de que el sistema se quede sin memoria y se congele por completo.

### Bloque 12 — `setup_power`
Instala y habilita `acpid` (+ `acpid-openrc`), para que Alpine reaccione a eventos físicos: cerrar la tapa de un laptop, presionar el botón de encendido, etc.

### Bloque 13 — `setup_usb_automount`
Configura el montaje automático de memorias USB al conectarlas. Es el bloque con más piezas coordinadas:
1. **`dbus`** (+ servicio `dbus`) — instalado primero porque todo lo demás en este bloque depende del bus de mensajes del sistema.
2. **`udisks2`** — hace el montaje real. No tiene servicio OpenRC propio: se activa bajo demanda vía D-Bus.
3. **`elogind` + `polkit-elogind`** (servicios `elogind` y `polkit`, nombres distintos a los paquetes) — autorización para que un usuario normal (no root) pueda montar sin contraseña, basada en detección de **sesión activa** (no en pertenencia a grupos Unix — ver [Limitaciones conocidas](#limitaciones-conocidas)).
4. **Disparador según entorno:** `gvfs` + `thunar-volman` para XFCE; `gvfs` para GNOME/MATE; `gvfs` + `lxqt-policykit` para LXQt. Plasma no necesita nada adicional aquí porque Dolphin usa KIO/Solid + `udisks2` directamente.

### Bloque 14 — `setup_printing`
Instala `cups` + `cups-openrc` + `cups-filters` + `system-config-printer`, habilita el servicio `cupsd`, y deja la interfaz web de CUPS disponible en `http://localhost:631`.

### Bloque 15 — `install_archive_tools`
Instala `zip`, `unzip`, `p7zip`. **`unrar` no se instala porque no existe como paquete en Alpine** (licencia no-libre, verificado en v3.24) — el script lo indica explícitamente en el log en vez de intentarlo y fallar en silencio, y apunta al binario oficial de `rarlab.com/download.htm` como única vía si de verdad se necesita soporte RAR (no automatizado por el script: cada versión de RARLAB cambia el nombre del archivo, y una URL fija quedaría rota con el tiempo).

### Bloque 16 — `setup_locale_es`
Configura español en tres capas independientes, porque ningún mecanismo por sí solo cubre todos los casos:
1. **`/etc/profile.d/lang-es.sh`** — variables `LANG`/`LC_ALL`/`LC_MESSAGES=es_ES.UTF-8` para shells de login tradicionales.
2. **`/etc/environment`** — las mismas variables, leídas por PAM (`pam_env`) en la mayoría de gestores de sesión gráficos (SDDM incluido), que no siempre pasan por `/etc/profile.d`.
3. **`plasma-localerc`** (solo si se detecta Plasma) — Plasma tiene su **propio** mecanismo de idioma, separado del `LANG` del sistema, con dos secciones distintas: `[Formats]` (números/fecha) y `[Translations]` (idioma real de la interfaz). Se escribe tanto en `/etc/xdg/plasma-localerc` (default para usuarios nuevos) como en `$HOME/.config/plasma-localerc` del usuario detectado en el Bloque 5.

También instala `musl-locales`/`musl-locales-lang` y el metapaquete `lang`, que dispara automáticamente (vía `install_if` de `apk`) los subpaquetes `-lang` de todo el software ya instalado en el sistema (XFCE, GTK, Plasma, NetworkManager applet, etc.), sin necesidad de listar cada paquete a mano.

> **Nota:** musl (la libc de Alpine) no tiene un locale `es_MX.UTF-8` — solo un conjunto reducido, entre ellos `es_ES.UTF-8`, que es el que usa el script. Para la traducción de interfaz esto no supone ninguna diferencia práctica (los paquetes de idioma no distinguen variantes regionales de español).

### Bloque 17 — `install_fonts`
Instala `ttf-dejavu`, `font-liberation` + `font-liberation-sans-narrow` (métricamente compatibles con Arial/Times/Courier — importante para abrir `.docx` sin que el texto se desborde) y `font-noto`. Se ejecuta antes de LibreOffice a propósito.

### Bloque 18 — `install_libreoffice`
Instala `libreoffice` + `libreoffice-lang-es`.

### Bloque 19 — `setup_flatpak`
Instala Flatpak y agrega el repositorio Flathub. Instala `xdg-desktop-portal` + `xdg-desktop-portal-gtk` como base universal, y además el portal nativo correspondiente si se detecta Plasma (`xdg-desktop-portal-kde`) o LXQt (`xdg-desktop-portal-lxqt`) — así los diálogos de "Abrir/Guardar" de apps en sandbox (Chrome, OnlyOffice) se ven coherentes con el entorno en vez de forzar siempre estética GTK. Luego **pregunta** (ver sección 5) si instalar OnlyOffice y Google Chrome desde Flathub.

### Bloque 20 — `setup_user_groups`
Agrega al usuario detectado en el Bloque 5 a los grupos `audio`, `video` y `lpadmin` (necesarios para acceso a hardware de sonido/video y administración de impresoras).

### Bloque 21 — `main`
Orquesta la ejecución de todos los bloques anteriores en el orden correcto (el orden importa: por ejemplo, `detect_desktop_environment` debe correr antes que `setup_applets`, y `detect_hardware` antes que `install_drivers`).

## Preguntas interactivas que hará el script

El script se detiene a preguntar en exactamente tres puntos:

1. **NVIDIA detectada (Bloque 8):**
   > `¿Bloquear la NVIDIA y usar solo la GPU restante (modo seguro)?`
   - **`s`** → Bloquea `nouveau` por completo: `Option "NoAccel" "True"` en Xorg **+** `blacklist nouveau` a nivel de kernel (`/etc/modprobe.d`). La NVIDIA queda inactiva; el sistema usa solo la(s) GPU(s) restante(s). Recomendado en tarjetas Tesla/Fermi/Kepler o si notas pantalla negra/cuelgues.
   - **`n`** → Deja `nouveau` activo con aceleración 3D normal. Riesgo de cuelgue en hardware legacy.

2. **OnlyOffice vía Flatpak (Bloque 19):**
   > `¿Deseas instalar OnlyOffice Desktop Editors vía Flatpak?`

3. **Google Chrome vía Flatpak (Bloque 19):**
   > `¿Deseas instalar Google Chrome vía Flatpak (paquete comunitario, no oficial de Google)?`
   - Se aclara explícitamente que es un empaquetado mantenido por la comunidad de Flathub, no publicado por Google.

Cualquier respuesta que no empiece con `s`/`S`/`y`/`Y` (incluyendo Enter vacío) se interpreta como "no".

## Archivos que el script crea o modifica

| Archivo | Bloque | Propósito |
|---|---|---|
| `/etc/X11/xorg.conf.d/00-keyboard.conf` | 3 | Layout de teclado latam en Xorg |
| `/etc/X11/xorg.conf.d/20-nouveau-safe.conf` | 8 | `NoAccel` para nouveau (solo si se acepta el modo seguro) |
| `/etc/modprobe.d/blacklist-nouveau.conf` | 8 | Bloqueo del módulo `nouveau` a nivel de kernel (solo si se acepta) |
| `/etc/conf.d/zram-init` | 10 | Tamaño y algoritmo del dispositivo zram |
| `/etc/sysctl.conf` | 10 | `vm.swappiness`, `vm.page-cluster` (se agregan líneas, no se sobreescribe) |
| `/etc/profile.d/lang-es.sh` | 16 | Variables de idioma para shells de login |
| `/etc/environment` | 16 | Variables de idioma para PAM (se limpian líneas `LANG`/`LC_*` previas antes de reescribir) |
| `/etc/xdg/plasma-localerc` | 16 | Idioma de Plasma, default de sistema (solo si se detecta Plasma) |
| `$HOME/.config/plasma-localerc` | 16 | Idioma de Plasma para el usuario detectado (solo si se detecta Plasma) |
| `/etc/rc.conf` | 16 | Se agrega `unicode="YES"` si no estaba presente |
| `/var/log/desktop-postinstall.log` | (todos) | Registro completo de la ejecución |

## Servicios OpenRC habilitados

Todos en el runlevel `default`, salvo aclaración:

`networkmanager`, `spice-vdagentd` (solo entornos virtualizados), `zram-init`, `earlyoom`, `acpid`, `dbus`, `elogind`, `polkit`, `cupsd`.

`udisks2`, `wpa_supplicant` y `pulseaudio` **no** se registran como servicios de arranque a propósito (ver Bloques 6 y 13 para el porqué de cada uno).

## Registro de ejecución (log)

Todo lo que el script hace queda en `/var/log/desktop-postinstall.log`, con cuatro niveles:

- `[INFO]` — paso en curso.
- `[OK]` — paso completado con éxito.
- `[WARN]` — algo no salió como se esperaba, pero el script continúa (paquete no encontrado, servicio no agregado, etc.).
- `[ERROR]` — fallo grave que sí detiene el script (falta de permisos root, `apk update` fallido).

El log es acumulativo entre ejecuciones (usa `tee -a`), así que si corres el script varias veces, verás el historial completo de todas las corridas en el mismo archivo.

## Reejecución / idempotencia

El script está diseñado para poder correrse más de una vez sin causar daño:

- `apk add` sobre un paquete ya instalado no hace nada.
- `rc-update add` sobre un servicio ya agregado a un runlevel no duplica la entrada.
- Los archivos de configuración se sobreescriben con `cat >` (contenido determinista, no se acumulan versiones).
- `/etc/environment` limpia explícitamente las líneas `LANG`/`LC_ALL`/`LC_MESSAGES` previas antes de volver a escribirlas, para evitar duplicados.

Esto es útil si quieres volver a correrlo tras cambiar de opinión en alguna de las preguntas interactivas, o después de instalar un segundo entorno de escritorio.

## Limitaciones conocidas

- **⚠️ Pantalla negra persistente en hardware NVIDIA, incluso con el modo seguro activado.** Pruebas realizadas hasta ahora muestran que, en al menos algunos equipos con tarjeta NVIDIA, el problema de pantalla negra **reaparece tras reiniciar** aunque se haya respondido "sí" a la pregunta del Bloque 8 (bloqueo de `nouveau` vía `NoAccel` en Xorg + `blacklist` en `/etc/modprobe.d`). Esto indica que la causa raíz **no está completamente resuelta** con el enfoque actual — es un pendiente abierto, no una solución garantizada. Si te encuentras en este caso:
  - No asumas que el equipo quedó "arreglado" solo por haber aceptado el modo seguro; verifica el arranque real tras reiniciar.
  - Si necesitas recuperar acceso, entra por una TTY (consola de texto, sin arrancar Xorg) para revisar `dmesg | grep -i nouveau` y `cat /var/log/desktop-postinstall.log`, y confirmar si `/etc/modprobe.d/blacklist-nouveau.conf` realmente se aplicó y si el módulo sigue cargado (`lsmod | grep nouveau`).
  - Si el bloqueo del módulo no fue suficiente, puede que el cuelgue ocurra en una etapa aún más temprana que la cubierta por este script (por ejemplo, en el propio firmware/KMS antes de que OpenRC llegue a iniciar servicios) — este escenario requiere más diagnóstico específico por equipo y todavía no tiene una solución generalizada incorporada al script.
- **`unrar` no está disponible.** No hay alternativa vía `apk`; ver Bloque 15.
- **El microcódigo de AMD no se garantiza cargado en el arranque** solo con instalar el paquete; Alpine no lo integra automáticamente al initramfs.
- **El montaje de USB depende de `elogind` reconociendo la sesión como activa.** Si en algún momento el montaje pide contraseña de root inesperadamente, el problema casi seguro está en que la sesión gráfica no está siendo reconocida como activa por `elogind` — **no** es un problema de pertenencia a grupos Unix (`plugdev`/`storage`), que es el mecanismo de un backend distinto (`seatd`) que este script no usa.
- **El script asume que el entorno de escritorio ya fue instalado por separado** (vía `setup-desktop`). No instala XFCE, Plasma, GNOME, MATE ni LXQt desde cero.
- **Hardware NVIDIA legacy:** el modo seguro del Bloque 8 deshabilita la NVIDIA por completo (a nivel de kernel). Si más adelante necesitas usarla (por ejemplo, para decodificación de video), tendrás que revertir manualmente (ver siguiente sección).

## Solución de problemas

**El teclado sigue en inglés dentro de la sesión gráfica.** Algunos entornos (especialmente XFCE) cachean su propia configuración de teclado la primera vez que arrancan. Abre el panel de configuración de teclado del entorno una sola vez y confirma que "latam" ya aparece preseleccionado.

**Pantalla negra o cuelgue al iniciar Xorg con NVIDIA.** Si respondiste "no" a la pregunta del Bloque 8 y ahora tienes problemas, vuelve a correr el script y responde "sí" esta vez — o edita manualmente `/etc/modprobe.d/blacklist-nouveau.conf` (ver contenido en la [tabla de archivos](#archivos-que-el-script-crea-o-modifica)).

**Flatpak no se instaló / falló el `remote-add`.** Verifica que el repositorio `community` esté habilitado (`grep -v '^#' /etc/apk/repositories`) y que haya conexión a internet.

**El montaje automático de USB no funciona.** Confirma que `elogind` y `polkit` estén corriendo (`rc-service elogind status`, `rc-service polkit status`) y que hayas reiniciado después de correr el script (estos servicios necesitan estar activos desde el arranque, no basta con iniciarlos manualmente después).

## Cómo revertir cambios específicos

| Para revertir... | Hacer esto |
|---|---|
| Bloqueo de NVIDIA | Borrar `/etc/X11/xorg.conf.d/20-nouveau-safe.conf` y `/etc/modprobe.d/blacklist-nouveau.conf`, luego reiniciar |
| Idioma del sistema | Borrar `/etc/profile.d/lang-es.sh`, quitar las líneas `LANG`/`LC_*` de `/etc/environment`, y (si aplica) `/etc/xdg/plasma-localerc` y `$HOME/.config/plasma-localerc` |
| zram | `rc-service zram-init stop`, `rc-update del zram-init`, borrar `/etc/conf.d/zram-init` |
| EarlyOOM | `rc-update del earlyoom`, `apk del earlyoom earlyoom-openrc` |
| CUPS | `rc-update del cupsd`, `apk del cups cups-filters system-config-printer` |

---

*Este README documenta el script `desktop-postinstall.sh` tal como quedó tras las correcciones y adiciones acumuladas: distribución latam, detección multi-entorno (XFCE/Plasma/GNOME/MATE/LXQt), soporte de gráficos híbridos, protección NVIDIA legacy, zram, EarlyOOM, gestión de energía, montaje automático de USB, impresión, idioma español en tres capas, tipografías, LibreOffice y Flatpak.*
