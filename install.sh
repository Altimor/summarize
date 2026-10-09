#!/usr/bin/env bash
# Summarize for Hammerspoon: press ⌘⌥⌃⇧2 to ask an AI about your selection or your screen.
#   curl -fsSL https://flocrivello.com/summarize/install.sh | bash
set -euo pipefail

ZIP_URL="https://flocrivello.com/summarize/summarize.zip"
HS_DIR="$HOME/.hammerspoon"
DEST="$HS_DIR/summarize"
INIT="$HS_DIR/init.lua"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

[[ "$(uname -s)" == "Darwin" ]] || { echo "Summarize needs macOS (it runs in Hammerspoon)." >&2; exit 1; }

# 1. Hammerspoon
if [[ -d "/Applications/Hammerspoon.app" || -d "$HOME/Applications/Hammerspoon.app" ]]; then
  say "Hammerspoon is installed."
elif command -v brew >/dev/null 2>&1; then
  say "Installing Hammerspoon with Homebrew…"
  brew install --cask hammerspoon
else
  say "Installing Hammerspoon…"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  URL="$(curl -fsSL https://api.github.com/repos/Hammerspoon/hammerspoon/releases/latest \
        | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
  [[ -n "$URL" ]] || { echo "Couldn't find the latest Hammerspoon release. Install it from https://www.hammerspoon.org and run this again." >&2; exit 1; }
  curl -fsSL "$URL" -o "$TMP/hs.zip"
  ditto -x -k "$TMP/hs.zip" "$TMP/app"
  if [[ -w /Applications ]]; then APPS=/Applications; else APPS="$HOME/Applications"; mkdir -p "$APPS"; fi
  ditto "$TMP/app/Hammerspoon.app" "$APPS/Hammerspoon.app"
  say "Hammerspoon installed in $APPS."
fi

# 2. The Summarize module (replaces an older copy)
say "Downloading Summarize…"
mkdir -p "$HS_DIR"
WORK="$(mktemp -d)"
curl -fsSL "$ZIP_URL" -o "$WORK/summarize.zip"
ditto -x -k "$WORK/summarize.zip" "$WORK/unzipped"
[[ -f "$WORK/unzipped/summarize/init.lua" ]] || { echo "The download looks incomplete. Try again." >&2; exit 1; }
rm -rf "$DEST"
mv "$WORK/unzipped/summarize" "$DEST"
rm -rf "$WORK"

# 3. Optional: Caps Lock as a Hyper key (asks first; the answer comes from the keyboard even under curl | bash)
CAPS=0
if [[ -d "/Applications/Karabiner-Elements.app" ]]; then
  echo "Karabiner-Elements is installed, so Caps Lock is left alone (set up Hyper there if you haven't)."
elif { exec 3</dev/tty; } 2>/dev/null; then
  echo
  echo "Hyper means pressing ⌘⌥⌃⇧ together, which is hard with one hand."
  printf '\033[1mTurn Caps Lock into a Hyper key, so Caps Lock+2 runs Summarize? [y/N] \033[0m'
  read -r -u 3 ANSWER || ANSWER=""
  exec 3<&-
  [[ "$ANSWER" =~ ^[Yy] ]] && CAPS=1
fi
if [[ "$CAPS" == 1 ]]; then
  LINE='require("summarize").start({ capsLockHyper = true })'
else
  LINE='require("summarize").start()'
fi

# 4. Load it from ~/.hammerspoon/init.lua (once; a re-run updates the line)
if [[ -f "$INIT" ]]; then
  if ! grep -qF "$LINE" "$INIT"; then
    cp "$INIT" "$INIT.backup-$(date +%Y%m%d-%H%M%S)"
    if grep -q 'require("summarize").start(' "$INIT"; then
      grep -v 'require("summarize").start(' "$INIT" > "$INIT.tmp" && mv "$INIT.tmp" "$INIT"
    else
      printf '\n-- Summarize (⌘⌥⌃⇧2): https://flocrivello.com/summarize\n' >> "$INIT"
    fi
    printf '%s\n' "$LINE" >> "$INIT"
  fi
else
  printf -- '-- Summarize (⌘⌥⌃⇧2): https://flocrivello.com/summarize\n%s\n' "$LINE" > "$INIT"
fi

# 5. Start / reload Hammerspoon
open -a Hammerspoon || true
if command -v hs >/dev/null 2>&1; then
  sleep 2
  hs -t 5 -c 'hs.reload()' >/dev/null 2>&1 || true
  RELOADED=1
else
  RELOADED=0
fi

echo
say "Summarize is installed."
echo "Next:"
if [[ "$RELOADED" == 0 ]]; then
  echo "  • If Hammerspoon was already running: click its menu bar icon → Reload Config."
fi
echo "  • Give Hammerspoon Accessibility access (it asks; or System Settings → Privacy & Security → Accessibility)."
echo "  • For screenshot mode, also allow it under Privacy & Security → Screen & System Audio Recording."
if [[ "$CAPS" == 1 ]]; then
  echo "  • Press Caps Lock+2 (or ⌘⌥⌃⇧2). The first time, it asks for an OpenRouter API key: https://openrouter.ai/keys"
else
  echo "  • Press ⌘⌥⌃⇧2 (Hyper-2). The first time, it asks for an OpenRouter API key: https://openrouter.ai/keys"
fi
