# Keyboard brightness HUD

This fork adds a classic 16-segment HUD for the built-in keyboard backlight.
The non-sandbox app enables **Keyboard Brightness HUD** by default; its setting
is independent of the display-brightness switch.

## Key presses only

Only an illumination up/down/toggle event (NX key types 21/22/23) arms this HUD.
The existing media-key tap recognizes native keys and the supplied hidutil
remapping. The tap needs Accessibility access for the particular app build;
Debug and Release builds have separate bundle IDs. Grant access to the running
build and restart it if the tap could not start.

When the private backlight setter is available, the app changes brightness
directly and consumes the illumination key press and its matching release.
This suppresses Apple's keyboard-brightness indicator, using the same approach
as the volume and display controls. Normal steps are 1/16; Option+Shift uses
1/64. Repeated up/down presses advance from the pending target during a fade;
a held toggle key toggles only once until released.

After a key press, the monitor reads the actual brightness at short intervals
for at most 600 ms to follow the hardware fade. Holding the key extends one
session, including at 0/100%; it does not queue additional timers or delay the
first display indefinitely. The HUD displays the measured level and retains
its existing hide/fade timing.

There is **no idle polling**. Launch, re-enable, wake, ambient-light changes,
idle dimming, and Control Center/System Settings sliders cannot start a keyboard
HUD. A late reading outside the key window is discarded before accessing the
backlight. Sleep, disable, inactive session, or read failure cancels pending
sampling; wake requires a new key press.

## Standard key mapping

[extras/com.local.KeyRemapping.plist](extras/com.local.KeyRemapping.plist) contains
the supplied, working launch-agent template with these exact pairs:

| HID source | HID destination |
| --- | --- |
| `0xC000000CF` | `0xFF00000009` |
| `0x10000009B` | `0xFF00000008` |

The HUD automatically recognizes the resulting illumination keys. **If this
mapping is already installed, keep using it; nothing else needs installing.**
The app does not also remap or synthesize these keys. Each press is handled
either by volumeHUD or by macOS when interception is unavailable.

The template is included for setting up other Macs; the app does not install or
overwrite a LaunchAgent automatically. Its `hidutil --set` command replaces
`UserKeyMapping`. Before using it on a new setup, inspect
`hidutil property --get UserKeyMapping` and preserve any additional mappings.
Existing `com.local.KeyRemapping` installations should not be duplicated.

## Compatibility

Keyboard control uses private CoreBrightness `KeyboardBrightnessClient`, with
runtime selector/signature checks and enumeration of built-in keyboard IDs.
Only explicit key presses request a brightness change; the app does not change
automatic-brightness or idle-dimming preferences. External/RGB keyboards remain
out of scope.

If the setter is missing, the setting is disabled, or a write returns failure,
the original event reaches macOS so the brightness keys keep working. Readback
also verifies the final requested level after the fade; a mismatch or lost
connection disables interception for subsequent presses. A previously accepted
write is never replayed, to avoid double adjustments. Wake, re-enable, or app
restart allows interception to try again. In fallback mode Apple's indicator
can appear; the custom HUD continues when key-only readback is available.

Volume and display-brightness controls retain their existing behavior.
The keyboard monitor and settings remain excluded from the sandbox app.

## Build output

The shared Xcode project settings put build products inside the checkout:

- `build/Debug/volumeHUD.app` for a Debug build of the `volumeHUD` scheme.
- `build/Release/volumeHUD.app` for Release.
- `build/Debug-Sandbox/volumeHUD.app` or `build/Release-Sandbox/volumeHUD.app`
  for the sandbox target, keeping its identically named app separate.

Intermediate build files go to `build/Intermediates.noindex`. The existing
`.gitignore` excludes `build/`. These defaults apply to Xcode and `xcodebuild`;
explicit command-line output-setting overrides take precedence.

## Verification

The preceding key-only version compiled and worked on the user's Mac. This
interception/build-output revision has been reviewed statically; the authoring
environment has no Xcode/macOS SDK or keyboard hardware.

Build the existing `volumeHUD` scheme once on the Mac, then check manually:

1. Leave the app idle for at least one minute. Change ambient lighting, allow
   idle dimming, and adjust the system keyboard-brightness slider: no keyboard HUD.
2. Press the remapped illumination keys: correct symbol and level, with repeated
   presses, hold, Option+Shift, and 0/100% boundaries. Each press changes
   brightness only once, and Apple's indicator stays hidden when interception
   works. If a toggle key is available, test off/on and a held toggle.
3. Stop pressing: the HUD fades and stays hidden. Sleep/wake and disable/re-enable
   the setting: no spontaneous HUD and no stale callback redisplay.
4. Disable Keyboard Brightness HUD: the original keys and Apple's indicator
   should work normally. Re-enable and verify interception resumes.
5. Confirm that volume and enabled display-brightness HUDs still work and that
   the app was generated in the project's `build/Debug` or `build/Release`.

Use the existing Xcode window. No simulators or UI-test suites. Stop a stalled
build; do not repeat an unchanged failing command. Address only a concrete
compiler error introduced by this revision.

## References

- [Apple media-key constants](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDSystem/IOKit/hidsystem/ev_keymap.h)
- [Apple key-remapping documentation](https://developer.apple.com/library/archive/technotes/tn2450/_index.html)
- [KeyboardBrightnessClient interface](https://github.com/rakalex/mac-brightnessctl/blob/main/KeyboardBrightnessClient.h)
