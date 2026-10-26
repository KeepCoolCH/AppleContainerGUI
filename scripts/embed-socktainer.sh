set -eu
runtime_dir="$SRCROOT/.build/runtime-bundle"
helper_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"
rm -rf "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/RuntimePayload"
if [ ! -f "$runtime_dir/manifest.json" ]; then
    printf '%s\n' 'error: Prepare all bundled components first: python3 scripts/bundle-runtime.py' >&2
    exit 1
fi
mkdir -p "$helper_dir"
rm -rf "$helper_dir/RuntimePayload"
/usr/bin/python3 "$SRCROOT/scripts/package-runtime.py" "$runtime_dir" "$helper_dir/RuntimePayload"
rm -f "$helper_dir/socktainer" "$helper_dir/Socktainer-LICENSE"
