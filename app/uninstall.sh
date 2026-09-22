#!/bin/sh
# Removes what `brew uninstall` cannot. Homebrew formulae have no uninstall or zap hook —
# those are cask-only — so the LaunchAgent, the /Applications symlink and the data directory
# all outlive the keg. Left alone, the timer keeps firing every 5 minutes at a script that
# is no longer there.
#
#   greythr-swipe-uninstall         stop the timer, remove the agent and the symlink
#   greythr-swipe-uninstall --all   also delete settings, logs and the Keychain items
#
# Then: brew uninstall direwolfv/tap/greythr-swipe
set -e

LABEL=com.direwolfv.greythr-swipe
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DATA="$HOME/Library/Application Support/greytHR"
APP=/Applications/greytHR.app

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
echo "stopped the 5-minute timer"

pkill -x greytHR 2>/dev/null || true

if [ -f "$PLIST" ]; then
  rm -f "$PLIST"
  echo "removed $PLIST"
fi

# Only ever remove our own symlink. A real app someone installed by hand stays put.
if [ -L "$APP" ]; then
  rm -f "$APP"
  echo "removed the $APP symlink"
elif [ -e "$APP" ]; then
  echo "left $APP alone — it is a real app, not our symlink"
fi

if [ "$1" = "--all" ]; then
  if [ -d "$DATA" ]; then
    rm -rf "$DATA"
    echo "removed $DATA"
  fi
  for s in greythr-username greythr-password; do
    if security delete-generic-password -s "$s" >/dev/null 2>&1; then
      echo "removed Keychain item $s"
    fi
  done
else
  echo
  echo "kept your settings, logs and Keychain items:"
  echo "  $DATA"
  echo "rerun with --all to delete those too."
fi

echo
echo "now run:  brew uninstall direwolfv/tap/greythr-swipe"
