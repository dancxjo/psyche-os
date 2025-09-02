#!/usr/bin/env bash
set -euo pipefail

# Customizes a Raspberry Pi OS Lite image:
# - Downloads image if URL provided
# - Mounts partitions via losetup
# - Enables SSH, sets hostname, optional user/password and WiFi
# - Installs the created package by extracting a .deb into the rootfs
# - Enables systemd service for created
#
# Requirements (host): sudo, losetup (-P), mount, xz/unzip, dpkg-deb,
# optionally curl if using --img-url, and cargo-deb if building the .deb.

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

ARCH="arm64"            # arm64 or armhf
IMG=""                  # path to .img or compressed image
IMG_URL=""              # optional: URL to download image
BUILD_DIR="$ROOT_DIR/build"
HOSTNAME="psyche"
USERNAME="pi"
PASSWORD="raspberry"
WIFI_SSID=""
WIFI_PSK=""
DEB_PATH=""            # optional override path to created_*.deb

usage() {
  cat <<EOF
Usage: $0 [options]
  --arch <arm64|armhf>            Target arch (default: arm64)
  --img <path>                    Path to Raspberry Pi OS image (.img or .img.xz/.zip)
  --img-url <url>                 URL to download image if --img not set
  --build-dir <dir>               Build/output directory (default: build)
  --hostname <name>               Hostname to set (default: psyche)
  --user <name>                   Username to create on first boot (default: pi)
  --password <pass>               Password for user (default: raspberry)
  --wifi-ssid <ssid>              WiFi SSID (optional)
  --wifi-psk <psk>                WiFi PSK (optional)
  --deb <path>                    Path to created .deb (optional)

Outputs image at: 
  <build-dir>/output/raspios-custom-<arch>.img
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2;;
    --img) IMG="$2"; shift 2;;
    --img-url) IMG_URL="$2"; shift 2;;
    --build-dir) BUILD_DIR="$2"; shift 2;;
    --hostname) HOSTNAME="$2"; shift 2;;
    --user) USERNAME="$2"; shift 2;;
    --password) PASSWORD="$2"; shift 2;;
    --wifi-ssid) WIFI_SSID="$2"; shift 2;;
    --wifi-psk) WIFI_PSK="$2"; shift 2;;
    --deb) DEB_PATH="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

mkdir -p "$BUILD_DIR" "$BUILD_DIR/tmp" "$BUILD_DIR/mnt/boot" "$BUILD_DIR/mnt/root" "$BUILD_DIR/output"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 3
  fi
}

require sudo
require losetup
require mount
require dpkg-deb

resolve_arch() {
  case "$ARCH" in
    arm64)
      DEB_ARCH="arm64"
      RUST_TARGET="aarch64-unknown-linux-gnu"
      ;;
    armhf)
      DEB_ARCH="armhf"
      RUST_TARGET="armv7-unknown-linux-gnueabihf"
      ;;
    *)
      echo "Unsupported ARCH: $ARCH (expected arm64 or armhf)" >&2
      exit 6
      ;;
  esac
}

resolve_arch

download_image() {
  local url="$1" out="$2"
  require curl
  echo "Downloading image: $url"
  curl -L "$url" -o "$out"
}

decompress_if_needed() {
  local in="$1"
  case "$in" in
    *.img) echo "$in";;
    *.img.xz)
      require xz
      local out="${in%.xz}"
      # Only emit the resolved path on stdout; log progress to stderr
      if [[ -f "$out" ]]; then
        echo "Using existing decompressed image: $out" >&2
      else
        echo "Decompressing $in -> $out" >&2
        xz -dk "$in" >&2
      fi
      echo "$out";;
    *.zip)
      require unzip
      echo "Unzipping $in" >&2
      local out
      out=$(unzip -Z1 "$in" | grep -E '\\.img$' | head -n1)
      [ -n "$out" ] || { echo "No .img in zip"; exit 4; }
      unzip -o "$in" "$out" -d "$(dirname "$in")" >&2
      echo "$(dirname "$in")/$out";;
    *) echo "Unsupported image format: $in"; exit 5;;
  esac
}

select_deb() {
  if [[ -n "$DEB_PATH" ]]; then
    # Verify deb architecture matches
    local arch
    arch=$(dpkg-deb -f "$DEB_PATH" Architecture 2>/dev/null || true)
    if [[ "$arch" != "$DEB_ARCH" ]]; then
      echo "Provided deb ($DEB_PATH) architecture '$arch' does not match target '$DEB_ARCH'" >&2
      exit 7
    fi
    echo "$DEB_PATH"; return
  fi
  # Try to find an existing package built by cargo-deb
  local deb
  for deb in "$ROOT_DIR/target/debian"/created_*.deb; do
    [[ -e "$deb" ]] || break
    local arch
    arch=$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)
    if [[ "$arch" == "$DEB_ARCH" ]]; then
      echo "$deb"; return
    fi
  done

  # Try to build with cargo-deb if available
  if command -v cargo-deb >/dev/null 2>&1 || cargo deb -V >/dev/null 2>&1; then
    echo "Building created .deb for $ARCH ($RUST_TARGET)" >&2
    # Check rust target and cross toolchain presence (best-effort)
    if command -v rustup >/dev/null 2>&1; then
      if ! rustup target list --installed | grep -q "^$RUST_TARGET$"; then
        echo "Rust target $RUST_TARGET not installed. Install with: rustup target add $RUST_TARGET" >&2
      fi
    fi
    case "$ARCH" in
      arm64)
        command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || echo "Note: cross C linker aarch64-linux-gnu-gcc not found; pure-Rust crates will still build." >&2
        ;;
      armhf)
        command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1 || echo "Note: cross C linker arm-linux-gnueabihf-gcc not found; pure-Rust crates will still build." >&2
        ;;
    esac
    # Send cargo output to stderr so stdout only carries the final .deb path
    (cd "$ROOT_DIR" && cargo deb -p created --target "$RUST_TARGET") >&2
    for deb in "$ROOT_DIR/target/debian"/created_*.deb; do
      [[ -e "$deb" ]] || break
      local arch
      arch=$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)
      if [[ "$arch" == "$DEB_ARCH" ]]; then
        echo "$deb"; return
      fi
    done
  fi

  echo "Could not find or build created .deb for $ARCH. Provide --deb /path/to/created_<ver>_${ARCH}.deb" >&2
  echo "Hints: install cross toolchains and rust target (on Debian/Ubuntu):" >&2
  echo "  sudo apt-get install gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf" >&2
  echo "  rustup target add aarch64-unknown-linux-gnu armv7-unknown-linux-gnueabihf" >&2
  exit 7
}

IMG_PATH=""
if [[ -n "$IMG" ]]; then
  IMG_PATH="$IMG"
elif [[ -n "$IMG_URL" ]]; then
  fname="$(basename "$IMG_URL")"
  case "$fname" in
    *.img|*.img.xz|*.zip) :;;
    *) echo "Unsupported or unknown image filename from URL: $fname"; exit 5;;
  esac
  localfile="$BUILD_DIR/tmp/$fname"
  download_image "$IMG_URL" "$localfile"
  IMG_PATH="$localfile"
else
  echo "Provide --img or --img-url"; exit 2
fi

IMG_DECOMPRESSED=$(decompress_if_needed "$IMG_PATH")
# Sanity: warn if image filename suggests a different arch than requested
base_img_name="$(basename "$IMG_DECOMPRESSED")"
case "$base_img_name" in
  *arm64*|*aarch64*) img_hint="arm64";;
  *armhf*|*armv7*) img_hint="armhf";;
  *) img_hint="";;
esac
if [[ -n "$img_hint" && "$img_hint" != "$ARCH" ]]; then
  echo "Warning: Image name ($base_img_name) suggests arch '$img_hint' but --arch is '$ARCH'" >&2
fi
OUT_IMG="$BUILD_DIR/output/raspios-custom-${ARCH}.img"
cp -f "$IMG_DECOMPRESSED" "$OUT_IMG"

DEB=$(select_deb)
echo "Using package: $DEB"

cleanup() {
  set +e
  if mountpoint -q "$BUILD_DIR/mnt/boot"; then sudo umount "$BUILD_DIR/mnt/boot"; fi
  if mountpoint -q "$BUILD_DIR/mnt/root"; then sudo umount "$BUILD_DIR/mnt/root"; fi
  if [[ -n "${LOOPDEV:-}" ]]; then sudo losetup -d "$LOOPDEV" || true; fi
}
trap cleanup EXIT

echo "Setting up loop device for $OUT_IMG"
LOOPDEV=$(sudo losetup --show -fP "$OUT_IMG")

echo "Mounting partitions"
sudo mount "${LOOPDEV}p2" "$BUILD_DIR/mnt/root"
sudo mount "${LOOPDEV}p1" "$BUILD_DIR/mnt/boot"

BOOT="$BUILD_DIR/mnt/boot"
ROOT="$BUILD_DIR/mnt/root"

echo "Enabling SSH"
sudo touch "$BOOT/ssh"

echo "Setting hostname: $HOSTNAME"
echo "$HOSTNAME" | sudo tee "$ROOT/etc/hostname" >/dev/null
sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" "$ROOT/etc/hosts" || true

echo "Configuring user via userconf on boot partition"
if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl not found, cannot hash password for userconf" >&2
  exit 8
fi
HASH=$(printf "%s" "$PASSWORD" | openssl passwd -6 -stdin)
echo "$USERNAME:$HASH" | sudo tee "$BOOT/userconf" >/dev/null

if [[ -n "$WIFI_SSID" && -n "$WIFI_PSK" ]]; then
  echo "Configuring WiFi on boot partition"
  cat <<WIFI | sudo tee "$BOOT/wpa_supplicant.conf" >/dev/null
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
  ssid="$WIFI_SSID"
  psk="$WIFI_PSK"
}
WIFI
fi

echo "Installing created package into rootfs"
sudo dpkg-deb -x "$DEB" "$ROOT"

echo "Enabling created.service"
sudo mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf \
  /lib/systemd/system/created.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/created.service"

# Since we extracted the .deb without dpkg, maintainer scripts didn't run.
# Add a drop-in so the service runs as root in the prebuilt image; the .deb
# installation on a live system will still use the dedicated 'created' user.
sudo mkdir -p "$ROOT/etc/systemd/system/created.service.d"
sudo tee "$ROOT/etc/systemd/system/created.service.d/override.conf" >/dev/null <<'OVR'
[Service]
User=root
Group=root
SupplementaryGroups=dialout
OVR

echo "Ensuring default config at /etc/created/config.toml"
if [[ ! -f "$ROOT/etc/created/config.toml" ]]; then
  sudo mkdir -p "$ROOT/etc/created"
  sudo tee "$ROOT/etc/created/config.toml" >/dev/null <<CFG
interval_ms = 5000
message = "hello world"
CFG
fi

echo "Customization complete: $OUT_IMG"
echo "Next: Write image to SD card or run in emulator. SSH will be enabled; login $USERNAME/$PASSWORD. The created service should be running (journalctl -u created)."
