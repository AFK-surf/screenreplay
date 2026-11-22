// The volume (a speaker that mutes and unmutes, its slider opening beside it under the pointer, as Steam's), and the
// window's bars in full screen: the picture all of the screen, the title bar and the dock over it while the pointer
// moves (2 s after it stops they fade out and the pointer hides), or while a clip is picked or a menu is up.

///|
let volume_drag : @signals.Signal[Bool] = @signals.signal(false)

///|
fn set_volume(v : Double, m : Bool) -> Unit {
  volume.set(v)
  muted.set(m)
  apply_volume()
}

///|
/// The speaker and its slider (72 wide, a 4 high track, a 12 knob), opening over 140 ms.
fn volume_control(parent : @view.View, stage? : Bool = false) -> Unit {
  parent.box(fn(area) {
    area.row(Is(true)).gap(Is(4.0)).lines_up(Is(Some(Middle))).presses(Is(true)) |> ignore
    let silent = fn() { muted.get() || volume.get() <= 0.0 }
    let speaker = icon_button(area, fn() { if silent() { "volume-x" } else { "volume" } }, fn() {
      if silent() {
        t("取消静音")
      } else {
        t("静音")
      }
    }, fn() {
      if @signals.untracked(silent) {
        set_volume(if volume.untracked() <= 0.0 { 0.6 } else { volume.untracked() }, false)
      } else {
        set_volume(volume.untracked(), true)
      }
      save_prefs()
    }, stage~)
    let open = @motion.NodeWay::new(0.0)
    // (open while the pointer is anywhere over the key and the slider, the room between them too, or the slider held;
    // closing only 400 ms after the pointer left (800 was too slow, the user, 2026-11-16), called off if it comes back meanwhile: at once, it was gone before
    // the hand had settled (the user, 2026-11-16: 「音量调节这个消失太快了」))
    let close_later : Ref[() -> Unit] = Ref(fn() {  })
    area.reacts(fn() { area.pointer_within() || speaker.pointed() || speaker.focus_shown() || volume_drag.get() }, fn(on) {
      (close_later.val)()
      close_later.val = fn() {  }
      if on {
        open.go_ms(area, 72.0, if motion_off() { 1.0 } else { 140.0 })
      } else {
        close_later.val = area.at_moment(now() + 400.0, fn() {
            open.go_ms(area, 0.0, if motion_off() { 1.0 } else { 140.0 })
          }, later=true)
      }
    })
    area.box(fn(clip) {
      clip.height(Is(Some(20.0))).clips(Is(true)).width(By(fn() { Some(open.shown(clip)) })) |> ignore
      clip.box(fn(s) {
        let k = fn() { if muted.get() { 0.0 } else { volume.get() } }
        s
        .width(Is(Some(72.0)))
        .height(Is(Some(20.0)))
        .presses(Is(true))
        .cursor(Is(Some(Arrow)))
        .says(By(fn() { Some(@view.said(Slider, label=t("音量"))) }))
        .on_drag(fn(d) {
          if d.kind == Down {
            region_let_go()
          }
          set_volume(clamp((d.x - 6.0) / 60.0, 0.0, 1.0), false)
          volume_drag.set(d.kind == Down || d.kind == Moved)
          if d.kind == Up || d.kind == Off {
            save_prefs()
          }
        }, captures=true)
        |> ignore
        s.box(fn(o) {
          o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(tr) {
            tr.width(Is(Some(60.0))).height(Is(Some(4.0))).radius(Is(2.0)).ground(By(fn() { if stage { stage_track } else { c_s4() } })).offset(Is((6.0, 8.0))) |> ignore
          })
          |> ignore
        })
        |> ignore
        s.box(fn(o) {
          o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(f) {
            f
            .height(Is(Some(4.0)))
            .radius(Is(2.0))
            .ground(By(fn() { if stage { stage_text } else { ui_text() } }))
            .width(By(fn() { Some(60.0 * k()) }))
            .offset(Is((6.0, 8.0)))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        s.box(fn(o) {
          o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(knob) {
            knob
            .width(Is(Some(12.0)))
            .height(Is(Some(12.0)))
            .radius(Is(6.0))
            .ground(By(fn() { if stage { stage_text } else { ui_text() } }))
            .offset(By(fn() { (60.0 * k(), 4.0) }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
extern "C" fn rp_hide_cursor() -> Unit = "rp_hide_cursor"

///|
/// Whether the bars show in full screen: told as the pointer moves, for 2 s from then.
let pointer_lately : Ref[() -> Bool] = Ref(fn() { true })

///|
/// Told as the pointer moves over the picture or the bars.
let pointer_moved : Ref[() -> Unit] = Ref(fn() {  })

///|
/// The window's bars in full screen: shown while the pointer moved lately or something needs them (clip mode, a menu,
/// the timeline held, a dialog, the saved clips, a window's options); faded in 120 ms, out 200 ms; the pointer hidden as
/// they go, and gone they are pressed no more (a press where they were is the picture's: play or pause).
fn chrome(root : @view.View, bar : @view.View) -> Unit {
  let way = @motion.NodeWay::new(1.0)
  let wanted = fn() {
    !full_screen.get() ||
    (pointer_lately.val)() ||
    clipping.get() ||
    menu_up.get() ||
    grabbed.get() != 0 ||
    settings_open.get() ||
    export_open.get() ||
    library_open.get() ||
    clip_playing.get() != "" ||
    window_options_open.get()
  }
  bars_wanted.val = wanted
  root.reacts(wanted, fn(on) {
    way.go_ms(root, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else if on { 120.0 } else { 200.0 })
    if !on {
      rp_hide_cursor()
    }
  })
  bar
  .on_pointer_moved(fn() { (pointer_moved.val)() })
  .alpha(By(fn() { way.shown(bar) }))
  .over_all(By(fn() { full_screen.get() }))
  .laid_nowhere(By(fn() { full_screen.get() && way.shown(bar) <= 0.0 }))
  |> ignore
}

///|
/// The pointer watched over all of the window (what moves it shows the bars in full screen).
fn watch_pointer(root : @view.View) -> Unit {
  let (tell, lately) = root.holds_for(2000.0, later=true)
  pointer_lately.val = lately
  pointer_moved.val = tell
  // (anywhere: the black round the picture in full screen, the window with nothing recorded)
  root.on_pointer_moved(fn() { tell() }) |> ignore
}

///|
/// In development (REPLAY_DEV_POINTER=1) the pointer held where `pointer.txt` in REPLAY_ROOT says ("x y" in points,
/// whole numbers; read every 16 ms, as a hand moves it), so a test looks at what shows under a still pointer (the
/// hover previews) without the system's cursor: a move posted to the window is undone by the leave the system posts
/// after it. (After a posted click the host keeps that point as the pointer's till a leave comes: post a move after it.)
fn dev_pointer(root : @view.View) -> Unit {
  if @ui.env("REPLAY_DEV_POINTER") != "1" {
    return
  }
  fn look() -> Unit {
    let nums : Array[Int] = []
    let mut n = -1
    for ch in read_text(pjoin(root_dir(), "pointer.txt")) + " " {
      if ch >= '0' && ch <= '9' {
        n = (if n < 0 { 0 } else { n }) * 10 + (ch.to_int() - '0'.to_int())
      } else if n >= 0 {
        nums.push(n)
        n = -1
      }
    }
    // (where it is alone, nothing followed there: what is under it by where it is (View::pointer_within,
    // View::pointer_piece: the bars' hover), not what a press there would take, which the host's own pointer, gone,
    // would undo at the next frame)
    if nums.length() >= 2 {
      // (nothing pointed at: one left so by a posted move would have the host take the pointer away again each frame)
      root.tree.unfollow()
      root.tree.pointed_to(None)
      root.tree.pointer_is(nums[0].to_double(), nums[1].to_double())
    }
    root.at_moment(now() + 16.0, look, later=true) |> ignore
  }
  look()
}

///|
extern "C" fn rp_launch_recorder() -> Int = "rp_launch_recorder"

///|
/// When the recorder was asked to start from here (on the tree's clock; none yet: far back), so the chip says it is
/// starting meanwhile.
let recorder_asked_at : @signals.Signal[Double] = @signals.signal(-1.0e18, same=fn(a, b) { a == b })

///|
/// How the recorder stands, as its state.json says (bound: read again each time the folder is): its words, whether
/// it records.
fn recorder_status() -> (String, Bool) {
  // (what was just asked of it, shown at once till the recorder says so itself, 8 s at most)
  match asked_state.get() {
    Some((code, words, at)) if now_status() - at < 8000.0 && real_code() != code => return (words, code == "recording")
    _ => ()
  }
  real_status()
}

///|
/// What was last asked of the recorder from here: the code it should come to say, what the chip says meanwhile, when.
let asked_state : @signals.Signal[(String, String, Double)?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
/// The moment as the chip's status is read (the status read again ties it to the folder's reads).
fn now_status() -> Double {
  status_rev.get() |> ignore
  @signals.untracked(now)
}

///|
/// Something asked of the recorder: the chip says so at once, and the recorder's word is read again every 250 ms for
/// 8 s (it takes the ask at once: its own watch of the folder), not at the folder's next read.
fn asked_recorder(code : String, words : String) -> Unit {
  asked_state.set(Some((code, words, now())))
  match the_root.val {
    Some(r) => {
      let until = now() + 8000.0
      // (asked again each 250 ms till the recorder says what was asked, 8 s at most: not on for the 8 s once it has;
      // one ask's following ends as another's begins)
      asked_follow.val += 1
      let mine = asked_follow.val
      fn look() {
        if asked_follow.val != mine {
          return
        }
        status_rev.set(status_rev.untracked() + 1)
        if now() < until && @signals.untracked(real_code) != code {
          r.at_moment(now() + 250.0, look) |> ignore
        }
      }
      look()
    }
    None => ()
  }
}

///|
/// Which ask of the recorder is followed now (asked_recorder).
let asked_follow : Ref[Int] = Ref(0)

///|
fn real_code() -> String {
  recorder_code()
}

///|
fn real_status() -> (String, Bool) {
  status_rev.get() |> ignore
  match state_json() {
    // (the recorder says how it stands every 2 s: older than 10 s, it is not running)
    Some({ "at": Number(at, ..), .. }) if rp_now() - at > 10000.0 => (t("录制程序没在运行"), false)
    // (the recorder's code said in the window's language; its own words from a recorder from before codes)
    Some({ "statusCode": String(code), "recording": r, .. } as o) => {
      let arg = match o {
        { "statusArg": String(a), .. } => a
        _ => ""
      }
      (status_words(code, arg), r is True)
    }
    Some({ "status": String(s), "recording": True, .. }) => (s, true)
    Some({ "status": String(s), .. }) => (s, false)
    _ => (t("录制程序没在运行"), false)
  }
}

///|
/// The recorder's state in the title bar: recording, a red dot with a halo breathing (2.4 s a breath) and grey words;
/// held or off, an amber dot and why, a press starting it where it is not running.
fn recorder_chip(parent : @view.View) -> Unit {
  // (pressed, what can be done about it: pause it, turn it off; go on, turn it on, start it)
  let ask = fn(b : @view.View) {
    let (_, on) = @signals.untracked(recorder_status)
    let code = @signals.untracked(recorder_code)
    let entries : Array[MenuEntry?] = []
    if on {
      entries.push(Some({ label: t("暂停 15 分钟"), key: "", act: fn() { pause_for(15) } }))
      entries.push(Some({ label: t("暂停 1 小时"), key: "", act: fn() { pause_for(60) } }))
      entries.push(None)
      entries.push(Some({ label: t("关闭后台录制"), key: "", act: fn() { set_recording(false) } }))
    } else if code == "paused" {
      entries.push(Some({ label: t("继续录制"), key: "", act: fn() {
            ask_recorder("resume")
            asked_recorder("recording", t("录制中"))
          } }))
      entries.push(None)
      entries.push(Some({ label: t("关闭后台录制"), key: "", act: fn() { set_recording(false) } }))
    } else if code == "disabled" {
      entries.push(Some({ label: t("开启后台录制"), key: "", act: fn() { set_recording(true) } }))
    } else if code == "noPermission" {
      entries.push(Some({ label: t("开启屏幕录制权限…"), key: "", act: fn() { ask_recorder("permissions") } }))
      entries.push(None)
      entries.push(Some({ label: t("关闭后台录制"), key: "", act: fn() { set_recording(false) } }))
    } else if code == "" {
      entries.push(Some({ label: t("启动录制"), key: "", act: start_recorder }))
    } else {
      entries.push(Some({ label: t("关闭后台录制"), key: "", act: fn() { set_recording(false) } }))
    }
    if @signals.untracked(fn() { info().buffer_trouble }) != "" {
      entries.push(None)
      entries.push(Some({ label: t("录像位置设置…"), key: "", act: fn() {
            load_settings()
            settings_page.set(2)
            settings_open.set(true)
          } }))
    }
    open_menu_under(b, entries)
  }
  pressable(parent, fn() { recorder_status().0 }, fn() {  }, fn(k) {
    // (not running: a press starts it, as its words say; otherwise what can be done about it)
    k.on_press(fn() { if real_code() == "" { start_recorder() } else { ask(k) } }) |> ignore
    k
    .row(Is(true))
    .height(Is(Some(28.0)))
    .padding(Is((10.0, 0.0, 8.0, 0.0)))
    .gap(Is(6.0))
    .radius(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .cursor(Is(Some(Arrow)))
    .edge(By(fn() { if k.focus_shown() { (1.5, focus_ring()) } else { (0.0, 0L) } }))
    .ground(By(fn() { if k.pointed() || k.focus_shown() { press_ground() } else { 0L } }))
    |> ignore
    k.pick(fn() { recorder_status().1 }, fn(b, on) {
      b.row(Is(true)).gap(Is(7.0)).lines_up(Is(Some(Middle))) |> ignore
      if on {
        // the dot, and from it one ring going out (the user, 2026-11-13: 「向外辐射那种」, A of the reviewer's 77th):
        // a disc of its red from the dot's size to 3.2 times it as it fades from 55% to nothing, in the first 1.6 s
        // of each 2.4 s, then nothing till the next; both on one curve (cubic-bezier .2 .6 .3 1). Drawn over what is
        // beside it, laid out nowhere. Still where animations are off, and while the folder chosen cannot be written
        // (the dot amber then). Off for a measure of what it costs: REPLAY_STILL_DOT=1. Still too while the window is not
        // in front (2026-11-15: a window left open behind others drew 16-17 frames a second for it, 3-4% of a core)
        let still_dot = @ui.env("REPLAY_STILL_DOT") == "1"
        let out = @motion.cubic_bezier(0.2, 0.6, 0.3, 1.0)
        let trouble = fn() { info().buffer_trouble != "" }
        b.box(fn(cell) {
          cell.width(Is(Some(7.0))).height(Is(Some(7.0))) |> ignore
          cell.show(fn() { !trouble() && !motion_off() && !still_dot && @ui.app_focused() }, fn(ring) {
            // (on steps of its own, 30 a second while it spreads, none in the 0.8 s between: a frame of the screen's
            // for each (a way, a cycle) cost 11-12% of a core, the reviewer's 78th asks under 4%; mbui's resident clock
            // steps 10 a second, too few for a ring that grows)
            let step : @signals.Signal[Int] = @signals.signal(48)
            fn tick(k : Int) -> Unit {
              step.set(k)
              if k < 48 {
                ring.at_moment(ring.cause_at() + 1600.0 / 48.0, fn() { tick(k + 1) }, later=true) |> ignore
              } else {
                ring.at_moment(ring.cause_at() + 800.0, fn() { tick(0) }, later=true) |> ignore
              }
            }
            tick(0)
            let at = fn() {
              let k = step.get()
              if k >= 48 {
                -1.0
              } else {
                out(k.to_double() / 48.0)
              }
            }
            ring
            .over(Is(true))
            .width(Is(Some(7.0)))
            .height(Is(Some(7.0)))
            .radius(Is(3.5))
            .ground(By(rec_red))
            .scale(By(fn() { let e = at(); if e < 0.0 { 1.0 } else { 1.0 + 2.2 * e } }))
            .alpha(By(fn() { let e = at(); if e < 0.0 { 0.0 } else { 0.55 * (1.0 - e) } }))
            |> ignore
          }, at_once=true)
          |> ignore
          cell.box(fn(dot) {
            dot
            .over(Is(true))
            .width(Is(Some(7.0)))
            .height(Is(Some(7.0)))
            .radius(Is(3.5))
            .ground(By(fn() { if trouble() { warn() } else { rec_red() } }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // (recording, but not where the settings ask: the folder chosen cannot be written, the default meanwhile)
        words(b, fn() { if info().buffer_trouble != "" { t("录制中 · 暂存到默认位置") } else { t("录制中") } }, 12.0, fn() {
            if info().buffer_trouble != "" {
              warn()
            } else {
              ui_muted()
            }
          })
        |> ignore
      } else {
        b.box(fn(d) { d.width(Is(Some(7.0))).height(Is(Some(7.0))).radius(Is(3.5)).ground(By(warn)) |> ignore }) |> ignore
        words(b, fn() {
          if now_starting() {
            t("正在启动录制…")
          } else if recorder_code() == "" {
            t("没在录制 · 点击启动")
          } else {
            recorder_status().0
          }
        }, 12.0, warn)
        |> ignore
      }
    }, at_once=true)
    k.box(fn(c) {
      c
      .width(Is(Some(8.0)))
      .height(Is(Some(8.0)))
      .laid_nowhere(By(fn() { recorder_code() == "" }))
      .picture(Is(Some(vector("M1.5 3 4 5.5 6.5 3", 8.0, 8.0, stroke=1.25))))
      .tint(By(ui_subtle))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The recorder's state's code as it last said it ("" not running).
fn recorder_code() -> String {
  status_rev.get() |> ignore
  match state_json() {
    Some({ "at": Number(at, ..), .. }) if rp_now() - at > 10000.0 => ""
    Some({ "statusCode": String(code), .. }) => code
    _ => ""
  }
}

///|
fn now_starting() -> Bool {
  now() - recorder_asked_at.get() < 12000.0
}

///|
/// The recorder asked to pause (minutes) or go on ("resume"), as its tray's items do (it reads pause.request every 2 s).
fn ask_recorder(what : String) -> Unit {
  rp_write(cstr(pjoin(root_dir(), "pause.request")), @utf8.encode(what)) |> ignore
}

///|
/// Background recording on or off, as the settings' switch does.
fn set_recording(on : Bool) -> Unit {
  load_settings()
  settings.enabled = on
  save_settings()
  if on {
    asked_recorder("recording", t("录制中"))
  } else {
    asked_recorder("disabled", t("后台录制已关闭"))
  }
}

///|
/// Paused for `minutes`: the chip saying till when at once.
fn pause_for(minutes : Int) -> Unit {
  ask_recorder(minutes.to_string())
  asked_recorder("paused", tf("已暂停，{0} 继续", [wall(rp_now() + minutes.to_double() * 60000.0, short=true)]))
}

///|
/// The recorder started where it is not running (a test window, REPLAY_NO_RECORDER=1, never starts one: it would record
/// the real screen into the test's folder).
fn start_recorder() -> Unit {
  if @ui.env("REPLAY_NO_RECORDER") != "1" && rp_launch_recorder() == 1 {
    recorder_asked_at.set(now())
    match the_root.val {
      Some(r) => r.at_moment(now() + 12000.0, fn() { recorder_asked_at.set(-1.0e18) }) |> ignore
      None => ()
    }
  }
}
