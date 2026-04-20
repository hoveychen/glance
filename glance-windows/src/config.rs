//! Persistent configuration stored at %APPDATA%\Glance\config.json.
//!
//! Counterpart to the macOS UserDefaults storage. Only a small, stable subset
//! of user state is persisted (split ratios, work area frame) — transient
//! runtime state (pinned hwnds, window order) is not saved.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

use crate::swap_resize::SwapResizeMode;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Left-reference split ratio in [0.15, 0.5].
    #[serde(default = "default_left_split")]
    pub left_split_ratio: f64,
    /// Right-reference split ratio in [0.15, 0.5].
    #[serde(default = "default_right_split")]
    pub right_split_ratio: f64,
    /// Last work-area frame as (x, y, width, height). None before first save.
    #[serde(default)]
    pub work_area_frame: Option<(f64, f64, f64, f64)>,
    /// How to fit a window swapped into the work area when oversized.
    #[serde(default)]
    pub swap_resize_mode: SwapResizeMode,
    /// Highlight the 3 most recently-interacted thumbnails with a yellow halo,
    /// brightness decreasing by recency. Default: true.
    #[serde(default = "default_mru_glow")]
    pub mru_glow_enabled: bool,
}

fn default_left_split() -> f64 { 0.25 }
fn default_right_split() -> f64 { 0.30 }
fn default_mru_glow() -> bool { true }

impl Default for Config {
    fn default() -> Self {
        Self {
            left_split_ratio: default_left_split(),
            right_split_ratio: default_right_split(),
            work_area_frame: None,
            swap_resize_mode: SwapResizeMode::default(),
            mru_glow_enabled: default_mru_glow(),
        }
    }
}

fn config_path() -> Option<PathBuf> {
    let mut p = dirs::config_dir()?;
    p.push("Glance");
    let _ = std::fs::create_dir_all(&p);
    p.push("config.json");
    Some(p)
}

static CACHE: Mutex<Option<Config>> = Mutex::new(None);

/// Load from disk, or return defaults if missing/corrupt. Cached.
pub fn load() -> Config {
    if let Ok(guard) = CACHE.lock() {
        if let Some(ref c) = *guard {
            return c.clone();
        }
    }
    let cfg = match config_path().and_then(|p| std::fs::read_to_string(&p).ok()) {
        Some(s) => serde_json::from_str::<Config>(&s).unwrap_or_default(),
        None => Config::default(),
    };
    if let Ok(mut guard) = CACHE.lock() {
        *guard = Some(cfg.clone());
    }
    cfg
}

/// Persist the current cached config to disk (best-effort).
pub fn save() {
    let snapshot = match CACHE.lock() {
        Ok(guard) => match &*guard {
            Some(c) => c.clone(),
            None => return,
        },
        Err(_) => return,
    };
    if let Some(path) = config_path() {
        if let Ok(s) = serde_json::to_string_pretty(&snapshot) {
            let _ = std::fs::write(&path, s);
        }
    }
}

/// Mutate the cached config and immediately persist it.
pub fn update<F: FnOnce(&mut Config)>(f: F) {
    if let Ok(mut guard) = CACHE.lock() {
        if guard.is_none() {
            *guard = Some(Config::default());
        }
        if let Some(ref mut c) = *guard {
            f(c);
        }
    }
    save();
}
