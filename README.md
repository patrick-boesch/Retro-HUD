# Retro HUD

**Retro HUD by Patrick Bösch, based on volumeHUD by Danny Stewart.**

A macOS menu-bar app that restores the classic volume, display-brightness and
keyboard-brightness overlays. This repository continues development under the
Retro HUD name. The original volumeHUD authorship and MIT license are preserved.

## Menu bar

Click the Retro HUD icon to open the native macOS menu. Checked items are enabled.

- **Open at Login**
- **HUD**
  - **Brightness**
  - **Keyboard**
  - **Volume**
- **Follow Mouse**
- **Relative Position**
- **Launch Notification**
- **About Retro HUD**
- **Quit Retro HUD**

There are no settings in the About panel. It uses macOS's standard About panel
and displays Patrick Bösch's authorship, Danny Stewart's original work, version,
build and project links.

Disabling a HUD stops its custom monitoring and returns its keys to macOS.
Volume and Keyboard are enabled by default; Brightness is opt-in. The sandbox
target exposes only Volume; its Brightness and Keyboard menu items are disabled.

Follow Mouse selects the mouse's screen for volume and keyboard overlays.
Brightness overlays stay on the display being controlled. Relative Position
uses 17% of screen height; disabling it uses the existing fixed bottom offset.
The optional launch notification is off by default.

## Brightness keys

| Keys | Behavior |
| --- | --- |
| Display brightness ± | Existing built-in display control |
| Shift + display brightness ± | Compatible external display |
| Option + Shift + display brightness ± | Existing fine steps for the built-in display |
| Keyboard illumination keys | Keyboard brightness and classic keyboard HUD |

For multiple external monitors, the compatible external display under the mouse
has priority. Supported external hardware uses native DisplayServices or DDC/CI.
Keyboard overlays appear only after illumination-key presses; there is no idle
keyboard polling. Supported intercepted controls suppress Apple's indicator.

See [keyboard behavior and mapping](KEYBOARD-HUD.md) and
[external-display compatibility](EXTERNAL-DISPLAY-BRIGHTNESS.md).
The supplied [key-remapping template](extras/com.local.KeyRemapping.plist) remains
available; existing working mappings need no reinstall.

## Build and upgrade

Open **RetroHUD.xcodeproj** and select the **RetroHUD** scheme.
The application is generated inside the checkout:

- Debug: `build/Debug/Retro HUD.app`
- Release: `build/Release/Retro HUD.app`
- Sandbox: `build/Debug-Sandbox/Retro HUD.app` or `build/Release-Sandbox/Retro HUD.app`

The source folder, shared schemes, icon bundle, editor workspace and lint
configuration use the RetroHUD name. Your checkout's enclosing folder can keep
its existing name. Quit the older running app before launching the renamed build.

The technical bundle identifiers deliberately stay unchanged to retain the
existing defaults domain, login registration and app identity. The old
`volumeHUDFollowsMouse` preference is migrated to `hudFollowsMouse`; other HUD
and position preferences retain their values. macOS manages permissions and may
ask to approve a newly signed or moved build.

The display-UUID C build error is corrected by importing **ColorSync** and linking
**ColorSync.framework** in the full app target. The previous declaration was not
provided by CoreGraphics.

## Repository name

To rename the repository, open its GitHub
**Settings → General**, change **Repository name** to `RetroHUD`, then choose
**Rename**. Afterward update a local checkout with:

```sh
git remote set-url origin https://github.com/patrick-boesch/RetroHUD.git
```

The current [repository link](https://github.com/patrick-boesch/volumeHUD) remains
valid through GitHub's redirect after renaming. The app no longer polls the
original author's releases or directs users to install the original Homebrew app.

## Verification

The editing environment has no Xcode/macOS SDK. The ColorSync declaration was
checked against its SDK header; the full app requires a Mac build and a manual
menu/hardware check.

Build the existing RetroHUD scheme once, then verify menu checkmarks, persistence,
all three HUD toggles, Open at Login, placement, About and Quit. Check that
disabled controls use macOS behavior and that Shift still controls a compatible
external monitor. 
The portable DDC response test can run without a macOS SDK:

```sh
mkdir -p build
cc -std=c11 -Wall -Wextra -Werror Tests/DDCBrightnessPacketTests.c -o build/ddc-packet-tests
./build/ddc-packet-tests
```

## Credits and license

Retro HUD additions: **Patrick Bösch, 2026**. Original
[volumeHUD](https://github.com/dannystewart/volumeHUD): **Danny Stewart, 2025**.
Released under the [MIT License](LICENSE). MonitorControl-derived transport
notices are included in [ThirdPartyNotices.txt](RetroHUD/ThirdPartyNotices.txt)
and bundled with the application.
