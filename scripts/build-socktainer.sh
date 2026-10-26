set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checkout="${SOCKTAINER_BUILD_DIRECTORY:-$project_dir/.build/socktainer-source-160}"
revision=cdadd189bf6899cb363a18489e31d36e204fd0dd
if [ ! -d "$checkout/.git" ]; then
    mkdir -p "$checkout"
    git -C "$checkout" init
    git -C "$checkout" remote add origin https://github.com/socktainer/socktainer.git
    git -C "$checkout" fetch --depth 1 origin "$revision"
    git -C "$checkout" checkout --detach FETCH_HEAD
fi
/usr/bin/python3 "$project_dir/scripts/prepare-socktainer.py" "$checkout"
export BUILD_VERSION=1.2.1-acgui.15
export BUILD_GIT_COMMIT="$revision"
cd "$checkout"
swift build -c release \
    -Xswiftc -file-prefix-map -Xswiftc "$project_dir=/source/AppleContainerGUI" \
    -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=/source/AppleContainerGUI" \
    -Xcc "-ffile-prefix-map=$project_dir=/source/AppleContainerGUI" \
    -Xcc "-fdebug-prefix-map=$project_dir=/source/AppleContainerGUI"
mkdir -p "$project_dir/.build/runtime"
cp .build/release/socktainer "$project_dir/.build/runtime/socktainer"
/usr/bin/strip -S "$project_dir/.build/runtime/socktainer"
codesign --force --sign - --entitlements entitlements.plist "$project_dir/.build/runtime/socktainer"
cp LICENSE "$project_dir/.build/runtime/Socktainer-LICENSE"
printf '%s\n' "Runtime built: $project_dir/.build/runtime/socktainer"
