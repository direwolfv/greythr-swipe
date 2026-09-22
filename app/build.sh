#!/bin/bash
# Build greytHR.app. No Xcode needed — Command Line Tools are enough.
#
# The bundle is self-contained: the Playwright worker and its node_modules ship inside
# Contents/Resources, and settings/logs live in ~/Library/Application Support/greytHR.
# The app installs its own LaunchAgent on first launch, so nothing here touches launchd.
set -e
cd "$(dirname "$0")"

PROJECT="$(cd .. && pwd)"
APP="greytHR.app"
DATA="$HOME/Library/Application Support/greytHR"

[ -d "$PROJECT/node_modules/playwright-core" ] || { echo "run 'npm install' in $PROJECT first"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>greytHR</string>
  <key>CFBundleDisplayName</key><string>greytHR</string>
  <key>CFBundleIdentifier</key><string>com.direwolfv.greythr-swipe</string>
  <key>CFBundleExecutable</key><string>greytHR</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>greytHR</string>
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.direwolfv.greythr-swipe</string>
      <key>CFBundleURLSchemes</key><array><string>greythr</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST_EOF

echo "compiling…"
swiftc -parse-as-library -O -o "$APP/Contents/MacOS/greytHR" Sources/App.swift

echo "bundling the worker…"
cp "$PROJECT/index.js" "$APP/Contents/Resources/"
# index.js is ESM. No package.json ships here otherwise, so without this Node falls back to
# syntax detection, which only exists from 20.19 — and the launcher runs whatever node it finds.
printf '{"type":"module"}\n' > "$APP/Contents/Resources/package.json"
# App icon. Regenerate with:  swiftc -O -o /tmp/mkicon app/mkicon.swift \
#   && /tmp/mkicon /tmp/greytHR.iconset && iconutil -c icns /tmp/greytHR.iconset -o app/greytHR.icns
cp greytHR.icns "$APP/Contents/Resources/"
cp run.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/run.sh"

# The LaunchAgent ships inside the bundle and is registered with SMAppService, not written
# to ~/Library/LaunchAgents. A loose plist runs /bin/sh, so macOS attributes the background
# item to "sh" in Login Items; registered this way it is attributed to this app. BundleProgram
# is relative to the bundle, which also means no absolute path to bake in at build time.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/com.direwolfv.greythr-swipe.plist" <<AGENT_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.direwolfv.greythr-swipe</string>
  <key>BundleProgram</key><string>Contents/Resources/run.sh</string>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
AGENT_EOF
cp -R "$PROJECT/node_modules" "$APP/Contents/Resources/"

# Ship runtime dependencies only. A source install runs plain `npm install`, which also
# pulls devDependencies (typescript, @types) — copying those wholesale put 34 MB of
# compiler and .d.ts files inside the app. Keep exactly what package.json declares as
# "dependencies"; anything else here is build-time tooling.
# Read the keys with sed, not node: nothing else in this build needs node, and the Homebrew
# formula deliberately does not depend on it. "devDependencies" cannot match — the pattern
# requires the quote immediately before the d.
KEEP=$(sed -n '/"dependencies"[[:space:]]*:/,/}/p' "$PROJECT/package.json" \
       | sed -n 's/.*"\([^"]*\)"[[:space:]]*:[[:space:]]*".*/\1/p' | tr '\n' '|' | sed 's/|$//')
[ -n "$KEEP" ] || { echo "could not read dependencies from package.json"; exit 1; }
find "$APP/Contents/Resources/node_modules" -maxdepth 1 -mindepth 1 \
  | grep -Ev "/(${KEEP}|\.package-lock\.json)$" | xargs -r rm -rf

# Drop the parts of playwright-core nothing here loads: TypeScript declarations, the
# trace-viewer UI, the webp encoder (screenshots are PNG), the Linux opener, the browser
# DOWNLOAD scripts (we always drive an already-installed Chromium) and the CLI entry.
# Kept on purpose: LICENSE, NOTICE, ThirdPartyNotices and the *.LICENSE bundles — Apache-2.0
# requires retaining them even though nothing loads them. index.mjs is the ESM entry we import.
# Verified by a real dry-run login after each cut. 14M -> 6.9M.
PW="$APP/Contents/Resources/node_modules/playwright-core"
rm -rf "$PW/types" "$PW/lib/vite" "$PW/lib/webp_codec.wasm" "$PW/lib/xdg-open" "$PW/lib/tools"
rm -rf "$PW/bin" "$PW/cli.js" "$PW/index.d.ts" "$PW/README.md" "$PW/lib/webp_codec.LICENSE"

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(ad-hoc signing skipped)"
echo "built $PWD/$APP ($(du -sh "$APP" | cut -f1))"

# One-time move of settings/logs out of the source tree. Skipped for package installs,
# which build in a sandbox and must not touch $HOME.
if [ "$1" != "--no-migrate" ] && [ ! -f "$DATA/config.json" ] && [ -f "$PROJECT/config.json" ]; then
  mkdir -p "$DATA/logs"
  cp "$PROJECT/config.json" "$DATA/config.json"
  [ -d "$PROJECT/logs" ] && cp -R "$PROJECT/logs/." "$DATA/logs/" 2>/dev/null || true
  echo "migrated settings and logs to $DATA"
fi

echo
echo "Next:  open $PWD/$APP   (it installs its own LaunchAgent on first launch)"
