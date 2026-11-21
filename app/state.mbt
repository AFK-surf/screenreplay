// What the window shows is worked out of signals (mbui's view made once: a node's property is bound to what it reads,
// and worked out again as that changes). The buffer's folder read again (`rev`), the playhead, the view of the
// timeline and the modes are signals; what reads them is bound to them. Time is the tree's: an action's moment is
// the cause's (`now`), and what moves by the clock (the playhead while it plays, the view gliding) is said as data,
// where it is from, at what moment and how fast, and worked out where it is drawn (View::drawn_while).

///|
/// The window's tree's root, kept as the window is made: whose moment an action is at.
let the_root : Ref[@view.View?] = Ref(None)

///|
/// The moment of what is being done (an input's, a due thing's, a message's): the tree's clock.
fn now() -> Double {
  match the_root.val {
    Some(r) => r.cause_at()
    None => 0.0
  }
}

///|
/// How far the epoch's clock is ahead of the tree's, the least seen: what it is while frames are drawn as they come.
let clock_gap : Ref[Double] = Ref(1.0e300)

///|
/// `f` done again `ms` from now, by the wall's clock: a window kept hidden draws no frames and its tree's clock waits
/// with it, so what is due is done, once it shows, at the moment each was due, one after another; a check every second
/// made due again a second after the last was caught up all at once (a tray panel hidden 1.7 h ran its checks some
/// 12 000 times as it was shown: 3.1 s of an empty frame, the user, 2026-11-18 「这会托盘点击又卡住了」). Due after now
/// as the wall has it, so the hours it waited are done once.
fn again(root : @view.View, ms : Double, f : () -> Unit) -> Unit {
  let gap = rp_now() - now()
  if gap < clock_gap.val {
    clock_gap.val = gap
  }
  root.at_moment(now() + (gap - clock_gap.val) + ms, f, later=true) |> ignore
}

///|
/// The buffer's folder as last read: its segments, the markers, the apps in front (buffer.mbt). Changed each time
/// the folder is read and differs, and as a marker is added or taken away.
let rev : @signals.Signal[Int] = @signals.signal(0)

///|
fn data_changed() -> Unit {
  rev.set(rev.untracked() + 1)
}

///|
/// What is bound to the buffer's folder reads this first.
fn data() -> Unit {
  rev.get() |> ignore
}

///|
/// Whether there is anything recorded (bound).
fn has_segs() -> Bool {
  data()
  !segs.is_empty()
}

// ---- the playhead ----

///|
/// Where the playhead is: at `pos` (ms into the buffer) at moment `at`, going on at `rate` while `going` (playing),
/// else standing there.
#derive(Eq)
struct Play {
  pos : Double
  at : Double
  rate : Double
  going : Bool
}

///|
let play : @signals.Signal[Play] = @signals.signal({ pos: 0.0, at: 0.0, rate: 1.0, going: false }, same=fn(a, b) {
  a == b
})

///|
fn pos_at(p : Play, t : Double) -> Double {
  if p.going {
    clamp(p.pos + (t - p.at) * p.rate, 0.0, span())
  } else {
    p.pos
  }
}

///|
/// Where the playhead is now, for what is done (not bound).
fn pos_now() -> Double {
  pos_at(play.untracked(), now())
}

///|
/// A jump of the playhead (a seek: a press on the band, J, L, a marker, a filter's skip; not a drag, not playing on):
/// where it was drawn from, and when. Its drawing slides from there to where it is over `head_glide_ms`, eased out
/// (the user, 2026-11-15: 「playhead快速跳的时候需要有动画」).
let head_glide : @signals.Signal[(Double, Double)] = @signals.signal((0.0, -1.0e18), same=fn(a, b) { a == b })

///|
let head_glide_ms : Double = 180.0

///|
/// The playhead about to jump to `to` from where it is now: it slides there (not a step of a frame or two: 250 ms or
/// less goes at once; nor where motions are off).
fn head_jump(to : Double) -> Unit {
  let from = pos_now()
  if (to - from).abs() > 250.0 && !motion_off() {
    head_glide.set((from, now()))
  }
}

///|
/// Where the playhead is drawn by node `v`: as the clock goes while it plays (bound to the clock then), else where it
/// stands; just after a jump, on its way there from where it was (head_glide).
fn pos_drawn(v : @view.View) -> Double {
  let p = play.get()
  let (gfrom, gat) = head_glide.get()
  let t = v.drawn_while(fn(t) { p.going || t < gat + head_glide_ms })
  let target = if !p.going || t > 1.0e300 { p.pos } else { pos_at(p, t) }
  if t > 1.0e300 || t >= gat + head_glide_ms {
    return target
  }
  let k = clamp((t - gat) / head_glide_ms, 0.0, 1.0)
  gfrom + (target - gfrom) * ease_out(k)
}

///|
/// Whether it is asked to play (the play key's state).
let want_play : @signals.Signal[Bool] = @signals.signal(false)

///|
/// How fast it plays.
let speed : @signals.Signal[Double] = @signals.signal(1.0, same=fn(a, b) { a == b })

// ---- the timeline's view ----

///|
/// Time covered by the view when the buffer is longer. New segments never change this scale.
let view_duration : @signals.Signal[Double] = @signals.signal(600000.0, same=fn(a, b) { a == b })

///|
let min_view : Double = 20000.0

///|
/// The view follows the newest recording (at first, and after "latest").
let follow_latest : @signals.Signal[Bool] = @signals.signal(true)

///|
/// Where the view starts, ms into the buffer.
let view_from : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })

///|
/// The view's length: all of the buffer (or a filter's axis, axis.mbt) when it is shorter than the scale (bound).
fn view_len() -> Double {
  data()
  @cmp.maximum(1.0, @cmp.minimum(view_duration.get(), view_total()))
}

///|
/// A glide of the view after a jump it was moved for (a key, a button, a marker, the clip framed): from where it was
/// shown (its start and length) at moment `at`, 200 ms eased out to where it is.
#derive(Eq)
struct Glide {
  from : Double
  len : Double
  at : Double
}

///|
let glide_ms : Double = 200.0

///|
let view_glide : @signals.Signal[Glide] = @signals.signal({ from: 0.0, len: 1.0, at: -1.0e18 }, same=fn(a, b) { a == b })

///|
/// The view as shown at moment `t`: on its way while a glide goes, else where it is.
fn shown_at(g : Glide, t : Double) -> (Double, Double) {
  let to_from = view_from.get()
  let to_len = view_len()
  let ms = if motion_off() { 0.0 } else { glide_ms }
  let k = (t - g.at) / ms
  if ms <= 0.0 || k >= 1.0 || k < 0.0 {
    (to_from, to_len)
  } else {
    let e = ease_out(k)
    (g.from + (to_from - g.from) * e, g.len + (to_len - g.len) * e)
  }
}

///|
/// The view as node `v` draws it (bound: to the clock while it glides).
fn shown(v : @view.View) -> (Double, Double) {
  let g = view_glide.get()
  if motion_off() {
    return (view_from.get(), view_len())
  }
  let t = v.drawn_while(fn(t) { t < g.at + glide_ms })
  shown_at(g, if t > 1.0e300 { g.at + glide_ms } else { t })
}

///|
/// The view as shown now, for what is done.
fn shown_now() -> (Double, Double) {
  @signals.untracked(fn() { shown_at(view_glide.get(), now()) })
}

///|
/// The view about to be moved for a jump: it glides there from where it is shown now.
fn glide() -> Unit {
  let (f, l) = shown_now()
  view_glide.set({ from: f, len: l, at: now() })
}

///|
/// Eased out (a cubic's): fast at first, settling.
fn ease_out(k : Double) -> Double {
  let u = 1.0 - clamp(k, 0.0, 1.0)
  1.0 - u * u * u
}

///|
fn clamp(v : Double, lo : Double, hi : Double) -> Double {
  @cmp.maximum(lo, @cmp.minimum(hi, v))
}

// ---- modes ----

///|
/// Picking a clip.
let clipping : @signals.Signal[Bool] = @signals.signal(false)

///|
let clip_a : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })

///|
let clip_b : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })

///|
/// What a press on the strip holds: 0 nothing, 1 the clip's start, 2 its end, 3 the playhead, 4 the whole clip.
let grabbed : @signals.Signal[Int] = @signals.signal(0)

///|
/// The window filling its screen.
let full_screen : @signals.Signal[Bool] = @signals.signal(false)

///|
/// What the last save said (shown in a note over the picture till closed), and the file it made.
let saved : @signals.Signal[String] = @signals.signal("")

///|
let saved_path : @signals.Signal[String] = @signals.signal("")

///|
/// Whether something is open over the replay (a dialog, a menu): what is under it is pointed at by nothing.
let menu_up : @signals.Signal[Bool] = @signals.signal(false)

///|
/// Animations off: Windows' own setting (Settings > Accessibility > Visual effects) or the system's reduced motion.
extern "C" fn rp_animations_off() -> Int = "rp_animations_off"

///|
let still_motion : @signals.Signal[Bool] = @signals.signal(false)

///|
fn motion_off() -> Bool {
  still_motion.get() || @ui.reduced_motion()
}

///|
/// The colour between `a` (t 0) and `b` (t 1), each channel.
fn mix(a : Int64, b : Int64, t : Double) -> Int64 {
  if t <= 0.0 {
    return a
  }
  if t >= 1.0 {
    return b
  }
  // (mixed as the screen would show them, each channel weighed by its alpha: a clear colour's own channels count for
  // nothing; mixed as they were written, a tint going from clear black to a light grey went dark half way, both tabs of
  // the settings' column darkening as one was left for another, the user's 2026-11-13)
  let ch = fn(c : Int64, shift : Int) { ((c >> shift) & 0xFFL).to_double() }
  let aa = ch(a, 0) / 255.0
  let ba = ch(b, 0) / 255.0
  let alpha = aa + (ba - aa) * t
  let one = fn(shift : Int) {
    let v = if alpha <= 0.0 {
      ch(b, shift)
    } else {
      (ch(a, shift) * aa + (ch(b, shift) * ba - ch(a, shift) * aa) * t) / alpha
    }
    @cmp.minimum(255.0, @cmp.maximum(0.0, v)).round().to_int64() << shift
  }
  one(24) | one(16) | one(8) | ((alpha * 255.0).round().to_int64() & 0xFFL)
}
