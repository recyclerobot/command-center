# 🤖 recyclerobot command center

A macOS menu bar app for managing window layouts and saving clipboard screenshots.

## Features

### Window Layout Profiles

- **Save** the position and size of all open application windows as a named profile
- **Restore** a saved profile to reposition windows (apps must be running)
- **Rename** and **delete** saved profiles
- Profiles are persisted to `~/Library/Application Support/RecycleRobotCommandCenter/profiles.json`

### Screenshot Clipboard Saver

- Automatically saves images copied to the clipboard (e.g. via ⌘⇧4) to a local folder
- Screenshots remain in your clipboard — they're duplicated, not moved
- Choose any folder as the save destination
- Files are saved as PNGs with timestamped filenames

### Settings

- **Launch at Login** — start the app automatically when you log in
- **Save Screenshots to Folder** — toggle clipboard screenshot saving on/off
- **Choose Save Folder** — pick where screenshots are saved

## Requirements

- macOS 13.0+
- **Accessibility permission** (System Settings → Privacy & Security → Accessibility) — required for capturing and restoring window positions

## Build

```bash
cd RecycleRobotCommandCenter
xcodebuild -project RecycleRobotCommandCenter.xcodeproj \
  -scheme RecycleRobotCommandCenter \
  -configuration Debug build
```

Or open `RecycleRobotCommandCenter/RecycleRobotCommandCenter.xcodeproj` in Xcode and hit ⌘R.

A convenience script is also available:

```bash
./build.sh
```

## Usage

1. After launching, a 🤖 icon appears in the menu bar
2. Click it to access all features
3. Grant Accessibility permissions when prompted on first use
