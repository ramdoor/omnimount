# Omnimount

**Read/write access** to filesystems macOS doesn't support natively —
**ext2/ext3/ext4** and **NTFS** — from a SwiftUI menu bar app and a CLI.
Omnimount implements no drivers: it **wraps existing open source tools**
([fuse2fs] from e2fsprogs and [ntfs-3g]) over a FUSE layer ([FUSE-T] by
default, kext-free; [macFUSE] as an alternative).

Built especially for retro-console SD cards (ArkOS, Batocera, ROCKNIX,
muOS…), which mix FAT partitions with ext4 partitions invisible to macOS.

🌍 [Versión en español](README.es.md) · 🛒 [Buy the ready-made build](https://omnimount.es)

- **Requirements**: macOS 13+, Apple Silicon (Intel should work, untested).
- **License**: GPL-3.0-or-later (fuse2fs and ntfs-3g are GPL).

[fuse2fs]: https://github.com/tytso/e2fsprogs
[ntfs-3g]: https://github.com/tuxera/ntfs-3g
[macFUSE]: https://macfuse.github.io
[FUSE-T]: https://www.fuse-t.org

## Components

| Component | What it is |
|---|---|
| `omnimount` (CLI) | Lists disks, detects filesystems by magic bytes, mounts/unmounts, formats, clones |
| `Omnimount.app` | Menu bar app: live disk detection (DiskArbitration), mount/eject/format, reveal in Finder |
| `OmnimountHelper` | Privileged daemon (SMAppService + XPC): password-free operations |
| `OmnimountKit` | Shared Swift library |

## Installation

### 1. FUSE layer

**Recommended — FUSE-T (no kext, no Recovery, no reboots):**

```sh
brew install --cask macos-fuse-t/cask/fuse-t
```

Trade-off: it's closed source (free of charge) and volumes mount as local
NFS. Decisive advantage: zero install friction.

**Fully open source alternative — macFUSE (kext):**

```sh
brew install --cask macfuse
```

macFUSE uses a kernel extension, which macOS blocks by default:

1. **Apple Silicon only** (mandatory; without this the "Allow" button in
   step 2 never appears): shut the Mac down completely, hold the power
   button until "Loading startup options" → **Options** → menu
   **Utilities → Startup Security Utility** → select your disk →
   **Security Policy… → Reduced Security** + check
   **Allow user management of kernel extensions from identified
   developers**. Reboot.
   (Check the state with `sudo bputil -d`: it must say
   "3rd Party Kexts Status: Enabled".)
2. Back in macOS, go to **System Settings → Privacy & Security**: scroll to
   the notice about system software from "Benjamin Fleischer" — click
   **Allow**.
3. Reboot when prompted.

⚠️ **FUSE-T and macFUSE don't coexist well**: the FUSE-T installer
overwrites macFUSE's libraries in `/usr/local/lib`. Pick one backend per
system (or reinstall macFUSE to go back to it).

### 2. Filesystem tools

Build them from source against your FUSE layer (Homebrew is NOT needed —
its e2fsprogs bottle lacks fuse2fs and its ntfs-3g links macFUSE):

```sh
make fuse2fs    # fuse2fs + static e2fsck, mke2fs, tune2fs (FUSE-T by default)
make ntfs3g     # ntfs-3g + mkntfs + ntfsfix, built against FUSE-T
BACKEND=macfuse make fuse2fs    # fuse2fs against macFUSE instead
```

Everything lands in `vendor/bin/` and gets bundled into the app by
`make install`. (The [paid build](https://omnimount.es) ships all of this
pre-built, signed and notarized.)

### 3. Omnimount

```sh
make install    # CLI at /opt/homebrew/bin/omnimount + app in /Applications
```

Check the state of everything:

```sh
omnimount doctor
```

### 4. Permissions (one-time)

Accessing `/dev/diskXsY` requires **two** distinct permissions:

1. **root** — device nodes belong to `root:operator`, mode 640.
2. **Full Disk Access (TCC)** — since macOS Catalina, opening raw devices
   returns `Operation not permitted` *even as root* unless the responsible
   app has Full Disk Access.

Recommended setup (app + helper, no password prompts):

1. Open Omnimount.app → click **"Activate helper"** → approve the
   background item in **Settings → General → Login Items**.
2. In **Settings → Privacy & Security → Full Disk Access**, add
   `/Applications/Omnimount.app/Contents/MacOS/OmnimountHelper` with **+**
   (Cmd+Shift+G to type the path).

To use the CLI with sudo, grant Full Disk Access to your terminal and to
the `omnimount` binary as well.

⚠️ **Developer note**: TCC binds the permission to the binary's code
signature. Build with a stable identity (the Makefile picks your first
development identity) or you'll have to re-grant after every build.

## CLI usage

```sh
omnimount list                  # external disks + detected filesystems
sudo omnimount detect disk4s2   # magic bytes (--verbose dumps the boot sector)
sudo omnimount mount disk4s2    # mounts with the right backend
omnimount unmount disk4s2       # clean unmount
sudo omnimount test disk4s2     # mount + write test + unmount + fsck

sudo omnimount clone disk4 backup.img        # clone whole disk (or partition)
sudo omnimount restore backup.img disk4      # restore (asks for confirmation)
sudo omnimount unhide disk4s3                # clear the "hidden" flag (FAT 0x1C, ArkOS)
sudo omnimount format disk4s3 ext4 --label EASYROMS   # format (strict confirmation)
```

Restore copies the image byte for byte; it does not resize its filesystem or
partition layout. A larger destination does not automatically become a larger
volume. For NTFS, a partition larger than the original image can also cause
`ntfsfix` to report a misplaced backup boot sector. Use matching partition sizes
for an exact restore; filesystem resizing is a separate operation.

Magic-byte detection:

- **ext2/3/4** — superblock at offset 1024, magic `0xEF53`; feature flags
  distinguish ext2/ext3/ext4 and the volume label is read too.
- **NTFS** — OEM ID `NTFS    ` at offset 3 of the boot sector.
- Also recognizes exFAT, FAT, Btrfs and Linux swap (without mounting them).

## Menu bar app

- Lists external disks live (DiskArbitration); mount/eject/reveal in Finder
  per partition.
- **Helper active** → every operation without a password dialog
  (SMAppService + XPC; the helper verifies the client's code signature).
  Without the helper, the app falls back to the macOS admin dialog.
- **Format** from each partition's "⋯" menu: a sheet with warnings and
  two-step confirmation (ext2/3/4, NTFS, FAT32, exFAT; also updates the MBR
  type byte).
- 🎮 notice when the inserted card looks like a retro console's
  (ArkOS/EASYROMS, Batocera, ROCKNIX, muOS, RetroPie, Recalbox…).

## Development

```sh
make build      # builds (scratch path at ~/.omnimount-build)
make test       # unit tests: detection, copying, mount preflight, command execution
make app        # signed dist/Omnimount.app
```

### Filesystem image tests

With macOS, Python 3, `swiftc`, FUSE-T and the filesystem tools from step 2
installed or built, run:

```sh
python3 scripts/test-storage-images.py
```

The runner compiles the current `OmnimountKit` with a small test harness and
uses `vendor/bin/` by default. Use `--ext-bin /path/to/ext-tools` and
`--ntfs-bin /path/to/ntfs-tools` to test alternative builds. An optional
`--work-dir /tmp/omnimount-storage-check` selects a directory that must not
already exist; otherwise a temporary directory is created automatically.
The directory is kept with images, per-command logs and `results.json`.

Tests use 64 MiB regular-file images: ext4/NTFS read/write and read-only
mounts, file hashes, image SHA-256 preservation in read-only mode,
clone/restore byte identity, remounting restored images, offline checks,
synthetic NTFS hibernation and ext4 quota removal. The journal-recovery
fixture additionally uses `/opt/homebrew/opt/e2fsprogs/sbin/debugfs` when
available. Check `results.json` for skipped checks and any remaining mounts
before removing the test directory.

This exercises the filesystem engines and the current kit's detection,
copy and preflight code. It does not run the app/helper or raw-device
clone/restore entry points, use `sudo`, access physical disks or change the
installed app. Passing on Apple Silicon does not validate physical Intel
hardware, a particular customer's disk or a large-disk failure.

Layout:

```
Sources/OmnimountKit/     DiskLister, FilesystemDetector, Mounter, Cloner,
                          Formatter, RetroCards, ToolLocator, HelperProtocol
Sources/OmnimountCLI/     list, detect, mount, unmount, test, clone, restore,
                          unhide, format, doctor
Sources/OmnimountApp/     NSStatusItem/NSPopover + SwiftUI + DiskArbitration + XPC client
Sources/OmnimountHelper/  privileged daemon (SMAppService)
scripts/build-fuse2fs.sh  builds fuse2fs (BACKEND=fuse-t|macfuse)
```

Don't build inside synced folders (OneDrive/Dropbox/iCloud): the scripts
use `--scratch-path` outside the repo for that reason.

## Known limitations

- ext4 volumes with the `casefold` feature, used on some Steam Deck cards,
  are not supported by fuse2fs. A clean e2fsck result does not remove that limit.
- Before cloning or restoring a disk with a FUSE-T volume mounted, eject that
  volume from Omnimount. FUSE-T mount names do not uniquely identify the source
  device; cloning/restoration stops when the association cannot be verified.
- Volumes mounted by the helper/root don't show in the Finder sidebar
  (DiskArbitration doesn't publish them into the user session). The volume
  works normally at `/Volumes/<name>`; drag it to Favorites once if you
  want it handy.
- NTFS over FUSE-T is validated on regular-file images with ntfs-3g built
  against FUSE-T, including read/write, read-only and explicit recovery from
  synthetic hibernation. Use the build script above; Homebrew's ntfs-3g-mac
  links against macFUSE's libraries.
- The app bundles filesystem executables from `vendor/bin/` when built with
  `make app` or `make install`; the paid build includes them pre-built.
  The FUSE layer itself is installed separately: FUSE-T through Setup or
  Homebrew, or macFUSE with its required system permissions.
- Verification fsck is non-destructive (`e2fsck -fn`, `ntfsfix -n`): it
  reports, it doesn't repair.
