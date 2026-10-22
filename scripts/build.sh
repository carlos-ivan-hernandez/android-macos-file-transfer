#!/usr/bin/env bash
# Builds "dist/PhoneFiles.app". Pass --install to also copy it into /Applications.
# Needs libmtp from Homebrew: brew install libmtp pkg-config
set -euo pipefail
cd "$(dirname "$0")/.."

if ! pkg-config --exists libmtp 2>/dev/null; then
  echo "libmtp isn't installed. Install it with: brew install libmtp pkg-config" >&2
  exit 1
fi

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"

app="dist/PhoneFiles.app"
frameworks="$app/Contents/Frameworks"
binary="$app/Contents/MacOS/PhoneFiles"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$frameworks"
cp Support/Info.plist "$app/Contents/Info.plist"
cp "$bin_dir/PhoneFiles" "$binary"

# Copy libmtp and the Homebrew libraries it needs (libusb) into the app, so the app
# keeps working after Homebrew updates and runs on Macs without Homebrew.
bundle_libraries() {
  local file="$1" dep name
  for dep in $(otool -L "$file" | tail -n +2 | awk '{print $1}'); do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*) ;;
      *) continue ;;
    esac
    name="$(basename "$dep")"
    if [[ ! -f "$frameworks/$name" ]]; then
      cp "$dep" "$frameworks/$name"
      chmod u+w "$frameworks/$name"
      install_name_tool -id "@rpath/$name" "$frameworks/$name"
      bundle_libraries "$frameworks/$name"
    fi
    install_name_tool -change "$dep" "@rpath/$name" "$file"
  done
}
bundle_libraries "$binary"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true

xattr -cr "$app"
for library in "$frameworks"/*.dylib; do
  [[ -e "$library" ]] && codesign --force --sign - "$library"
done
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/PhoneFiles.app"
  cp -R "$app" /Applications/
  echo "Installed /Applications/PhoneFiles.app"
fi
