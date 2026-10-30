# PIGEON EYE · Quest 3 (v0.1.0 MVP)

An AR HUD for Meta Quest 3, for messing about with friends: passthrough with a black + acid-green (#9ACD32) heads-up display. It is the headset sibling of the iPhone web app [PIGEON EYE](https://govconnew.github.io/pigeon-eye/).

**Rules:**
- Everything runs on the headset. There are no paid APIs and no uploads, and it works with no internet.
- There is **no gun or weapon detection** of any kind. The detector is limited to people and animals.

## What's in v0.1.0 (APK)

| Feature | Status |
|---|---|
| Passthrough full colour (OpenXR alpha-blend, Meta passthrough) | ✅ in APK |
| Compass tape HUD with waypoint and squad markers | ✅ heading is **relative** (Quest has no magnetometer); use **SET NORTH** in Settings while facing north |
| Person and animal detection from the **Passthrough Camera API** (Camera2 + `horizonos.permission.HEADSET_CAMERA`), using MediaPipe EfficientDet-Lite0 on-device | ✅ in APK; needs Horizon OS **v74+** |
| Boxes with `~distance` (pinhole, or shoulder width when cut off) and bearing | ✅ |
| Stick-figure pose skeleton, HANDS: 2/1 visible, HANDS UP / 1 HAND UP (hysteresis + 0.5 s hold) | ✅ MediaPipe Pose Landmarker lite, up to 4 people, One Euro filter + identity tracking + prediction (ported from web v1.3.0) |
| Heading-up minimap: your 6DoF path, waypoints, cleared rooms, contacts, squad | ✅ |
| WAYPOINT (right trigger), MARK CLEAR (A) | ✅ |
| Settings: detection, skeleton, low power, minimap, big text, squad, callsign, SET NORTH, SQUAD SYNC, clear, demo feed | ✅ saved on the headset |
| Squad link over local Wi-Fi | ✅ UDP broadcast on port 47474, Quest↔Quest only (see limitations) |
| Demo feed (synthetic person and dog) to try the HUD without a camera | ✅ |

### Controls (Quest controllers)
- **Right trigger:** drop a waypoint where you look (on the floor, up to 10 m away, otherwise 3 m ahead).
- **A:** MARK CLEAR (marks a room at your position).
- **X:** big text.
- **B or ≡ (menu):** open or close Settings. In Settings, use the **thumbstick** up/down to move and the **trigger** to select.

## Install on your Quest 3 (SideQuest)

1. Turn on Developer Mode: in the Meta Horizon phone app, go to Devices → your Quest → Developer Mode → On. Then reboot the headset.
2. Connect the headset to your laptop with USB-C. In the headset, accept **Allow USB debugging** (tick "Always allow").
3. Download `pigeon-eye-quest-0.1.0.apk` from the [Releases page](https://github.com/GOVCONnew/pigeon-eye-quest/releases).
4. Install it:
   - **SideQuest (Advanced installer):** check the dot at the top-left is green, click the **"Install APK file from folder"** icon (box with a down arrow) and pick the APK.
   - **Meta Quest Developer Hub:** Device Manager → Apps → **Add Build** → choose the APK.
   - **Command line:** `adb install -r pigeon-eye-quest-0.1.0.apk`
5. On the headset, open **Library → Unknown Sources → Pigeon Eye**.
6. On first launch, **allow Camera / Headset camera access**. If you denied it, go to Settings → Privacy → App permissions → Pigeon Eye. The HUD status line reads `vision: RUNNING cam …` when detection is live.
7. **Squad:** every headset must be on the same Wi-Fi. Stand on the same spot facing the same way, then choose **SQUAD SYNC** in Settings on each headset. Pick different **Callsigns**.

The release APK is debug-signed, so it's for sideloading only and not for the Store.

## WebXR fallback (no install)
Open https://govconnew.github.io/pigeon-eye-quest/ in the **Meta Quest Browser** and tap **ENTER AR**. You get a passthrough HUD with a compass tape and a minimap with path, waypoints (trigger), MARK CLEAR (grip) and SET NORTH (A/X). It has **no camera detection**, because browsers can't access the Quest camera.

## Build it yourself

This repo is a **Godot 4.4.1** project plus a small Kotlin Android plugin. Unity could not be used on the build box (see Blockers).

```
android-plugin/   Kotlin Godot plugin "PigeonVision": Camera2 passthrough camera → MediaPipe detector + pose → JSON to Godot
godot/            Godot project: scripts/main.gd (app), scripts/hud.gd (HUD painter), scripts/pelogic.gd (pure logic), tests/
webxr/            Browser fallback (three.js, vendored)
build.sh          Builds the plugin, runs tests and exports the APK
```

To build on Windows, macOS or Linux:
1. Install **Godot 4.4.1** (standard build, not .NET) and its **export templates** (Editor → Manage Export Templates → Download).
2. Install **Android Studio** or the command-line tools, plus **JDK 17**. Then in Godot, set Editor Settings → Export → Android: Java SDK path, Android SDK path and the debug keystore.
3. Open `godot/` in Godot, then choose Project → **Install Android Build Template**.
4. Build the plugin: `cd android-plugin && gradle :pigeonvision:assembleRelease` (or open it in Android Studio). Copy `pigeonvision/build/outputs/aar/pigeonvision-release.aar` to `godot/addons/pigeonvision/bin/`.
5. In Project → Export, choose the **Quest 3** preset → Export Project, or use **One-click deploy** with the headset plugged in.

To run the tests: `godot --headless --xr-mode off --path godot -s tests/run_tests.gd`. The desktop demo is `godot --path godot -- --demo` (keys: W waypoint, C clear, M settings, ←/→ turn).

## Limitations (v0.1.0)
- **Not yet run on a real headset.** It was built and unit-tested on Linux without a Quest. Expect a tuning pass (camera-to-eye alignment, frame rate).
- **Box alignment:** boxes and skeletons are projected with the camera intrinsics, assuming the camera looks the same way as your eyes. Quest 3's cameras sit a few cm off-axis and the camera frame is about 30–60 ms old, so close-up boxes can sit slightly off. The fix is to use `LENS_POSE_*` plus head-pose history.
- **Heading:** heading is relative to where you started until you SET NORTH. There is no GPS on Quest, so the minimap uses headset tracking (accurate, but per session).
- **Squad:** the link is Quest↔Quest UDP over the same Wi-Fi and needs SQUAD SYNC to share a frame. It does not talk to the iPhone app's WebRTC link yet. Some routers and guest networks block broadcast.
- **Performance:** detection runs as fast as the headset allows (or ≤7 Hz in low power). YUV→RGB conversion is in plain Kotlin and could move to GPU.
- **Passthrough Camera API:** needs Horizon OS v74 or newer. On older OS versions the status shows `NO PASSTHROUGH CAMERA` and the HUD still works.

## Licences
- Godot (MIT)
- Godot OpenXR Vendors plugin (MIT)
- MediaPipe Tasks and models EfficientDet-Lite0 / Pose Landmarker lite (Apache-2.0)
- three.js (MIT)
