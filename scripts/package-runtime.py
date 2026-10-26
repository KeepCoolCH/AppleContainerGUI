import hashlib
import json
import pathlib
import stat
import sys
import zipfile

source = pathlib.Path(sys.argv[1]).resolve()
destination = pathlib.Path(sys.argv[2])
manifest_bytes = (source / "manifest.json").read_bytes()
manifest = json.loads(manifest_bytes)
destination.mkdir(parents=True, exist_ok=True)
archive = destination / "runtime.zip"
try:
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as package:
        package.writestr("manifest.json", manifest_bytes)
        for relative, expected in sorted(manifest["files"].items()):
            path = pathlib.PurePosixPath(relative)
            if path.is_absolute() or ".." in path.parts or not path.parts:
                raise RuntimeError("Invalid runtime path: " + relative)
            original = source / relative
            if original.is_symlink() or not original.is_file() or not original.resolve().is_relative_to(source):
                raise RuntimeError("Invalid runtime file: " + relative)
            details = original.stat()
            entry = zipfile.ZipInfo(relative)
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | stat.S_IMODE(details.st_mode)) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            digest = hashlib.sha256()
            with original.open("rb") as incoming, package.open(entry, "w", force_zip64=True) as outgoing:
                for block in iter(lambda: incoming.read(1024 * 1024), b""):
                    digest.update(block)
                    outgoing.write(block)
            if digest.hexdigest() != expected:
                raise RuntimeError("Runtime checksum mismatch before packaging: " + relative)
    digest = hashlib.sha256()
    with archive.open("rb") as incoming:
        for block in iter(lambda: incoming.read(1024 * 1024), b""):
            digest.update(block)
    (destination / "manifest.json").write_bytes(manifest_bytes)
    (destination / "archive.sha256").write_text(digest.hexdigest() + "\n")
except BaseException:
    archive.unlink(missing_ok=True)
    raise
print("Packaged runtime archive with verified file checksums")
