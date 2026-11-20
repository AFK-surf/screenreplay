// The note of a clip saved (the user, 2026-11-18: 「托盘save后感觉需要有个通知啥的，现在啥都没有」, then
// 「做自己的保存卡片」 and 「这个卡片应该在回放窗口使用也是通用的」): one card, drawn by note_body, wherever a clip is
// saved. By the tray: the same program run by the recorder with REPLAY_NOTE, a window of its own at the foot of the
// screen, never taking the focus, gone by itself after a few seconds (kept while the pointer is over it);
// REPLAY_NOTE=saved: a clip just saved (REPLAY_NOTE_PATH); =text: one line the recorder gives (REPLAY_NOTE_TEXT,
// already in the user's language), a warning with REPLAY_NOTE_WARN=1. Shown whatever Windows' do-not-disturb says: it
// answers what the user just pressed. In the replay window: over the picture's corner (save.mbt saved_note).

///|
extern "C" fn rp_note_window(w : Double, h : Double, cloaked : Int) -> Int = "rp_note_window"

///|
extern "C" fn rp_note_reveal() -> Unit = "rp_note_reveal"

///|
extern "C" fn rp_note_hide() -> Unit = "rp_note_hide"

///|
fn note_mode() -> String {
  @ui.env("REPLAY_NOTE")
}

///|
/// The card's width, and its heights: a clip's (14 in, a picture 72 high, 12, the buttons 28, 14 in), a line's.
let note_w : Double = 360.0

///|
let note_clip_h : Double = 140.0

///|
let note_line_h : Double = 52.0

///|
fn note_h() -> Double {
  if note_mode() == "saved" && @ui.env("REPLAY_NOTE_PATH") != "" {
    note_clip_h
  } else {
    note_line_h
  }
}

///|
/// The clip its copy button has copied: that button says so while the card shows it.
let note_copied : @signals.Signal[String] = @signals.signal("")

///|
/// The card's inside, in `parent` (its ground, corners and size the caller's): a clip saved at `path` (its first
/// picture, pressed played; what was saved, its date, length and size; play, copy, show in the folder), or where `path`
/// is "" one line, `title`, after `mark` (a tick; amber with `warning`). The close button in its corner.
fn note_body(
  parent : @view.View,
  title : () -> String,
  path : String,
  play : () -> Unit,
  reveal : () -> Unit,
  close : () -> Unit,
  warning? : Bool = false,
  mark? : String = "check-circle",
) -> Unit {
  parent.padding(Is(if path == "" { (14.0, 0.0, 8.0, 0.0) } else { (14.0, 14.0, 14.0, 14.0) })).gap(Is(12.0)) |> ignore
  if path == "" {
    parent.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(10.0)) |> ignore
    @sf.icon_node(parent, if warning { "info" } else { mark }, 16.0, By(fn() {
      if warning {
        0xD08A1EFFL
      } else {
        ui_muted()
      }
    }))
    |> ignore
    words(parent, title, 13.0, ui_text, weight=500).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true))
    |> ignore
    icon_button(parent, fn() { "close" }, fn() { t("关闭") }, close, w=28.0, h=28.0, size=12.0) |> ignore
    return
  }
  let name = match path.rev_find("\\") {
    Some(i) => path[i + 1:].to_owned()
    None => path
  }
  parent.box(fn(head) {
    head.row(Is(true)).height(Is(Some(72.0))).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
    pressable(head, fn() { t("播放") }, play, fn(pic) {
      pic
      .width(Is(Some(128.0)))
      .height(Is(Some(72.0)))
      .radius(Is(6.0))
      .clips(Is(true))
      .ground(Is(picture_ground))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .edge(By(fn() { (1.0, if pic.pointed() { tone(0xFFFFFF33L, 0x00000040L) } else { hair2() }) }))
      .image(By(fn() {
        clips_rev.get() |> ignore
        let k = clip_thumb(path)
        if k == "" || k == "!" {
          None
        } else {
          Some((k, "", 256))
        }
      }))
      .image_contains(Is(true))
      |> ignore
      // its length on its corner, as the library's cards have it
      pic.box(fn(o) {
        o.over(Is(true)).pad(Is(5.0)).lines_up(Is(Some(End))).lies_along(Is(End)) |> ignore
        let ms = clip_duration(path)
        if ms > 0.0 {
          o.box(fn(tag) {
            tag.height(Is(Some(18.0))).padding(Is((5.0, 0.0, 5.0, 0.0))).radius(Is(4.0)).ground(Is(0x000000B3L)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
            words(tag, fn() { clock(ms) }, 11.0, fn() { 0xFFFFFFFFL }, weight=500) |> ignore
          })
          |> ignore
        }
      })
      |> ignore
      // under the pointer, a play mark over it
      pic.box(fn(o) {
        o
        .over(Is(true))
        .presses(Is(false))
        .ground(Is(0x00000040L))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .alpha(By(fn() { if pic.pointed() { 1.0 } else { 0.0 } }))
        |> ignore
        o.box(fn(c) {
          c.width(Is(Some(28.0))).height(Is(Some(28.0))).radius(Is(14.0)).ground(Is(0xFFFFFFE6L)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
          @sf.icon_node(c, "play", 13.0, Is(0x0F1011FFL)) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // what was saved, its date, its size: in the middle of the picture's height
    head.box(fn(says) {
      says.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).gap(Is(4.0)) |> ignore
      says.box(fn(top) {
        top.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
        @sf.icon_node(top, "check-circle", 14.0, By(ui_muted)) |> ignore
        words(top, title, 13.0, ui_text, weight=600).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true))
        |> ignore
      })
      |> ignore
      words(says, fn() { clip_title(name) }, 12.0, ui_muted).allow_ellipsis(Is(true)).min_width(Is(Some(0.0))) |> ignore
      words(says, fn() {
        let mb = (rp_size(cstr(path)) / 1048576.0).to_int()
        if mb < 1 {
          t("小于 1 MB")
        } else {
          "\{mb} MB"
        }
      }, 12.0, ui_subtle)
      |> ignore
    })
    |> ignore
    // (the close button at the head's right, its top with the picture's)
    head.box(fn(c) {
      c.height(Is(Some(72.0))) |> ignore
      icon_button(c, fn() { "close" }, fn() { t("关闭") }, close, w=24.0, h=24.0, size=12.0) |> ignore
    })
    |> ignore
  })
  |> ignore
  // what can be done with it: three buttons sharing the card's width
  parent.box(fn(acts) {
    acts.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
    let even = fn(b : @view.View) { b.grow(Is(1.0)).basis(Is(Some(0.0))).lies_along(Is(Middle)) |> ignore }
    even(text_button(acts, fn() { t("播放") }, play, icon="play", small=true))
    even(
      text_button(acts, fn() { if note_copied.get() == path { t("已复制") } else { t("复制") } }, fn() {
        if rp_copy_file(cstr(path)) == 1 {
          note_copied.set(path)
        }
      }, icon="copy", small=true),
    )
    even(text_button(acts, fn() { t("打开位置") }, reveal, icon="folder", small=true))
  })
  |> ignore
}

///|
/// A clip being saved: one quiet line (the user, 2026-11-18: 「saving过程我觉得应该降低打扰，不用这么大卡片」), its dot
/// breathing; the card grows to the clip's once it is made.
fn note_pending(parent : @view.View, title : () -> String, close : () -> Unit) -> Unit {
  parent.padding(Is((14.0, 0.0, 8.0, 0.0))).row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(10.0)) |> ignore
  parent.box(fn(d) {
    d.width(Is(Some(16.0))).height(Is(Some(16.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    d.box(fn(dot) {
      dot.width(Is(Some(8.0))).height(Is(Some(8.0))).radius(Is(4.0)).ground(By(ui_muted)).alpha(By(fn() { note_breath(dot) })) |> ignore
    })
    |> ignore
  })
  |> ignore
  words(parent, title, 13.0, ui_text, weight=500).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true))
  |> ignore
  icon_button(parent, fn() { "close" }, fn() { t("关闭") }, close, w=28.0, h=28.0, size=12.0) |> ignore
}

///|
/// How much of a shape being waited for shows: from 0.55 to 1 and back over 1.4 s, still where motions are off.
fn note_breath(v : @view.View) -> Double {
  if motion_off() {
    return 0.8
  }
  let k = v.cycle(1400.0)
  0.775 + 0.225 * @math.cos(k * 2.0 * 3.141592653589793)
}

///|
/// What the recorder asks the card to show, as note.json beside the buffer has it ({"id", "mode": "saved" | "text",
/// "path", "text", "warn"}), or as the card was started with (REPLAY_NOTE…, where none was kept warm): its id, mode,
/// clip ("" while being saved), line, whether a warning.
#derive(Eq)
priv struct NoteAsk {
  id : Int
  mode : String
  path : String
  text : String
  warn : Bool
}

///|
fn note_file_ask() -> NoteAsk? {
  match parse(read_text(root_dir() + "\\note.json")) {
    Some(Object(o)) => {
      let str = fn(k) {
        match o.get(k) {
          Some(String(v)) => v
          _ => ""
        }
      }
      let id = match o.get("id") {
        Some(Number(n, ..)) => n.to_int()
        _ => -1
      }
      Some({ id, mode: str("mode"), path: str("path"), text: str("text"), warn: o.get("warn") is Some(True) })
    }
    _ => None
  }
}

///|
/// The card by the tray, as made once: the whole window is the card. Kept warm (REPLAY_NOTE=warm: started with the
/// recorder, drawn once unseen, hidden), it shows what the recorder asks the moment it is asked (the recorder shows its
/// window, rp_note_ask, and its look here finds the ask): started only then, it took a second to come up, by when a
/// clip was saved already (the user, 2026-11-18, 「我没看到这个啊？」 of the line shown while saving). Gone, the
/// process ends; the recorder keeps another warm.
fn note_window(root : @view.View) -> Unit {
  the_root.val = Some(root)
  root.tree.hand_over_presses(false)
  @ui.set_tree_theme(@sf.ui_theme_now)
  load_prefs()
  ask_system(root)
  keep_theme(root)
  load_settings()
  root.ground(By(c_s2)) |> ignore
  let gone = fn() { @hostapi.exit(0) }
  // (kept warm: what was asked before it was started is no ask of its own (another card's, shown or gone), only
  // what comes after; it once came up of itself with the last card's ask, saving that never ended)
  let first : NoteAsk = if note_mode() == "warm" {
    let id = match note_file_ask() {
      Some(f) => f.id
      None => -1
    }
    { id, mode: "", path: "", text: "", warn: false }
  } else {
    {
      // (its id the ask the recorder wrote before starting it, so the same ask is not taken again)
      id: match note_file_ask() {
        Some(f) => f.id
        None => 0
      },
      mode: note_mode(),
      path: @ui.env("REPLAY_NOTE_PATH"),
      text: @ui.env("REPLAY_NOTE_TEXT"),
      warn: @ui.env("REPLAY_NOTE_WARN") == "1",
    }
  }
  let ask : @signals.Signal[NoteAsk] = @signals.signal(first)
  // (gone after its time, counted once there is something whole to show, later while the pointer is over it)
  fn leave() -> Unit {
    if root.pointed() {
      again(root, 1000.0, leave)
    } else {
      gone()
    }
  }
  let height = fn(a : NoteAsk) { if a.mode == "saved" && a.path != "" { note_clip_h } else { note_line_h } }
  // (seen: made the card's size at the tray's corner, cloaked, and let be seen once a frame of it is drawn)
  let shown_at = Ref(-1.0)
  let show = fn(a : NoteAsk) {
    rp_note_window(note_w, height(a), 1) |> ignore
    // (by the wall's clock, as all its times: a card kept hidden comes up with its tree's clock where it hid, and what
    // it is asked is first looked at as of then; timed by that, its 30 s of saving were long gone and it went at once,
    // the user, 2026-11-18: 「saving 状态一闪而过」)
    again(root, 60.0, fn() { rp_note_reveal() })
    shown_at.val = rp_now()
    if a.mode != "saved" || a.path != "" {
      again(root, if a.mode == "saved" { 8000.0 } else { 4000.0 }, leave)
    }
  }
  if first.mode != "" {
    root.at_moment(now() + 1.0, fn() { show(first) }) |> ignore
  } else {
    // (warm: drawn once unseen, then hidden till asked)
    root.at_moment(now() + 1.0, fn() { rp_note_window(note_w, note_line_h, 1) |> ignore }) |> ignore
    root.at_moment(now() + 2500.0, fn() { if ask.untracked().mode == "" { rp_note_hide() } }) |> ignore
  }
  // what the recorder asks, looked for while the card is up (a hidden window's looks wait for it to show)
  fn look() -> Unit {
    let was = ask.untracked()
    match note_file_ask() {
      Some(a) if a.mode != "" && (a.id > was.id || (a.id == was.id && was.mode != "")) => {
        if a.id != was.id {
          ask.set(a)
          show(a)
        } else if a.path != was.path {
          ask.set(a)
          // (grown to the clip's card, its foot where it was)
          rp_note_window(note_w, height(a), 0) |> ignore
          again(root, 8000.0, leave)
        }
      }
      _ => ()
    }
    // (a clip being saved 30 s on with no word of it: gone)
    let a = ask.untracked()
    if a.mode == "saved" && a.path == "" && shown_at.val >= 0.0 && rp_now() - shown_at.val > 30000.0 {
      gone()
    }
    again(root, 100.0, look)
  }
  look()
  root.box(fn(card) {
    card.grow(Is(1.0)) |> ignore
    card.pick(fn() { ask.get() }, fn(b, a) {
      b.grow(Is(1.0)) |> ignore
      if a.mode == "saved" && a.path == "" {
        note_pending(b, fn() { tf("正在保存最近 {0} 秒…", [settings.last_seconds.to_string()]) }, gone)
      } else if a.mode == "saved" {
        let path = a.path
        note_body(b, fn() { tf("已保存最近 {0} 秒", [settings.last_seconds.to_string()]) }, path, fn() {
          rp_launch(cstr(path)) |> ignore
          gone()
        }, fn() {
          rp_reveal(cstr(path))
          gone()
        }, gone)
      } else if a.mode == "text" {
        note_body(b, fn() { a.text }, "", gone, gone, gone, warning=a.warn)
      }
    }, at_once=true)
  })
  |> ignore
}
