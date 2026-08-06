#!/usr/bin/env bash
#
# Compass installer for macOS
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/jtrefon/compass/main/install.sh | bash
#
# What it does:
#   1. Verifies macOS + Apple Silicon (Compass requires both)
#   2. Downloads the latest compass.dmg from GitHub Releases
#   3. Mounts the DMG and copies Compass.app into /Applications
#   4. Clears download provenance xattrs so the first launch
#      is not blocked by Gatekeeper (curl downloads are exempt
#      from the browser-download quarantine, and this keeps it that way)
#
# The script is open source and lives in the Compass repository:
#   https://github.com/jtrefon/compass/blob/main/install.sh
# Read it before you run it. That's the point of open source.

set -euo pipefail

REPO="jtrefon/compass"
APP_NAME="Compass"
DMG_URL="https://github.com/${REPO}/releases/latest/download/compass.dmg"
INSTALL_DIR="/Applications"
REQUIRED_MAJOR_MACOS="26"

warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
info() { printf '\033[1;36m%s\033[0m\n' "$*"; }
error() { printf '\033[1;31m%s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m%s\033[0m\n' "$*"; }

if [[ "$(uname)" != "Darwin" ]]; then
  error "Compass is a macOS app. Run this on a Mac."
  exit 2
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  error "Compass requires Apple Silicon (M-series). This Mac is $(uname -m)."
  exit 3
fi

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if (( macos_major < REQUIRED_MAJOR_MACOS )); then
  error "Compass requires macOS ${REQUIRED_MAJOR_MACOS}+. This Mac runs macOS $(sw_vers -productVersion)."
  exit 4
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  error "hdiutil not found. This tool ships with macOS; something is wrong with this system."
  exit 5
fi

workdir="$(mktemp -d)"
cleanup() {
  if [[ -n "${mountpoint:-}" ]]; then
    hdiutil detach "$mountpoint" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

if [[ -d "${INSTALL_DIR}/${APP_NAME}.app" ]]; then
  warn "${APP_NAME} is already installed in ${INSTALL_DIR}."
  if [[ ! -t 0 ]]; then
    error "Not an interactive terminal. Remove ${INSTALL_DIR}/${APP_NAME}.app first, then re-run."
    exit 6
  fi
  read -r -p "Replace it with the latest release? [y/N] " response
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    info "Installation cancelled. Existing copy left untouched."
    exit 0
  fi
  info "Removing existing installation..."
  rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
fi

info "Downloading ${APP_NAME} (latest release)..."
curl -fsSL "$DMG_URL" -o "$workdir/compass.dmg"

info "Mounting disk image..."
mountpoint="$workdir/mnt"
mkdir -p "$mountpoint"
hdiutil attach "$workdir/compass.dmg" -nobrowse -quiet -mountpoint "$mountpoint"

app_path="$mountpoint/${APP_NAME}.app"
if [[ ! -d "$app_path" ]]; then
  error "Could not find ${APP_NAME}.app inside the downloaded disk image. The release may be incomplete."
  exit 7
fi

info "Installing ${APP_NAME}.app into ${INSTALL_DIR}..."
ditto "$app_path" "${INSTALL_DIR}/${APP_NAME}.app"

# Clear download-provenance xattrs (quarantine, provenance, ...) recursively.
# Harmless when absent; essential on macOS Sequoia and later, where quarantine
# on the bundle would trigger a Gatekeeper block on first launch.
xattr -cr "${INSTALL_DIR}/${APP_NAME}.app" 2>/dev/null || true

ok "${APP_NAME} installed at ${INSTALL_DIR}/${APP_NAME}.app"

if codesign --verify --deep --strict "${INSTALL_DIR}/${APP_NAME}.app" >/dev/null 2>&1; then
  ok "Code signature verified."
else
  warn "Code signature check did not pass. The app is ad-hoc signed; see the release notes if it won't launch."
fi

if [[ -t 0 ]]; then
  read -r -p "Launch ${APP_NAME} now? [Y/n] " launch
  if [[ ! "$launch" =~ ^[Nn]$ ]]; then
    open "${INSTALL_DIR}/${APP_NAME}.app"
  fi
else
  info "Run 'open /Applications/${APP_NAME}.app' to launch."
fi

ok "Done."
