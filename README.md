# OBS Stretched Projector for macOS

An OBS Studio plugin for macOS that opens projectors which stretch the Program
output or a scene to fill the entire display or window, ignoring the canvas
aspect ratio. No letterbox or pillarbox bars.

- OBS Studio 28 or newer
- macOS 11 or newer, Apple Silicon and Intel (universal binary)

## Install

### From a release
1. Download `stretched-projector-macos.zip` from [Releases](../../releases) and unzip it.
2. Copy `stretched-projector.plugin` to `~/Library/Application Support/obs-studio/plugins/`.
3. The plugin is ad-hoc signed and not notarized, so clear the quarantine flag:
   ```sh
   xattr -dr com.apple.quarantine ~/Library/Application\ Support/obs-studio/plugins/stretched-projector.plugin
   ```
4. Restart OBS.

### From source
Requires Xcode Command Line Tools (`xcode-select --install`) and git.

```sh
./build.sh install
```

`build.sh` downloads the OBS 28.0.0 headers into `.deps/`, builds a universal
`build/stretched-projector.plugin`, and with `install` copies it into the OBS
plugins folder. Restart OBS afterwards.

## Usage
1. Open `Tools` > `Stretched Projector`.
2. Choose `Program`, or `Scene` and then a scene.
3. Choose a target:
   - `Fullscreen: <display>` covers that whole display, including the menu bar and Dock.
   - `Windowed` opens a resizable window.
4. Right-click a projector for these options:
   - `Stretch to Fill`: switch between stretched and letterboxed
   - `Always on Top`: windowed projectors only
   - `Close Projector`

   `Esc` also closes the projector.

Each display holds one fullscreen projector at a time. Projectors close automatically when their display is disconnected or their scene is removed. They are not restored when OBS restarts.

## How it works
The plugin creates its own Cocoa windows and renders into them through the
public libobs display API (`obs_display_create`). It sets a viewport that
covers the whole window instead of the aspect-preserving one OBS uses. Built-in
OBS projectors are left unchanged. The plugin does not touch OBS internals or
Qt, so OBS updates do not break it.

## Credits
Inspired by [Wst-04d12/obs-stretched-projector](https://github.com/Wst-04d12/obs-stretched-projector),
a Windows plugin that stretches OBS's built-in projectors by patching OBS in
memory. This project is an independent macOS implementation and contains no
code from the original.

## License
[Mozilla Public License 2.0](LICENSE), the same license as the original project.

The plugin is built against OBS Studio headers, which are licensed under
GPL-2.0-or-later. MPL-2.0 is compatible with the GPL, so distributing the
compiled plugin together with OBS is allowed.
