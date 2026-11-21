# ScreenReplay — Microsoft Store submission (0.1.0)

Store ID 9PCZQK5BVPC6 · package identity pengx17.ScreenReplay · free (since 0.1.7, 2026-11-19; before: USD 1.99 with a
7-day trial) · sponsors at screenreplay.pages.dev/support · category Productivity › Utilities & tools (or
Photo & video) · age rating: IARC questionnaire, no user interaction, no data shared.

## Restricted capabilities: why each is needed (Partner Center › Submission options › "Why do you need…")

> **runFullTrust**
> ScreenReplay is a desktop app (Win32, packaged with MSIX). It has two processes: a background recorder that lives in
> the notification area and the replay window. The recorder captures the screen with Windows.Graphics.Capture and
> encodes it with the GPU's hardware video encoder through Media Foundation (Direct3D 11), records system audio and
> the microphone with WASAPI, registers global hotkeys (Ctrl+Alt+R, Ctrl+Alt+S, Ctrl+Alt+M), shows a notification-area
> icon, and starts the replay window as a second process. These are Win32 APIs that need a full-trust process.
>
> **graphicsCaptureProgrammatic**
> The app's one purpose is a rolling screen recording kept on the user's PC (like an "instant replay"): once the user
> has turned on background recording on the first-run consent page (off by default), the recorder captures the main
> display with Windows.Graphics.Capture without asking each time through the system picker, which would defeat a
> recording that runs in the background and resumes after sign-in, lock and sleep. The user can pause it (15 min,
> 1 h), turn it off from the tray or Settings, and see that it records from the tray icon and the status in the
> replay window. Recordings are kept only on this PC for the time the user chooses (30 min to 4 h), then deleted;
> nothing is uploaded.
>
> **graphicsCaptureWithoutBorder**
> Windows draws a yellow border around a captured display. ScreenReplay records continuously in the background, so the
> border would stay on screen at all times, cover what the user works on and end up in every saved clip. The app shows
> instead that it records with its own notification-area icon (red while recording) and its status in the replay
> window, and the user turns recording on explicitly on first run.

(The microphone is a normal device capability: off by default, Windows asks on first use.)

## English listing

**Product name:** ScreenReplay

**Short description (≤ 1000 chars, shown on top):**
Always recording in the background, so you can rewind and keep what just happened. ScreenReplay keeps the last 30
minutes to 4 hours of screen and sound on your PC; when something worth keeping happens, open the replay, drag
back to it and save just that part as a clip.

**Description:**
Missed the moment? ScreenReplay was already recording.

ScreenReplay records your screen quietly in the background with your graphics card's hardware encoder, and keeps only
the most recent stretch (30 minutes, 1, 2 or 4 hours — your choice). Older video is deleted as new video comes in, so
it never fills your disk.

When something happens that you want to keep — a bug you can't reproduce, a great play in a game, a call you need
to remember — press Ctrl+Alt+R to open the replay, scrub back on the timeline and save exactly the part you want.
Or press Ctrl+Alt+S to save the last 30 seconds without opening anything.

• A timeline that shows which app was in front at every moment, with the sound's loudness, your markers and a hover
  preview
• The timeline shows how busy your mouse, keyboard and game controller were (counts only, never which keys or buttons), so an intense game or
  a burst of typing stands out
• Clip the whole screen, one window (it follows the window as it moves) or any area you draw
• Save as recorded in an instant, or re-encode to H.264, H.265, AV1 or GIF, by target size or by your own settings
• System audio and microphone, each on or off
• Pauses itself while the PC is locked or asleep, and optionally while a game or video is full screen
• Your saved clips in the app: play them, copy them to share in a chat, show them in their folder
• Light and dark themes, English and Simplified Chinese

Private by design: recordings never leave your PC. There is no account, no cloud and no analytics. Background
recording stays off until you turn it on, and you can pause it or turn it off at any time from the tray.

Completely free, every feature, no time limit. If it helps you, you can support it at screenreplay.pages.dev/support.

**Features (each ≤ 200 chars):**
1. Rolling background screen recording with hardware encoding (HEVC or H.264), kept only for the time you choose
2. Rewind on a timeline that shows which app was in front, the sound, how busy mouse, keyboard and controller were, and your markers
3. Save the last 30 seconds with one hotkey (Ctrl+Alt+S)
4. Clip the whole screen, a single window or an area you draw
5. Export as recorded, or as H.264, H.265, AV1 or GIF, by target size or custom settings
6. System audio and microphone recording
7. Pauses while locked or asleep, and optionally in full screen
8. Recordings stay on your PC: no account, no cloud, no analytics

**Search terms (≤ 7):** screen recorder, instant replay, rewind, screen capture, clip, game recording, background recording

**What's new in this version (0.1.18):** Raised D3D11 capture/encode GPU thread priority and upgraded the WGC capture frame pool to 4 buffers with latest-frame draining for smoother recording when 4K games peg the GPU. Patched lossless quick-save and H.265 exports to hvc1 in place so clips play directly in QuickTime, Safari and iOS. Sped up hardware AV1 re-encoding, lowered the save-card breathing indicator to 10 Hz on high-refresh displays, and automatically refresh cached timeline app icons when an application updates.

**Copyright:** © 2026 pengx17 · **Privacy policy URL:** https://screenreplay.hisenxpress.workers.dev/privacy ·
**Website:** https://screenreplay.hisenxpress.workers.dev · **Support contact:** the site's feedback link.

## 简体中文商品信息

**名称：** ScreenReplay

**简短说明：**
一直在后台录屏，随时倒回去存下刚才那一段。ScreenReplay 只在你的电脑上保留最近 30 分钟到 4 小时的画面和声音；遇到值得留下的片段，打开回放，拖回到那一刻，只把那一段存成片段。

**说明：**
错过了刚才那一下？ScreenReplay 一直在录。

ScreenReplay 用显卡的硬件编码器在后台安静地录屏，只保留最近一段时间（30 分钟、1、2 或 4 小时，由你选择）。新的录像进来，旧的就自动删除，不会把硬盘占满。

遇到想留下的瞬间——复现不了的 bug、游戏里的精彩操作、需要记住的会议内容——按 Ctrl+Alt+R 打开回放，在时间轴上拖回去，只保存你要的那一段；或者按 Ctrl+Alt+S，不打开窗口直接存下最近 30 秒。

• 时间轴上能看到每一刻前台是哪个应用，还有声音大小、你打的标记，悬停即可预览
• 时间轴上标出鼠标、键盘和手柄的忙碌程度（只记次数，不记按了哪个键），激烈的游戏、密集的打字一眼可见
• 可以剪整个屏幕、单个窗口（窗口移动时跟着走）或自己框选的区域
• 原样保存，秒存；或重新编码为 H.264、H.265、AV1、GIF，可按目标大小或自定义参数
• 系统声音和麦克风可分别开关
• 锁屏、睡眠时自动暂停；也可以在游戏或视频全屏时暂停
• 应用内可以浏览已保存的片段：播放、复制到聊天里分享、在文件夹中显示
• 支持浅色、深色主题，支持简体中文和英文

隐私优先：录像不会离开你的电脑。没有账号、没有云端、没有统计。后台录制默认关闭，需要你自己开启，之后也可以随时在托盘里暂停或关闭。

完全免费，全部功能不限时。觉得好用的话，可以在 screenreplay.pages.dev/support 赞助支持。

**功能（每条 ≤ 200 字）：**
1. 后台循环录屏，硬件编码（HEVC 或 H.264），只保留你设定的时长
2. 在时间轴上倒回，看得到前台应用、声音、键鼠和手柄的忙碌程度和你的标记
3. 一个快捷键保存最近 30 秒（Ctrl+Alt+S）
4. 剪整个屏幕、单个窗口或自选区域
5. 原样导出，或导出为 H.264、H.265、AV1、GIF，按目标大小或自定义
6. 录制系统声音和麦克风
7. 锁屏、睡眠时暂停，可选全屏时暂停
8. 录像只存在本机：无账号、无云端、无统计

**搜索词：** 录屏, 即时回放, 回放, 屏幕录制, 剪辑, 游戏录制, 后台录制

**此版本新增内容（0.1.18）：** 提升 D3D11 采集/编码设备 GPU 线程优先级并将 WGC 帧池升级为 4 缓冲排空，减少 4K 游戏 GPU 满载时的录屏掉帧；H.265 导出与无损秒存（Ctrl+Alt+S / 原样保存）原地写入 hvc1 标记，直接兼容 iPhone、Mac QuickTime 与 Safari 播放；优化硬件 AV1 重编码导出速度与线程计时精度；保存卡片呼吸提示降为 10 Hz 低功耗刷新；时间轴应用图标缓存随程序更新自动刷新。

## Screenshots (1920×1080 or larger, English and Chinese sets, fixture recordings only)

1. The replay window on a workday timeline (apps across the track, markers), playhead mid-way.
2. Clip mode with a window picked (the rest shaded, "Only …" chip) and the clip's time beside the play key.
3. The save dialog: By size, H.265, the size estimate.
4. Saved clips: the library's player with the hover preview.
5. Settings › Recording (what is recorded, pause in full screen, start with Windows).
6. The tray's menu and the card shown on saving the last 30 seconds, over a softened desktop (both grabbed from the
   app, tools/compose_tray.py).

Made by tools/siteshots.ps1-style runs on the fixture buffer with REPLAY_NOW fixed, so the times and "ago" read the
same in every shot; no personal content, no Steam.
