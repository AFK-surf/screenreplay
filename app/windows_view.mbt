// Picking a window to clip (clip mode): over the picture, the window under the pointer lit, a press picks it (empty
// room: the whole screen), the one picked keeping the rest under a 60% shade; under the track a strip saying where it
// was in view; in the controls' row its chip, the note of where it was not and the fix; its options in a card over
// their button.

///|
/// Where the pointer is over the picture (its own points), None off it.
let picker_at : @signals.Signal[(Double, Double)?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
/// The front windows as the picture shows them at the playhead, and the scale from the screen to the picture `w` wide.
fn picker_snap(v : @view.View, w : Double) -> (Snap, Double)? {
  data()
  let abs = t0() + pos_drawn(v)
  match snap_at(abs) {
    Some(s) if s.sw > 0.0 && w > 0.0 => Some((s, w / s.sw))
    _ => None
  }
}

///|
/// The picker's layer over the picture (window_picker).
let picker_layer : Ref[@view.View?] = Ref(None)

///|
/// The window under the pointer over the picture `w` wide, as node `v` has it: none once the pointer has left the
/// picture or something is over it.
fn picker_under(v : @view.View, w : Double) -> Win? {
  match picker_layer.val {
    Some(l) if l.pointer_within() && !layer_over() => ()
    _ => return None
  }
  match (picker_at.get(), picker_snap(v, w)) {
    (Some((x, y)), Some((s, k))) => window_under(t0() + pos_drawn(v), s.sx + x / k, s.sy + y / k)
    _ => None
  }
}

///|
/// The window lit under the pointer: none while a region is dragged, or over the region (a press there is the
/// region's).
fn hover_window(v : @view.View, w : Double) -> Win? {
  if clip_kind.get() != 1 || region_grab.get() != 0 {
    return None
  }
  match (region_on(), picker_at.get()) {
    (Some(r), Some((x, y))) => {
      let (sw, _) = rec_size()
      if sw > 0.0 && region_hit(r, w / sw, x, y) is Some(_) {
        return None
      }
    }
    _ => ()
  }
  picker_under(v, w)
}

///|
/// The picker over the picture (`pic`), in clip mode: windows to pick where they were noted, a region to drag out.
fn window_picker(pic : @view.View) -> Unit {
  pic.by_room(fn(lay, room) {
    picker_layer.val = Some(lay)
    let w = fn() { room.width() }
    // (a click: the window under it picked, the one picked let go, empty room the whole screen; with no windows noted
    // and no region, playing or pausing as the picture's own press does)
    let click = fn(x : Double, y : Double) {
      if snaps.is_empty() {
        set_playing(!want_play.untracked())
        return
      }
      let under = @signals.untracked(fn() {
        match picker_snap(lay, room.width()) {
          Some((s, k)) => window_under(t0() + pos_drawn(lay), s.sx + x / k, s.sy + y / k)
          None => None
        }
      })
      match under {
        Some(u) if u.hwnd == picked_hwnd.untracked() => pick_window(None)
        _ => pick_window(under)
      }
    }
    lay
    .over(Is(true))
    // (in clip mode: a region is dragged out with or without the windows noted)
    // (in 整屏 none: a press on the picture plays or pauses as ever)
    .presses(By(fn() { clipping.get() && clip_kind.get() != 0 }))
    .cursor(By(fn() {
      if !clipping.get() {
        return Some(Arrow)
      }
      if clip_kind.get() == 1 {
        // (a window to pick under the pointer)
        return Some(if hover_window(lay, w()) is Some(_) { Arrow } else { Arrow })
      }
      let (sw, _) = rec_size()
      match region_cursor(if sw > 0.0 { w() / sw } else { 1.0 }, picker_at.get()) {
        Some(c) => Some(c)
        // (outside it: room to drag one out)
        None => Some(Crosshair)
      }
    }))
    .on_pointer_moved(fn() {
      (pointer_moved.val)()
      picker_at.set(lay.pointer_here())
    })
    .on_drag(fn(d) { region_drag(d, room.width(), click, @signals.untracked(fn() { clip_kind.get() == 2 })) }, captures=true)
    |> ignore
    lay.show(fn() { clipping.get() }, fn(o) {
      o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
      // (the picture's height for its width: the recording's shape)
      let h = fn() { w() / picture_aspect.get() }
      let to_view = fn(s : Snap, k : Double, r : (Double, Double, Double, Double)) {
        ((r.0 - s.sx) * k, (r.1 - s.sy) * k, r.2 * k, r.3 * k)
      }
      // the shade round the window picked, its frame, the frame of the one under the pointer
      o.box(fn(p) {
        p
        .width(By(fn() { Some(w()) }))
        .height(By(fn() { Some(h()) }))
        .picture(By(fn() {
          let width = w()
          let height = h()
          let layers : Array[@pixels.VectorPath] = []
          // (a side on the picture's own edge drawn not at all: there the picture's edge is the frame, and a line
          // there would stand out of the picture as a rim round it)
          let frame = fn(r : (Double, Double, Double, Double), fill : Int64) {
            let (rx, ry, rw, rh) = r
            if fill != 0L {
              layers.push(layer(rect_d(rx, ry, rw, rh), fill))
            }
            let top = ry > 0.5
            let left = rx > 0.5
            let right = rx + rw < width - 0.5
            let bottom = ry + rh < height - 0.5
            let side = fn(x : Double, y : Double, sw : Double, sh : Double, ink : Int64) {
              layers.push(layer(rect_d(x, y, sw, sh), ink))
            }
            let white = 0xEDEEF0E6L
            if top {
              side(rx - 2.0, ry - 2.0, rw + 4.0, 1.0, over_picture_edge)
              side(rx - 1.0, ry - 1.0, rw + 2.0, 2.0, white)
            }
            if bottom {
              side(rx - 2.0, ry + rh + 1.0, rw + 4.0, 1.0, over_picture_edge)
              side(rx - 1.0, ry + rh - 1.0, rw + 2.0, 2.0, white)
            }
            if left {
              side(rx - 2.0, ry - 2.0, 1.0, rh + 4.0, over_picture_edge)
              side(rx - 1.0, ry - 1.0, 2.0, rh + 2.0, white)
            }
            if right {
              side(rx + rw + 1.0, ry - 2.0, 1.0, rh + 4.0, over_picture_edge)
              side(rx + rw - 1.0, ry - 1.0, 2.0, rh + 2.0, white)
            }
          }
          let shade = 0x08090A99L
          // (the rest of the picture shaded round what is kept: one path, the picture with what is kept cut out of it
          // (wound the other way). Four rectangles meeting at the kept edges' rows, off the pixel grid at 150%, each
          // covered a shared pixel row in part, together less than the shade: a light line across the whole picture
          // at its top and bottom edges (the user, 2026-11-16: 「area select时，看起来视窗有白色线」))
          let shade_round = fn(r : (Double, Double, Double, Double)) {
            let (rx, ry, rw, rh) = r
            let x0 = clamp(rx, 0.0, width)
            let y0 = clamp(ry, 0.0, height)
            let x1 = clamp(rx + rw, x0, width)
            let y1 = clamp(ry + rh, y0, height)
            let hole = "M\{x0} \{y0}V\{y1}H\{x1}V\{y0}Z"
            layers.push(layer(rect_d(0.0, 0.0, width, height) + hole, shade))
          }
          let snap = picker_snap(p, width)
          match region_on() {
            Some(r) => {
              let (sw, _) = rec_size()
              let k = if sw > 0.0 { width / sw } else { 1.0 }
              let v = (r.0 * k, r.1 * k, r.2 * k, r.3 * k)
              let (rx, ry, rw, rh) = v
              shade_round(v)
              // (thirds while the hand is on it)
              if region_grab.get() != 0 {
                let third = 0xFFFFFF47L
                for i in 1..<3 {
                  let f = i.to_double() / 3.0
                  layers.push(layer(rect_d(rx + rw * f - 0.5, ry, 1.0, rh), third))
                  layers.push(layer(rect_d(rx, ry + rh * f - 0.5, rw, 1.0), third))
                }
              }
              // its frame as the user picked it (方案 A, 2026-11-16, over the 2 wide white line in a black one and its
              // 8 square handles: 「感觉这个框选框不好看」): a 1 wide line just outside it (a side on the picture's own
              // edge left out, as `frame`'s), L marks 12 long and 3 thick at its corners, and while selected a bar 16
              // by 3 at each side's middle; the marks each on a faint dark rim so they hold on a light picture
              let line = 0xEDEEF0E6L
              let white = 0xEDEEF0FFL
              let rim = 0x00000073L
              if ry > 0.5 {
                layers.push(layer(rect_d(rx - 1.0, ry - 1.0, rw + 2.0, 1.0), line))
              }
              if ry + rh < height - 0.5 {
                layers.push(layer(rect_d(rx - 1.0, ry + rh, rw + 2.0, 1.0), line))
              }
              if rx > 0.5 {
                layers.push(layer(rect_d(rx - 1.0, ry, 1.0, rh), line))
              }
              if rx + rw < width - 0.5 {
                layers.push(layer(rect_d(rx + rw, ry, 1.0, rh), line))
              }
              let mark = fn(d : String) {
                layers.push(layer(d, 0L, stroke=rim, width=2.0))
                layers.push(layer(d, white))
              }
              let (arm, thick) = (12.0, 3.0)
              for hx in [-1, 1] {
                for hy in [-1, 1] {
                  let sx = hx.to_double()
                  let sy = hy.to_double()
                  // (its outer corner 3 out from the region's, held inside the picture; its arms back along the sides)
                  let ex = if hx < 0 { rx } else { rx + rw }
                  let ey = if hy < 0 { ry } else { ry + rh }
                  let px = clamp(ex + sx * thick, 0.0, width)
                  let py = clamp(ey + sy * thick, 0.0, height)
                  let ax = px - sx * arm
                  let ay = py - sy * arm
                  let ix = px - sx * thick
                  let iy = py - sy * thick
                  mark("M\{px} \{py}H\{ax}V\{iy}H\{ix}V\{ay}H\{px}Z")
                }
              }
              if region_selected.get() || region_grab.get() != 0 {
                let (bar, half) = (16.0, 8.0)
                let mx = rx + rw / 2.0
                let my = ry + rh / 2.0
                mark(rect_d(mx - half, clamp(ry - 2.0, 0.0, height - thick), bar, thick))
                mark(rect_d(mx - half, clamp(ry + rh - 1.0, 0.0, height - thick), bar, thick))
                mark(rect_d(clamp(rx - 2.0, 0.0, width - thick), my - half, thick, bar))
                mark(rect_d(clamp(rx + rw - 1.0, 0.0, width - thick), my - half, thick, bar))
              }
            }
            None =>
              if picked_hwnd.get() != 0L {
                match snap {
                  Some((s, k)) =>
                    match picked_rect(s) {
                      Some(r) => {
                        let v = to_view(s, k, r)
                        shade_round(v)
                        frame(v, 0L)
                      }
                      None => layers.push(layer(rect_d(0.0, 0.0, width, height), shade))
                    }
                  None => ()
                }
              }
          }
          match (snap, hover_window(p, width)) {
            (Some((s, k)), Some(u)) if u.hwnd != picked_hwnd.get() =>
              match intersect((u.x, u.y, u.w, u.h), (s.sx, s.sy, s.sw, s.sh)) {
                Some(r) => frame(to_view(s, k, r), ui_accent_faint())
                None => ()
              }
            _ => ()
          }
          if layers.is_empty() {
            return None
          }
          Some({ w: width, h: height, layers })
        }))
        |> ignore
      })
      |> ignore
      // the tag of the window lit or picked: its icon and words, 8 in from its frame's corner
      let tag = fn(v : @view.View) -> (Double, Double, String, String)? {
        guard picker_snap(v, w()) is Some((s, k)) else { return None }
        match hover_window(v, w()) {
          Some(u) if u.hwnd != picked_hwnd.get() =>
            match intersect((u.x, u.y, u.w, u.h), (s.sx, s.sy, s.sw, s.sh)) {
              Some(r) => {
                let (rx, ry, _, _) = to_view(s, k, r)
                return Some((rx + 8.0, ry + 8.0, tf("点击只导出 {0}", [win_label(u)]), u.process))
              }
              None => ()
            }
          _ => ()
        }
        if picked_hwnd.get() != 0L {
          match picked_rect(s) {
            Some(r) => {
              let (rx, ry, _, _) = to_view(s, k, r)
              Some((rx + 8.0, ry + 8.0, picked_name.get(), picked_process.get()))
            }
            None => Some((w() / 2.0 - 120.0, h() / 2.0 - 13.0, tf("这时 {0} 不在屏幕上", [picked_name.get()]), ""))
          }
        } else {
          None
        }
      }
      o.box(fn(t) {
        t.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
        t.box(fn(b) {
          b
          .row(Is(true))
          .height(Is(Some(26.0)))
          .padding(Is((9.0, 0.0, 9.0, 0.0)))
          .gap(Is(7.0))
          .radius(Is(6.0))
          .ground(Is(0x0E0F11DBL))
          .lines_up(Is(Some(Middle)))
          .laid_nowhere(By(fn() { tag(b) is None }))
          .offset(By(fn() {
            match tag(b) {
              Some((x, y, _, _)) => (x, y)
              None => (0.0, 0.0)
            }
          }))
          |> ignore
          b.pick(fn() { tag(b).map(fn(x) { x.3 }).unwrap_or("") }, fn(i, p) { if p != "" { app_icon(i, p) } }, at_once=true)
          words(b, fn() { tag(b).map(fn(x) { x.2 }).unwrap_or("") }, 12.0, fn() { 0xEDEEF0FFL }, weight=500) |> ignore
        })
        |> ignore
      })
      |> ignore
      // the region's size, as it is exported: over its frame's top left, outside it (inside where there is no room
      // over it), following the hand as it is dragged
      o.box(fn(t) {
        t.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
        t.box(fn(b) {
          let at = fn() -> (Double, Double)? {
            guard region_on() is Some(r) else { return None }
            let (sw, _) = rec_size()
            let k = if sw > 0.0 { w() / sw } else { 1.0 }
            let (rx, ry) = (r.0 * k, r.1 * k)
            Some(if ry >= 30.0 { (rx, ry - 28.0) } else { (rx + 8.0, ry + 8.0) })
          }
          b
          .row(Is(true))
          .height(Is(Some(22.0)))
          .padding(Is((8.0, 0.0, 8.0, 0.0)))
          .radius(Is(6.0))
          .ground(Is(0x0E0F11DBL))
          .lines_up(Is(Some(Middle)))
          .laid_nowhere(By(fn() { at() is None }))
          .offset(By(fn() { at().unwrap_or((0.0, 0.0)) }))
          |> ignore
          words(b, region_label, 12.0, fn() { 0xEDEEF0FFL }, weight=500) |> ignore
        })
        |> ignore
      })
      |> ignore
    }, at_once=true)
  })
  // (over the picture itself, not after the player in its column, where it was laid out none tall and the press went
  // to the picture: playing, 2026-11-13)
  .over(Is(true))
  |> ignore
}

///|
/// The note in the controls' row about the picked window, with its fix: (words, fix's label, whether the fix keeps
/// only the fully visible part); "" none.
fn window_note() -> (String, String, Bool) {
  if picked_hwnd.get() == 0L {
    return ("", "", false)
  }
  let mut absent = 0.0
  let mut covered = 0.0
  let mut longest = 0.0
  let mut present = 0.0
  for r in picked_runs(clip_a.get(), clip_b.get()) {
    if r.2 == 0 {
      absent += r.1 - r.0
    } else {
      present += r.1 - r.0
      if r.2 == 1 {
        covered += r.1 - r.0
      } else {
        longest = @cmp.maximum(longest, r.1 - r.0)
      }
    }
  }
  if absent >= 1000.0 {
    (tf("有 {0} 不在屏幕上", [clock(absent)]), tf("只留有画面的 {0}", [clock(present)]), false)
  } else if covered >= 1000.0 {
    (tf("有 {0} 被遮住", [clock(covered)]), tf("只留完整可见的 {0}", [clock(longest)]), true)
  } else {
    ("", "", false)
  }
}

///|
/// The clip mode's left: the window picked (a chip, its icon, ×), its note in amber and the fix, underlined; none
/// picked, how to pick one.
fn window_bar(parent : @view.View) -> Unit {
  // (what the clip is of: the whole picture, a window, an area; one at a time)
  segmented(parent, fn() { [t("整屏"), t("选窗口"), t("框选区域")] }, fn() { clip_kind.get() }, set_clip_kind)
  parent.box(fn(g) { g.width(Is(Some(8.0))) |> ignore }) |> ignore
  // 0 the whole picture, 1 a window to pick, 2 one picked, 3 an area to drag out, 4 one drawn
  parent.pick(fn() {
    match clip_kind.get() {
      1 => if picked_hwnd.get() != 0L { 2 } else { 1 }
      2 => if region_on() is Some(_) { 4 } else { 3 }
      _ => 0
    }
  }, fn(b, kind) {
    b.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
    match kind {
      0 => {
        words(b, fn() { t("导出整个画面") }, 12.0, ui_subtle) |> ignore
        return
      }
      1 => {
        words(b, fn() { t("在画面上点一个窗口，只导出它") }, 12.0, ui_subtle) |> ignore
        return
      }
      3 => {
        words(b, fn() { t("在画面上拖出一个区域") }, 12.0, ui_subtle) |> ignore
        return
      }
      4 => {
        region_chip(b)
        return
      }
      _ => ()
    }
    b.box(fn(chip) {
      chip.row(Is(true)).height(Is(Some(28.0))).padding(Is((9.0, 0.0, 6.0, 0.0))).gap(Is(8.0)).radius(Is(6.0)).ground(By(c_s2)).lines_up(Is(Some(Middle))) |> ignore
      chip.pick(fn() { picked_process.get() }, fn(i, p) { app_icon(i, p) }, at_once=true)
      words(chip, fn() { tf("只导出 {0}", [app_name(picked_process.get())]) }, 12.0, ui_text, weight=500) |> ignore
      icon_button(chip, fn() { "close" }, fn() { t("改回整屏") }, fn() { pick_window(None) }, w=18.0, h=18.0, size=10.0) |> ignore
    })
    |> ignore
    words(b, fn() { window_note().0 }, 12.0, warn) |> ignore
    b.show(fn() { window_note().1 != "" }, fn(x) {
      pressable(x, fn() { window_note().1 }, fn() { trim_to_window(@signals.untracked(window_note).2) }, fn(f) {
        f.gap(Is(2.0)) |> ignore
        words(f, fn() { window_note().1 }, 12.0, ui_text) |> ignore
        f.box(fn(u) { u.height(Is(Some(1.0))).ground(By(fn() { if f.pointed() { ui_muted() } else { ui_subtle() } })) |> ignore }) |> ignore
      })
      |> ignore
    }, at_once=true)
  }, at_once=true)
}

///|
/// The region's chip, where a picked window's is: 「自定义区域」 and its ratio's chevron, pressed for a menu of the
/// ratios (the one in force ticked); × lets the region go. While it is selected, after it, how the keys move it.
fn region_chip(parent : @view.View) -> Unit {
  let key : Ref[@view.View?] = Ref(None)
  parent.box(fn(chip) {
    chip.row(Is(true)).height(Is(Some(28.0))).padding(Is((0.0, 0.0, 6.0, 0.0))).gap(Is(2.0)).radius(Is(6.0)).ground(By(c_s2)).lines_up(Is(Some(Middle))) |> ignore
    let body = pressable(chip, fn() { t("自定义区域") }, fn() {
      guard key.val is Some(b) else { return }
      let now = region_ratio.untracked()
      // (the region stays selected or not as it was: choosing its shape is no press elsewhere)
      let was = region_selected.untracked()
      open_menu_under(
        b,
        Array::makei(region_ratios.length(), fn(i) {
          Some({
            label: if i == 0 { t(region_ratios[i].0) } else { region_ratios[i].0 },
            key: if i == now { "✓" } else { "" },
            act: fn() {
              set_region_ratio(i)
              region_selected.set(was)
            },
          })
        }),
        above=true,
      )
    }, fn(b) {
      let (hand, _) = answer(b)
      b
      .row(Is(true))
      .height(Is(Some(28.0)))
      .padding(Is((9.0, 0.0, 6.0, 0.0)))
      .gap(Is(5.0))
      .radius(Is(6.0))
      .lines_up(Is(Some(Middle)))
      .ground(By(fn() { mix(clear(c_s3()), c_s3(), hand.shown(b)) }))
      |> ignore
      words(b, fn() { t("自定义区域") }, 12.0, ui_text, weight=500) |> ignore
      b.box(fn(c) {
        c.width(Is(Some(8.0))).height(Is(Some(8.0))).picture(Is(Some(vector("M1.5 3 4 5.5 6.5 3", 8.0, 8.0, stroke=1.25)))).tint(By(ui_muted)) |> ignore
      })
      |> ignore
    }, keeps_region=true)
    key.val = Some(body)
    tip(body, fn() { t("区域比例") + " · " + t("方向键微调 · Shift 加快 · Alt 改大小") })
    icon_button(chip, fn() { "close" }, fn() { t("改回整屏") }, clear_region, w=18.0, h=18.0, size=10.0) |> ignore
  })
  |> ignore
  words(parent, fn() { if region_selected.get() { t("方向键微调 · Shift 加快 · Alt 改大小") } else { "" } }, 12.0, ui_subtle) |> ignore
}

///|
/// Under the track in clip mode with a window picked, 3 high across the clip: s3, and the muted grey where the window
/// was fully in view (fainter where partly covered).
fn window_strip(parent : @view.View, w : () -> Double) -> Unit {
  parent.box(fn(o) {
    o.height(By(fn() { Some(if clipping.get() && picked_hwnd.get() != 0L { 7.0 } else { 0.0 }) })) |> ignore
    o.box(fn(p) {
      p
      .height(Is(Some(7.0)))
      .laid_nowhere(By(fn() { !(clipping.get() && picked_hwnd.get() != 0L) }))
      .picture(By(fn() {
        let width = w()
        if !clipping.get() || picked_hwnd.get() == 0L || width <= 0.0 {
          return None
        }
        let (from, len) = shown(p)
        let vl = view_len()
        let x = fn(at : Double) { clamp((ax_d(at, vl) - from) / len * width, 0.0, width) }
        let layers = [layer(rect_d(x(clip_a.get()), 4.0, x(clip_b.get()) - x(clip_a.get()), 3.0), c_s3())]
        for r in picked_runs(clip_a.get(), clip_b.get()) {
          if r.2 != 0 && x(r.1) > x(r.0) {
            layers.push(
              layer(rect_d(x(r.0), 4.0, x(r.1) - x(r.0), 3.0), if r.2 == 2 { ui_muted() } else { tone(0xA0A4AB66L, 0x4A4E5566L) }),
            )
          }
        }
        Some({ w: width, h: 7.0, layers })
      }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A switch, 34 by 20: on, the accent with its knob in the accent's opposite; off, s4 with a grey one; its knob sliding
/// over 140 ms.
fn switch(parent : @view.View, label : () -> String, on : () -> Bool, set : (Bool) -> Unit) -> Unit {
  pressable(parent, label, fn() { set(!@signals.untracked(on)) }, fn(b) {
    let way = @motion.NodeWay::new(if @signals.untracked(on) { 1.0 } else { 0.0 })
    b.reacts(on, fn(v) { way.go_ms(b, if v { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else { 140.0 }) })
    b
    .width(Is(Some(34.0)))
    .height(Is(Some(20.0)))
    .radius(Is(10.0))
    .lines_up(Is(Some(Start)))
    .cursor(Is(Some(Arrow)))
    .ground(By(fn() {
      let off_g = if b.pointed() { tone(0x555860FFL, 0xB8BDC6FFL) } else { tone(0x454850FFL, 0xC5C9D1FFL) }
      mix(off_g, ui_accent(), way.shown(b))
    }))
    .edge(By(fn() {
      if b.focus_shown() {
        (1.5, focus_ring())
      } else if way.shown(b) < 0.5 {
        (1.0, tone(0xFFFFFF38L, 0x17181B45L))
      } else {
        (0.0, 0L)
      }
    }))
    |> ignore
    b.box(fn(k) {
      k
      .width(Is(Some(16.0)))
      .height(Is(Some(16.0)))
      .radius(Is(8.0))
      .ground(By(fn() { mix(tone(0xD5D8DEFFL, 0xFFFFFFFFL), ui_on_accent(), way.shown(k)) }))
      .offset(By(fn() { (2.0 + 14.0 * way.shown(k), 2.0) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The options button's node, for the card to stand over it.
let options_anchor : Ref[@view.NodeId?] = Ref(None)

///|
/// The clip's options button (only with a window picked).
fn window_options_button(parent : @view.View) -> Unit {
  parent.show(fn() { picked_hwnd.get() != 0L }, fn(b) {
    let key = icon_button(b, fn() { "sliders" }, fn() { t("选项") }, fn() {
      window_options_open.set(!window_options_open.untracked())
      menu_up.set(window_options_open.untracked())
    })
    options_anchor.val = Some(key.id())
  }, at_once=true)
}

///|
/// The clip's options in a card over their button: follow the window or keep a fixed area, its menus and dialogs or
/// not, as the settings' rows are. A press beside it closes it.
fn window_options_layer(root : @view.View) -> Unit {
  root.box(fn(o) {
    o.over(Is(true)).over_all(Is(true)) |> ignore
    o.show(fn() { window_options_open.get() && picked_hwnd.get() != 0L }, fn(m) {
      let close = fn() {
        window_options_open.set(false)
        menu_up.set(false)
      }
      m.over(Is(true)).modal(Is(true)).presses(Is(true)).on_press(close) |> ignore
      layer_keys(m, ["escape"])
      m.box(fn(card) {
        card
        .width(Is(Some(320.0)))
        .radius(Is(10.0))
        .ground(By(c_s2))
        .edge(By(fn() { (1.0, hair2()) }))
        .shadow(By(fn() { (30.0, 8.0, sheet_shadow()) }))
        .presses(Is(true))
        .on_press(fn() {  })
        |> ignore
        match options_anchor.val {
          Some(a) => card.beside(a, side=Top, along=End, offset=8.0) |> ignore
          None => ()
        }
        setting_row(card, true, fn() { t("窗口移动时") }, fn() {
          if picked_moved_and_popups().0 {
            t("这段里它移动或改变过大小")
          } else {
            t("这段里它没有移动")
          }
        }, fn(c) {
          segmented(c, fn() { [t("跟随"), t("固定")] }, fn() { if follow_window.get() { 0 } else { 1 } }, fn(i) {
            follow_window.set(i == 0)
          })
        })
        setting_row(card, false, fn() { t("包含菜单和对话框") }, fn() {
          if picked_moved_and_popups().1 {
            t("这段里出现过")
          } else {
            t("这段里没有出现")
          }
        }, fn(c) { switch(c, fn() { t("包含菜单和对话框") }, fn() { with_popups.get() }, fn(v) { with_popups.set(v) }) })
      })
      |> ignore
    }, at_once=true)
  })
  |> ignore
}
