// What the band holds besides its stretches (timeline_view.mbt), as nodes bound to the view, the buffer and the
// playhead: the stretch under the playhead lighter, each stretch's app (its icon and name), the markers, the clip's
// frame, the line where the pointer is and the card of that moment's picture over the video, the chip that says where
// the playhead is when it is out of view.

///|
/// The band, as the timeline is made.
let band_node : Ref[@view.View?] = Ref(None)

///|
/// The dock's room over the timeline (its heat lane in it): the timeline's own, so the hover reaches it.
let dock_over : Double = 18.0

///|
/// What the hover is found over: the timeline's block, the band, the heat lane over it and the room above that.
let hover_node : Ref[@view.View?] = Ref(None)

///|
/// Where the pointer is across the band, a quarter of a point at least (None: not over it, nor holding it), followed
/// as the pointer moves and as what is under it moves: worked out by the tree as it places things (View::pointer_piece),
/// whatever is drawn over the band there.
fn hover_now() -> Double? {
  guard band_node.val is Some(band) else { return None }
  // (not while the overview's viewfinder is held: the pointer is over the timeline's block then, but on what it holds)
  if view_dragging.get() {
    return None
  }
  // (across the timeline's block, as wide as the band and from the same left)
  let b = match hover_node.val {
    Some(h) => h
    None => band
  }
  if !b.pointer_within() && grabbed.get() != 3 {
    return None
  }
  let q = b.pointer_piece(fn(x, _) { (@cmp.maximum(0.0, x) * 4.0).round().to_int() })
  if q < 0 {
    None
  } else {
    Some(q.to_double() / 4.0)
  }
}

///|
/// Told every 400 ms while the scrub index is making pictures: what shows one looks for it again.
let idx_tick : @signals.Signal[Int] = @signals.signal(0)

///|
fn index_watch(root : @view.View) -> Unit {
  if rp_idx_pending() > 0 {
    idx_tick.set(idx_tick.untracked() + 1)
  }
  again(root, 400.0, fn() { index_watch(root) })
}

///|
/// The moment (ms into the buffer) at `x` across the band `w` wide, as the view is shown now.
fn at_x(x : Double, w : Double) -> Double {
  let (from, len) = shown_now()
  let vlen = @signals.untracked(view_len)
  if w <= 0.0 {
    ax_b(from, vlen)
  } else {
    ax_b(from + clamp(x / w, 0.0, 1.0) * len, vlen)
  }
}

///|
/// The moment (ms into the buffer) at `x` across the band `w` wide, as node `v` draws it (bound).
fn at_x_drawn(v : @view.View, x : Double, w : Double) -> Double {
  let (from, len) = shown(v)
  ax_b(from + clamp(x / @cmp.maximum(1.0, w), 0.0, 1.0) * len, view_len())
}

///|
/// Where moment `at` lies across the band as node `v` draws it.
fn x_drawn_of(v : @view.View, at : Double, w : Double) -> Double {
  let (from, len) = shown(v)
  (ax_d(at, view_len()) - from) / len * w
}

///|
/// The stretch under the playhead a step lighter (s4 over s2).
fn current_piece(parent : @view.View, w : () -> Double) -> Unit {
  parent.box(fn(o) {
    o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(b) {
      // (the piece the playhead is in, where it is across: its start and width)
      let rect = fn() -> (Double, Double)? {
        let p = pos_drawn(b)
        for pc in pieces_now.get() {
          if p >= pc.0 && p < pc.1 {
            let a = clamp(x_drawn_of(b, pc.0, w()), 0.0, w())
            let z = clamp(x_drawn_of(b, pc.1, w()), 0.0, w())
            return if z - a >= 2.0 { Some((a, z - a - 1.0)) } else { None }
          }
        }
        None
      }
      b
      .height(Is(Some(strip_h)))
      .ground(By(c_s4))
      .laid_nowhere(By(fn() { rect() is None }))
      .width(By(fn() { Some(rect().map(fn(r) { r.1 }).unwrap_or(0.0)) }))
      .offset(By(fn() { (rect().map(fn(r) { r.0 }).unwrap_or(0.0), 0.0) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The app icon files found (process, lower case -> path, "" when none).
let app_icons_found : Map[String, String] = Map([])

///|
fn app_icon_path(process : String) -> String {
  if process == "" {
    return ""
  }
  let key = process.to_lower()
  match app_icons_found.get(key) {
    Some(p) => p
    None => {
      let path = root_dir() + "\\AppIcons\\" + key + ".png"
      let found = if rp_size(cstr(path)) > 0.0 { path } else { "" }
      app_icons_found[key] = found
      found
    }
  }
}

///|
/// The icon of the app a process belongs to, `size` square: the one the recorder kept of it (AppIcons\<name>.png), else
/// its first letter on s4.
fn app_icon(parent : @view.View, process : String, size? : Double = 16.0) -> Unit {
  let path = app_icon_path(process)
  if path != "" {
    parent.box(fn(i) {
      i.width(Is(Some(size))).height(Is(Some(size))).image(Is(Some((path, "", 64)))).image_contains(Is(true)) |> ignore
    })
    |> ignore
  } else {
    let name = app_name(process)
    let letter = if name.length() > 0 { name[:1].to_owned().to_upper() } else { "·" }
    parent.box(fn(i) {
      i
      .width(Is(Some(size)))
      .height(Is(Some(size)))
      .radius(Is(size * 0.22))
      .ground(By(c_s4))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      |> ignore
      words(i, fn() { letter }, 9.0, ui_text, weight=600) |> ignore
    })
    |> ignore
  }
}

///|
/// How soft a stretch's name's halo is: its blur's sigma in points (3: a blur of 6 as CSS says one).
let name_halo : Double = 3.0

///|
/// Each stretch's app: its icon where 30 points fit, its name where 52 do, cut short where it has not the room (9 in, 7
/// between; the reviewer's 75th: 72 left a stretch of a minute's time with its icon alone).
fn piece_labels(parent : @view.View, w : () -> Double) -> Unit {
  parent.box(fn(o) {
    o.over(Is(true)).presses(Is(false)) |> ignore
    // (only the pieces in reach of the view and wide enough to ever show an icon (30 pt): the view's length either side
    // of it, on steps of its length (and on steps of 1.5x scale while resizing the overview), so the list changes only
    // as the view moves on by a whole length or steps scale; all of the buffer's, or hundreds of sub-30pt stretches when
    // zoomed out, held a drag or resize of the overview up for hundreds of ms where apps came and went often)
    let reach_held : Ref[(Double, Double, Double)?] = Ref(None)
    let reach = @signals.computed(fn(_) {
      let (from, len) = shown(o)
      let width = @cmp.maximum(1.0, w())
      if view_resizing.get() {
        let q_len = min_view * @math.pow(1.5, (@math.ln(@cmp.maximum(1.0, len / min_view)) / @math.ln(1.5)).floor())
        let at = (from / q_len).floor() * q_len
        let min_dur = 30.0 / width * q_len
        let r = (at - q_len, at + 3.0 * q_len, min_dur)
        reach_held.val = Some(r)
        return r
      }
      let at = (from / len).floor() * len
      let min_dur = 30.0 / width * len
      let c = (at - len, at + 2.0 * len, min_dur)
      match (view_dragging.get(), reach_held.val) {
        (true, Some(h)) if h.2 == min_dur && from >= h.0 && from + len <= h.1 => h
        _ => {
          reach_held.val = Some(c)
          c
        }
      }
    }, same=fn(a, b) { a == b })
    o.each(fn() {
      let (a, z, min_dur) = reach.get()
      // (the reach is along the view's axis: a filter's, axis.mbt, where one is on)
      let vl = view_len()
      pieces_now
      .get()
      .filter(fn(p) {
        if p.2 == "" || p.1 - p.0 < min_dur {
          return false
        }
        let d0 = ax_d(p.0, vl)
        let d1 = ax_d(p.1, vl)
        d1 - d0 >= min_dur && d1 > a && d0 < z
      })
    }, fn(p) { "\{p.0}/\{p.2}" }, fn(row, p) {
      let app = @signals.untracked(fn() { p.get().2 })
      row.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
      row.box(fn(b) {
        let span = fn() {
          let (a0, z0, _) = p.get()
          let a = clamp(x_drawn_of(b, a0, w()), 0.0, w())
          let z = clamp(x_drawn_of(b, z0, w()), 0.0, w())
          (a, z - a - 1.0)
        }
        b
        .row(Is(true))
        .height(Is(Some(strip_h)))
        .padding(Is((9.0, 0.0, 6.0, 0.0)))
        .gap(Is(7.0))
        .lines_up(Is(Some(Middle)))
        .clips(Is(true))
        .laid_nowhere(By(fn() { span().1 < 30.0 }))
        .width(By(fn() { Some(@cmp.maximum(0.0, span().1)) }))
        .offset(By(fn() { (span().0, 0.0) }))
        |> ignore
        // (the name on a soft halo of the stretch's own ground, the loudness behind it pushed back, never cut by a hard
        // edge: the user's pick, 2026-11-14, 「L4a 柔和光晕」; mbui's own halo of the words (View::words_halo), no box
        // under them, the user, 2026-11-15; the icon as it is)
        b.box(fn(lab) {
          lab.row(Is(true)).gap(Is(7.0)).lines_up(Is(Some(Middle))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          app_icon(lab, app, size=14.0)
          lab.box(fn(n) {
            // (down to nothing: its least of four of its size is wider than a short stretch leaves it)
            n.laid_nowhere(By(fn() { span().1 < 52.0 })).shrink(Is(1.0)).cuts(Is(true)).min_width(Is(Some(0.0))) |> ignore
            words(n, fn() { app_name(app) }, 12.0, ui_text).words_halo(By(fn() { (name_halo, c_s2()) })) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }, at_once=true)
  })
  |> ignore
}

///|
/// Where nothing was recorded, its words in its middle where 72 points fit (未录制).
fn gap_labels(parent : @view.View, w : () -> Double) -> Unit {
  parent.box(fn(o) {
    o.over(Is(true)).presses(Is(false)) |> ignore
    o.each(fn() {
      gaps_now.get()
    }, fn(g) { g.0 }, fn(row, g) {
      row.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
      row.box(fn(b) {
        let span = fn() {
          let (a0, z0) = g.get()
          let a = clamp(x_drawn_of(b, a0, w()), 0.0, w())
          let z = clamp(x_drawn_of(b, z0, w()), 0.0, w())
          (a, z - a - 1.0)
        }
        b
        .height(Is(Some(strip_h)))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .laid_nowhere(By(fn() { span().1 < 72.0 }))
        .width(By(fn() { Some(@cmp.maximum(0.0, span().1)) }))
        .offset(By(fn() { (span().0, 0.0) }))
        |> ignore
        words(b, fn() { t("未录制") }, 11.0, ui_subtle) |> ignore
      })
      |> ignore
    }, at_once=true)
  })
  |> ignore
}

///|
/// The marker's head (the user's pick, 2026-11-13: 「F 定位针」): a pin 16 by 21, its tip at (8, 20.5), a round hole in
/// it of the ground's colour, edged 1.25 in the ground's colour under its fill.
let pin_d : String = "M8 20.5C8 20.5.75 13.2.75 8a7.25 7.25 0 0 1 14.5 0c0 5.2-7.25 12.5-7.25 12.5z"

///|
let pin_hole_d : String = "M5.4 8a2.6 2.6 0 1 0 5.2 0a2.6 2.6 0 1 0-5.2 0z"

///|
fn pin_picture(fill : Int64, ground : Int64) -> @pixels.Vector {
  {
    w: 16.0,
    h: 21.0,
    layers: [
      // (its shadow, 0 1 2 at 45%: drawn as the pin a point down in two rings fading out, the picture having no blur)
      { ..layer(pin_d, 0L, stroke=0x0000001AL, width=2.5), ty: 1.0 },
      { ..layer(pin_d, 0x00000040L, stroke=0x00000033L, width=1.25), ty: 1.0 },
      layer(pin_d, ground, stroke=ground, width=1.25),
      layer(pin_d, fill),
      layer(pin_hole_d, ground),
    ],
  }
}

///|
/// A marker under others: the sunk grey (s4 dark; light's #AEB3BB).
fn pin_covered() -> Int64 {
  tone(0x484A51FFL, 0xAEB3BBFFL)
}

///|
/// The marker the pointer is over (its moment), None none: brought in front of the others and lit.
let mark_pointed : @signals.Signal[Double?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
/// The markers' moments in order, and the next one after `abs` (None: the last).
fn mark_after(abs : Double) -> Double? {
  data()
  let mut next : Double? = None
  for m in marks {
    if m > abs && (next is None || m < next.unwrap()) {
      next = Some(m)
    }
  }
  next
}

///|
/// The markers: each a pin over the track, its tip at its moment 1 over the track's top. One closer to the next than a
/// pin is wide is under it (the later on top), sunk grey, and is pressed only where it shows; the one the pointer is
/// over comes in front, lit. Pressed, the playhead goes to it; its time in a tip; a right click takes it away. Never a
/// line across the track (the user, 2026-11-13: 「不需要穿过时间线」).
fn marks_layer(band : @view.View, w : () -> Double) -> Unit {
  band.box(fn(o) {
    o.over(Is(true)) |> ignore
    o.each(fn() {
      data()
      let all = marks.copy()
      all.sort()
      all
    }, fn(m) { m }, fn(row, m) {
      let abs = m.untracked()
      row.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
      pressable(row, fn() { wall(abs) }, fn() { seek_to(abs - t0()) }, fn(b) {
        // (just added here: it grows out of its tip over 220 ms, eased out, so the press is seen to have done it)
        let grow : @motion.NodeWay? = if abs == just_marked.val && !motion_off() {
          just_marked.val = -1.0
          let way = @motion.NodeWay::new(0.3)
          way.go_ms(b, 1.0, 220.0)
          Some(way)
        } else {
          None
        }
        let x = fn() { x_drawn_of(b, abs - t0(), w()) }
        // (how much of it shows: up to the next one's left edge)
        let shows = fn() {
          match mark_after(abs) {
            Some(n) => clamp(x_drawn_of(b, n - t0(), w()) - x(), 4.0, 16.0)
            None => 16.0
          }
        }
        let covered = fn() { shows() < 16.0 }
        b.reacts(fn() { b.pointed() }, fn(on) {
          if on {
            mark_pointed.set(Some(abs))
          } else if mark_pointed.untracked() == Some(abs) {
            mark_pointed.set(None)
          }
        })
        b
        .width(By(fn() { Some(shows()) }))
        .height(Is(Some(21.0)))
        .laid_nowhere(By(fn() { x() < 0.0 || x() > w() }))
        .offset(By(fn() { (x() - 8.0, -21.5) }))
        .on_menu(fn(m) {
          let at = abs - t0()
          open_menu(m.wx, m.wy, [
            Some({
              label: t("移除这里的标记"),
              key: "",
              act: fn() {
                remove_marker(abs)
                tell(tf("已移除 {0} 的标记", [wall(abs)]), icon="bookmark")
              },
            }),
            None,
            Some({
              label: t("从这里开始剪辑"),
              key: "",
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
              label: t("剪辑到这里结束"),
              key: "",
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
        })
        |> ignore
        b.box(fn(g) {
          g
          .width(Is(Some(16.0)))
          .height(Is(Some(21.0)))
          .picture(By(fn() { Some(pin_picture(if covered() { pin_covered() } else { ui_text() }, c_bg())) }))
          |> ignore
          match grow {
            Some(way) => g.scale(By(fn() { way.shown(g) }), about=At(0.5, 0.976)) |> ignore
            None => ()
          }
        })
        |> ignore
        tip(b, fn() { wall(abs) })
      })
      |> ignore
    }, at_once=true)
    // the one the pointer is over, in front of the rest, lit
    o.box(fn(f) {
      f.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
      f.box(fn(g) {
        let x = fn() {
          match mark_pointed.get() {
            Some(abs) => x_drawn_of(g, abs - t0(), w())
            None => -100.0
          }
        }
        g
        .width(Is(Some(16.0)))
        .height(Is(Some(21.0)))
        .laid_nowhere(By(fn() { mark_pointed.get() is None || x() < 0.0 || x() > w() }))
        .offset(By(fn() { (x() - 8.0, -21.5) }))
        .picture(By(fn() { Some(pin_picture(ui_text(), c_bg())) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The clip over the track: what it holds lit (a fill, no frame round it), each end a 2 wide bar the band's height with
/// a grip on it, a rounded 8 by 22 in its middle (the user, 2026-11-14: the frame 「样式感觉还是不太行，感觉可以抄一下」
/// Steam's editor: a lit stretch between two end lines). Its length is told under it, beside the play key, with where
/// the playhead is in it (clip_time), not in a tag over it (the user: 「不如 steam 那种」).
fn clip_layer(band : @view.View, w : () -> Double) -> Unit {
  band.box(fn(o) {
    o.over(Is(true)).presses(Is(false)) |> ignore
    o.show(fn() { clipping.get() }, fn(c) {
      // (coming in over 160 ms as clip mode is entered)
      let come = @motion.NodeWay::new(0.0)
      come.go_ms(c, 1.0, if motion_off() { 1.0 } else { 160.0 })
      c.over(Is(true)).lines_up(Is(Some(Start))).alpha(By(fn() { come.shown(c) })) |> ignore
      let ax = fn() { x_drawn_of(c, clip_a.get(), w()) }
      let bx = fn() { x_drawn_of(c, clip_b.get(), w()) }
      // the frame (laid out at the column's top: each drawn to its place)
      c.box(fn(f) {
        f
        .height(Is(Some(strip_h)))
        .ground(By(fn() { tone(0xEDEEF033L, 0x17181B1FL) }))
        .width(By(fn() { Some(@cmp.maximum(1.0, clamp(bx(), 0.0, w()) - clamp(ax(), 0.0, w()))) }))
        .offset(By(fn() { (clamp(ax(), 0.0, w()), 0.0) }))
        |> ignore
      })
      |> ignore
      // (each end: its line, then its grip over it; the column lays them one under another, each lifted back up)
      for end in [0, 1] {
        let x = fn() { if end == 0 { ax() } else { bx() } }
        let seen = fn() { if x() < -4.0 || x() > w() + 4.0 { 0.0 } else { 1.0 } }
        c.box(fn(l) {
          l
          .width(Is(Some(2.0)))
          .height(Is(Some(strip_h)))
          .ground(By(ui_accent))
          .alpha(By(seen))
          .offset(By(fn() { (x() - 1.0, -(if end == 0 { strip_h } else { 2.0 * strip_h + 22.0 })) }))
          |> ignore
        })
        |> ignore
        c.box(fn(g) {
          g
          .width(Is(Some(8.0)))
          .height(Is(Some(22.0)))
          .radius(Is(4.0))
          .ground(By(ui_accent))
          .edge(By(fn() { (1.0, tone(0x00000066L, 0xFFFFFF99L)) }))
          .alpha(By(seen))
          .offset(By(fn() { (x() - 4.0, (strip_h - 22.0) / 2.0 - (if end == 0 { 2.0 * strip_h } else { 3.0 * strip_h + 22.0 })) }))
          |> ignore
        })
        |> ignore
      }
    }, at_once=true)
  })
  |> ignore
}

///|
/// A line where the pointer is over the band (not while it is held).
fn hover_line(band : @view.View, w : () -> Double) -> Unit {
  band.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(l) {
      l
      .width(Is(Some(1.0)))
      .height(Is(Some(strip_h)))
      .ground(By(fn() { tone(0xA0A4AB99L, 0x4A4E5599L) }))
      .laid_nowhere(By(fn() { hover_now() is None || grabbed.get() != 0 || layer_over() }))
      .offset(By(fn() { (clamp(hover_now().unwrap_or(0.0), 0.0, w()) - 0.5, 0.0) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The playhead out of view: a chip at that side, its time and an arrow toward it; pressed, the view goes there.
fn away_chip(band : @view.View, w : () -> Double) -> Unit {
  band.box(fn(o) {
    o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
    // (-1 left of the view, 1 right of it, 0 in it)
    let side = fn(v : @view.View) {
      let (from, len) = shown(v)
      let p = ax_d(pos_drawn(v), view_len())
      if p < from {
        -1
      } else if p > from + len {
        1
      } else {
        0
      }
    }
    o.box(fn(slot) {
      slot
      .width(Is(Some(92.0)))
      .row(Is(true))
      .laid_nowhere(By(fn() { side(slot) == 0 }))
      .lies_along(By(fn() { if side(slot) < 0 { Start } else { End } }))
      .offset(By(fn() { (if side(slot) < 0 { 0.0 } else { w() - 92.0 }, -23.0) }))
      |> ignore
      pressable(slot, fn() { t("回到播放头") }, fn() { reveal(pos_now()) }, fn(b) {
        let (hand, _) = answer(b)
        b
        .row(Is(true))
        .height(Is(Some(19.0)))
        .padding(Is((7.0, 0.0, 7.0, 0.5)))
        .gap(Is(4.0))
        .radius(Is(6.0))
        .lines_up(Is(Some(Middle)))
        .ground(By(fn() { mix(ui_accent(), ui_accent_hover(), hand.shown(b)) }))
        |> ignore
        words(b, fn() { if side(b) < 0 { "‹" } else { "" } }, 12.0, ui_on_accent, weight=600) |> ignore
        words(b, fn() { wall(t0() + pos_drawn(b)) }, 11.0, ui_on_accent, weight=600) |> ignore
        words(b, fn() { if side(b) > 0 { "›" } else { "" } }, 12.0, ui_on_accent, weight=600) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The card over the video where the pointer is on the band: that moment's picture (the index's, there at once), its
/// time of day, how long ago and the app in front; s1, radius 10, a hairline; fading in and out over 100 ms.
fn hover_card(band : @view.View, w : () -> Double) -> Unit {
  let card_w = 288.0
  let pic_h = (card_w - 8.0) * 9.0 / 16.0
  let card_h = pic_h + 40.0
  // (the last picture drawn, kept while the one wanted is made: never an empty frame between two)
  let last_key : Ref[String] = Ref("")
  band.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
    // (the pointer's leaving the band kept for 120 ms: the user's 「hover preview这个时间轴时候会闪烁…感觉像是整张卡片闪」
    // of 2026-11-14, the whole card going out and back as the pointer moved along it: not seen under a held test
    // pointer, so whatever leaves the band with no pointer for a moment between two moves over it no longer takes the
    // card away; a pointer that has gone, the card fades out after it, where it was)
    let (left, left_lately) = o.holds_for(120.0)
    o.reacts(fn() { hover_now() is Some(_) }, fn(over) { if !over { left() } })
    let shown_now = fn() {
      (hover_now() is Some(_) || left_lately()) && (grabbed.get() == 0 || grabbed.get() == 3) && !layer_over() &&
      seam_hovered(o) is None
    }
    let fade = @motion.NodeWay::new(0.0)
    // (where it first showed, kept while it shows: the card stays put as the pointer moves along the band, its picture
    // following, as Steam's recording viewer has it: the user, 2026-11-17 「preview窗口在timeline hover的时候会固定在第一次
    // 出现的位置，我觉得合理」)
    let placed : Ref[Double?] = Ref(None)
    o.reacts(shown_now, fn(on) {
      if !on {
        placed.val = None
      }
      fade.go_ms(o, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else { 100.0 })
    })
    // (the moment the card shows, kept while it fades out)
    let at = fn() {
      match hover_now() {
        Some(x) => at_x_drawn(o, x, w())
        None => @signals.untracked(fn() { shown_now_at.val })
      }
    }
    o.box(fn(card) {
      card
      .width(Is(Some(card_w)))
      .height(Is(Some(card_h)))
      .radius(Is(10.0))
      .pad(Is(4.0))
      .ground(By(c_s1))
      .edge(By(fn() { (1.0, hair2()) }))
      .shadow(By(fn() { (30.0, 8.0, sheet_shadow()) }))
      .alpha(By(fn() { fade.shown(card) }))
      .laid_nowhere(By(fn() { fade.shown(card) <= 0.0 }))
      .offset(By(fn() {
        let a = at()
        shown_now_at.val = a
        let left = match placed.val {
          Some(x) => x
          None => {
            let x = clamp(x_drawn_of(card, a, w()) - card_w / 2.0, 0.0, @cmp.maximum(0.0, w() - card_w))
            placed.val = Some(x)
            x
          }
        }
        // (its foot 6 over the playhead's capsule (top at -23), never over it: at -14 it covered the capsule's top
        // half wherever the playhead stood under it, the user, 2026-11-17 「playhead 和 preview 好像会有重叠」)
        (left, -card_h - 29.0)
      }))
      |> ignore
      card.box(fn(pic) {
        pic
        .height(Is(Some(pic_h)))
        .radius(Is(6.0))
        .clips(Is(true))
        .ground(Is(picture_ground))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .image(By(fn() {
          data()
          idx_tick.get() |> ignore
          let a = at()
          if seg_at(t0() + a) is None {
            last_key.val = ""
            return None
          }
          let want = thumb_key(a)
          // (the next few seconds either way decoded ahead while hovering, once per half second (the index's step), so
          // they are there when the pointer gets to them; not while scrubbing the playhead, which decodes the stage's
          // keyframes)
          if grabbed.get() == 0 {
            let sec = (a / 500.0).floor().to_int()
            if sec != last_prefetch_sec.val {
              last_prefetch_sec.val = sec
              for d in [500.0, -500.0, 1000.0, -1000.0, 1500.0, -1500.0, 2000.0, -2000.0, 3000.0, -3000.0] {
                let k = thumb_key(a + d)
                if k != "" {
                  pic.image_ask(k, card_px)
                }
              }
            }
          }
          if want == "" {
            // (not made yet: the last one meanwhile, 300 ms at most; then none, and the note: missing_long)
            if missing_long.get() {
              last_key.val = ""
            }
            return if last_key.val == "" { None } else { Some((last_key.val, "", card_px.to_int())) }
          }
          // (the one wanted shown once it is decoded; till then the last one decoded stands in for it, never an empty
          // frame between two)
          let ready = pic.image_ready(want, card_px)
          let stand_in = last_key.val
          if ready {
            last_key.val = want
          }
          Some((want, if ready { "" } else { stand_in }, card_px.to_int()))
        }))
        .image_contains(Is(true))
        |> ignore
        // (a recorded moment with no picture made yet: its note after 300 ms of it, not at once)
        let missing_due : Ref[() -> Unit] = Ref(fn() {  })
        pic.reacts(fn() {
          data()
          idx_tick.get() |> ignore
          let a = at()
          seg_at(t0() + a) is Some(_) && thumb_key(a) == ""
        }, fn(missing) {
          (missing_due.val)()
          missing_long.set(false)
          if missing {
            missing_due.val = pic.at_moment(now() + 300.0, fn() { missing_long.set(true) })
          } else {
            missing_due.val = fn() {  }
          }
        })
        words(
          pic,
          fn() {
            data()
            idx_tick.get() |> ignore
            if seg_at(t0() + at()) is None {
              t("这段时间没有录制")
            } else if missing_long.get() {
              if thumb_failed(at()) {
                t("这一段没法生成预览")
              } else {
                t("正在生成预览…")
              }
            } else {
              ""
            }
          },
          12.0,
          fn() { 0x8C9199FFL },
        )
        |> ignore
      })
      |> ignore
      card.box(fn(foot) {
        foot.row(Is(true)).grow(Is(1.0)).padding(Is((6.0, 0.0, 6.0, 0.0))).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
        // (its digits all one width, the theme's tabular figures: the time running as the pointer moves never pushes
        // what follows it about, the user, 2026-11-17 「时间变化的时候，这个时间label的长度会不停变化」)
        words(foot, fn() { wall(t0() + picture_time(last_key.val, at())) }, 12.0, ui_text, weight=500) |> ignore
        words(foot, fn() { ago(t0() + at()) }, 12.0, ui_subtle) |> ignore
        spring(foot)
        // (the app's name cut short where it does not fit the card, never past its edge)
        foot.box(fn(app) {
          app.row(Is(true)).gap(Is(8.0)).shrink(Is(1.0)).cuts(Is(true)).lines_up(Is(Some(Middle))) |> ignore
          app.pick(fn() {
            data()
            app_at(at())
          }, fn(b, name) {
            b.row(Is(true)).gap(Is(8.0)).shrink(Is(1.0)).cuts(Is(true)).lines_up(Is(Some(Middle))) |> ignore
            if name != "" {
              app_icon(b, name)
              b.box(fn(n) {
                n.shrink(Is(1.0)).cuts(Is(true)) |> ignore
                words(n, fn() { app_name(name) }, 12.0, ui_muted) |> ignore
              })
              |> ignore
              // (how long the app was in front there, the stretch the pointer is over: the user, 2026-11-14
              // 「感觉这里需要有当前片段的时间」)
              words(b, fn() {
                match stretch_at(at()) {
                  Some((a, z)) => clock(z - a)
                  None => ""
                }
              }, 12.0, ui_subtle)
              |> ignore
            }
          }, at_once=true)
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
/// Whether something is over the window's own (a menu, a dialog, the saved clips, a clip playing, a window's options):
/// nothing under it answers the pointer over the timeline then.
fn layer_over() -> Bool {
  menu_up.get() ||
  settings_open.get() ||
  export_open.get() ||
  library_open.get() ||
  clip_playing.get() != "" ||
  window_options_open.get()
}

///|
/// How many pixels a hover card's picture is decoded at (its long side).
let card_px : Double = 600.0

///|
/// The hover card over a recorded moment whose picture is not made yet for 300 ms: its note shown then, not before.
let missing_long : @signals.Signal[Bool] = @signals.signal(false)

///|
/// The moment the hover card last showed (kept while it fades out).
let shown_now_at : Ref[Double] = Ref(0.0)

///|
let last_prefetch_sec : Ref[Int] = Ref(-1)

///|
/// The moment (ms into the buffer) the index picture `key` ("ix:<segment>:<ms into it>") was taken at; `at` when none.
fn picture_time(key : String, at : Double) -> Double {
  if !key.has_prefix("ix:") {
    return at
  }
  let parts = key.split(":").map(fn(p) { p.to_owned() }).to_array()
  let ms = match parse(parts[parts.length() - 1]) {
    Some(Number(v, ..)) => v
    _ => return at
  }
  let path = key[3:key.length() - parts[parts.length() - 1].length() - 1].to_owned()
  for s in segs {
    if s.path == path {
      return s.start - t0() + ms
    }
  }
  at
}
