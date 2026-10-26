import datetime
import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import urllib.parse
import urllib.request
import uuid

root = pathlib.Path(__file__).resolve().parents[1]
cache = root / ".build/bundle-downloads"
bundle = root / ".build/runtime-bundle"
cache.mkdir(parents=True, exist_ok=True)
bundle.mkdir(parents=True, exist_ok=True)

def digest(path):
    result = hashlib.sha256()
    with open(path, "rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            result.update(data)
    return result.hexdigest()

def download(url, name, checksum=None):
    path = cache / name
    if not path.exists():
        print("Downloading " + name, flush=True)
        temporary = path.with_suffix(path.suffix + ".partial")
        with urllib.request.urlopen(url, timeout=120) as response, open(temporary, "wb") as destination:
            shutil.copyfileobj(response, destination)
        temporary.replace(path)
    if checksum and digest(path) != checksum.removeprefix("sha256:"):
        raise RuntimeError("Checksum mismatch: " + name)
    return path

apple = download("https://github.com/apple/container/releases/download/1.6.0/container-1.6.0-installer-signed.pkg", "container-1.6.0.pkg",
                 "a084d66df2fb573172d7f923fa83c9229d17f6c1ab61f09c8a90c43dab66ba02")
signature = subprocess.check_output(["/usr/sbin/pkgutil", "--check-signature", str(apple)], text=True)
if "UPBK2H6LZM" not in signature:
    raise RuntimeError("The Apple installer has an unexpected signing identity")
expanded = cache / "apple-1.6.0-expanded"
if not expanded.exists():
    subprocess.run(["/usr/sbin/pkgutil", "--expand-full", str(apple), str(expanded)], check=True)
if (bundle / "AppleContainer").exists():
    shutil.rmtree(bundle / "AppleContainer")
shutil.copytree(expanded / "Payload", bundle / "AppleContainer")
for name in ["update-container.sh", "uninstall-container.sh"]:
    (bundle / "AppleContainer/bin" / name).unlink(missing_ok=True)

kernel_archive = download("https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst", "kata-3.32.0.tar.zst",
                          "8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5")
(bundle / "Boot").mkdir(exist_ok=True)
if not (bundle / "Boot/vmlinux").exists():
    decompressor = shutil.which("zstd")
    if not decompressor:
        raise RuntimeError("The developer build needs zstd to unpack the kernel. The distributed app does not need zstd.")
    process = subprocess.Popen([decompressor, "-dc", str(kernel_archive.resolve())], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
            for member in archive:
                if member.name.lstrip("./") == "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug":
                    with open(bundle / "Boot/vmlinux", "wb") as destination:
                        shutil.copyfileobj(archive.extractfile(member), destination)
                    break
            else:
                raise RuntimeError("Recommended kernel not found in archive")
    finally:
        process.stdout.close()
        process.wait()

(bundle / "Tools/cli-plugins").mkdir(parents=True, exist_ok=True)
docker = download("https://download.docker.com/mac/static/stable/aarch64/docker-29.9.2.tgz", "docker-29.9.2.tgz", "ea8a2ce5ac31f9f5f3fb711a7a485e1e46cc7a69798a629a70306f6e6af25b7a")
with tarfile.open(docker, "r:gz") as archive:
    with open(bundle / "Tools/docker", "wb") as destination:
        shutil.copyfileobj(archive.extractfile("docker/docker"), destination)
compose = download("https://github.com/docker/compose/releases/download/v5.5.1/docker-compose-darwin-aarch64", "docker-compose-5.5.1",
                   "998735c9b6fe68a4f05895e6ea73d71ad06f9fc7046383ad89e47346781b6af5")
shutil.copy2(compose, bundle / "Tools/cli-plugins/docker-compose")
for path in [bundle / "Tools/docker", bundle / "Tools/cli-plugins/docker-compose"]:
    path.chmod(0o755)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)], check=True)

image_pins = {}
expected_images = {
    "ghcr.io/apple/containerization/vminit:0.52.1": "sha256:fb07a2aa554e056347a6f18d286f73f3cd0e6840b1fc91a97b6006523d4f40a1",
    "ghcr.io/apple/container-builder-shim/builder:0.13.2": "sha256:027a6054cc9ef0bbf3d628cd709917c2e742783a83b35c53f9d5726637842251"
}

def bundle_image(repository, tag, filename):
    reference = "ghcr.io/" + repository + ":" + tag
    token_url = "https://ghcr.io/token?" + urllib.parse.urlencode({"service": "ghcr.io", "scope": "repository:" + repository + ":pull"})
    token = json.load(urllib.request.urlopen(token_url))["token"]
    headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json"}
    def fetch(kind, ref):
        return urllib.request.urlopen(urllib.request.Request("https://ghcr.io/v2/" + repository + "/" + kind + "/" + ref, headers=headers), timeout=120).read()
    manifest = fetch("manifests", tag)
    value = json.loads(manifest)
    if "manifests" in value:
        selected = next(x for x in value["manifests"] if x.get("platform", {}).get("os") == "linux" and x.get("platform", {}).get("architecture") == "arm64")
        manifest = fetch("manifests", selected["digest"])
        if "sha256:" + hashlib.sha256(manifest).hexdigest() != selected["digest"]:
            raise RuntimeError("Image manifest digest mismatch")
        value = json.loads(manifest)
    image_digest = "sha256:" + hashlib.sha256(manifest).hexdigest()
    if image_digest != expected_images[reference]:
        raise RuntimeError("Pinned image digest changed: " + reference)
    image_pins[reference] = image_digest
    image_dir = cache / filename.removesuffix(".tar")
    blobs = image_dir / "blobs/sha256"
    blobs.mkdir(parents=True, exist_ok=True)
    (blobs / image_digest.split(":")[1]).write_bytes(manifest)
    for descriptor in [value["config"], *value["layers"]]:
        checksum = descriptor["digest"].split(":")[1]
        blob = blobs / checksum
        if not blob.exists():
            print("Fetching " + reference + " " + checksum[:12], flush=True)
            blob.write_bytes(fetch("blobs", descriptor["digest"]))
        if digest(blob) != checksum:
            raise RuntimeError("Image layer checksum mismatch")
    (image_dir / "oci-layout").write_text('{"imageLayoutVersion":"1.0.0"}')
    (image_dir / "index.json").write_text(json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": value["mediaType"], "digest": image_digest, "size": len(manifest), "platform": {"os": "linux", "architecture": "arm64"}, "annotations": {"org.opencontainers.image.ref.name": reference}}]}))
    with tarfile.open(bundle / "Boot" / filename, "w") as archive:
        for path in sorted(image_dir.rglob("*")):
            if path.is_file():
                archive.add(path, arcname=str(path.relative_to(image_dir)), recursive=False)

bundle_image("apple/containerization/vminit", "0.52.1", "vminit.tar")
bundle_image("apple/container-builder-shim/builder", "0.13.2", "builder.tar")

(bundle / "Licenses").mkdir(exist_ok=True)
for project, revision, name, file in [
    ("apple/container", "1.6.0", "AppleContainer", "LICENSE"),
    ("apple/containerization", "0.52.1", "Containerization", "LICENSE"),
    ("docker/cli", "v29.9.2", "DockerCLI", "LICENSE"),
    ("facebook/zstd", "v1.5.7", "Zstd", "LICENSE"),
    ("docker/compose", "v5.5.1", "DockerCompose", "LICENSE"),
    ("kata-containers/kata-containers", "3.32.0", "Kata", "LICENSE")
]:
    source = download("https://raw.githubusercontent.com/" + project + "/" + revision + "/" + file, name + "-LICENSE")
    shutil.copy2(source, bundle / "Licenses" / (name + "-LICENSE"))

runtime = root / ".build/runtime/socktainer"
version = subprocess.check_output([str(runtime), "--version"], text=True)
if "1.2.1-acgui.15" not in version:
    raise RuntimeError("Rebuild Socktainer for Apple Container 1.6.0 before bundling")
shutil.copy2(runtime, bundle / "Tools/socktainer")
shutil.copy2(root / ".build/runtime/Socktainer-LICENSE", bundle / "Licenses/Socktainer-LICENSE")
shutil.copy2(root / "RuntimeSupport/DNS/MUSL-COPYRIGHT", bundle / "Licenses/Musl-COPYRIGHT")
identity = os.environ.get("APPLE_CONTAINER_GUI_SIGNING_IDENTITY", "Developer ID Application: Kevin Tobler (RYPSKH8HG5)")
if identity == "-":
    raise RuntimeError("The distribution runtime requires a Developer ID signing identity")
for relative in ["Tools/docker", "Tools/cli-plugins/docker-compose", "Tools/socktainer"]:
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp", str(bundle / relative)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(bundle / relative)], check=True)

for relative in ["Tools/docker", "Tools/cli-plugins/docker-compose", "Tools/socktainer"]:
    personal_path = str(pathlib.Path.home()).encode()
    with open(bundle / relative, "rb") as source:
        previous = b""
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            data = previous + chunk
            if personal_path in data:
                raise RuntimeError("Personal build path found in " + relative)
            previous = data[-len(personal_path):]

build_version = "2026.10.26-15." + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "." + uuid.uuid4().hex
manifest = {"schemaVersion": 1, "bundleVersion": build_version, "appleContainerVersion": "1.6.0", "socktainerVersion": "1.2.1-acgui.15", "dockerVersion": "29.9.2", "composeVersion": "5.5.1", "vminitImage": "ghcr.io/apple/containerization/vminit:0.52.1", "builderImage": "ghcr.io/apple/container-builder-shim/builder:0.13.2", "images": image_pins, "files": {}}
for path in sorted(bundle.rglob("*")):
    if path.is_file() and path.name != "manifest.json":
        manifest["files"][str(path.relative_to(bundle))] = digest(path)
(bundle / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Offline runtime bundle ready: " + str(bundle), flush=True)
