# Omnimount

Acceso de **lectura y escritura** a sistemas de ficheros que macOS no soporta
de forma nativa — **ext2/ext3/ext4** y **NTFS** — desde una app de barra de
menú en SwiftUI y un CLI. Omnimount no implementa drivers: **envuelve
herramientas open source ya existentes** ([fuse2fs] de e2fsprogs y [ntfs-3g])
sobre una capa FUSE ([FUSE-T] por defecto, sin kext; [macFUSE] como
alternativa).

Pensado especialmente para tarjetas SD de consolas retro (ArkOS, Batocera,
ROCKNIX, muOS…), que mezclan particiones FAT con particiones ext4 invisibles
para macOS.

- **Requisitos**: macOS 13+, Apple Silicon (Intel debería funcionar, no probado).
- **Licencia**: GPL-3.0-or-later (fuse2fs y ntfs-3g son GPL).

[fuse2fs]: https://github.com/tytso/e2fsprogs
[ntfs-3g]: https://github.com/tuxera/ntfs-3g
[macFUSE]: https://macfuse.github.io
[FUSE-T]: https://www.fuse-t.org

## Componentes

| Componente | Qué es |
|---|---|
| `omnimount` (CLI) | Lista discos, detecta el FS por magic bytes, monta/desmonta, formatea, clona |
| `Omnimount.app` | App de barra de menú: detección de discos al vuelo (DiskArbitration), montar/expulsar/formatear, abre en Finder |
| `OmnimountHelper` | Daemon privilegiado (SMAppService + XPC): operaciones sin pedir contraseña |
| `OmnimountKit` | Librería Swift compartida |

## Instalación

### 1. Capa FUSE

**Opción recomendada — FUSE-T (sin kext, sin Recovery, sin reinicios):**

```sh
brew install --cask macos-fuse-t/cask/fuse-t
```

Contras: es de código cerrado (gratuito) y los volúmenes se montan como NFS
local. Ventaja decisiva: cero fricción de instalación.

**Opción 100 % open source — macFUSE (kext):**

```sh
brew install --cask macfuse
```

macFUSE usa una extensión del kernel, que macOS bloquea por defecto:

1. **Solo Apple Silicon** (imprescindible; sin este paso el botón "Permitir"
   del paso 2 ni siquiera aparece): apaga el Mac del todo, mantén pulsado el
   botón de encendido hasta ver "Cargando opciones de arranque" → **Opciones**
   → menú **Utilidades → Utilidad de Seguridad de Arranque** → selecciona tu
   disco → **Política de seguridad… → Seguridad reducida** + marca
   **Permitir la gestión de usuario de extensiones de kernel de
   desarrolladores identificados**. Reinicia.
   (Comprueba el estado con `sudo bputil -d`: debe decir
   "3rd Party Kexts Status: Enabled".)
2. Ya en macOS, ve a **Ajustes del Sistema → Privacidad y seguridad**: baja
   hasta el aviso sobre software de sistema de "Benjamin Fleischer" — pulsa
   **Permitir**.
3. Reinicia cuando lo pida.

⚠️ **FUSE-T y macFUSE no conviven bien**: el instalador de FUSE-T sobrescribe
las librerías de macFUSE en `/usr/local/lib`. Elige un backend por sistema
(o reinstala macFUSE si quieres volver a él).

### 2. Herramientas de sistemas de ficheros

```sh
# e2fsprogs: aporta e2fsck, mkfs.ext4, etc. (¡pero NO fuse2fs, ver abajo!)
brew install e2fsprogs

# ntfs-3g: montaje NTFS lectura/escritura + mkntfs (tap gromgit/fuse)
brew install gromgit/fuse/ntfs-3g-mac
```

**fuse2fs hay que compilarlo**: el bottle de Homebrew de e2fsprogs no lo
incluye porque necesita cabeceras FUSE al compilar. Con la capa FUSE ya
instalada:

```sh
make fuse2fs                    # compila contra FUSE-T (por defecto)
BACKEND=macfuse make fuse2fs    # o contra macFUSE
```

### 3. Omnimount

```sh
make install    # CLI en /opt/homebrew/bin/omnimount + app en /Applications
```

Verifica el estado de todo:

```sh
omnimount doctor
```

### 4. Permisos (una sola vez)

Acceder a `/dev/diskXsY` exige **dos** permisos distintos:

1. **root** — los nodos pertenecen a `root:operator` con modo 640.
2. **Acceso total al disco (TCC)** — desde macOS Catalina, abrir dispositivos
   en bruto devuelve `Operation not permitted` *incluso siendo root* si la app
   responsable no tiene Acceso total al disco.

Configuración recomendada (app + helper, sin contraseñas):

1. Abre Omnimount.app → pulsa **"Activar helper"** → aprueba el elemento de
   fondo en **Ajustes → General → Elementos de inicio**.
2. En **Ajustes → Privacidad y seguridad → Acceso total al disco**, añade con
   **+** el binario `/Applications/Omnimount.app/Contents/MacOS/OmnimountHelper`
   (Cmd+Mayús+G para escribir la ruta).

Para usar el CLI con sudo, concede Acceso total al disco también a tu
terminal y a `/opt/homebrew/bin/omnimount`.

⚠️ **Nota para desarrolladores**: TCC liga el permiso a la firma del binario.
Compila con una identidad estable (el Makefile usa tu primera identidad de
desarrollo) o tendrás que renovar el permiso tras cada build.

## Uso del CLI

```sh
omnimount list                  # discos externos + FS detectado
sudo omnimount detect disk4s2   # magic bytes (--verbose vuelca el boot sector)
sudo omnimount mount disk4s2    # monta con el backend adecuado
omnimount unmount disk4s2       # desmontaje limpio
sudo omnimount test disk4s2     # monta + prueba de escritura + desmonta + fsck

sudo omnimount clone disk4 backup.img        # clona disco entero (o partición)
sudo omnimount restore backup.img disk4      # restaura (pide confirmación)
sudo omnimount unhide disk4s3                # quita el flag "oculta" (FAT 0x1C, ArkOS)
sudo omnimount format disk4s3 ext4 --label EASYROMS   # formatea (confirmación estricta)
```

Detección por magic bytes:

- **ext2/3/4** — superbloque en offset 1024, magic `0xEF53`; las feature flags
  distinguen ext2/ext3/ext4 y se lee la etiqueta del volumen.
- **NTFS** — OEM ID `NTFS    ` en el offset 3 del boot sector.
- También reconoce exFAT, FAT, Btrfs y Linux swap (sin montarlos).

## App de barra de menú

- Lista discos externos al vuelo (DiskArbitration); montar/expulsar/abrir en
  Finder por partición.
- **Helper activo** → todas las operaciones sin diálogo de contraseña
  (SMAppService + XPC; el helper verifica la firma del cliente). Sin helper,
  la app recurre al diálogo de administrador de macOS.
- **Formatear** desde el menú "⋯" de cada partición: hoja con avisos y
  confirmación en dos pasos (ext2/3/4, NTFS, FAT32, exFAT; ajusta el tipo MBR).
- Aviso 🎮 cuando la tarjeta parece de una consola retro (ArkOS/EASYROMS,
  Batocera, ROCKNIX, muOS, RetroPie, Recalbox…).

## Desarrollo

```sh
make build      # compila (scratch path en ~/.omnimount-build)
make test       # tests del detector con imágenes sintéticas
make app        # dist/Omnimount.app firmada
```

Estructura:

```
Sources/OmnimountKit/     DiskLister, FilesystemDetector, Mounter, Cloner,
                          Formatter, RetroCards, ToolLocator, HelperProtocol
Sources/OmnimountCLI/     list, detect, mount, unmount, test, clone, restore,
                          unhide, format, doctor
Sources/OmnimountApp/     MenuBarExtra + DiskArbitration + cliente XPC
Sources/OmnimountHelper/  daemon privilegiado (SMAppService)
scripts/build-fuse2fs.sh  compila fuse2fs (BACKEND=fuse-t|macfuse)
```

No compiles dentro de carpetas sincronizadas (OneDrive/Dropbox/iCloud): los
scripts usan `--scratch-path` fuera del repo por ese motivo.

## Limitaciones conocidas

- Los volúmenes montados por el helper/root no aparecen en la barra lateral
  del Finder (DiskArbitration no los publica en la sesión del usuario). El
  volumen funciona con normalidad en `/Volumes/<nombre>`; arrástralo una vez
  a Favoritos si lo quieres a mano.
- NTFS con backend FUSE-T está pendiente de validación (ntfs-3g de Homebrew
  enlaza contra las librerías de macFUSE).
- Los binarios FUSE no se empaquetan con la app: deben estar instalados.
- fsck de verificación es no-destructivo (`e2fsck -fn`, `ntfsfix -n`): informa,
  no repara.
