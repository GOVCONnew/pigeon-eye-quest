#!/usr/bin/env bash
# Builds build/pigeon-eye-quest-<ver>.apk on Linux/macOS. Needs: Godot 4.4.1 (+ export templates), JDK 17, Android SDK
# (platform-tools, build-tools 34, platforms 34, ndk 23.2.8568313, cmake 3.10.2), gradle 8.x (plugin build only).
# Env: GODOT (path to Godot 4.4.1 binary), JAVA_HOME, ANDROID_HOME. Godot editor settings must point at the SDK/JDK/debug keystore.
set -euo pipefail
cd "$(dirname "$0")"
GODOT=${GODOT:-godot}
( cd android-plugin && echo "sdk.dir=$ANDROID_HOME" > local.properties && gradle -q :pigeonvision:assembleRelease )
cp android-plugin/pigeonvision/build/outputs/aar/pigeonvision-release.aar godot/addons/pigeonvision/bin/
if [ ! -f godot/android/.build_version ]; then
  TPL=${TPL:-"$HOME/.local/share/godot/export_templates/4.4.1.stable/android_source.zip"}
  mkdir -p godot/android/build && unzip -qo "$TPL" -d godot/android/build && printf 4.4.1.stable > godot/android/.build_version && touch godot/android/build/.gdignore
fi
"$GODOT" --headless --xr-mode off --path godot -s tests/run_tests.gd
mkdir -p build && "$GODOT" --headless --path godot --export-debug "Quest 3" ../build/pigeon-eye-quest-0.1.0.apk
ls -la build/*.apk
