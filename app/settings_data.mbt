// The settings (REPLAY_ROOT's settings.json, which the recorder reads every few seconds): whether it records in the
// background, how far back it keeps, how much disk it may take, whether it starts with Windows. Changed in the
// settings dialog, written at once.

///|
struct Settings {
  mut enabled : Bool
  /// how far back is kept, minutes
  mut window_minutes : Int
  /// the most the buffer may take, GB (0: no limit but the window)
  mut max_gb : Int
  mut autostart : Bool
  /// the system's sound recorded with the picture
  mut system_audio : Bool
  /// the default microphone recorded too
  mut microphone : Bool
  /// recording paused while a full-screen app (a game, a video) is in front
  mut pause_in_fullscreen : Bool
  /// "hevc" (H.265, the default: H.264 where it cannot be encoded) or "h264"
  mut codec : String
  /// the height recorded at most (0: the display's own)
  mut max_height : Int
  mut fps : Int
  /// "low", "medium", "high", "ultra"
  mut quality : String
  /// how much the "save the last moments" key keeps, seconds
  mut last_seconds : Int
  /// where the recorder writes its segments ("": the folder's own Buffer)
  mut buffer_dir : String
  /// the first run's consent: its version (0 none given) and when, ms since the epoch (consent.mbt)
  mut consent_version : Int
  mut consent_at : Double
  /// standalone automatic updates (checked daily, installed silently when idle)
  mut auto_update : Bool
}

///|
let settings : Settings = {
  enabled: true,
  window_minutes: 120,
  max_gb: 20,
  autostart: true,
  system_audio: true,
  microphone: false,
  pause_in_fullscreen: false,
  codec: "hevc",
  max_height: 0,
  fps: 30,
  quality: "high",
  last_seconds: 30,
  buffer_dir: "",
  consent_version: 0,
  consent_at: 0.0,
  auto_update: true,
}

///|
let settings_open : @signals.Signal[Bool] = @signals.signal(false)

///|
/// Told as the settings are read or changed: what shows them reads `sets`.
let settings_rev : @signals.Signal[Int] = @signals.signal(0)

///|
/// The settings, bound.
fn sets() -> Settings {
  settings_rev.get() |> ignore
  settings
}

///|
fn settings_path() -> String {
  root_dir() + "\\settings.json"
}

///|
fn load_settings() -> Unit {
  match parse(read_text(settings_path())) {
    Some(Object(o)) => {
      match o.get("enabled") {
        Some(True) => settings.enabled = true
        Some(False) => settings.enabled = false
        _ => ()
      }
      match o.get("windowMinutes") {
        Some(Number(v, ..)) => settings.window_minutes = v.to_int()
        _ => ()
      }
      match o.get("maxGB") {
        Some(Number(v, ..)) => settings.max_gb = v.to_int()
        _ => ()
      }
      match o.get("autostart") {
        Some(True) => settings.autostart = true
        Some(False) => settings.autostart = false
        _ => ()
      }
      match o.get("systemAudio") {
        Some(True) => settings.system_audio = true
        Some(False) => settings.system_audio = false
        _ => ()
      }
      match o.get("microphone") {
        Some(True) => settings.microphone = true
        Some(False) => settings.microphone = false
        _ => ()
      }
      match o.get("codec") {
        Some(String(v)) => settings.codec = if v == "h264" { "h264" } else { "hevc" }
        _ => ()
      }
      match o.get("maxHeight") {
        Some(Number(v, ..)) => settings.max_height = v.to_int()
        _ => ()
      }
      match o.get("fps") {
        Some(Number(v, ..)) => settings.fps = fps_of(v)
        _ => ()
      }
      match o.get("quality") {
        Some(String(v)) => settings.quality = v
        _ => ()
      }
      match o.get("lastSeconds") {
        Some(Number(v, ..)) => settings.last_seconds = v.to_int()
        _ => ()
      }
      match o.get("bufferDir") {
        Some(String(v)) => settings.buffer_dir = v
        _ => settings.buffer_dir = ""
      }
      match o.get("pauseInFullscreen") {
        Some(True) => settings.pause_in_fullscreen = true
        Some(False) => settings.pause_in_fullscreen = false
        _ => ()
      }
      match o.get("autoUpdate") {
        Some(True) => settings.auto_update = true
        Some(False) => settings.auto_update = false
        _ => settings.auto_update = true
      }
      match o.get("consent") {
        Some({ "version": Number(v, ..), "at": Number(at, ..), .. }) => {
          settings.consent_version = v.to_int()
          settings.consent_at = at
        }
        _ => {
          settings.consent_version = 0
          settings.consent_at = 0.0
        }
      }
    }
    _ => ()
  }
  settings_rev.set(settings_rev.untracked() + 1)
}

///|
/// `text` as it stands inside a JSON string: its backslashes and quotes escaped.
fn json_escaped(text : String) -> String {
  let b = StringBuilder()
  for c in text {
    if c == '\\' || c == '"' {
      b.write_char('\\')
    }
    b.write_char(c)
  }
  b.to_string()
}

///|
fn save_settings() -> Unit {
  settings_rev.set(settings_rev.untracked() + 1)
  let text = "{\"enabled\":\{settings.enabled},\"windowMinutes\":\{settings.window_minutes},\"maxGB\":\{settings.max_gb},\"autostart\":\{settings.autostart},\"systemAudio\":\{settings.system_audio},\"microphone\":\{settings.microphone},\"pauseInFullscreen\":\{settings.pause_in_fullscreen},\"autoUpdate\":\{settings.auto_update},\"codec\":\"\{settings.codec}\",\"maxHeight\":\{settings.max_height},\"fps\":\{settings.fps},\"quality\":\"\{settings.quality}\",\"lastSeconds\":\{settings.last_seconds},\"bufferDir\":\"\{json_escaped(settings.buffer_dir)}\"" +
    (if settings.consent_version > 0 {
      ",\"consent\":{\"version\":\{settings.consent_version},\"at\":\{settings.consent_at.to_int64()}}"
    } else {
      ""
    }) +
    "}"
  rp_write(cstr(settings_path()), @utf8.encode(text)) |> ignore
}

///|
let window_choices : Array[Int] = [30, 60, 120, 240]


///|
fn index_of(xs : Array[Int], v : Int, fallback : Int) -> Int {
  for i, x in xs {
    if x == v {
      return i
    }
  }
  fallback
}

///|
/// Rows drawn in the group open now (the first has no rule over it).

///|
let height_choices : Array[Int] = [0, 1440, 1080, 720]

///|
let quality_choices : Array[String] = ["low", "medium", "high", "ultra"]

///|
let last_choices : Array[Int] = [15, 30, 60, 120]

///|
fn index_of_text(xs : Array[String], v : String, fallback : Int) -> Int {
  for i, x in xs {
    if x == v {
      return i
    }
  }
  fallback
}

///|
/// What the recorder says of how it records (state.json): its codec, size, rate and bitrate, the display's size, the
/// disk's free bytes (-1 not known).
struct RecordingInfo {
  codec : String
  width : Int
  height : Int
  screen_w : Double
  screen_h : Double
  /// the recorder's last trouble with the sound (a diagnostics code), "" none
  audio_trouble : String
  /// where it writes its segments now, and why not where the settings ask ("bufferUnavailable"; "" none)
  buffer_dir : String
  buffer_trouble : String
  /// the disk's free room under 10 GB: the oldest recordings deleted before their time to keep it
  disk_tight : Bool
  /// where NVIDIA's Fast Sync is on (recorder/NvidiaSync.cs): "global", program profiles' names joined by "; ", ""
  fast_sync : String
  /// the main display's refresh rate (Hz; 0 unknown), and whether the frame rate asked (90, 120) was refused by the
  /// encoder (60 recorded instead)
  display_hz : Int
  fps_fell_back : Bool
  /// the GPU shares the computer's memory (integrated graphics: its video engine shared by recording and a video
  /// being played), and of the last 10 s the frames encoded and those left out with the encoder behind
  shared_gpu : Bool
  frames_encoded : Int
  frames_skipped : Int
}

///|
/// A frame rate as the recorder takes it: 30, 60, 90 or 120 (recorder/Program.cs).
fn fps_of(v : Double) -> Int {
  if v >= 120.0 {
    120
  } else if v >= 90.0 {
    90
  } else if v >= 60.0 {
    60
  } else {
    30
  }
}

///|
/// The recorder's state.json as last read: read and parsed once each time status_rev moves (each read of the folder,
/// 3 s; every 250 ms while an ask of the recorder is followed), not by each who asks. Before, the recording's size
/// (rec_size, under the region and the window picker) read and parsed the file at each move of the pointer, and the
/// title bar's chip twice a read.
let state_read : Ref[(Int, Json?)] = Ref((-1, None))

///|
fn state_json() -> Json? {
  let rev = status_rev.untracked()
  let (at, j) = state_read.val
  if at == rev {
    return j
  }
  let j = parse(read_text(root_dir() + "\\state.json"))
  state_read.val = (rev, j)
  j
}

///|
fn recording_info() -> RecordingInfo {
  let mut info = {
    codec: "",
    width: 0,
    height: 0,
    screen_w: 0.0,
    screen_h: 0.0,
    audio_trouble: "",
    buffer_dir: "",
    buffer_trouble: "",
    disk_tight: false,
    fast_sync: "",
    display_hz: 0,
    fps_fell_back: false,
    shared_gpu: false,
    frames_encoded: 0,
    frames_skipped: 0,
  }
  match state_json() {
    Some(Object(o)) => {
      let num = fn(k : String) {
        match o.get(k) {
          Some(Number(v, ..)) => v
          _ => 0.0
        }
      }
      let codec = match o.get("codec") {
        Some(String(v)) => v
        _ => ""
      }
      info = {
        codec,
        width: num("width").to_int(),
        height: num("height").to_int(),
        screen_w: num("screenWidth"),
        screen_h: num("screenHeight"),
        audio_trouble: match o.get("audioTrouble") {
          Some(String(v)) => v
          _ => ""
        },
        buffer_dir: match o.get("bufferDir") {
          Some(String(v)) => v
          _ => ""
        },
        buffer_trouble: match o.get("bufferTrouble") {
          Some(String(v)) => v
          _ => ""
        },
        disk_tight: o.get("diskTight") is Some(True),
        fast_sync: match o.get("fastSync") {
          Some(String(v)) => v
          _ => ""
        },
        display_hz: num("displayHz").to_int(),
        fps_fell_back: o.get("fpsWhy") is Some(String("fallback")),
        shared_gpu: o.get("sharedGpu") is Some(True),
        frames_encoded: num("framesEncoded").to_int(),
        frames_skipped: num("framesSkipped").to_int(),
      }
    }
    _ => ()
  }
  info
}

///|
/// The bitrate the recorder will use for these settings at the display's size, as the recorder works it out
/// (recording/Bitrate.cs): 3 Mbps × (pixels / 10⁶)^0.8 × (fps / 30)^0.6 × the quality (0.5 low, 0.75 medium, 1 high,
/// 1.6 ultra) × the codec (H.265 1, H.264 1.5), held to 1…150 Mbps, of the picture brought down to maxHeight.
fn planned_bitrate(screen_w : Double, screen_h : Double) -> Double {
  let mut w = if screen_w > 0.0 { screen_w } else { 1920.0 }
  let mut h = if screen_h > 0.0 { screen_h } else { 1080.0 }
  if settings.max_height > 0 && h > settings.max_height.to_double() {
    w = w * settings.max_height.to_double() / h
    h = settings.max_height.to_double()
  }
  let megapixels = @cmp.maximum(2.0, (w / 2.0).floor() * 2.0) *
    @cmp.maximum(2.0, (h / 2.0).floor() * 2.0) /
    1000000.0
  let q = match settings.quality {
    "low" => 0.5
    "medium" => 0.75
    "ultra" => 1.6
    _ => 1.0
  }
  let c = if settings.codec == "h264" { 1.5 } else { 1.0 }
  let fps = fps_of(settings.fps.to_double()).to_double()
  let rate = 3000000.0 *
    @math.pow(megapixels, 0.8) *
    @math.pow(fps / 30.0, 0.6) *
    q *
    c
  @cmp.minimum(150000000.0, @cmp.maximum(1000000.0, rate))
}

///|
/// Bytes as "1.4 GB", "620 MB" or, under a megabyte (a short GIF), "180 KB".
fn bytes_text(bytes : Double) -> String {
  let mb = bytes / 1048576.0
  if mb >= 1024.0 {
    let tenths = (mb / 102.4).round().to_int()
    "\{tenths / 10}.\{tenths % 10} GB"
  } else if mb < 0.995 {
    "\{@cmp.maximum(1, (bytes / 1024.0).round().to_int())} KB"
  } else {
    "\{mb.round().to_int()} MB"
  }
}

///|
#borrow(path)
extern "C" fn rp_dir_size(path : Bytes) -> Double = "rp_dir_size"

///|
/// The storage card: a 6 high meter of the window's ground, the recordings (t1) and the scrub index (t3) in it against
/// the limit; under it a legend, the disk's free room at its right.

/// The keys, a row each: what it does on the left, its keys on the right.
fn shortcut_rows() -> Array[(String, Array[String])] {
  [
  (t("打开回放"), ["Ctrl+Alt+R"]),
  (t("标记此刻"), ["Ctrl+Alt+M"]),
  (t("保存最近一段"), ["Ctrl+Alt+S"]),
  (t("播放 / 暂停"), ["Space", "K"]),
  (t("逐帧"), ["←", "→"]),
  (t("前后 5 秒"), ["Shift+←", "Shift+→"]),
  (t("前后 15 秒"), ["J", "L"]),
  (t("在当前位置加标记"), ["M"]),
  (t("上一个 / 下一个标记"), ["[", "]"]),
  (t("复制当前帧"), ["Ctrl+C"]),
  (t("剪辑"), ["C"]),
  (t("设起点 / 终点"), ["I", "O"]),
  (t("撤销 / 重做"), ["Ctrl+Z", "Ctrl+Y"]),
  (t("保存片段"), ["Enter"]),
  (t("保存并复制"), ["Shift+Enter"]),
  (t("回到最新"), ["End"]),
  (t("时间线缩放"), ["+", "-"]),
  (t("适应窗口"), ["0"]),
  (t("全屏"), ["F"]),
  (t("设置"), ["Ctrl+,"]),
  ]
}

///|
