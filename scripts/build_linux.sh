#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
TARGET_DIR="$ROOT_DIR/target"

cd "$ROOT_DIR"
cargo build -p timetrace-bridge --release

cd "$APP_DIR"
if [[ ! -d linux ]]; then
  flutter create --platforms=linux --project-name timetrace_app . >/dev/null
fi
flutter pub get
flutter build linux --release

BUNDLE_DIR="$APP_DIR/build/linux/x64/release/bundle"
if [[ ! -d "$BUNDLE_DIR" ]]; then
  BUNDLE_DIR="$(find "$APP_DIR/build/linux" -type d -path '*/release/bundle' -print -quit)"
fi
if [[ -z "${BUNDLE_DIR:-}" || ! -d "$BUNDLE_DIR" ]]; then
  echo "Unable to locate Flutter Linux release bundle" >&2
  exit 1
fi

mkdir -p "$BUNDLE_DIR/lib"
cp "$TARGET_DIR/release/libtimetrace_bridge.so" "$BUNDLE_DIR/lib/libtimetrace_bridge.so"

printf '%s\n' "TimeTrace Linux bundle: $BUNDLE_DIR"
