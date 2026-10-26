#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo 'ERROR: Install Apple Command Line Tools first: xcode-select --install'
  exit 1
fi
if [ ! -x /opt/local/bin/displayplacer ]; then
  echo 'ERROR: displayplacer is missing. First run: sudo port install displayplacer'
  exit 1
fi
DEST="$HOME/Applications/Display Menu.app"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources" "$HOME/Library/LaunchAgents"
echo 'Compiling the macOS menu bar app...'
xcrun swiftc -O -framework AppKit DisplayMenu.swift -o "$DEST/Contents/MacOS/DisplayMenu"
chmod +x "$DEST/Contents/MacOS/DisplayMenu"
echo 'Generating app icon...'
ICONSET="$(mktemp -d)/AppIcon.iconset"
if xcrun swift make_icon.swift "$ICONSET" && iconutil -c icns "$ICONSET" -o "$DEST/Contents/Resources/AppIcon.icns"; then
  ICON_OK=1
else
  ICON_OK=0
  echo 'WARNING: icon generation failed; continuing without an app icon.'
fi
cat > "$DEST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DisplayMenu</string>
<key>CFBundleIdentifier</key><string>com.local.displaymenu</string>
<key>CFBundleName</key><string>Display Menu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
if [ "$ICON_OK" = 1 ]; then
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$DEST/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Add :BuildTime string $(date '+%Y-%m-%d %H:%M:%S %Z')" "$DEST/Contents/Info.plist"
AGENT="$HOME/Library/LaunchAgents/com.local.displaymenu.plist"
cat > "$AGENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>
PLIST
/usr/libexec/PlistBuddy -c 'Add :Label string com.local.displaymenu' "$AGENT"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$AGENT"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $DEST/Contents/MacOS/DisplayMenu" "$AGENT"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$AGENT"
/usr/libexec/PlistBuddy -c 'Add :ProcessType string Interactive' "$AGENT"
echo 'Installed in ~/Applications/Display Menu.app'
echo 'Auto-start is configured for subsequent logins.'
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
open "$DEST"
echo 'Look for the displays icon in the top menu bar.'
