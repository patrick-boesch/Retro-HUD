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

After a key press, the monitor reads the actual brightness at short intervals
for at most 600 ms to follow macOS's hardware fade. Holding the key extends one
session, including at 0/100%; it does not queue additional timers or delay the
first display indefinitely. The existing HUD hide/fade timing remains in use.

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
The app does not also remap or synthesize these keys, so each press continues to
be handled once by macOS.

The template is included for setting up other Macs; the app does not install or
overwrite a LaunchAgent automatically. Its `hidutil --set` command replaces
`UserKeyMapping`. Before using it on a new setup, inspect
`hidutil property --get UserKeyMapping` and preserve any additional mappings.
Existing `com.local.KeyRemapping` installations should not be duplicated.

## Compatibility

Readback uses private CoreBrightness `KeyboardBrightnessClient`, with runtime
selector/signature checks and enumeration of built-in keyboard IDs. No
backlight, automatic-brightness, or idle-dimming settings are written.
Unsupported backlights fail quietly and can be retried on the next key press.
External/RGB keyboards remain out of scope.

The system keyboard HUD may also appear because illumination keys are passed
through. This patch does not change volume or display-brightness controls.
The keyboard monitor and settings remain excluded from the sandbox app.

## Verification

The preceding version compiled on the user's Mac and successfully displayed
keyboard brightness. This key-only revision has been reviewed statically; the
authoring environment has no Xcode/macOS SDK or keyboard hardware.

Build the existing `volumeHUD` scheme once on the Mac, then check manually:

1. Leave the app idle for at least one minute. Change ambient lighting, allow
   idle dimming, and adjust the system keyboard-brightness slider: no keyboard HUD.
2. Press the remapped illumination keys: correct symbol and level, with repeated
   presses, hold, and 0/100% boundaries. Each press changes brightness only once.
3. Stop pressing: the HUD fades and stays hidden. Sleep/wake and disable/re-enable
   the setting: no spontaneous HUD and no stale callback redisplay.
4. Confirm that volume and enabled display-brightness HUDs still work.

Use the existing Xcode window. No simulators or UI-test suites. Stop a stalled
build; do not repeat an unchanged failing command. Address only a concrete
compiler error introduced by this revision.

## References

- [Apple media-key constants](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDSystem/IOKit/hidsystem/ev_keymap.h)
- [Apple key-remapping documentation](https://developer.apple.com/library/archive/technotes/tn2450/_index.html)
- [KeyboardBrightnessClient interface](https://github.com/rakalex/mac-brightnessctl/blob/main/KeyboardBrightnessClient.h)
