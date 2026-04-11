#![windows_subsystem = "windows"]

mod app;
pub mod input;
mod layout;
mod monitor;
pub mod overlay;
pub mod thumbnail_manager;
pub mod tray;
mod types;
mod virtual_desktop;
mod window_manager;
pub mod window_tracker;
pub mod work_area;

fn main() {
    env_logger::init();
    log::info!("Glance Windows starting...");

    let mut app = app::GlanceApp::new();
    app.run();
}
