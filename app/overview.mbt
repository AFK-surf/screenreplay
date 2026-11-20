// The overview right under the track (letter 26; thin since 2026-11-16, the user's option E): all of the buffer along a
// track 10 high, as wide as the track, no times beside it. A band 4 high, hatched where nothing may be, solid where
// something was recorded; the markers dots that take a press; the playhead a line across it; the part in view a
// viewfinder (a 1.5 edge, 12% inside, radius 2.5, a handle 4 in from each end), at least 24 wide. Its viewfinder
// dragged by its middle moves the view; by an end, that end (so it zooms); a press beside it brings the view's middle
// there.

///|
let overview_h : Double = 10.0

///|
/// What a press on the overview took: 0 nothing, 1 the frame's start, 2 its end, 3 the frame; and the view's start and
/// length when it was pressed.
let over_grab : Ref[(Int, Double, Double)] = Ref((0, 0.0, 0.0))

///|
/// The viewfinder held (what is costly to make again as the view moves waits for its letting go).
let view_dragging : @signals.Signal[Bool] = @signals.signal(false)

///|
/// An end of the viewfinder held (the view's scale changing continuously till let go).
let view_resizing : @signals.Signal[Bool] = @signals.signal(false)

///|
/// The viewfinder across the track `w` wide: its left and width (at least 24, about its middle).
fn finder(w : Double) -> (Double, Double) {
  let total = ax_span(view_len())
  let k = if total > 0.0 { w / total } else { 0.0 }
  let tx = view_from.get() * k
  let tw = view_len() * k
  let fw = @cmp.maximum(24.0, tw)
  (clamp(tx + tw / 2.0 - fw / 2.0, 0.0, @cmp.maximum(0.0, w - fw)), fw)
}

///|
let over_down_x : Ref[Double] = Ref(0.0)

///|
fn overview_drag(d : @view.Drag, w : Double) -> Unit {
  let total = ax_span(@signals.untracked(view_len))
  if w <= 0.0 || total <= 0.0 {
    return
  }
  let k = w / total
  match d.kind {
    Down => {
      region_let_go()
      let (fx, fw) = @signals.untracked(fn() { finder(w) })
      let px = d.x
      let part = if px >= fx - 2.0 && px <= fx + 6.0 {
        1
      } else if px >= fx + fw - 6.0 && px <= fx + fw + 2.0 {
        2
      } else if px > fx && px < fx + fw {
        3
      } else {
        0
      }
      let len = @signals.untracked(view_len)
      if part == 0 {
        // beside the frame: the view's middle brought there, then dragged as the frame
        set_view(px / k - len / 2.0, len)
      }
      over_grab.val = (if part == 0 { 3 } else { part }, view_from.untracked(), @signals.untracked(view_len))
      view_dragging.set(true)
      view_resizing.set(part == 1 || part == 2)
      // (where it went down: a raw event's own `ox` is where it is now)
      over_down_x.val = d.x
    }
    Moved => {
      let (part, from0, len0) = over_grab.val
      let moved = (d.x - over_down_x.val) / k
      match part {
        1 => {
          let end = from0 + len0
          let from = clamp(from0 + moved, 0.0, end - min_view)
          set_view(from, end - from)
        }
        2 => set_view(from0, clamp(len0 + moved, min_view, total - from0))
        3 => {
          view_from.set(from0 + moved)
          follow_latest.set(from0 + moved + len0 >= total - 1.0)
          keep_view()
        }
        _ => ()
      }
    }
    Up | Off => {
      over_grab.val = (0, 0.0, 0.0)
      view_resizing.set(false)
      view_dragging.set(false)
    }
  }
}

///|
fn overview(parent : @view.View) -> Unit {
  parent.box(fn(row) {
    // (a thin strip right under the track, as wide as it, no times beside it: the user's option E, 2026-11-16,
    // 「感觉屏幕下方的内容好像占的空间有点大了」)
    row.row(Is(true)).margin(Is((0.0, 4.0, 0.0, 0.0))).lines_up(Is(Some(Middle))) |> ignore
    row.box(fn(cell) {
      cell.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
      cell.by_room(fn(track, room) {
        let w = fn() { room.width() }
        let k = fn() {
          data()
          let total = ax_span(view_len())
          if total > 0.0 { w() / total } else { 0.0 }
        }
        // (where the pointer is along it, a quarter of a point at least; -1 off it)
        let at = fn() {
          if !track.pointer_within() {
            return -1.0
          }
          track.pointer_piece(fn(x, _) { (@cmp.maximum(0.0, x) * 4.0).round().to_int() }).to_double() / 4.0
        }
        track
        .height(Is(Some(overview_h)))
        .presses(Is(true))
        // (the viewfinder's ends resize it, its inside moves it, outside it the view goes there)
        .cursor(By(fn() {
          let x = at()
          let (a, fw) = finder(w())
          Some(
            if x >= 0.0 && ((x - a).abs() <= 6.0 || (x - a - fw).abs() <= 6.0) {
              ResizeX
            } else if x > a && x < a + fw {
              Arrow
            } else {
              Arrow
            },
          )
        }))
        .on_drag(fn(d) { overview_drag(d, room.width()) }, captures=true)
        |> ignore
        // the moment under the pointer, over it (11, subtle on s2)
        track.box(fn(o) {
          o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(tag) {
            tag
            .padding(Is((6.0, 2.0, 6.0, 2.0)))
            .radius(Is(4.0))
            .ground(By(c_s2))
            .edge(By(fn() { (1.0, hair2()) }))
            .laid_nowhere(By(fn() { at() < 0.0 || grabbed.get() != 0 }))
            .offset(By(fn() { (clamp(at() - 30.0, 0.0, @cmp.maximum(0.0, w() - 60.0)), -22.0) }))
            |> ignore
            words(tag, fn() {
              let x = at()
              if x < 0.0 || k() <= 0.0 {
                ""
              } else {
                wall(t0() + ax_b(x / k(), view_len()), short=true)
              }
            }, 11.0, ui_muted)
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // the band, hatched, a hairline round it; solid where something was recorded
        track.box(fn(b) {
          b
          .over(Is(true))
          .presses(Is(false))
          .picture(By(fn() {
            let width = w()
            if width <= 0.0 {
              return None
            }
            let layers : Array[@pixels.VectorPath] = [
              layer(hatch_d(0.0, width, 4.0), 0L, stroke=tone(0xFFFFFF17L, 0x00000017L), width=1.0),
            ]
            // (under a filter of apps, its stretches along its axis, the seams between them left hatched)
            let vl = view_len()
            let spans = match axis_now.get() {
              Some(a) => a.ks
              None => runs_now.get()
            }
            for r in spans {
              let a = clamp(ax_d(r.0, vl) * k(), 0.0, width)
              let z = clamp(ax_d(r.1, vl) * k(), 0.0, width)
              if z - a >= 1.0 {
                layers.push(layer(rect_d(a, 0.0, z - a, 4.0), c_s4()))
              }
            }
            layers.push(layer(rect_d(0.5, 0.5, width - 1.0, 3.0), 0L, stroke=hair(), width=1.0))
            // (the band 4 high, 3 under the track's top)
            Some({ w: width, h: overview_h, layers: layers.map(fn(l) { { ..l, ty: 3.0 } }) })
          }))
          |> ignore
        })
        |> ignore
        // the viewfinder and its handles
        track.box(fn(o) {
          o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(f) {
            f
            .height(Is(Some(overview_h)))
            .radius(Is(2.5))
            .ground(By(fn() { tone(0xEDEEF01FL, 0x17181B1FL) }))
            .edge(By(fn() { (1.5, ui_text()) }))
            .width(By(fn() { Some(finder(w()).1) }))
            .offset(By(fn() { (finder(w()).0, 0.0) }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        for end in [0, 1] {
          track.box(fn(o) {
            o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
            o.box(fn(h) {
              h
              .width(Is(Some(2.0)))
              .height(Is(Some(4.0)))
              .radius(Is(1.0))
              .ground(By(ui_text))
              .offset(By(fn() {
                let (fx, fw) = finder(w())
                (if end == 0 { fx + 4.0 } else { fx + fw - 6.0 }, 3.0)
              }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        }
        // the playhead, 3 over and under the band
        track.box(fn(o) {
          o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(p) {
            p
            .width(Is(Some(2.0)))
            .height(Is(Some(overview_h)))
            .ground(By(ui_text))
            .drawn_off(By(fn() { (clamp(ax_d(pos_drawn(p), view_len()) * k(), 0.0, w()) - 1.0, 0.0) }), exact=true)
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // the markers: dots that take a press (the moment brought into view)
        track.box(fn(o) {
          o.over(Is(true)) |> ignore
          o.each(fn() {
            data()
            marks.copy()
          }, fn(m) { m }, fn(row, m) {
            let abs = m.untracked()
            row.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
            pressable(row, fn() { wall(abs) }, fn() { jump_to(abs - t0()) }, fn(b) {
              b
              .width(Is(Some(12.0)))
              .height(Is(Some(12.0)))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              .offset(By(fn() { (ax_d(abs - t0(), view_len()) * k() - 6.0, -1.0) }))
              |> ignore
              b.box(fn(dot) {
                let r = fn() { if b.pointed() { 6.0 } else { 4.0 } }
                dot.width(By(fn() { Some(r()) })).height(By(fn() { Some(r()) })).radius(Is(3.0)).ground(By(ui_text)) |> ignore
              })
              |> ignore
              tip(b, fn() { wall(abs) })
            })
            |> ignore
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
