// What is drawn over all of the window: the tips (the library's, in a layer of their own), the moment's menu (a right
// click on the band or the picture: a marker there, the clip from there or to there), and the note that a clip was
// saved. A menu up is a modal layer: what is under it takes no press, no pointer, no wheel till it goes.

///|
/// The layer the tips are drawn in, as the window is made.
let tips_layer : Ref[@view.View?] = Ref(None)

///|
let tips : @sf.TipLayer = @sf.TipLayer::new(fn() { tips_layer.val })

///|
/// A tip saying `label` by `anchor` (over it).
fn tip(anchor : @view.View, label : () -> String) -> Unit {
  @sf.tip_node(tips, anchor, label, side=Top) |> ignore
}

///|
/// One entry of a menu: its words, its key's name ("" none), what it does; None a separator.
struct MenuEntry {
  label : String
  key : String
  act : () -> Unit
}

///|
/// The menu up: where (in the window), its entries; None while none is.
let menu_shown : @signals.Signal[(Double, Double, Array[MenuEntry?])?] = @signals.signal_by(None, same=fn(a, b) {
  physical_equal(a, b)
})

///|
fn open_menu(x : Double, y : Double, entries : Array[MenuEntry?]) -> Unit {
  menu_anchor.val = None
  menu_shown.set(Some((x, y, entries)))
  menu_up.set(true)
}

///|
/// The node a menu stands under (None: at the point it was asked at).
let menu_anchor : Ref[@view.NodeId?] = Ref(None)

///|
/// The menu over what it opened from (centred on it), not under it (at its end): from the controls' row.
let menu_above : Ref[Bool] = Ref(false)

///|
/// A menu under `anchor`, its right edge at the anchor's.
fn open_menu_under(anchor : @view.View, entries : Array[MenuEntry?], above? : Bool = false) -> Unit {
  menu_shown.set(Some((0.0, 0.0, entries)))
  menu_anchor.val = Some(anchor.id())
  menu_above.val = above
  menu_up.set(true)
}

///|
fn close_menu() -> Unit {
  menu_shown.set(None)
  menu_up.set(false)
}

///|
/// The menu of a moment (`at`, ms into the buffer) at (`x`, `y`) in the window: a marker there, the clip from there or
/// to there (`at_playhead`: the playhead's, from the picture).
fn open_moment_menu(x : Double, y : Double, at : Double, at_playhead : Bool) -> Unit {
  if segs.is_empty() {
    return
  }
  open_menu(x, y, [
    Some({
      label: t(if at_playhead { "在当前位置加标记" } else { "在这里加标记" }),
      key: "",
      act: fn() { add_marker(at) },
    }),
    Some({
      label: t(if at_playhead { "复制当前帧" } else { "复制这一帧" }),
      key: if at_playhead { "Ctrl+C" } else { "" },
      act: fn() { copy_frame(at, shown=at_playhead) },
    }),
    None,
    Some({
      label: t(if at_playhead { "从当前位置开始剪辑" } else { "从这里开始剪辑" }),
      key: "I",
      act: fn() {
        let fresh = !clipping.untracked()
        set_clip_start(at)
        if fresh {
          clip_b.set(@cmp.minimum(span(), clip_a.untracked() + 30000.0))
        }
        show_clip()
      },
    }),
    Some({
      label: t(if at_playhead { "剪辑到当前位置结束" } else { "剪辑到这里结束" }),
      key: "O",
      act: fn() {
        let fresh = !clipping.untracked()
        set_clip_end(at)
        if fresh {
          clip_a.set(@cmp.maximum(0.0, clip_b.untracked() - 30000.0))
        }
        show_clip()
      },
    }),
  ])
}

///|
/// A key's name: a small chip.
fn kbd(parent : @view.View, key : String) -> Unit {
  parent.box(fn(k) {
    k
    .height(Is(Some(20.0)))
    .min_width(Is(Some(20.0)))
    .padding(Is((6.0, 0.0, 6.0, 0.0)))
    .radius(Is(5.0))
    .ground(By(c_s3))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    |> ignore
    words(k, fn() { key }, 12.0, ui_muted, weight=500) |> ignore
  })
  |> ignore
}

///|
/// The menu's panel: s2, a hairline, radius 10, 4 in, a shadow; its items 32 high, radius 6, s3 under the pointer, their
/// keys in chips after them. Pressed outside it, it goes; an item pressed does its work and the menu goes.
fn menu_layer(root : @view.View) -> Unit {
  root.box(fn(o) {
    o.over(Is(true)).over_all(Is(true)) |> ignore
    o.show(fn() { menu_shown.get() is Some(_) }, fn(m) {
      m.over(Is(true)).modal(Is(true)).presses(Is(true)).lines_up(Is(Some(Start))).on_press(close_menu) |> ignore
      m.on_menu(fn(_) { close_menu() }) |> ignore
      layer_keys(m, ["escape"])
      m.box(fn(panel) {
        // (it opens over 120 ms from 96%, faded, from where it stands)
        let open = @motion.NodeWay::new(0.0)
        open.go_ms(panel, 1.0, if motion_off() { 1.0 } else { 120.0 })
        panel
        .alpha(By(fn() { open.shown(panel) }))
        .scale(By(fn() { 0.96 + 0.04 * open.shown(panel) }), about=At(1.0, 0.0))
        .min_width(Is(Some(200.0)))
        .pad(Is(4.0))
        .ground(By(c_s2))
        .radius(Is(10.0))
        .edge(By(fn() { (1.0, hair2()) }))
        .shadow(By(fn() { (32.0, 12.0, sheet_shadow()) }))
        .presses(Is(true))
        |> ignore
        match menu_anchor.val {
          Some(a) =>
            if menu_above.val {
              panel.beside(a, side=Top, along=Middle, offset=6.0) |> ignore
            } else {
              panel.beside(a, side=Bottom, along=End, offset=6.0) |> ignore
            }
          None => ()
        }
        panel
        .offset(By(fn() {
          if menu_anchor.val is Some(_) {
            return (0.0, 0.0)
          }
          match menu_shown.get() {
            Some((x, y, es)) => {
              // (kept in the window: above the pointer where it has not the room under it)
              let (ww, wh) = panel.window()
              let mut h = 8.0
              for e in es {
                h += if e is Some(_) { 32.0 } else { 9.0 }
              }
              let x = clamp(x, 8.0, @cmp.maximum(8.0, ww - 208.0))
              let y = if y + h > wh - 8.0 { @cmp.maximum(8.0, y - h) } else { y }
              (x, y)
            }
            None => (0.0, 0.0)
          }
        }))
        |> ignore
        panel.each(fn() {
          match menu_shown.get() {
            Some((_, _, es)) => Array::makei(es.length(), fn(i) { i })
            None => []
          }
        }, fn(i) { i }, fn(row, i) {
          let entry = @signals.untracked(fn() {
            match menu_shown.get() {
              Some((_, _, es)) if i.get() < es.length() => es[i.get()]
              _ => None
            }
          })
          match entry {
            None => {
              row.padding(Is((0.0, 4.0, 0.0, 4.0))) |> ignore
              rule(row, hair)
            }
            Some(e) =>
              pressable(row, fn() { e.label }, fn() {
                close_menu()
                (e.act)()
              }, fn(b) {
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
                  words(l, fn() { e.label }, 13.0, ui_text) |> ignore
                })
                |> ignore
                if e.key != "" {
                  kbd(b, e.key)
                }
              })
              |> ignore
          }
        }, at_once=true)
      })
      |> ignore
    }, at_once=true)
  })
  |> ignore
  // (the tips over all of it, the menu too)
  root.box(fn(t) {
    t.over(Is(true)).over_all(Is(true)).presses(Is(false)) |> ignore
    tips_layer.val = Some(t)
  })
  |> ignore
}

///|
/// A word for a moment (what a press did that shows nowhere else at once: a marker added): its words and icon, and
/// how many have been said (each its own 1.6 s).
let told : @signals.Signal[(String, String, Int)] = @signals.signal(("", "", 0), same=fn(a, b) { a == b })

///|
let told_until : Ref[() -> Unit] = Ref(fn() {  })

///|
fn tell(words : String, icon? : String = "info") -> Unit {
  let n = told.untracked().2 + 1
  told.set((words, icon, n))
  (told_until.val)()
  match the_root.val {
    Some(r) =>
      told_until.val = r.at_moment(now() + 1600.0, fn() {
        if told.untracked().2 == n {
          told.set(("", told.untracked().1, n))
        }
      })
    None => ()
  }
}

///|
/// The word said, at the picture's top in its middle: a small capsule fading in over 120 ms and out over 200 ms.
fn told_layer(parent : @view.View) -> Unit {
  parent.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Middle))).padding(Is((0.0, 16.0, 0.0, 0.0))) |> ignore
    let way = @motion.NodeWay::new(0.0)
    let kept = Ref("")
    o.reacts(fn() { told.get().0 != "" }, fn(on) {
      way.go_ms(o, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else if on { 120.0 } else { 200.0 })
    })
    o.box(fn(c) {
      c
      .row(Is(true))
      .gap(Is(8.0))
      .height(Is(Some(36.0)))
      .padding(Is((12.0, 0.0, 14.0, 0.0)))
      .radius(Is(18.0))
      .ground(By(c_s1))
      .edge(By(fn() { (1.0, hair2()) }))
      .shadow(By(fn() { (24.0, 6.0, sheet_shadow()) }))
      .lines_up(Is(Some(Middle)))
      .alpha(By(fn() { way.shown(c) }))
      .offset(By(fn() { (0.0, -6.0 * (1.0 - way.shown(c))) }))
      .laid_nowhere(By(fn() { way.shown(c) <= 0.0 && told.get().0 == "" }))
      |> ignore
      @sf.icon_node(c, "", 16.0, By(ui_muted), name_now=fn() { told.get().1 }) |> ignore
      words(c, fn() {
        let w = told.get().0
        if w != "" {
          kept.val = w
        }
        kept.val
      }, 13.0, ui_text, weight=500)
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
#borrow(path)
extern "C" fn rp_frame_copy(path : Bytes, ms : Double) -> Int = "rp_frame_copy"

///|
extern "C" fn rp_frame_copy_shown(stream : Int) -> Int = "rp_frame_copy_shown"

///|
extern "C" fn rp_frame_copy_state() -> Int = "rp_frame_copy_state"

///|
/// The frame at `at` (ms into the buffer), whole and at the recording's size, put on the clipboard (a picture: pasted
/// into a chat or a document): made in the background, said when it is there (the user, 2026-11-16
/// 「给回放加一个右键复制当前帧的功能」).
/// `shown`: the frame the player shows now, as it is (the playhead's: Ctrl+C, the picture's menu), read off the GPU
/// where it is drawn from (some tens of ms for 4K), not decoded again from its key frame (the user, 2026-11-17:
/// 「这个要尽可能快，不要有性能损耗」); decoded where the player shows none.
fn copy_frame(at : Double, shown? : Bool = false) -> Unit {
  let from_player = shown &&
    (match native_made.val {
      Some(d) =>
        match d.stream {
          Some(st) => st.shown_any() && rp_frame_copy_shown(st.id()) == 1
          None => false
        }
      None => false
    })
  if !from_player {
    guard seg_at(t0() + at) is Some(i) else { return }
    let s = segs[i]
    if rp_frame_copy(cstr(s.path), t0() + at - s.start) == 0 {
      return
    }
  }
  fn wait() {
    match rp_frame_copy_state() {
      2 => tell(t("已复制当前帧"), icon="check-circle")
      3 => tell(t("没能复制到剪贴板"))
      _ =>
        match the_root.val {
          // (asked again soon: what is said is done as it is there, a frame or so after)
          Some(r) => r.at_moment(now() + 8.0, wait) |> ignore
          None => ()
        }
    }
  }
  wait()
}
