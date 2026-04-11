# Glance

**Turn your desktop into a command center.** Glance replaces the clutter of overlapping windows with a clean, always-visible layout — your main window front and center, everything else as live thumbnails at your fingertips.

![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue) ![Windows 10+](https://img.shields.io/badge/Windows-10%2B-0078d4) ![Swift](https://img.shields.io/badge/Swift-5.10-orange) ![Rust](https://img.shields.io/badge/Rust-stable-dea584) ![License](https://img.shields.io/badge/license-MIT-green)

## Why Glance?

If you regularly juggle 10+ windows, you know the pain: `Cmd+Tab` / `Alt+Tab` is slow, Mission Control is a blur of rectangles, and Stage Manager / Snap Layouts never quite get it right.

Glance takes a different approach:

- **One focused window** lives in a frosted-glass work area — always visible, never buried
- **Everything else** becomes a live thumbnail arranged around it — no hunting, no guessing
- **Switch instantly** by clicking a thumbnail, or use keyboard hints to jump to any window with a single keystroke

Think of it as a persistent, keyboard-driven Mission Control that actually stays out of your way.

## Features

|  | macOS | Windows |
|---|:---:|:---:|
| Live Thumbnails | CGWindowList capture (3 FPS) | DWM hardware-accelerated (real-time) |
| Keyboard Quick Switch | Option double-tap | Alt double-tap |
| Drag & Drop Reorder | Drag to rearrange | Drag to rearrange |
| Hover Preview | Blue border highlight | Blue border highlight |
| Pin Reference Window | Adjustable split ratio | Adjustable split ratio |
| Spring-Loading | Drag file over thumbnail for 2s | Drag file over thumbnail for 2s |
| Multi-Display | Intelligent distribution | Intelligent distribution |
| Window Parking | Hidden virtual display | Virtual desktop / off-screen |
| Auto-Swap on Focus | - | Alt+Tab auto-swap |
| Private Window Detection | Lock icon placeholder | - |
| System Tray / Menu Bar | Menu bar icon | System tray icon |
| Frosted Glass Work Area | NSVisualEffectView | Windows 11 Mica/Acrylic |

## Keyboard Shortcuts

| Action | macOS | Windows |
|---|---|---|
| Toggle Glance on/off | `Ctrl + Option + H` | `Ctrl + Alt + H` |
| Enter quick-switch hint mode | `Option` (double-tap) | `Alt` (double-tap) |
| Jump to window (in hint mode) | `1-9`, `A-Z` | `1-9`, `A-Z` |
| Exit hint mode | `Esc` | `Esc` |

## Installation

### macOS

Grab the latest `Glance.pkg` from the [Releases](../../releases) page and run the installer.

<details>
<summary>Build from source</summary>

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Xcode 16+.

```bash
git clone https://github.com/hoveychen/glance.git
cd glance
./build.sh
open build/Build/Products/Release/Glance.app
```
</details>

### Windows

Grab the latest `glance-windows.exe` from the [Releases](../../releases) page and run it. No installation needed.

<details>
<summary>Build from source</summary>

Requires [Rust](https://rustup.rs/) stable toolchain.

```bash
git clone https://github.com/hoveychen/glance.git
cd glance/glance-windows
cargo build --release
# Binary at target/release/glance-windows.exe
```
</details>

## Setup

### macOS

On first launch, macOS will ask for two permissions:

1. **Accessibility** — needed to move and resize windows. Go to **System Settings > Privacy & Security > Accessibility** and enable Glance.
2. **Screen Recording** — needed to capture live window thumbnails. Go to **System Settings > Privacy & Security > Screen Recording** and enable Glance.

Glance runs as a menu bar app (no Dock icon). Click the status bar icon to toggle it on or off.

### Windows

No special permissions required. Glance runs in the system tray — left-click to toggle, right-click for options.

For the best visual experience, Windows 11 is recommended (Mica/Acrylic backdrop). On Windows 10, Glance works fully but the work area window uses a solid dark background instead.

## How It Works

Glance parks your non-focused windows out of sight — on macOS via a hidden virtual display, on Windows via a secondary virtual desktop (or off-screen coordinates as fallback). The parked windows remain fully alive and functional. Their contents are rendered as live thumbnails around your work area.

When you click or keyboard-select a thumbnail, the parked window swaps back and the previously active window takes its place. The result: one window in focus, everything else a glance away, zero overlap.

## Requirements

**macOS:** 14.0 (Sonoma) or later, Accessibility + Screen Recording permissions

**Windows:** Windows 10 (1809+) or later, no special permissions

## License

MIT
