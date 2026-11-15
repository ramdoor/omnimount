#!/usr/bin/env python3
"""Exercise bundled filesystem engines and OmnimountKit on disposable files.

No sudo, hdiutil, /dev access, physical disks, or installed-app changes. Requires
FUSE-T, Swift, and built vendor tools. Full app/helper raw-device tests are separate.
"""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def main():
    if not __debug__:
        raise RuntimeError("Run without Python -O: validation assertions must stay enabled")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ntfs-bin", type=Path, help="Directory containing rebuilt NTFS tools")
    parser.add_argument("--ext-bin", type=Path, help="Directory containing rebuilt ext tools")
    parser.add_argument("--work-dir", type=Path, help="New empty directory (kept for inspection)")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    run = args.work_dir.resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix="omnimount-storage-"))
    if args.work_dir:
        run.mkdir(exist_ok=False, parents=True)
    vendor = repo / "vendor/bin"
    ntfs_bin = args.ntfs_bin.resolve() if args.ntfs_bin else vendor
    ext_bin = args.ext_bin.resolve() if args.ext_bin else vendor
    selected_tools = {
        **{name: ext_bin / name for name in ("fuse2fs", "mke2fs", "e2fsck", "tune2fs")},
        **{name: ntfs_bin / name for name in ("ntfs-3g", "mkntfs", "ntfsfix")},
    }
    tools_dir = run / "tools"
    tools_dir.mkdir()
    for name, path in selected_tools.items():
        if not path.is_file() or not os.access(path, os.X_OK):
            raise RuntimeError(f"Missing executable: {path}")
        (tools_dir / name).symlink_to(path.resolve())
    environment = os.environ.copy()
    environment["OMNIMOUNT_TOOL_DIR"] = str(tools_dir)
    results = []
    mounted = set()
    candidate_mounts = set()

    def command(label, argv, allowed=(0,), timeout=45):
        with (run / (label + ".log")).open("w") as log:
            process = subprocess.run([str(x) for x in argv], stdout=log, stderr=log,
                                     timeout=timeout, cwd=repo, env=environment)
        output = (run / (label + ".log")).read_text(errors="replace")
        if process.returncode not in allowed:
            raise RuntimeError(f"{label}: exit {process.returncode}: {output[-1800:]}")
        return output

    def record(name, **details):
        results.append(dict(check=name, passed=True, **details))
        print("PASS", name, flush=True)

    def mount(fs, image, name, readonly=False, extra=()):
        point = run / name
        point.mkdir(exist_ok=True)
        candidate_mounts.add(point)
        assert image.parent == run and image.is_file() and not image.is_symlink()
        opts = ["local", "volname=" + name]
        if fs == "ntfs":
            opts += ["windows_names", "big_writes"]
        if readonly:
            opts.append("ro")
        opts += list(extra)
        tool = ext_bin / "fuse2fs" if fs == "ext4" else ntfs_bin / "ntfs-3g"
        try:
            command(name, [tool, image, point, "-o", ",".join(opts)])
        finally:
            # Track mounts even when a backend exits nonzero or times out.
            if os.path.ismount(point):
                mounted.add(point)
        for _ in range(30):
            if os.path.ismount(point):
                mounted.add(point)
                return point
            time.sleep(0.1)
        raise RuntimeError(f"{name}: backend returned success but did not mount")

    def unmount(point):
        command(point.name + "-unmount", ["/usr/sbin/diskutil", "unmount", point])
        assert not os.path.ismount(point), "Volume still mounted"
        mounted.discard(point)

    binary = run / "image-kit"
    try:
        command("compile", ["swiftc", "-O", "-o", binary,
                            *sorted((repo / "Sources/OmnimountKit").glob("*.swift")),
                            repo / "Tests/StorageIntegration/main.swift"], timeout=120)
        record("compiled current OmnimountKit image harness")
        payload = {"empty.txt": b"", "espacios y ñ.txt": "Prueba Omnimount: áéíóú 日本語\n".encode(),
                   "binary.bin": bytes(range(256)) * (16384 + 3)}
        expected = {name: hashlib.sha256(data).hexdigest() for name, data in payload.items()}
        for fs in ("ext4", "ntfs"):
            image = run / (fs + ".img")
            with image.open("wb") as stream:
                stream.truncate(64 * 1024 * 1024)
            if fs == "ext4":
                command("ext4-format", [ext_bin / "mke2fs", "-q", "-F", "-t", "ext4",
                                        "-E", f"root_owner={os.getuid()}:{os.getgid()}",
                                        "-L", "OMTEST_EXT4", image])
                command("ext4-preflight", [binary, "preflight", image])
            else:
                command("ntfs-format", [ntfs_bin / "mkntfs", "-F", "-Q", "-L", "OMTEST_NTFS", image])
            detection = command(fs + "-detect", [binary, "detect", image]).strip()
            assert detection.startswith(fs), detection
            record(fs + " detection", result=detection)
            point = mount(fs, image, fs + "-rw")
            assert command(fs + "-probe-rw", [binary, "probe", point]).strip() == "writable"
            for name, data in payload.items():
                with (point / name).open("wb") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
            assert {name: digest(point / name) for name in payload} == expected
            unmount(point)
            record(fs + " read/write and clean unmount", files=len(payload))
            before_ro = digest(image)
            point = mount(fs, image, fs + "-ro", readonly=True)
            assert command(fs + "-probe-ro", [binary, "probe", point]).strip() == "read-only"
            assert {name: digest(point / name) for name in payload} == expected
            try:
                (point / "must-not-write").write_bytes(b"forbidden")
                raise AssertionError("Read-only volume accepted a write")
            except OSError as error:
                assert error.errno in (errno.EROFS, errno.EACCES, errno.EPERM), error
            unmount(point)
            assert digest(image) == before_ro, "Read-only mount changed the image"
            record(fs + " read-only denies writes and preserves image SHA-256")
            clone = run / (fs + "-clone.img")
            restored = run / (fs + "-restored.img")
            command(fs + "-clone", [binary, "copy", image, clone])
            command(fs + "-restore", [binary, "copy", clone, restored])
            original_hash = digest(image)
            assert original_hash == digest(clone) == digest(restored)
            record(fs + " clone/restore byte identity", bytes=image.stat().st_size, sha256=original_hash)
            point = mount(fs, restored, fs + "-restored-ro", readonly=True)
            assert {name: digest(point / name) for name in payload} == expected
            unmount(point)
            assert digest(restored) == original_hash, "Read-only restore validation changed image"
            record(fs + " restored filesystem mounts with original file hashes")
            check = [ext_bin / "e2fsck", "-f", "-n"] if fs == "ext4" else [ntfs_bin / "ntfsfix", "-n"]
            command(fs + "-verify", [*check, restored])
            record(fs + " offline filesystem check")

        hibernated = run / "ntfs-hibernated.img"
        shutil.copyfile(run / "ntfs.img", hibernated)
        point = mount("ntfs", hibernated, "ntfs-create-hibernation")
        (point / "hiberfil.sys").write_bytes(b"hibr" + bytes(4092))
        unmount(point)
        point = mount("ntfs", hibernated, "ntfs-hibernated-rw-request")
        assert command("ntfs-hibernated-probe", [binary, "probe", point]).strip() == "read-only"
        assert {name: digest(point / name) for name in payload} == expected
        unmount(point)
        record("NTFS synthetic hibernation falls back to read-only with files intact")
        command("ntfs-hibernation-preflight", [binary, "ntfs-preflight", hibernated])
        point = mount("ntfs", hibernated, "ntfs-remove-test-hibernation", extra=("remove_hiberfile",))
        assert command("ntfs-writable-again", [binary, "probe", point]).strip() == "writable"
        assert not (point / "hiberfil.sys").exists()
        assert {name: digest(point / name) for name in payload} == expected
        unmount(point)
        record("NTFS explicit writable recovery removes synthetic hibernation and preserves files")

        quota = run / "ext4-quota.img"
        shutil.copyfile(run / "ext4.img", quota)
        command("ext4-quota-enable", [ext_bin / "tune2fs", "-O", "quota,project", quota])
        command("ext4-quota-initialize", [ext_bin / "e2fsck", "-fy", quota], allowed=(0, 1))
        assert "quota=true" in command("ext4-quota-detect", [binary, "detect", quota])
        command("ext4-quota-repair", [binary, "repair-quota", quota])
        assert "quota=false" in command("ext4-quota-removed", [binary, "detect", quota])
        point = mount("ext4", quota, "ext4-after-quota")
        assert command("ext4-quota-probe", [binary, "probe", point]).strip() == "writable"
        assert {name: digest(point / name) for name in payload} == expected
        unmount(point)
        record("ext4 NAS quotas detected and explicit quota removal yields writable mount")

        debugfs = Path("/opt/homebrew/opt/e2fsprogs/sbin/debugfs")
        if debugfs.exists():
            dirty = run / "ext4-needs-recovery.img"
            shutil.copyfile(run / "ext4.img", dirty)
            command("ext4-mark-needs-recovery", [debugfs, "-w", "-R", "feature needs_recovery", dirty])
            def needs_recovery(path):
                with path.open("rb") as stream:
                    stream.seek(1024 + 96)
                    return bool(struct.unpack("<I", stream.read(4))[0] & 4)
            assert needs_recovery(dirty), "Failed to set journal recovery flag"
            dirty_hash = digest(dirty)
            point = mount("ext4", dirty, "ext4-dirty-readonly", readonly=True)
            assert {name: digest(point / name) for name in payload} == expected
            unmount(point)
            assert needs_recovery(dirty), "Read-only mount replayed the journal"
            assert digest(dirty) == dirty_hash, "Read-only dirty mount changed image bytes"
            record("ext4 read-only dirty mount preserves recovery flag and image SHA-256")
            command("ext4-journal-preflight", [binary, "preflight", dirty])
            assert not needs_recovery(dirty), "Preflight failed to clear journal recovery flag"
            command("ext4-journal-check", [ext_bin / "e2fsck", "-f", "-n", dirty])
            point = mount("ext4", dirty, "ext4-after-recovery", readonly=True)
            assert {name: digest(point / name) for name in payload} == expected
            unmount(point)
            record("ext4 marked for journal recovery passes preflight and retains files")
        else:
            results.append(dict(check="ext4 journal recovery flag", skipped=True,
                                reason="debugfs is not installed"))
        # This negative test needs no debugfs and must run in every environment.
        broken = run / "ext4-corrupt.img"
        shutil.copyfile(run / "ext4.img", broken)
        with broken.open("r+b") as stream:
            stream.seek(1024 + 56)
            stream.write(b"\x00\x00")
        command("ext4-corrupt-preflight", [binary, "preflight", broken], allowed=(2,))
        record("ext4 damaged superblock rejected by mount preflight")
    except Exception as error:
        results.append(dict(check="suite", passed=False, error=str(error)))
        raise
    finally:
        # FUSE-T can finish a daemonized mount after the client already exited.
        time.sleep(1)
        for point in sorted(candidate_mounts):
            if not os.path.ismount(point):
                mounted.discard(point)
                continue
            try:
                unmount(point)
            except Exception as error:
                results.append(dict(check="cleanup", passed=False, mount=str(point), error=str(error)))
        (run / "results.json").write_text(json.dumps(dict(
            work_dir=str(run), scope="regular-file engines and current OmnimountKit; no raw devices or helper",
            engines={name: dict(path=str(path), sha256=digest(path))
                     for name, path in selected_tools.items()},
            checks=results, remaining_mounts=[str(p) for p in candidate_mounts if os.path.ismount(p)]), indent=2))
        print("Results:", run / "results.json", flush=True)
        if any(os.path.ismount(p) for p in candidate_mounts):
            raise RuntimeError("Test mount remains active; inspect results.json before deleting images")


if __name__ == "__main__":
    main()
