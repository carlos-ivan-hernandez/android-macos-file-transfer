#!/usr/bin/env bash
# Builds "dist/AM File Transfer.app". Pass --install to also copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

# libusb and libmtp, built for the app's minimum macOS version and linked into the app.
./scripts/build-libmtp.sh
if [[ ! -f .deps/include/libmtp.h || ! -f .deps/lib/libmtp.a ]]; then
  echo "libmtp wasn't built, so the app can't be built. See the errors above." >&2
  exit 1
fi

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"

app="dist/AM File Transfer.app"
binary="$app/Contents/MacOS/AMFileTransfer"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Support/Info.plist "$app/Contents/Info.plist"
cp "$bin_dir/AMFileTransfer" "$binary"

# The app's icon is Support/AppIcon.png, put on the macOS icon grid by the app itself.
"$binary" icon Support/AppIcon.png "$app/Contents/Resources/AppIcon.icns"

xattr -cr "$app"
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/AM File Transfer.app"
  cp -R "$app" /Applications/
  echo "Installed /Applications/AM File Transfer.app"
fi
