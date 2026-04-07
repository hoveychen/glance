# HackerScreen

**Turn your Mac into a command center.** HackerScreen replaces the clutter of overlapping windows with a clean, always-visible layout — your main window front and center, everything else as live thumbnails at your fingertips.

![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.10-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Why HackerScreen?

If you regularly juggle 10+ windows, you know the pain: `Cmd+Tab` is slow, Mission Control is a blur of rectangles, and Stage Manager never quite gets it right.

HackerScreen takes a different approach:

- **One focused window** lives in a frosted-glass work area — always visible, never buried
- **Everything else** becomes a live thumbnail arranged around it — no hunting, no guessing
- **Switch instantly** by clicking a thumbnail, or press `Option` twice to enter keyboard hint mode and jump to any window with a single keystroke

Think of it as a persistent, keyboard-driven Mission Control that actually stays out of your way.

## Features

### Live Thumbnails
All your non-focused windows are displayed as real-time thumbnail previews on your screen(s). They update continuously so you always know what's happening in every window at a glance.

### Keyboard-First Quick Switch
Double-tap `Option` to enter hint mode — each thumbnail gets a letter/number overlay. Press the key to instantly swap that window into your work area. No mouse needed.

### Drag & Drop Reorder
Drag thumbnails to rearrange them across screens. Your layout, your rules.

### Hover Preview
Hover over any thumbnail for a second to see a full-size preview — great for peeking at a window without switching to it.

### Multi-Display Aware
Thumbnails distribute intelligently across all connected displays, making full use of your screen real estate.

### Auto-Swap New Windows
Newly opened windows automatically move into the work area so you never miss them.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl + Option + H` | Toggle HackerScreen on/off |
| `Option` (double-tap) | Enter quick-switch hint mode |
| `1-9`, `A-Z` | Jump to window (in hint mode) |
| `Esc` | Exit hint mode |

## Installation

### Download

Grab the latest `HackerScreen.dmg` from the [Releases](../../releases) page. Open the DMG and drag **HackerScreen** to your Applications folder.

### Build from Source

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Xcode 16+.

```bash
git clone https://github.com/hoveychen/hacker-screen.git
cd hacker-screen
./build.sh
open build/Build/Products/Release/HackerScreen.app
```

## Setup

On first launch, macOS will ask for two permissions:

1. **Accessibility** — needed to move and resize windows. Go to **System Settings > Privacy & Security > Accessibility** and enable HackerScreen.
2. **Screen Recording** — needed to capture live window thumbnails. Go to **System Settings > Privacy & Security > Screen Recording** and enable HackerScreen.

HackerScreen runs as a menu bar app (no Dock icon). Click the status bar icon to toggle it on or off.

## How It Works

HackerScreen creates a hidden virtual display behind the scenes. Non-focused windows are parked there — they remain fully alive and functional, just not visible on your physical screens. Their contents are captured as live thumbnails and displayed as overlay windows around your work area. When you click or keyboard-select a thumbnail, the parked window swaps back onto your real screen and the previously active window takes its place on the virtual display.

The result: one window in focus, everything else a glance away, zero overlap.

## Requirements

- macOS 14.0 (Sonoma) or later
- Accessibility permission
- Screen Recording permission

## License

MIT
