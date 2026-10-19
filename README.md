# VolMix

A macOS menu bar app that sets the volume of each app separately (0–100% plus mute).
Requires macOS 15 or later and Xcode 16 or later (Swift 6 toolchain). Verified building with Xcode 26.0.1 on macOS 26.3.

## Build and run

```bash
cd VolMix
scripts/build-app.sh          # builds the app and installs it in /Applications
```

After that, open VolMix like any app: from Launchpad, Spotlight or Finder → Applications.
Rebuilding replaces the installed copy; quit VolMix first so the new version takes over.

A three-bar icon appears in the menu bar. The first time you change an app's volume, macOS asks
for permission to record system audio; click **Allow**. If you dismissed it, enable VolMix in
**System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only**,
then quit and reopen the app.

The script signs ad-hoc by default, so macOS may ask for the permission again after each rebuild.
To avoid that, sign with your own certificate:

```bash
SIGN_IDENTITY="Apple Development: you@example.com" scripts/build-app.sh
```

To edit the code in Xcode, run `open Package.swift`. Run it via the script rather than Xcode's
Run button: the audio permission only works from a real `.app` bundle with `Support/Info.plist`.

## How it works

| File | Role |
| --- | --- |
| `VolMixApp.swift` | `MenuBarExtra` window: one row per app with icon, slider, percentage and mute. Launch-at-login toggle. |
| `AudioController.swift` | Lists apps, stores each app's volume in `UserDefaults` by bundle ID, and keeps one tap per app that isn't at 100%. |
| `AudioProcesses.swift` | Reads Core Audio's process list and groups helper processes under their app (Safari's WebKit process, Chrome Helper, etc.). |
| `ProcessTap.swift` | The audio engine for one app. |
| `CoreAudioHelpers.swift` | Small wrappers for reading Core Audio properties. |
| `scripts/make-icon.swift` | Draws the app icon and writes `Support/AppIcon.icns`; delete that file and rebuild to regenerate it. |

For each app whose volume you change, `ProcessTap`:

1. Creates a **Core Audio process tap** (`CATapDescription`, macOS 14.4+) on that app's audio
   processes with `muteBehavior = .mutedWhenTapped`, so the app's normal output goes silent.
2. Creates a **private aggregate device** combining the current output device and the tap.
3. Runs an **IOProc** that copies the tap's audio to the output device multiplied by the gain,
   ramping across each buffer so slider moves don't click.

Apps at 100% and unmuted have no tap at all, so they play exactly as before with no extra latency.
Taps are rebuilt when the default output device changes or when an app starts new audio
processes (for example a new browser tab with sound).

## Known limits

- No boost above 100% yet; the gain math supports it, but it would need a limiter to avoid clipping.
- A tapped app keeps the output device running while it has audio open, even when silent.
- Audio is mixed to stereo, so multichannel (5.1) output from a tapped app is folded to L/R.
- Grouping helper processes uses the private `responsibility_get_pid_responsible_for_pid` call
  (looked up at runtime). It's fine for personal use but would block Mac App Store submission.
