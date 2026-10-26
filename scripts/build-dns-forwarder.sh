set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
container_binary="${APPLE_CONTAINER_BINARY:-$project_dir/.build/runtime-bundle/AppleContainer/bin/container}"
"$container_binary" run --rm --name "acgui-dns-build-$$" --cpus 1 --memory 512m --volume "$project_dir/RuntimeSupport/DNS:/work" alpine:3.22 sh -c 'apk add --no-cache build-base >/dev/null && cc -O2 -static -pthread -o /work/dns-forwarder /work/forwarder.c'
python3 "$project_dir/scripts/build-dns-image.py"
