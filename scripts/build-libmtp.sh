#!/usr/bin/env bash
# Builds libusb and libmtp from source as static libraries in .deps/, for the app's minimum
# macOS version, so they're linked into the app itself. (Homebrew's copies are built for the
# macOS version they were installed on, so an app linked with them only runs on that version
# or later.) Does nothing if .deps/ is already up to date.
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_MACOS="13.0"  # keep in step with `platforms` in Package.swift
LIBUSB_VERSION="1.0.27"
LIBUSB_SHA256="ffaa41d741a8a3bee244ac8e54a72ea05bf2879663c098c82fc5757853441575"
LIBMTP_VERSION="1.1.21"
LIBMTP_SHA256="f4c1ceb3df020a6cb851110f620c14fe399518c494ed252039cbfb4e34335135"

prefix="$PWD/.deps"
stamp="libusb-$LIBUSB_VERSION libmtp-$LIBMTP_VERSION macos-$MIN_MACOS"
if [[ -f "$prefix/lib/libmtp.a" && -f "$prefix/include/libmtp.h" && "$(cat "$prefix/stamp" 2>/dev/null)" == "$stamp" ]]; then
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rm -rf "$prefix"
jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

usb_extra_libs=""
configure_flags=(--prefix="$prefix" --disable-shared --enable-static)
if [[ "$(uname)" == "Darwin" ]]; then
  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  export CFLAGS="-O2 -mmacosx-version-min=$MIN_MACOS"
  export LDFLAGS="-mmacosx-version-min=$MIN_MACOS"
  usb_extra_libs="-lobjc -framework IOKit -framework CoreFoundation -framework Security"
else
  # Only used to check the build on Linux; the app itself is macOS-only.
  export CFLAGS="-O2 -fPIC"
fi

# Runs a build step quietly. libusb's and libmtp's own compiler warnings go to a log, which is
# shown only if the step fails.
log="$work/build.log"
quiet() {
  if ! "$@" >>"$log" 2>&1; then
    tail -n 40 "$log" >&2
    echo "Building the libraries failed." >&2
    exit 1
  fi
}

# Downloads a file and checks it against its known SHA-256.
fetch() {
  local url="$1" sha="$2" file="$work/$(basename "$1")"
  echo "Downloading $(basename "$url")…" >&2
  curl -fsSL "$url" -o "$file"
  if command -v shasum >/dev/null; then
    echo "$sha  $file" | shasum -a 256 -c - >/dev/null
  else
    echo "$sha  $file" | sha256sum -c - >/dev/null
  fi
  echo "$file"
}

archive="$(fetch "https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2" "$LIBUSB_SHA256")"
tar xjf "$archive" -C "$work"
echo "Building libusb $LIBUSB_VERSION…"
(
  cd "$work/libusb-$LIBUSB_VERSION"
  usb_flags=()
  [[ "$(uname)" == "Darwin" ]] || usb_flags=(--disable-udev)
  quiet ./configure "${configure_flags[@]}" ${usb_flags[@]+"${usb_flags[@]}"}
  quiet make -j"$jobs"
  quiet make install
)

archive="$(fetch "https://github.com/libmtp/libmtp/releases/download/v$LIBMTP_VERSION/libmtp-$LIBMTP_VERSION.tar.gz" "$LIBMTP_SHA256")"
tar xzf "$archive" -C "$work"
echo "Building libmtp $LIBMTP_VERSION…"
(
  cd "$work/libmtp-$LIBMTP_VERSION"
  # MTPZ is only for Zune players and would need libgcrypt.
  quiet ./configure "${configure_flags[@]}" --disable-mtpz \
    LIBUSB_CFLAGS="-I$prefix/include/libusb-1.0" \
    LIBUSB_LIBS="-L$prefix/lib -lusb-1.0 $usb_extra_libs"
  # Only the library; libmtp's example programs aren't needed.
  quiet make -C src -j"$jobs"
  quiet make -C src install
)

for built in lib/libmtp.a lib/libusb-1.0.a include/libmtp.h; do
  if [[ ! -f "$prefix/$built" ]]; then
    echo "Building the libraries didn't produce .deps/$built." >&2
    exit 1
  fi
done
echo "$stamp" > "$prefix/stamp"
echo "Built libusb and libmtp in .deps/"
