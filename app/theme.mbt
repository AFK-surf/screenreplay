// The window's own preferences (viewer.json in REPLAY_ROOT; settings.json is the recorder's too): its appearance
// (following Windows, dark or light), its language (following Windows, 简体中文 or English: strings.mbt) and the
// player's volume; and the save dialog's format and a GIF's frame rate, as last chosen (save.mbt). Following Windows,
// both are asked of it again every second (it tells nothing as they change), so switching the system's theme or
// language turns the window at once.

///|
/// "system", "dark" or "light".
let appearance : @signals.Signal[String] = @signals.signal("system")

///|
/// "system", "zh" or "en".
let language : @signals.Signal[String] = @signals.signal("system")

///|
let volume : @signals.Signal[Double] = @signals.signal(1.0, same=fn(a, b) { a == b })

///|
let muted : @signals.Signal[Bool] = @signals.signal(false)

///|
/// Whether Windows' apps are light (AppsUseLightTheme), 1 or 0.
extern "C" fn rp_system_light() -> Int = "rp_system_light"

///|
/// Whether Windows shows Chinese (its UI language's primary language), 1 or 0.
extern "C" fn rp_system_chinese() -> Int = "rp_system_chinese"

///|
/// The window's frame and system menu dark (1) or light (0).
extern "C" fn rp_window_dark(on : Int) -> Unit = "rp_window_dark"

///|
/// Every window of this process kept out of screen capture (1) or let back (0): replay_win.c.
extern "C" fn rp_hide_from_capture(on : Int) -> Unit = "rp_hide_from_capture"

///|
/// Whether the window is kept out of what is recorded, and of every other capture (the user, 2026-11-15: on at first, a
/// switch to let a screenshot of it be taken). viewer.json's, read again with the system's each second, so the tray's
/// panel, another process, follows the switch.
let hidden_from_capture : @signals.Signal[Bool] = @signals.signal(true)

///|
/// Whether the timeline folds away where nothing was recorded (ScreenReplay not running, recording off or paused) to a
/// seam, as a filter's axis does (axis.mbt; the user, 2026-11-19: 「加一个选项，默认开启。假如用户没有开这个 APP，或者
/// 没有真正录的时候，不用把这段空白的时间算进来」). viewer.json's fold_gaps; on at first.
let fold_gaps : @signals.Signal[Bool] = @signals.signal(true)

///|
let system_light : @signals.Signal[Bool] = @signals.signal(false)

///|
let system_chinese : @signals.Signal[Bool] = @signals.signal(true)

///|
fn viewer_path() -> String {
  pjoin(root_dir(), "viewer.json")
}

///|
/// Dark (bound).
fn is_dark() -> Bool {
  match appearance.get() {
    "dark" => true
    "light" => false
    _ => !system_light.get()
  }
}

///|
/// English (bound).
fn is_english() -> Bool {
  match language.get() {
    "en" => true
    "zh" => false
    _ => !system_chinese.get()
  }
}

///|
fn load_prefs() -> Unit {
  match parse(read_text(viewer_path())) {
    Some(Object(o)) => {
      match o.get("volume") {
        Some(Number(v, ..)) => volume.set(clamp(v, 0.0, 1.0))
        _ => ()
      }
      muted.set(o.get("muted") is Some(True))
      fold_gaps.set(!(o.get("fold_gaps") is Some(False)))
      hidden_from_capture.set(!(o.get("hide_from_capture") is Some(False)))
      match o.get("appearance") {
        Some(String(v)) => appearance.set(v)
        _ => ()
      }
      match o.get("language") {
        Some(String(v)) => language.set(v)
        _ => ()
      }
      match o.get("export_format") {
        Some(String(v)) => export_format.set(index_of_text(format_names, v, 0))
        _ => ()
      }
      match o.get("gif_fps") {
        Some(Number(v, ..)) => gif_fps.set(if v.to_int() == 10 { 10 } else { 15 })
        _ => ()
      }
    }
    _ => ()
  }
}

///|
fn save_prefs() -> Unit {
  @signals.untracked(fn() {
    rp_write(
      cstr(viewer_path()),
      @utf8.encode(
        "{\"volume\":\{volume.get()},\"muted\":\{muted.get()},\"appearance\":\"\{appearance.get()}\",\"language\":\"\{language.get()}\",\"export_format\":\"\{format_names[export_format.get()]}\",\"gif_fps\":\{gif_fps.get()},\"hide_from_capture\":\{hidden_from_capture.get()},\"fold_gaps\":\{fold_gaps.get()}}",
      ),
    )
  })
  |> ignore
}

///|
/// When viewer.json and settings.json were written as ask_system last read them (-2 never).
let viewer_seen : Ref[Double] = Ref(-2.0)

///|
let settings_seen : Ref[Double] = Ref(-2.0)

///|
/// Windows asked how it stands (its theme, its language) now, and again in a second.
fn ask_system(root : @view.View) -> Unit {
  system_light.set(rp_system_light() == 1)
  system_chinese.set(rp_system_chinese() == 1)
  still_motion.set(rp_animations_off() == 1)
  // (reload viewer.json and settings.json when another process writes them, so warm tray & note windows stay in sync)
  let written = rp_modified(cstr(viewer_path()))
  if written != viewer_seen.val {
    viewer_seen.val = written
    match parse(read_text(viewer_path())) {
      Some(Object(o)) => {
        hidden_from_capture.set(!(o.get("hide_from_capture") is Some(False)))
        match o.get("appearance") {
          Some(String(v)) => appearance.set(v)
          _ => ()
        }
        match o.get("language") {
          Some(String(v)) => language.set(v)
          _ => ()
        }
      }
      _ => ()
    }
  }
  let set_written = rp_modified(cstr(settings_path()))
  if set_written != settings_seen.val {
    settings_seen.val = set_written
    load_settings()
  }
  rp_hide_from_capture(if hidden_from_capture.untracked() { 1 } else { 0 })
  again(root, 1000.0, fn() { ask_system(root) })
}

///|
/// The library's parts and the window's frame turned with the look, as it changes.
fn keep_theme(root : @view.View) -> Unit {
  let way = @motion.NodeWay::new(if @signals.untracked(is_dark) { 1.0 } else { 0.0 })
  theme_way.val = Some(way)
  root.reacts(is_dark, fn(dark) {
    way.go_ms(root, if dark { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else { 160.0 })
    @sf.set_dark(Some(dark))
    rp_window_dark(if dark { 1 } else { 0 })
  })
}

///|
/// The players told the volume (the replay's and a saved clip's).
fn apply_volume() -> Unit {
  let v = volume_now()
  ntrace("volume \{v}")
  native().stream().audio_volume(v)
  match clip_deck.val {
    Some(d) => d.stream().audio_volume(v)
    None => ()
  }
}
