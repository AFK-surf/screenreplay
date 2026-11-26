# ScreenReplay

[简体中文](README.zh-CN.md) · [Website & Installer](https://screenreplay.pages.dev) · [Microsoft Store](https://apps.microsoft.com/detail/9PCZQK5BVPC6)

Always-on background screen recorder and instant replay viewer for Windows 11, inspired by Steam's background game recording and brought to the whole desktop. ScreenReplay keeps a rolling hardware-encoded buffer of the last stretch of your screen and audio (2 hours by default) on your PC, so a bug you cannot reproduce or a moment when OBS was not running can be rewound on a timeline, cropped to a single window, and copied to a chat in seconds.

The replay window (`ScreenReplayViewer.exe`) is written in [Pion](https://github.com/AFK-surf/pion) on the native UI framework [`invar`](https://github.com/AFK-surf/invar) — no Electron or WebView, Direct3D 11 hardware video decoding without CPU frame copies, instant wake, ~9.3 MB standalone installer.

![ScreenReplay](packaging/store/screenshots/en/1-replay.png)

## Installation

Requires Windows 11 x64.

- **Microsoft Store**: install [ScreenReplay on the Microsoft Store](https://apps.microsoft.com/detail/9PCZQK5BVPC6) (updates automatically through the Store).
- **Standalone installer**: download `ScreenReplay-Setup.exe` from [screenreplay.pages.dev](https://screenreplay.pages.dev) and run it. It installs under the current user (no administrator rights needed), adds Start menu and Settings › Apps entries, and optionally starts with Windows. The standalone installer is not Authenticode-signed: if Windows SmartScreen prompts "Windows protected your PC", choose **More info › Run anyway**.

### Standalone updates

Settings › About includes **Check for updates** and an **Automatic updates** toggle (on by default in the standalone installer). When enabled, ScreenReplay checks [screenreplay.pages.dev/dl/latest.json](https://screenreplay.pages.dev/dl/latest.json) periodically, verifies the release's ECDSA P-256 signature (against the public key built into `recorder/Updater.cs`) and SHA-256 digest, and silently installs the update once the replay window is closed and the PC has been idle for two minutes. A release whose signature does not verify is rejected before download. The Microsoft Store package is updated by the Store and never checks for updates itself.

On macOS (Apple silicon, macOS 14+), `ScreenReplay-mac.zip` is signed with AFK AI's Developer ID and notarized by Apple. A copy in Applications updates itself the same way (`mac/Sources/ScreenReplayKit/Updater.swift`): it reads `mac_sha256` / `mac_signature` in `latest.json`, checks the zip's SHA-256 and the new app's code signature (Team `D9AAN3VJK8`), then swaps the app and restarts it once the replay window is closed and the Mac has been idle for two minutes.

## Use

- **Global hotkeys** (configurable in Settings):
  - `Ctrl+Alt+R` (or click the tray icon): open the replay window
  - `Ctrl+Alt+S`: save the last 30 seconds in the background and show a quick card by the tray (Play, Copy, Show in folder)
  - `Ctrl+Alt+M`: drop a marker at the current moment
- **Timeline**:
  - Shows which app was in front at every moment (`windows.jsonl`, kept strictly on this PC), audio loudness, markers, hover thumbnails, and a 100 ms input activity heat strip above the track (keyboard, mouse clicks/wheel, and XInput/HID controller counts only — never which keys or where)
  - **Filter by app**: click the Apps chip to keep only selected apps on the timeline; stretches spent in other apps fold into thin seams showing how much time was skipped
  - Mouse wheel pans horizontally; `Ctrl+wheel` zooms around the pointer; click jumps the playhead; right-click opens the context menu (add marker, copy frame, set clip start/end)
- **Playback**:
  - `Space` or `K` play/pause; `,` / `.` step one recorded frame backward/forward; `←` / `→` jump 5 s (`Shift`: 1 s); `J` / `L` jump 15 s; `Home` / `End` jump to start/end; `[` / `]` jump between markers
  - `Ctrl+wheel` over the picture zooms up to 8× around the pointer (`0` resets); double-click toggles fullscreen
- **Clipping & export**:
  - Press `C` to enter clip mode (`I` / `O` set start/end at the playhead; `Ctrl+Z` / `Ctrl+Y` undo/redo)
  - Clip the **whole screen**, **a single window** (click any recorded window on the canvas; crop follows the window if it moved), or **a custom region**
  - **As recorded**: lossless MP4 remux (`rp_concat`) with an edit list (`edts`/`elst`) for frame-accurate start without re-encoding
  - **By target size**: picks resolution and Peak-Constrained VBR bitrate to fit 10 / 25 / 50 / 100 / 250 MB
  - **Custom**: H.264, H.265, hardware AV1, or ordered-dithered animated GIF
  - `Enter` opens the save sheet; `Shift+Enter` quick-saves and copies the file to the clipboard

All recordings, thumbnails, and window indexes stay on your PC (`%LOCALAPPDATA%\Replay` by default, configurable under Settings › Storage). Nothing is uploaded, and no usage statistics or crash reports are collected.

## How it works

- **`recorder/`** (`ScreenReplay.exe`, C# / Native-trimmed .NET): tray resident process, global hotkeys, rolling 30 s segment lifecycle, foreground window tracker (`WindowTrack.cs`), raw input & gamepad activity counters (`RawInput.cs`, `XInputPads.cs`, `HidPads.cs`), and signed standalone updater (`Updater.cs`).
- **`recording/`** (C#, `Vortice.Windows` Direct3D 11 & Media Foundation):
  - Captures the display via `Windows.Graphics.Capture` straight into GPU VRAM, converts and tone-maps HDR FP16 scRGB → SDR on the GPU via `ID3D11VideoProcessor` (`DisplayColor.cs`, `HdrToSdr.cs`), and encodes H.265 (HEVC) or H.264 through hardware NVENC / AMF / QuickSync MFTs (`VideoEncoder.cs`). Unchanged frames are skipped so a still desktop writes almost nothing.
  - Mixes WASAPI system loopback audio and optional microphone input into AAC (`AudioSource.cs`, `AudioMixer.cs`).
- **`src/` + `native/`** (`ScreenReplayViewer.exe`, Pion + C/C++/ObjC++ on `invar`):
  - Retained-mode native UI built on `invar`'s `view::View` tree and Direct3D 11 / Metal renderer (`WDA_EXCLUDEFROMCAPTURE` enabled by default so reviewing past footage does not record the viewer itself).
  - Demuxes MP4 segments directly (`src/mp4.pion`, `src/sps.pion`) and decodes frames on the GPU via Media Foundation's D3D11VA hardware decoder into an NV12 `ID3D11Texture2D` pool, converted to BGRA on the GPU and presented through `invar`'s `ui::Stream` (`src/native_player.pion`, `native/replay_play.cpp`) synchronized against `XAudio2` output latency.
  - Background keyframe thumbnailer (`native/replay_index.cpp`), lossless MP4 remuxer, GPU window/region cropper (`native/replay_export.cpp`), and GIF encoder (`native/replay_gif.cpp`).

## Windows build

Needs Windows 11, Visual Studio 2022 (with **Desktop development with C++**), .NET 10 SDK, Clang/LLVM (`clang`), and `pionc` (`PIONC` env var or `pionc` on `PATH`) with sibling `invar` and `pion-packages` checkouts matching `pion.toml`.

```powershell
powershell -File scripts/build.ps1                     # Builds out\ScreenReplay.exe + out\ScreenReplayViewer.exe
powershell -File packaging/pack-setup.ps1              # Builds out\setup\ScreenReplay-Setup-<ver>.exe (Inno Setup 6)
powershell -File packaging/pack-msix.ps1 -Viewer out   # Builds Microsoft Store MSIX package
```

## macOS build

Needs Xcode (Swift 6) and `pionc` (with sibling `invar` and `pion-packages` checkouts matching `pion.toml`). `bash scripts/build-mac.sh` builds `out/mac/ScreenReplay.app` and `out/mac/ScreenReplay-mac.zip` (ad hoc signed). The **macOS package** workflow (`.github/workflows/macos.yml`, run by hand or by the release workflow) builds the same, then signs it with AFK AI's Developer ID and notarizes it (`scripts/sign-mac.sh`, using the `MACOS_DEVELOPER_ID_KEYCHAIN_B64_1` / `_2` and `KEYCHAIN_PASSWORD_AFK` secrets). `packaging/publish-setup.ps1` takes that build of the commit it publishes and puts it on the download site and in `latest.json` (`-NoMac`: Windows only).

## Releases

A pushed `v<version>` tag makes the release (`.github/workflows/release.yml`): the **Windows package** and **macOS package** workflows build `ScreenReplay-Setup-<version>.exe` and `ScreenReplay-mac.zip` from the tag and put them on its GitHub release; then, once approved in the `release` environment (which alone holds the update-signing key and the Cloudflare token), `packaging/publish-setup.ps1` signs `latest.json` and puts the downloads in R2, and the site is deployed. The tag must be the version in `src/about.pion` and `recorder/Updater.cs`.

## Sponsor

ScreenReplay is free and open source. If it saves a moment that mattered, you can support its development on the [sponsor page](https://screenreplay.pages.dev/support) (WeChat Reward, Ko-fi), also linked under Settings › About.

## License

ScreenReplay is free software licensed under the **GNU General Public License v3.0 (GPL-3.0)** — see [`LICENSE`](LICENSE).

**Trademark & branding notice**: The name **"ScreenReplay"** and the ScreenReplay icons/logos (`assets/`, `site/img/icon.png`) are not covered by the GPL-3.0 license. Modified versions or binaries built from modified source code must not be distributed or published under the name "ScreenReplay" or with the official ScreenReplay icons.

Third-party notices: [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) and [`site/licenses.txt`](site/licenses.txt). Privacy policy: [`PRIVACY.md`](PRIVACY.md).
