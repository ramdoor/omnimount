# Omnimount

**Read/write access** to filesystems macOS doesn't support natively —
**ext2/ext3/ext4** and **NTFS** — from a SwiftUI menu bar app and a CLI.
Omnimount implements no drivers: it **wraps existing open source tools**
([fuse2fs] from e2fsprogs and [ntfs-3g]) over a FUSE layer ([FUSE-T] by
default, kext-free; [macFUSE] as an alternative).

Built especially for retro-console SD cards (ArkOS, Batocera, ROCKNIX,
muOS…), which mix FAT partitions with ext4 partitions invisible to macOS.

🌍 [Versión en español](README.es.md) · 🛒 [Buy the ready-made build](https://omnimount.toucedo.com)

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

```sh
# e2fsprogs: provides e2fsck, mkfs.ext4, etc. (but NOT fuse2fs, see below!)
brew install e2fsprogs

# ntfs-3g: read/write NTFS mounting + mkntfs (gromgit/fuse tap)
brew install gromgit/fuse/ntfs-3g-mac
```

**fuse2fs must be compiled**: the Homebrew bottle of e2fsprogs doesn't
include it because it needs FUSE headers at build time. With the FUSE layer
installed:

```sh
make fuse2fs                    # builds against FUSE-T (default)
BACKEND=macfuse make fuse2fs    # or against macFUSE
```

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
make test       # detector tests with synthetic images
make app        # signed dist/Omnimount.app
```

Layout:

```
Sources/OmnimountKit/     DiskLister, FilesystemDetector, Mounter, Cloner,
                          Formatter, RetroCards, ToolLocator, HelperProtocol
Sources/OmnimountCLI/     list, detect, mount, unmount, test, clone, restore,
                          unhide, format, doctor
Sources/OmnimountApp/     MenuBarExtra + DiskArbitration + XPC client
Sources/OmnimountHelper/  privileged daemon (SMAppService)
scripts/build-fuse2fs.sh  builds fuse2fs (BACKEND=fuse-t|macfuse)
```

Don't build inside synced folders (OneDrive/Dropbox/iCloud): the scripts
use `--scratch-path` outside the repo for that reason.

## Known limitations

- Volumes mounted by the helper/root don't show in the Finder sidebar
  (DiskArbitration doesn't publish them into the user session). The volume
  works normally at `/Volumes/<name>`; drag it to Favorites once if you
  want it handy.
- NTFS over the FUSE-T backend is pending validation (Homebrew's ntfs-3g
  links against macFUSE's libraries).
- FUSE binaries aren't bundled with the open source build: they must be
  installed. (The [paid build](https://omnimount.toucedo.com) bundles
  everything.)
- Verification fsck is non-destructive (`e2fsck -fn`, `ntfsfix -n`): it
  reports, it doesn't repair.
