# External display brightness

Enable **HUD → Brightness** in the menu bar and grant Accessibility access to the running
Retro HUD build. The feature is available in the non-sandbox app.

| Keys | Target |
| --- | --- |
| Brightness up/down | Existing built-in display behavior |
| Shift + brightness up/down | Compatible external display, in 1/16 steps |
| Option + Shift + brightness up/down | Existing fine-step behavior for the built-in display |

When multiple external displays are connected, the screen under the pointer is
tried first, followed by other external screens in stable display-ID order.
The first display with a readable hardware-brightness interface is selected.
A held key keeps that candidate order until release, even if Shift is released
or the pointer moves. Both the handled down and matching up event are consumed.
The classic brightness HUD appears on the display that was successfully changed,
using its measured level.

If no external screen is connected, the existing brightness-key behavior remains.
When external screens are present but none supports hardware control, Shift
does not change a screen or display a false success HUD. A failed external write
is never redirected to the built-in display or another monitor. The native
volume and keyboard-brightness controls keep their existing routes.

## Hardware compatibility

The backend tries Apple's DisplayServices first (for supported Apple/native
external displays), then DDC/CI luminance VCP `0x10`:

- Apple Silicon: IOAVService over the available external display transport.
- Intel: IOKit framebuffer I2C, with the bus's supported reply transaction type.

DDC/CI must be enabled in the monitor's own settings when that option exists.
The monitor, cable, adapter and dock must allow hardware brightness commands.
Some HDMI paths, docks, virtual displays, DisplayLink devices and HDR modes
will not expose usable control. Compatibility is established from valid reads;
writes are followed by readback. There is no software dimming fallback.

Display-to-service mapping uses the registry location or an unambiguous hardware
identity. Identical displays without distinguishable location/identity are
skipped instead of guessing. Handles retain a display UUID and are rechecked
before access. Discovery/transport references and their MIT license are included
in [ThirdPartyNotices.txt](RetroHUD/ThirdPartyNotices.txt), also bundled with the app.

## Responsiveness and lifecycle

A dedicated serial queue owns hardware handles and runs all discovery, DDC
transfers and bounded readback retries. The event tap only records a request.
Pending repeats are coalesced as a composition of clamped steps, preserving
direction reversals at minimum/maximum brightness without an unbounded queue.
Requests expire 800 ms after their latest press.

There is no idle polling or automatic brightness synchronization. Disconnect,
display reconfiguration, sleep, session changes, disabling Brightness HUD and
stopping the interceptor cancel pending work and invalidate stale HUD callbacks.
A hardware operation already in flight may finish; pending requests and stale
HUD completions are discarded. Failed devices can be retried after
reconfiguration, wake, toggling Brightness HUD, or app restart.

## Verification

The authoring environment has no macOS SDK/Xcode or monitor hardware.
Portable C protocol checks cover checksums, response type/status/VCP, zero maxima,
out-of-range values, endpoints, and maxima greater than 255.

Build the existing `RetroHUD` scheme once on the Mac and check manually:

1. Enable Brightness HUD. Shift + up/down changes a supported external monitor
   and shows the classic HUD there; plain keys and Option+Shift retain their behavior.
2. Hold up/down, reverse direction, and reach 0/100%. Release Shift before the
   brightness key: the held press must remain on its external route.
3. With two monitors, move the pointer and use a new press to select the preferred
   compatible screen. No other screen should change after a failed write.
4. Disconnect/reconnect, sleep/wake and disable/re-enable the setting. No delayed
   writes or spontaneous HUD; volume and keyboard-brightness HUDs still work.
5. Try an unsupported display or disable its DDC/CI option: no false success HUD.

Build products still go to `build/Debug/Retro HUD.app` and
`build/Release/Retro HUD.app`. Use the existing Xcode window; no simulators or UI
test loops. Stop stalled verification and report the concrete failure.

Portable protocol check, from the project root:

```sh
mkdir -p build
cc -std=c11 -Wall -Wextra -Werror Tests/DDCBrightnessPacketTests.c -o build/ddc-packet-tests
./build/ddc-packet-tests
```
