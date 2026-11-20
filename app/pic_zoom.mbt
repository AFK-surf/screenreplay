// The picture looked at closer (the user, 2026-11-19: 「回放窗口可以加一个zoomin/out功能」, 「放大后感觉需要有个reset按钮」):
// Ctrl+wheel (or a touchpad's pinch) over the picture grows it about the pointer, up to 8 times; grown, a drag pans it
// and a press still plays or pauses; a pill in its corner says how large and, pressed, fits it again, as `0` does. Only
// how it is looked at: a clip saved is the whole frame, as ever. Clip mode fits it again and takes no zoom (what is
// picked or drawn there is in the whole picture's terms).

///|
/// How the picture is looked at: grown `z` times (1: fitted whole), drawn off its place by (`dx`, `dy`) points of
/// the picture's box (0 to that box's size × (1 - z): never past an edge).
#derive(Eq)
priv struct PicZoom {
  z : Double
  dx : Double
  dy : Double
}

///|
let pic_fitted : PicZoom = { z: 1.0, dx: 0.0, dy: 0.0 }

///|
let pic_zoom : @signals.Signal[PicZoom] = @signals.signal(pic_fitted, same=fn(a, b) { a == b })

///|
/// The most it grows.
let pic_zoom_most : Double = 8.0

///|
/// Whether it is grown now.
fn pic_zoomed() -> Bool {
  pic_zoom.get().z > 1.001
}

///|
/// `v` kept within its box `w` × `h`: no edge of the picture inside it.
fn pic_kept(v : PicZoom, w : Double, h : Double) -> PicZoom {
  let z = clamp(v.z, 1.0, pic_zoom_most)
  if z <= 1.001 {
    return pic_fitted
  }
  { z, dx: clamp(v.dx, w * (1.0 - z), 0.0), dy: clamp(v.dy, h * (1.0 - z), 0.0) }
}

///|
/// Grown by `k` about (`x`, `y`) of its box `w` × `h`: what is under that point stays under it.
fn pic_zoom_about(k : Double, x : Double, y : Double, w : Double, h : Double) -> Unit {
  if w <= 0.0 || h <= 0.0 || clipping.untracked() {
    return
  }
  let v = pic_zoom.untracked()
  let z = clamp(v.z * k, 1.0, pic_zoom_most)
  // (the point of the picture under the pointer, in the fitted picture's terms, kept there)
  let ux = (x - v.dx) / v.z
  let uy = (y - v.dy) / v.z
  pic_zoom.set(pic_kept({ z, dx: x - z * ux, dy: y - z * uy }, w, h))
}

///|
/// Fitted whole again.
fn pic_fit() -> Unit {
  pic_zoom.set(pic_fitted)
}

///|
/// The wheel over the picture: with Ctrl, or a touchpad's pinch, it grows or shrinks it about the pointer, a notch
/// (100) about a fifth; else it is not the picture's (false: on to what holds it).
fn pic_wheel(e : @view.Wheel) -> Bool {
  if (e.mods & (@ui.wheel_mod_ctrl | @ui.wheel_mod_cmd | @ui.wheel_mod_pinch)) == 0 || e.dy == 0.0 ||
    clipping.untracked() {
    return false
  }
  pic_zoom_about(@math.exp(-e.dy * 0.002), e.x, e.y, e.w, e.h)
  true
}

///|
/// Where a drag on the grown picture began (where the picture was then) and whether it went past a press.
priv struct PicDrag {
  mut from : PicZoom
  mut moved : Bool
  mut wx : Double
  mut wy : Double
}

///|
let pic_drag : PicDrag = { from: pic_fitted, moved: false, wx: 0.0, wy: 0.0 }

///|
/// A drag on the grown picture: past 4 points it pans it; let go where it went down, it is a press (plays or pauses).
fn pic_drag_by(d : @view.Drag, w : Double, h : Double) -> Unit {
  match d.kind {
    Down => {
      pic_drag.from = pic_zoom.untracked()
      pic_drag.moved = false
      pic_drag.wx = d.wx
      pic_drag.wy = d.wy
    }
    Moved => {
      let mx = d.wx - pic_drag.wx
      let my = d.wy - pic_drag.wy
      if !pic_drag.moved && (mx.abs() > 4.0 || my.abs() > 4.0) {
        pic_drag.moved = true
      }
      if pic_drag.moved {
        let f = pic_drag.from
        pic_zoom.set(pic_kept({ z: f.z, dx: f.dx + mx, dy: f.dy + my }, w, h))
      }
    }
    Up =>
      if !pic_drag.moved {
        set_playing(!want_play.untracked())
      }
    Off => ()
  }
}

///|
/// The stream's node `s` in the picture's box: drawn grown and moved as the zoom says, cut to the box (its holder
/// clips); grown, it takes the drags that pan it, the presses it lets go of still playing or pausing.
fn pic_zoomed_node(s : @view.View) -> Unit {
  s
  .scale(By(fn() { pic_zoom.get().z }), about=At(0.0, 0.0))
  .offset(By(fn() {
    let v = pic_zoom.get()
    (v.dx, v.dy)
  }))
  .presses(By(pic_zoomed))
  .cursor(By(fn() { if pic_zoomed() { Some(Grab) } else { None } }))
  .on_drag(fn(d) { pic_drag_by(d, d.w, d.h) })
  |> ignore
  // (clip mode: fitted whole, as it begins)
  s.reacts(fn() { clipping.get() }, fn(on) { if on { pic_fit() } }) |> ignore
}

///|
/// The pill in the picture's top right corner while it is grown: how large (200%) and 适应窗口; pressed, fitted again.
fn pic_zoom_pill(pic : @view.View) -> Unit {
  pic.box(fn(o) {
    // (the layer itself takes no finger: a press beside the pill is the picture's)
    o
    .over(Is(true))
    .lines_up(Is(Some(End)))
    .lies_along(Is(Start))
    .padding(Is((0.0, 10.0, 10.0, 0.0)))
    .takes(fn(_, _, _) { [] })
    |> ignore
    o.show(fn() { pic_zoomed() }, fn(b) {
      pressable(b, fn() { t("适应窗口") + " (0)" }, pic_fit, fn(p) {
        let (hand, _) = answer(p)
        p
        .row(Is(true))
        .height(Is(Some(28.0)))
        .padding(Is((10.0, 0.0, 10.0, 0.0)))
        .gap(Is(7.0))
        .radius(Is(14.0))
        .lines_up(Is(Some(Middle)))
        .ground(By(fn() { mix(0x000000A6L, 0x000000D9L, hand.shown(p)) }))
        |> ignore
        words(p, fn() { (pic_zoom.get().z * 100.0).round().to_int().to_string() + "%" }, 12.5, fn() { 0xFFFFFFFFL }, weight=600) |> ignore
        p.box(fn(l) { l.width(Is(Some(1.0))).height(Is(Some(12.0))).ground(Is(0xFFFFFF40L)) |> ignore }) |> ignore
        words(p, fn() { t("适应窗口") }, 12.5, fn() { mix(0xFFFFFFC0L, 0xFFFFFFFFL, hand.shown(p)) }, weight=500) |> ignore
      }, keeps_region=true)
      |> ignore
    }, at_once=true)
    |> ignore
  })
  |> ignore
}
