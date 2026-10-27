#!/bin/sh
# Launcher for the LaunchAgent. Resolves node at run time instead of baking an absolute
# path into the plist: launchd gives us almost no PATH, and an nvm path like
# ~/.nvm/versions/node/v22.21.0/bin/node stops existing at the next `nvm install`.
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="$HOME/Library/Application Support/greytHR"
LOG="$DATA/logs/checkout.log"
CFG="$DATA/config.json"

MIN_NODE=24.22.1   # keep in step with "engines" in package.json

# True when $1 is a runnable node at least MIN_NODE. Version-sorting MIN_NODE against it puts
# MIN_NODE first exactly when the candidate is new enough.
new_enough() {
  [ -x "$1" ] || return 1
  nv="$("$1" -v 2>/dev/null | sed 's/^v//')"   # not $v: plain sh has no locals, find_node uses v
  [ -n "$nv" ] && [ "$(printf '%s\n' "$MIN_NODE" "$nv" | sort -V | head -1)" = "$MIN_NODE" ]
}

find_node() {
  # An explicit override wins, then "nodePath" from the app's Settings window, then
  # Homebrew, then the highest nvm version installed, then whatever PATH happens to offer.
  # Each candidate must be at least MIN_NODE; an older one is skipped, not run.
  if [ -n "$NODE_BIN" ] && new_enough "$NODE_BIN"; then echo "$NODE_BIN"; return; fi
  # One key out of config.json without a JSON parser — we cannot use node to find node.
  # Swift's JSONEncoder escapes slashes, so \/ has to come back as /.
  cfg="$(sed -n 's/.*"nodePath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" 2>/dev/null \
         | sed 's|\\/|/|g' | head -1)"
  if [ -n "$cfg" ] && new_enough "$cfg"; then echo "$cfg"; return; fi
  for p in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if new_enough "$p"; then echo "$p"; return; fi
  done
  d="$HOME/.nvm/versions/node"
  if [ -d "$d" ]; then
    v="$(ls -1 "$d" 2>/dev/null | sort -V | tail -1)"
    if [ -n "$v" ] && new_enough "$d/$v/bin/node"; then echo "$d/$v/bin/node"; return; fi
  fi
  p="$(command -v node 2>/dev/null)"
  if [ -n "$p" ] && new_enough "$p"; then echo "$p"; fi
}

NODE="$(find_node)"

# Answers the Test button next to Node in Settings. Lives here so the app never has to
# re-implement find_node() — whatever this prints is what the 5-minute job will run.
if [ "$1" = "--print-node" ]; then
  [ -z "$NODE" ] && { echo "no node $MIN_NODE or newer found — install it (brew install node)"; exit 1; }
  v="$("$NODE" -v 2>/dev/null)"
  [ -z "$v" ] && { echo "not runnable: $NODE"; exit 1; }
  # process.arch is what node reports about itself: arm64 or x64. An x64 node on an
  # Apple Silicon Mac runs under Rosetta — it works, but it is slower and worth knowing.
  a="$("$NODE" -p 'process.arch' 2>/dev/null)"
  [ -z "$a" ] && a="unknown arch"
  if [ "$(uname -m)" = "arm64" ] && [ "$a" = "x64" ]; then a="$a under Rosetta"; fi
  echo "$v $a — $NODE"
  exit 0
fi

# Node missing (or too old) is the one failure index.js can never report — it is what runs index.js.
# Hourly, not every tick: launchd retries every 5 minutes and 288 identical notifications
# (and log lines) a day would bury the real history.
STAMP="$DATA/logs/.node-missing"
if [ -z "$NODE" ]; then
  mkdir -p "$(dirname "$LOG")"
  now=$(date +%s)
  last=0
  [ -f "$STAMP" ] && last=$(cat "$STAMP" 2>/dev/null || echo 0)
  if [ $((now - last)) -ge 3600 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: no node $MIN_NODE or newer found. Install it (brew install node)." >> "$LOG"
    # Same route index.js uses: the menu bar app owns the notification, so clicking it
    # opens Settings. `open -g` starts the app in the background if it is not running.
    /usr/bin/open -g "greythr://notify?title=greytHR%20failed&body=node%20$MIN_NODE%2B%20not%20found%20-%20brew%20install%20node" 2>/dev/null
    echo "$now" > "$STAMP"
  fi
  exit 1
fi
rm -f "$STAMP"   # node is back; the next outage notifies immediately

# The bundled LaunchAgent has no StandardOutPath: it would need an absolute path baked in at
# build time, and the build does not know the installing user's home. Redirect here instead.
mkdir -p "$DATA/logs"
exec >>"$DATA/logs/launchd.out.log" 2>&1
exec "$NODE" "$HERE/index.js" "$@"
