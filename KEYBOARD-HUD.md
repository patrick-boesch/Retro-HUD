# Keyboard brightness HUD

This fork adds a third classic HUD for the Mac's built-in keyboard backlight.
The non-sandbox app enables **Keyboard Brightness HUD** by default; its setting
is independent of the display-brightness switch. It uses the existing material,
16-segment bar, display-placement preference, and hide/fade timing, with the
keyboard-illumination symbol (`light.max`).

## Behavior

- Read the actual built-in backlight level through dynamically loaded
  CoreBrightness `KeyboardBrightnessClient`. Enumerate keyboard IDs and check
  method signatures before calling them. Unsupported hardware/API shapes disable
  this monitor instead of inventing a value or changing another setting.
- Poll every 250 ms with 50 ms timer tolerance while enabled and awake. Query
  extra dimming status only when the brightness changes or a keyboard-light key
  is pressed. Stop polling on sleep, display sleep, inactive user session,
  disabling the feature, or read failure. Reconnect on wake or re-enable.
- Recognize illumination up/down/toggle events (NX key types 21/22/23) through
  the existing event tap. Pass those events through unchanged and read back after
  macOS has had time to handle them. Repeats and presses at the boundaries can
  refresh the HUD when the tap has Accessibility access.
- Also observe actual changes made through Control Center or System Settings.
  This path does not need key interception. Without Accessibility permission,
  a press that leaves the value unchanged cannot be detected.
- Start and resume with a silent baseline. Filter OS-reported idle/suppressed
  backlight states and their restoration fades. No brightness values,
  auto-brightness settings, or idle-dimming settings are written.

## Limitations

This is a read-only HUD addition. It does **not** suppress the keyboard's native
system HUD, so both indicators may appear. External/RGB keyboards are out of
scope. CoreBrightness is a private API and can change between macOS releases.
Unflagged automatic brightness changes cannot reliably be distinguished from
slider changes and may also show the HUD. If hardware becomes unavailable,
toggle the setting off/on or wake the Mac to retry.

The existing sandbox target excludes this monitor's implementation and settings.
No new entitlement, dependency, background helper, or global key shortcut is added.

## Validation on a Mac

The authoring environment has no Xcode/macOS SDK or keyboard hardware. This
change has been reviewed statically; compilation and hardware behavior remain
unverified. Keep the pull request in draft until the following check is complete.

1. Open the existing project in Xcode 26 or newer and build the `volumeHUD`
   scheme for **My Mac**. Also compile the `volumeHUD (Sandbox)` scheme to
   confirm the conditional source/settings exclusion. Use the existing Xcode
   window. Do not launch simulators or set up a UI-test suite.
2. Quit any installed volumeHUD instance before running this fork. Confirm that
   launch shows no keyboard HUD. A second launch opens settings; all rows should
   fit, and the keyboard switch should be enabled independently of display HUD.
3. On a Mac with a supported backlit keyboard, change keyboard brightness via
   its available illumination controls and the system slider. Check the symbol,
   16-segment level, 0/100% boundaries, key repeat, and fade-out. Test fine steps
   if the Mac's controls support them. Confirm that the hardware still responds.
4. Disable/re-enable the switch, restart, and sleep/wake. Check preference
   persistence, no startup/wake flash, no repeated idle-dimming HUD, and no
   updates while disabled. Check placement on an external display.
5. Confirm that volume/mute and display brightness retain their existing behavior.
   If available, check an unsupported desktop/external keyboard: no false HUD or
   blocked controls should result.

Use one build attempt per scheme. If a build fails, address the concrete error;
do not repeat an unchanged command. Stop a stalled build and report its last
useful output. Hardware behavior is checked manually, not through test loops.

## API references

- [Apple's media-key constants](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDSystem/IOKit/hidsystem/ev_keymap.h)
- [KeyboardBrightnessClient interface used by mac-brightnessctl](https://github.com/rakalex/mac-brightnessctl/blob/main/KeyboardBrightnessClient.h)

These establish key codes and API shape; they are not proof of compatibility
with the particular Mac or macOS version under test.
