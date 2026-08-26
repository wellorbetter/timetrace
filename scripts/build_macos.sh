#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build_macos.sh must run on macOS" >&2
  exit 1
fi

cd "$APP"
if [[ ! -d macos ]]; then
  echo "==> Generating Flutter macOS runner"
  flutter create --platforms=macos --project-name timetrace_app .
  # `flutter create` adds a template test that references MyApp, while this
  # existing project boots TimetraceApp. Keep only the project's real tests.
  rm -f test/widget_test.dart
fi

# TimeTrace is a desktop activity tracker. The default Flutter macOS template
# enables App Sandbox, which blocks observing other processes, direct access to
# the user's Application Support directory, and LaunchAgent management. Keep
# sandboxing off for this system utility; release distribution will still use
# normal code signing/notarization.
for entitlements in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  if [[ -f "$entitlements" ]]; then
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.app-sandbox false" "$entitlements" 2>/dev/null || true
  fi
done

flutter pub get
flutter analyze --no-fatal-infos
flutter test

cd "$ROOT"
echo "==> Building Rust bridge"
cargo build -p timetrace-bridge --release

cd "$APP"
echo "==> Building Flutter macOS app"
flutter build macos --release

APP_PATH="$(find build/macos/Build/Products/Release -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "Unable to locate built .app bundle" >&2
  exit 1
fi

FRAMEWORKS="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
cp "$ROOT/target/release/libtimetrace_bridge.dylib" \
  "$FRAMEWORKS/libtimetrace_bridge.dylib"

# Copying a dylib changes the app bundle after Flutter/Xcode's signing step.
# Ad-hoc signing is sufficient for local/CI validation; release notarization
# can replace this with a Developer ID identity later.
codesign --force --sign - "$FRAMEWORKS/libtimetrace_bridge.dylib"
codesign --force --deep --sign - "$APP_PATH"

codesign --verify --deep --strict "$APP_PATH"
test -f "$FRAMEWORKS/libtimetrace_bridge.dylib"

# Assert the final bundle really carries the non-sandboxed utility entitlement.
ENTITLEMENTS_OUT="$(mktemp)"
codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_OUT" 2>/dev/null || true
if grep -A1 -q 'com.apple.security.app-sandbox' "$ENTITLEMENTS_OUT" && \
   grep -A1 'com.apple.security.app-sandbox' "$ENTITLEMENTS_OUT" | grep -q '<true/>'; then
  echo "Final app unexpectedly has App Sandbox enabled" >&2
  exit 1
fi
rm -f "$ENTITLEMENTS_OUT"

echo "==> macOS bundle ready: $APP_PATH"
