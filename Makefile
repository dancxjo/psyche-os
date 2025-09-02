# Simple image build orchestration for Raspberry Pi OS Lite

.PHONY: all build-created-deb-arm64 image clean

ARCH ?= arm64
TARGET_arm64 = aarch64-unknown-linux-gnu
TARGET_armhf = armv7-unknown-linux-gnueabihf

# Path to a Raspberry Pi OS Lite image (.img or .img.xz/.zip) you downloaded
IMG ?=

# Optional: URL to download an image if IMG is not set
IMG_URL ?= https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64-lite.img.xz

# Where to place outputs
BUILD_DIR ?= build

all: image

build-created-deb-arm64:
	@which cargo-deb >/dev/null 2>&1 || { echo "cargo-deb not found. Install with: cargo install cargo-deb"; exit 1; }
	cargo deb -p created --target $(TARGET_arm64)

# Create a customized image with created service enabled
image:
	@[ -n "$(strip $(IMG))" ] || [ -n "$(strip $(IMG_URL))" ] || { echo "Provide IMG=/path/to/raspios.img[.xz|.zip] or IMG_URL=..."; exit 2; }
	$(eval IMG_ARG :=)
	$(eval IMG_URL_ARG :=)
	$(if $(strip $(IMG)),$(eval IMG_ARG := --img "$(IMG)"),)
	$(if $(strip $(IMG_URL)),$(eval IMG_URL_ARG := --img-url "$(IMG_URL)"),)
	bash scripts/build-image.sh --arch $(ARCH) $(IMG_ARG) $(IMG_URL_ARG) --build-dir "$(BUILD_DIR)"

clean:
	rm -rf $(BUILD_DIR)
