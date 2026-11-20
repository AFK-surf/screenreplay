// The timeline's axis under a filter of apps (the user, 2026-11-18: 「感觉还是得在filter模式下，主要显示过滤后的时间线」, the
// mock's B with its seams' widths by how long was skipped, 「B4 缝宽随跳过时长」): only the ticked apps' stretches,
// one after another, a seam between each two as wide as how long was left out between them (5 minutes about 8 points,
// an hour about 28; 5 at least), plain ground with a faint hairline in its middle. What is before the first and after
// the last is left out with no seam.
//
// The view (state.mbt's view_from and view_len) is along this axis: ms of the kept stretches, a seam counting as the
// ms its points come to at the view's scale (`len` / ax_ref ms a point), so it keeps its width in points as the view
// zooms. ax_d takes a moment of the buffer to the axis, ax_b back; with no filter both are the moment itself.

///|
/// The points the seams' widths are made for (about the band's width); they come to as much less on a narrower band.
let ax_ref : Double = 1400.0

///|
/// The kept stretches (ms into the buffer), the seam before each (points; 0 before the first) and, before each, the
/// kept ms and the seams' points; all the kept ms and all the seams' points.
#derive(Eq)
struct Axis {
  ks : Array[(Double, Double)]
  g : Array[Double]
  kb : Array[Double]
  gb : Array[Double]
  kept : Double
  seams : Double
}

///|
/// A seam's width for `skip` ms left out: 8 points at 5 minutes, 5.6 more each time it doubles (28 at an hour), 5 at
/// least.
fn seam_w(skip : Double) -> Double {
  clamp(8.0 + 5.6 * @math.ln(@cmp.maximum(1.0, skip) / 300000.0) / @math.ln(2.0), 5.0, 28.0)
}

///|
/// Where nothing was recorded for at least this long (ms), the timeline folds it to a seam when fold_gaps is on;
/// shorter gaps stay where they are, hatched.
let fold_min : Double = 30000.0

///|
/// What was recorded (ms into the buffer), runs apart by less than fold_min taken as one (bound).
let folded_now : @signals.Computed[Array[(Double, Double)]] = @signals.computed(fn(_) {
  let out : Array[(Double, Double)] = []
  for r in runs_now.get() {
    if out.length() > 0 && r.0 - out[out.length() - 1].1 < fold_min {
      let last = out[out.length() - 1]
      out[out.length() - 1] = (last.0, @cmp.maximum(last.1, r.1))
    } else {
      out.push(r)
    }
  }
  out
})

///|
/// The axis while a filter of apps is on and something of theirs was recorded; with no filter, while fold_gaps is on
/// and there is a gap of fold_min or longer (bound).
let axis_now : @signals.Computed[Axis?] = @signals.computed(fn(_) {
  let ks = if !app_filter.get().is_empty() {
    kept_now.get()
  } else if fold_gaps.get() {
    let f = folded_now.get()
    if f.length() < 2 {
      return None
    }
    f
  } else {
    return None
  }
  if ks.is_empty() {
    return None
  }
  let n = ks.length()
  let g = Array::make(n, 0.0)
  for i in 1..<n {
    g[i] = seam_w(ks[i].0 - ks[i - 1].1)
  }
  // (the seams together never more than half the band: all of them narrowed alike where there are many)
  let mut all = 0.0
  for x in g {
    all += x
  }
  if all > ax_ref * 0.5 {
    let k = ax_ref * 0.5 / all
    for i in 0..<n {
      g[i] = g[i] * k
    }
    all = ax_ref * 0.5
  }
  let kb = Array::make(n, 0.0)
  let gb = Array::make(n, 0.0)
  let mut kept = 0.0
  let mut seams = 0.0
  for i in 0..<n {
    seams += g[i]
    kb[i] = kept
    gb[i] = seams
    kept += ks[i].1 - ks[i].0
  }
  Some({ ks, g, kb, gb, kept, seams: all })
})

///|
fn axis() -> Axis? {
  axis_now.get()
}

///|
/// Whether the timeline is along a filter's axis (bound).
fn ax_on() -> Bool {
  axis_now.get() is Some(_)
}

///|
/// The last kept stretch starting at or before `t` (ms into the buffer), -1 before the first.
fn ax_find(a : Axis, t : Double) -> Int {
  let mut lo = 0
  let mut hi = a.ks.length() - 1
  if t < a.ks[0].0 {
    return -1
  }
  while lo < hi {
    let mid = (lo + hi + 1) / 2
    if a.ks[mid].0 <= t {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  lo
}

///|
/// Where kept stretch `i` starts along the axis, at the view's length `len`.
fn ax_start(a : Axis, i : Int, len : Double) -> Double {
  a.kb[i] + a.gb[i] * len / ax_ref
}

///|
/// Moment `t` (ms into the buffer) along the axis at the view's length `len`: in a kept stretch, where it is in it; in
/// what was left out between two, the seam's middle; before the first, its start; after the last, the axis' end.
fn ax_d(t : Double, len : Double) -> Double {
  match axis() {
    None => t
    Some(a) => {
      let i = ax_find(a, t)
      if i < 0 {
        return 0.0
      }
      let s = ax_start(a, i, len)
      let l = a.ks[i].1 - a.ks[i].0
      if t <= a.ks[i].1 {
        s + (t - a.ks[i].0)
      } else if i + 1 < a.ks.length() {
        s + l + a.g[i + 1] * len / ax_ref / 2.0
      } else {
        s + l
      }
    }
  }
}

///|
/// The moment (ms into the buffer) at `d` along the axis at the view's length `len`: in a seam, the end of the stretch
/// before it (its near half) or the start of the one after (its far half).
fn ax_b(d : Double, len : Double) -> Double {
  match axis() {
    None => d
    Some(a) => {
      let n = a.ks.length()
      // (the last stretch starting at or before d)
      let mut lo = 0
      let mut hi = n - 1
      while lo < hi {
        let mid = (lo + hi + 1) / 2
        if ax_start(a, mid, len) <= d {
          lo = mid
        } else {
          hi = mid - 1
        }
      }
      let i = lo
      let s = ax_start(a, i, len)
      let l = a.ks[i].1 - a.ks[i].0
      if d <= s {
        a.ks[i].0
      } else if d <= s + l || i + 1 >= n {
        a.ks[i].0 + @cmp.minimum(d - s, l)
      } else {
        let mid = s + l + a.g[i + 1] * len / ax_ref / 2.0
        if d < mid {
          a.ks[i].1
        } else {
          a.ks[i + 1].0
        }
      }
    }
  }
}

///|
/// How long the axis is at the view's length `len`.
fn ax_span(len : Double) -> Double {
  match axis() {
    None => span()
    Some(a) => a.kept + a.seams * len / ax_ref
  }
}

///|
/// The view's length that holds all of the axis (its seams as wide as that length makes them).
fn view_total() -> Double {
  match axis() {
    None => span()
    Some(a) => a.kept / (1.0 - a.seams / ax_ref)
  }
}

///|
/// A picture `w` wide of the axis from `from` `len` long, made of `make`'s pictures of each kept stretch (or the part
/// of it in reach; `make(w, from, len)` draws the buffer from `from` `len` long `w` wide) laid side by side as they lie
/// along it; with no filter, `make`'s own.
fn ax_picture(
  w : Double,
  from : Double,
  len : Double,
  make : (Double, Double, Double) -> @pixels.Vector?,
) -> @pixels.Vector? {
  match axis() {
    None => make(w, from, len)
    Some(a) => {
      if w <= 0.0 || len <= 0.0 {
        return None
      }
      let vlen = @signals.untracked(view_len)
      let layers : Array[@pixels.VectorPath] = []
      let mut h = 0.0
      for i, k in a.ks {
        let s = ax_start(a, i, vlen)
        let e = s + (k.1 - k.0)
        let v0 = @cmp.maximum(s, from)
        let v1 = @cmp.minimum(e, from + len)
        if v1 - v0 <= 0.0 {
          continue
        }
        let pw = (v1 - v0) / len * w
        if pw < 0.25 {
          continue
        }
        match make(pw, k.0 + (v0 - s), v1 - v0) {
          Some(p) => {
            h = p.h
            let x0 = (v0 - from) / len * w
            for l in p.layers {
              layers.push({ ..l, tx: l.tx + x0 })
            }
          }
          None => ()
        }
      }
      if layers.is_empty() {
        None
      } else {
        Some({ w, h, layers })
      }
    }
  }
}

///|
/// The seams in reach as a picture `w` wide (from `from` `len` long along the axis), `h` high: a hairline down each
/// one's middle, 9 in from its top and foot; None with no filter.
fn seams_picture(w : Double, from : Double, len : Double, h : Double) -> @pixels.Vector? {
  guard axis() is Some(a) else { return None }
  if w <= 0.0 || len <= 0.0 {
    return None
  }
  let vlen = @signals.untracked(view_len)
  let d = StringBuilder()
  for i in 1..<a.ks.length() {
    let s = ax_start(a, i, vlen)
    let mid = s - a.g[i] * vlen / ax_ref / 2.0
    if mid < from || mid > from + len {
      continue
    }
    let x = (mid - from) / len * w
    d.write_string(rect_d(x - 0.5, 9.0, 1.0, h - 18.0))
  }
  let ds = d.to_string()
  if ds == "" {
    None
  } else {
    Some({ w, h, layers: [layer(ds, tone(0xFFFFFF24L, 0x00000024L))] })
  }
}

///|
/// Under a filter of apps, what the timeline shows: 「6 段 · 共 54 分」 (bound).
fn filter_summary() -> String {
  match axis_now.get() {
    Some(a) => tf("{0} 段 · 共 {1}", [a.ks.length().to_string(), front_words(a.kept)])
    None => ""
  }
}

///|
/// The seam under the pointer at `x` across the band `w` wide, as node `v` draws the view (bound): its number (the
/// stretch after it) where the pointer is on it or 2 points either side of it.
fn seam_under(v : @view.View, x : Double, w : Double) -> Int? {
  guard axis_now.get() is Some(a) else { return None }
  if w <= 0.0 {
    return None
  }
  let (from, len) = shown(v)
  let vl = view_len()
  let x_of = fn(d : Double) { (d - from) / len * w }
  for i in 1..<a.ks.length() {
    let right = x_of(ax_start(a, i, vl))
    let left = right - a.g[i] * vl / ax_ref / len * w
    if x >= left - 2.0 && x <= right + 2.0 {
      return Some(i)
    }
    if left > x + 2.0 {
      break
    }
  }
  None
}

///|
/// The seam under the pointer on the band, as node `v` draws the view (bound), not while something on it is held.
fn seam_hovered(v : @view.View) -> Int? {
  match seam_x.get() {
    Some(x) if grabbed.get() == 0 && !apps_open.get() => seam_under(v, x, (band_w.val)())
    _ => None
  }
}

///|
/// Where the pointer is across the band for the seams, its going away held 120 ms (as the hover card holds it): the
/// hover goes and comes back between moves along the band, and the card, holding it, showed in the tip's place.
let seam_x : @signals.Signal[Double?] = @signals.signal(None)

///|
/// When the pointer was last over the band (now's ms).
let seam_seen : Ref[Double] = Ref(-1.0e18)

///|
/// The band's width (its room's, bound), as the timeline is made: the seams' tip reads it where the band's own closure
/// is not at hand.
let band_w : Ref[() -> Double] = Ref(fn() { 0.0 })

///|
/// Over the seam under the pointer, a tip of what was left out there: 「跳过 16 分 · 10:00 – 10:16」 (the user's B4:
/// the seams say nothing till pointed at). The hover card and line stand back while it shows.
fn seam_tip(band : @view.View, w : () -> Double) -> Unit {
  band.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
    band_w.val = w
    o.reacts(hover_now, fn(h) {
      match h {
        Some(x) => {
          seam_seen.val = now()
          seam_x.set(Some(x))
        }
        None => {
          let t = now()
          o.at_moment(t + 120.0, fn() {
            if hover_now_untracked() is None && now() - seam_seen.val >= 119.0 {
              seam_x.set(None)
            }
          })
          |> ignore
        }
      }
    })
    // (its words and where its middle is across the band, worked out once for the seam pointed at)
    let at = fn() -> (String, Double)? {
      guard seam_hovered(o) is Some(i) else { return None }
      guard axis_now.get() is Some(a) else { return None }
      let (from, len) = shown(o)
      let vl = view_len()
      let right = (ax_start(a, i, vl) - from) / len * w()
      let mid = right - a.g[i] * vl / ax_ref / len * w() / 2.0
      let (b, e) = (a.ks[i - 1].1, a.ks[i].0)
      Some(
        (
          tf(if app_filter.get().is_empty() { "未录制 {0} · {1} – {2}" } else { "跳过 {0} · {1} – {2}" }, [front_words(e - b), wall(t0() + b, short=true), wall(t0() + e, short=true)]),
          mid,
        ),
      )
    }
    o.box(fn(tag) {
      tag
      .padding(Is((8.0, 3.0, 8.0, 3.0)))
      .radius(Is(6.0))
      .ground(By(c_s1))
      .edge(By(fn() { (1.0, hair2()) }))
      .presses(Is(false))
      .laid_nowhere(By(fn() { at() is None }))
      .offset(By(fn() {
        // (as wide as its words and 8 either side, its middle over the seam's, kept inside the band)
        let (s, m) = at().unwrap_or(("", 0.0))
        let tw = @sf.node_words_w(s, 11.5).ceil() + 16.0
        (clamp(m - tw / 2.0, 0.0, @cmp.maximum(0.0, w() - tw)), -30.0)
      }))
      |> ignore
      words(tag, fn() { at().map(fn(p) { p.0 }).unwrap_or("") }, 11.5, ui_text) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn hover_now_untracked() -> Double? {
  @signals.untracked(hover_now)
}

///|
/// fold_gaps turned (the settings' switch): saved, and the view kept about the playhead where it was across the band
/// along the new axis.
fn set_fold_gaps(on : Bool) -> Unit {
  let p = pos_now()
  let len0 = @signals.untracked(view_len)
  let frac = (ax_d(p, len0) - view_from.untracked()) / len0
  fold_gaps.set(on)
  save_prefs()
  let len = @signals.untracked(view_len)
  if !follow_latest.untracked() {
    view_from.set(ax_d(p, len) - clamp(frac, 0.0, 1.0) * len)
  }
  keep_view()
}
