// The tray's panel (the user, 2026-11-14: 「为啥我们的tray 菜单这么丑」, then B: drawn as the replay window is): the
// same program run by the recorder with REPLAY_TRAY=1, hidden, kept; the recorder shows it by its icon when the icon
// is pressed with the right button, beside it. It hides itself when it loses the focus, when a press lands outside it,
// on Esc, or when something in it is chosen. What is chosen is told to the recorder (its window, REPLAY_RECORDER_HWND,
// a message: rp_tray_tell), which does it as its own menu did. How the recorder stands it reads from its state.json, as
// the replay window's chip does. Drawn as the replay window's own menus are (overlay.mbt's menu_layer: s2, 4 in, items
// 32 high, radius 6, s3 under the pointer, keys in chips, hairlines between groups), so it is one of them (the user:
// 「感觉跟主题好像不太搭」).

///|
extern "C" fn rp_tray_window(w : Double, h : Double) -> Int = "rp_tray_window"

///|
extern "C" fn rp_tray_hide() -> Unit = "rp_tray_hide"

///|
extern "C" fn rp_tray_tell(command : Int) -> Int = "rp_tray_tell"

///|
extern "C" fn rp_window_shown() -> Int = "rp_window_shown"

///|
fn tray_mode() -> Bool {
  @ui.env("REPLAY_TRAY") == "1"
}

///|
/// The panel's width and height, in points (its window's, fixed): 4 in, a head of 36, nine items of 32 and three
/// hairlines of 9 at most.
let tray_w : Double = 280.0

///|
let tray_h : Double = 359.0

///|
/// What is chosen told to the recorder, and the panel hidden.
fn tray_do(command : Int) -> Unit {
  rp_tray_tell(command) |> ignore
  rp_tray_hide()
}

///|
/// An item, as the replay window's menus have them: its words, its keys in a chip after them.
fn tray_item(parent : @view.View, label : () -> String, keys : String, press : () -> Unit, strong? : Bool = false) -> Unit {
  pressable(parent, label, press, fn(b) {
    b
    .row(Is(true))
    .height(Is(Some(32.0)))
    .padding(Is((10.0, 0.0, 10.0, 0.0)))
    .gap(Is(10.0))
    .radius(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .cursor(Is(Some(Arrow)))
    .ground(By(fn() { if b.pointed() || b.focus_shown() { c_s3() } else { 0L } }))
    |> ignore
    b.box(fn(l) {
      l.grow(Is(1.0)) |> ignore
      words(l, label, 13.0, ui_text, weight=if strong { 600 } else { 400 }) |> ignore
    })
    |> ignore
    if keys != "" {
      kbd(b, keys)
    }
  })
  |> ignore
}

///|
/// A hairline between groups, as the menus' (4 over and under it).
fn tray_rule(parent : @view.View) -> Unit {
  parent.box(fn(r) {
    r.padding(Is((0.0, 4.0, 0.0, 4.0))) |> ignore
    rule(r, hair)
  })
  |> ignore
}

///|
/// The panel as made once.
fn tray_window(root : @view.View) -> Unit {
  the_root.val = Some(root)
  root.tree.hand_over_presses(false)
  @ui.set_tree_theme(@sf.ui_theme_now)
  load_prefs()
  ask_system(root)
  keep_theme(root)
  load_settings()
  root.ground(By(c_s2)).pad(Is(4.0)) |> ignore
  // (its window made a panel once it is up; while it shows, the recorder's word read every second)
  // (and drawn once unseen, its device made, before anyone presses for it: rp_tray_window, rp_tray_primed)
  root.at_moment(now() + 1.0, fn() { rp_tray_window(tray_w, tray_h) |> ignore }) |> ignore
  fn look() -> Unit {
    if rp_window_shown() == 1 {
      status_rev.set(status_rev.untracked() + 1)
    }
    again(root, 1000.0, look)
  }
  look()
  // the head: the mark and the name; how the recorder stands at the right, its dot red while it records
  root.box(fn(head) {
    head.row(Is(true)).height(Is(Some(36.0))).padding(Is((10.0, 0.0, 10.0, 0.0))).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
    app_logo(head, 16.0)
    words(head, fn() { "ScreenReplay" }, 13.0, ui_text, weight=600) |> ignore
    spring(head)
    head.box(fn(s) {
      s.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      s.box(fn(dot) {
        dot
        .width(Is(Some(7.0)))
        .height(Is(Some(7.0)))
        .radius(Is(3.5))
        .ground(By(fn() { if recorder_status().1 { 0xFF4D4DFFL } else { 0xD08A1EFFL } }))
        |> ignore
      })
      |> ignore
      // (a word or two: the panel is narrow; what more there is the replay window's chip says)
      words(s, fn() {
          match recorder_code() {
            "recording" => t("录制中")
            "paused" => t("已暂停")
            "disabled" => t("已关闭")
            _ => recorder_status().0
          }
        }, 12.0, ui_muted)
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      .allow_ellipsis(Is(true))
      |> ignore
    })
    |> ignore
  })
  |> ignore
  tray_rule(root)
  // what it is for, first: the last moments saved
  tray_item(root, fn() { tf("保存最近 {0} 秒", [settings.last_seconds.to_string()]) }, "Ctrl+Alt+S", fn() { tray_do(5) }, strong=true)
  tray_item(root, fn() { t("打开回放") }, "Ctrl+Alt+R", fn() { tray_do(1) })
  tray_item(root, fn() { t("标记此刻") }, "Ctrl+Alt+M", fn() { tray_do(4) })
  tray_item(root, fn() { t("已保存片段文件夹") }, "", fn() { tray_do(3) })
  tray_rule(root)
  // recording held or let go, as it stands now
  root.pick(fn() { recorder_code() }, fn(b, code) {
    if code == "paused" {
      tray_item(b, fn() { t("继续录制") }, "", fn() {
        asked_recorder("recording", t("录制中"))
        tray_do(8)
      })
      tray_item(b, fn() { t("关闭后台录制") }, "", fn() { tray_do(9) })
    } else if code == "disabled" {
      tray_item(b, fn() { t("开启后台录制") }, "", fn() { tray_do(10) })
    } else {
      tray_item(b, fn() { t("暂停 15 分钟") }, "", fn() { tray_do(6) })
      tray_item(b, fn() { t("暂停 1 小时") }, "", fn() { tray_do(7) })
      tray_item(b, fn() { t("关闭后台录制") }, "", fn() { tray_do(9) })
    }
  }, at_once=true)
  spring(root)
  tray_rule(root)
  tray_item(root, fn() { t("设置…") }, "", fn() { tray_do(2) })
  tray_item(root, fn() { t("退出") }, "", fn() { tray_do(11) })
}
