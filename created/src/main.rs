use std::env;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use log::{error, info, warn};
use serde::Deserialize;
use serialport::SerialPort;

#[derive(Debug, Deserialize, Default, Clone)]
struct SerialConfig {
    /// Serial device path (e.g. /dev/ttyUSB0). If not set, autodetects.
    path: Option<String>,
    /// Baud rate (default 57600 for Create 1)
    baud: Option<u32>,
}

#[derive(Debug, Deserialize, Default)]
struct Config {
    /// Log interval in milliseconds
    interval_ms: Option<u64>,
    /// Optional message to log instead of default
    message: Option<String>,
    /// Serial configuration for iRobot Create
    serial: Option<SerialConfig>,
}

impl Config {
    fn interval(&self) -> Duration {
        Duration::from_millis(self.interval_ms.unwrap_or(5_000))
    }

    fn message(&self) -> &str {
        self.message.as_deref().unwrap_or("hello world")
    }
}

fn main() {
    // Initialize logger (stdout/stderr -> journald when under systemd)
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    // Handle graceful shutdown on SIGINT/SIGTERM
    let (tx_main, rx_main) = std::sync::mpsc::channel::<()>();
    let (tx_robot, rx_robot) = std::sync::mpsc::channel::<()>();
    if let Err(e) = ctrlc::set_handler(move || {
        let _ = tx_main.send(());
        let _ = tx_robot.send(());
    }) {
        warn!("failed to set signal handler: {e}");
    }

    let config = load_config();
    info!("starting created daemon");
    info!("config: interval={:?}, message=\"{}\"", config.interval(), config.message());

    // Spawn background thread to handle iRobot Create over serial (plug-and-play)
    let robot_cfg = config.serial.clone().unwrap_or_default();
    thread::spawn(move || {
        robot_worker(rx_robot, robot_cfg);
    });

    // Main loop
    loop {
        if let Ok(_) = rx_main.try_recv() {
            info!("shutdown signal received; exiting");
            break;
        }
        info!("{}", config.message());
        thread::sleep(config.interval());
    }
}

fn load_config() -> Config {
    match find_config_file() {
        Some(path) => match read_toml::<Config>(&path) {
            Ok(cfg) => cfg,
            Err(e) => {
                error!("failed to parse config at {}: {e}", path.display());
                Config { interval_ms: None, message: None, serial: None }
            }
        },
        None => {
            warn!("no config file found; using defaults");
            Config { interval_ms: None, message: None, serial: None }
        }
    }
}

fn read_toml<T: for<'de> serde::Deserialize<'de>>(path: &Path) -> Result<T, String> {
    let mut f = fs::File::open(path).map_err(|e| format!("open: {e}"))?;
    let mut s = String::new();
    f.read_to_string(&mut s).map_err(|e| format!("read: {e}"))?;
    toml::from_str(&s).map_err(|e| format!("toml: {e}"))
}

fn find_config_file() -> Option<PathBuf> {
    // 1) Explicit path via env var
    if let Ok(p) = env::var("CREATED_CONFIG") {
        let pb = PathBuf::from(p);
        if pb.is_file() {
            return Some(pb);
        }
    }

    // 2) XDG config home
    if let Ok(xdg) = env::var("XDG_CONFIG_HOME") {
        let p = Path::new(&xdg).join("created").join("config.toml");
        if p.is_file() {
            return Some(p);
        }
    }

    // 3) ~/.config
    if let Some(home) = dirs_home() {
        let p = home.join(".config").join("created").join("config.toml");
        if p.is_file() {
            return Some(p);
        }
    }

    // 4) /etc/created/config.toml
    let etc = Path::new("/etc").join("created").join("config.toml");
    if etc.is_file() {
        return Some(etc);
    }

    None
}

fn dirs_home() -> Option<PathBuf> {
    if let Ok(home) = env::var("HOME") {
        return Some(PathBuf::from(home));
    }
    // Fallback for non-standard envs
    dirs_fallback_home()
}

#[cfg(unix)]
fn dirs_fallback_home() -> Option<PathBuf> { None }

#[cfg(not(unix))]
fn dirs_fallback_home() -> Option<PathBuf> { None }

// ---------------- iRobot Create OI handling ----------------

fn robot_worker(rx: std::sync::mpsc::Receiver<()>, serial_cfg: SerialConfig) {
    let mut last_handled: Option<PathBuf> = None;
    loop {
        // Shutdown check with short timeout to keep loop responsive
        if let Ok(_) = rx.recv_timeout(Duration::from_millis(200)) {
            info!("robot worker shutdown");
            return;
        }

        // Reset last_handled if it disappeared
        if let Some(ref p) = last_handled {
            if !p.exists() {
                last_handled = None;
            }
        }

        match pick_serial_port(&serial_cfg) {
            Some(port_path) => {
                // Only act when a new device shows up or if we haven't handled any
                let should_handle = match &last_handled {
                    Some(prev) => prev != &port_path,
                    None => true,
                };
                if should_handle {
                    let baud = serial_cfg.baud.unwrap_or(57_600);
                    match connect_and_act(&port_path, baud) {
                        Ok(()) => {
                            info!("handled robot on {}", port_path.display());
                            last_handled = Some(port_path);
                        }
                        Err(e) => {
                            warn!("failed to handle robot on {}: {}", port_path.display(), e);
                        }
                    }
                }
            }
            None => {
                // No candidate device found right now
            }
        }

        // Avoid busy loop
        thread::sleep(Duration::from_secs(2));
    }
}

fn pick_serial_port(cfg: &SerialConfig) -> Option<PathBuf> {
    // 1) Configured path
    if let Some(ref p) = cfg.path {
        let pb = PathBuf::from(p);
        if pb.exists() { return Some(pb); }
    }
    // 2) Our udev-provided symlinks
    if let Ok(entries) = fs::read_dir("/dev/serial") {
        for e in entries.flatten() {
            let p = e.path();
            if let Some(name) = p.file_name().and_then(|s| s.to_str()) {
                if name.starts_with("by-irobot-") {
                    if p.exists() { return Some(p); }
                }
            }
        }
    }
    // 3) /dev/serial/by-id/* is the most stable symlink location
    if let Ok(entries) = fs::read_dir("/dev/serial/by-id") {
        for e in entries.flatten() {
            let p = e.path();
            if p.exists() { return Some(p); }
        }
    }
    // 4) Fallback to ttyUSB* and ttyACM*
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(entries) = fs::read_dir("/dev") {
        for e in entries.flatten() {
            let name = e.file_name();
            if let Some(s) = name.to_str() {
                if s.starts_with("ttyUSB") || s.starts_with("ttyACM") {
                    candidates.push(e.path());
                }
            }
        }
    }
    candidates.sort();
    candidates.into_iter().next()
}

fn connect_and_act(port_path: &Path, baud: u32) -> Result<(), String> {
    info!("connecting to {} at {} baud", port_path.display(), baud);
    let mut port = serialport::new(port_path.to_string_lossy(), baud)
        .timeout(Duration::from_millis(500))
        .open()
        .map_err(|e| format!("open serial: {e}"))?;

    // iRobot Create OI minimal sequence: Start (128), define song (140), play (141), power (133)
    // Define a tiny 3-note song (C4, E4, G4)
    send_bytes(&mut *port, &[128])?; // Start
    thread::sleep(Duration::from_millis(50));

    // Song definition: [140, song_number, length, note, duration, ...]
    let song: [u8; 9] = [140, 0, 3, 60, 16, 64, 16, 67, 24];
    send_bytes(&mut *port, &song)?;
    thread::sleep(Duration::from_millis(20));

    // Play song 0
    send_bytes(&mut *port, &[141, 0])?;
    thread::sleep(Duration::from_millis(1500));

    // Power down (sleep)
    send_bytes(&mut *port, &[133])?;
    Ok(())
}

fn send_bytes(port: &mut dyn SerialPort, data: &[u8]) -> Result<(), String> {
    port.write_all(data).map_err(|e| format!("write: {e}"))?;
    port.flush().map_err(|e| format!("flush: {e}"))
}
