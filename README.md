# Rainy Desktop

A native macOS live wallpaper: your actual desktop picture behind rain on
fogged glass, running on Metal. Drops slide and leave clear trails through
the condensation, with occasional HDR lightning. A floating 3D radio widget
shows what's playing. A companion Chrome extension carries the same rain and
a liquid-glass look into your browser.

## Features

- **Rain on glass wallpaper:** a Metal port of the "Heartfelt" rain shader
  (see [Credits](#credits)), drawn over your real desktop picture on every
  screen. Fog blur, drop refraction, lightning (overbright on EDR displays),
  vignette and breathing zoom are all adjustable live.
- **Follows your wallpaper:** changing the desktop picture in System
  Settings reloads it within about 2 seconds.
- **3D radio widget:** a spinning SceneKit radio with the album art, a
  dot-matrix title and synced lyrics. It reads
  [Dromac](https://github.com/yatharth1011/dromac) first, then falls back to
  macOS's own Now Playing (Music, Spotify, browser tabs).
- **Universal GPU kill switch:** press ⌃⌥⌘R, or open
  `rainydesktop://effects/toggle`. The rain stops on the desktop and in
  Chrome. The glass stays, drawn only when something changes.
- **Chrome:**
  - *Rainy Tab* extension: rain behind any site you turn on with ⌥⇧G. Cards,
    buttons, menus and pop-ups become liquid glass: refraction-only lenses
    with a jelly wobble on click.
  - *Rainy Theme*: a Chrome theme generated from your wallpaper.

  See [`ChromeExtension/README.md`](ChromeExtension/README.md).

## Install

You'll need a Mac running macOS 13 (Ventura) or later.

1. **Install Apple's developer tools** if you haven't already. In Terminal:
   ```bash
   xcode-select --install
   ```
2. **Download and build Rainy:**
   ```bash
   git clone https://github.com/yatharth1011/rainy-desktop.git
   cd rainy-desktop
   ./Scripts/bundle_app.sh
   ```
   This builds the app and installs it to `/Applications/RainyDesktop.app`.
3. **Open it:**
   ```bash
   open /Applications/RainyDesktop.app
   ```
   Rain appears over your wallpaper within a few seconds. If your wallpaper
   file is in Desktop, Documents or Downloads, macOS asks once for access.
   Click **Allow**.
4. **Optional: start at login:**
   ```bash
   ./Scripts/install_login_item.sh
   ```
5. **Optional: Chrome.** Follow the three steps in
   [`ChromeExtension/README.md`](ChromeExtension/README.md#install-once) to
   load the Rainy Tab extension and the generated theme.

**Using it:**
- **Settings:** open them from the ☁ menu-bar icon. If your menu bar is
  full, open Rainy from Spotlight again while it's running.
- **Pause all effects:** press ⌃⌥⌘R to turn everything off and on.
- **Quit:** use **Quit** at the bottom of Settings.
- **Update:** `git pull && ./Scripts/bundle_app.sh`.
- **Uninstall:** run `./Scripts/uninstall_login_item.sh`, then delete
  `/Applications/RainyDesktop.app`.

## Build and run

Requires macOS 13+ and Xcode's command-line tools.

```bash
./Scripts/bundle_app.sh           # builds, bundles, signs, installs to /Applications
open /Applications/RainyDesktop.app
```

- **Signing:** `bundle_app.sh` signs with your Apple Development certificate
  when there is one (ad-hoc otherwise). A stable signature means macOS
  remembers folder-access permissions across rebuilds.
- **Shaders:** they're compiled from source at launch
  (`Rendering/ShaderSource.swift`), so editing a `.metal` file only needs a
  rebuild.
- **Development:** `swift run RainyDesktop` also works.

Other scripts:

- `./Scripts/install_login_item.sh` starts Rainy at login;
  `./Scripts/uninstall_login_item.sh` undoes it.
- `swift Scripts/make_icon.swift && iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns && rm -r Assets/AppIcon.iconset`
  re-renders the app icon with the app's own rain shader.

## Settings

Open settings from the menu-bar icon, from the gear on Rainy Tab's pages, or
by launching Rainy again from Spotlight while it's running. Every control
is live:
- **Rain:** intensity, speed, drop layers, zoom out.
- **Fog:** blur range.
- **Lightning.**
- **Look:** colour grading, vignette, brightness, dim.
- **Chrome:** Chrome dim, theme darkness, frost, pure-black address bar.
- **Radio widget.**

## Works with Dromac

[Dromac](https://github.com/yatharth1011/dromac) (a phone-mirroring
dashboard) and Rainy talk to each other over loopback:

- Rainy's radio widget reads Dromac's now-playing API at
  `http://127.0.0.1:8811/api/external/now-playing`: track, artwork and synced
  lyrics.
- Dromac's liquid-glass theme reads Rainy's bridge at `http://127.0.0.1:47823`
  (`/state.json` and `/wallpaper.jpg`). That gives it the same wallpaper,
  rain clock and settings.

The bridge accepts connections only from this Mac and serves no CORS
headers, so web pages can't read it.

## Credits

The rain-on-glass effect is a port of
**["Heartfelt"](https://www.shadertoy.com/view/ltffzl) by Martijn Steinrucken
(BigWings)**, licensed
[CC BY-NC-SA 3.0](https://creativecommons.org/licenses/by-nc-sa/3.0/). It
appears in two files:
- `Sources/RainyDesktop/Rendering/Shaders/RenderShaders.metal` (Metal)
- `ChromeExtension/RainyTab/rain.js` (WebGL)

## License

This project's own code is released under the [MIT License](LICENSE).
Third-party terms are in [NOTICE](NOTICE).

The Heartfelt-derived shader code in the two files listed under
[Credits](#credits) remains under **CC BY-NC-SA 3.0**: attribution,
non-commercial use only, and adaptations shared under the same license.
