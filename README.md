# Display Menu for macOS

A small, free, open-source-style menu bar utility for macOS Sonoma on Intel iMac. It relies on your installed **MacPorts displayplacer** tool.

## Features
- Menu bar icon, no Dock icon or regular window.
- Lists all monitors detected by `displayplacer list`.
- Labels external displays in bold and shows ON/OFF with a checkmark.
- Click an external display to toggle it on/off.
- Built-in display is protected and cannot be toggled.
- Refresh item to rescan devices.
- Installs a per-user LaunchAgent to start on future logins.

## What's new in v1.1
- Fixes `could not find res:0x0 scaling:off` when turning a display back on.
- Before a display is turned off, its working configuration (resolution, refresh rate, color depth, scaling, origin, rotation) is saved. Configurations are also refreshed whenever an enabled external display is seen, and stored in the app's preferences, so they survive restarts.
- Turning a display on restores that saved configuration instead of sending only `enabled:true`. `res:0x0` or any invalid resolution is never sent; if no valid saved configuration exists you get an error message instead.
- The current state is re-read before every action; if the display is already in the requested state, no command runs.
- The menu is refreshed after every operation, and `displayplacer` errors are shown in an alert.
- Works with any number of external displays; nothing is hardcoded.

## Requirements
- macOS 13 or later (tested conceptually for Sonoma; not tested on a Mac in this environment)
- Apple Command Line Tools: `xcode-select --install`
- MacPorts `displayplacer`: `sudo port install displayplacer`

## Installation
1. Unzip, open Terminal, and `cd` into the extracted `DisplayMenuMac` folder.
2. Run `bash install.sh`.
3. Find the display icon on the top menu bar.
4. Click an **External** line to toggle its state.

For additional diagnostics run `/opt/local/bin/displayplacer list` in Terminal.

## Caveats
- Some external displays need a cable reconnect before they can be enabled again.
- `displayplacer` can change display identifiers; refresh after reconnection.
- An external display disconnected at the hardware level cannot be turned on via software.
- The app is compiled locally, not notarized/distributed as a prebuilt Mac binary.
- Display detection and control depend on `displayplacer` and the macOS graphics driver.

## Uninstall
Run `bash uninstall.sh` from this folder.
