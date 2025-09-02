# psyche-os workspace

This workspace contains a daemon crate `created`.

## created

A tiny Rust daemon that repeatedly logs a message and reads configuration from sensible locations. It can be packaged as a Debian `.deb` that installs a systemd service.

### Build

- Build binary: `cargo build -p created --release`
- Package as `.deb` (requires `cargo-deb`): `cargo deb -p created`
  - Install `cargo-deb`: `cargo install cargo-deb`

Cross-compile for Raspberry Pi (arm64/armhf):

- Install Rust targets: `rustup target add aarch64-unknown-linux-gnu armv7-unknown-linux-gnueabihf`
- Install cross C toolchains (Debian/Ubuntu): `sudo apt-get install gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf`
- Build: `cargo build -p created --release --target aarch64-unknown-linux-gnu`
- Package: `cargo deb -p created --target aarch64-unknown-linux-gnu`

### Install (systemd)

- Install the `.deb`: `sudo dpkg -i target/debian/created_*.deb`
- Enable + start: handled by post-install script. If needed:
  - `sudo systemctl enable created.service`
  - `sudo systemctl start created.service`
- Logs: `journalctl -u created -f`

### Config

Lookup order for `config.toml`:

1. `CREATED_CONFIG` environment variable (absolute path)
2. `$XDG_CONFIG_HOME/created/config.toml`
3. `$HOME/.config/created/config.toml`
4. `/etc/created/config.toml`

An example config is provided in `created/assets/etc/created/config.toml` and is installed by the `.deb` to `/etc/created/config.toml`.

Fields:

- `interval_ms`: integer, milliseconds between log lines (default 5000)
- `message`: string, message to log (default "hello world")
- `serial.path`: optional string path to serial device (e.g. `/dev/ttyUSB0`). If omitted, the daemon autodetects from `/dev/serial/by-id/*`, then `ttyUSB*`/`ttyACM*`.
- `serial.baud`: baud rate (default 57600), used when connecting to iRobot Create.

### Service unit

The service runs the foreground binary and logs to journald. Unit installed to `/lib/systemd/system/created.service`.

### Serial Access and udev

- The package installs a udev rule at `/lib/udev/rules.d/99-created-serial.rules` that:
  - Ensures `ttyUSB*`/`ttyACM*` devices are `root:dialout` with `0660` (usually default).
  - Adds stable symlinks `serial/by-irobot-<dev>` for those ports.
- The systemd unit runs as user `created` with supplementary group `dialout` for serial access.
- On install, the postinst script creates the `created` system user and adds it to `dialout`, then reloads udev and systemd.
- The daemon autodetects serial ports in this order:
  1) `serial.path` from config, if set
  2) `/dev/serial/by-irobot-*` symlinks
  3) `/dev/serial/by-id/*`
  4) `/dev/ttyUSB*` and `/dev/ttyACM*`

Note: The maintainer scripts under `created/debian/` may need the executable bit if your VCS/checkout drops it:

```
chmod +x created/debian/postinst created/debian/prerm created/debian/postrm
```

### Development

- Run locally with config path:
  - `CREATED_CONFIG=./created/assets/etc/created/config.toml RUST_LOG=info cargo run -p created`
- Stop with Ctrl-C. Under systemd, stop with `systemctl stop created`.

## Raspberry Pi Image Build

This repo provides a simple pipeline to customize a Raspberry Pi OS Lite image and embed the `created` service so it runs on first boot.

Prereqs (host): `sudo`, `losetup` (with `-P`), `mount`, `dpkg-deb`, `openssl`, and for convenience `curl`, `unzip` or `xz` depending on image format. To auto-build the `.deb`, install `cargo-deb`.

Cross-compiling `created` for Raspberry Pi on x86_64 hosts requires the Rust target and a C cross-linker:

- Rust targets: `rustup target add aarch64-unknown-linux-gnu armv7-unknown-linux-gnueabihf`
- Debian/Ubuntu packages:
  - `sudo apt-get install gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf`

This repo includes `.cargo/config.toml` that points those targets to the correct GCC cross linkers, so `cargo deb -p created --target aarch64-unknown-linux-gnu` will link successfully once the packages above are installed.

1) Obtain a Raspberry Pi OS Lite image (arm64 recommended). Either:
- Download manually and provide `IMG=/path/to/raspios.img[.xz|.zip]`, or
- Provide a URL via `IMG_URL=...` and the script will download it.

2) Build the image:

- Using Makefile (defaults: `ARCH=arm64`, hostname `psyche`, user `pi`/`raspberry`):
  - `make image IMG=/path/to/raspios.img.xz`
  - or `make image IMG_URL=https://.../raspios_lite_arm64-<date>.img.xz`

- The script will try to use an existing package under `target/debian/created_*_arm64.deb`, or build it with `cargo deb -p created --target aarch64-unknown-linux-gnu` if `cargo-deb` is installed. Override with `--deb /path/to/created_<ver>_arm64.deb`.
  - If you see a linker error like “Relocations in generic ELF (EM: 183)” or “file in wrong format”, install the cross toolchain packages listed above and ensure the Rust target is added.

Alternative: use `cross` (Docker-based) to avoid local toolchains:

- `cargo install cross` then `cross build --target aarch64-unknown-linux-gnu -p created`
- For `.deb` packaging, you can run `cross` with an image that has `cargo-deb` preinstalled, or build in a container/chroot. The local GCC cross toolchain approach above is simpler for this repo.

3) Optional flags (pass via Makefile variables or call script directly):
- Hostname: `--hostname mypi`
- User + password: `--user alice --password secret123`
- WiFi: `--wifi-ssid MySSID --wifi-psk MyPassword`
- Arch: `--arch armhf` for 32-bit (requires an `armhf` `.deb`)

Outputs:
- Customized image at `build/output/raspios-custom-<arch>.img`

First boot:
- SSH is enabled; login with the provided user/password.
- The `created` service is enabled. Check logs with `journalctl -u created -f`.
