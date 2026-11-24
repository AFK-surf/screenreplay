// The time of day drawn into the track (the user's pick, 2026-11-24: 「E：画进轨道里」, after 「注意我们要尽可能高效利用
// 垂直空间」 took back a ruler of its own under it), no height added. Since 「I：淡出底边只标半点」 (2026-11-24, the
// ticks beside their times found ugly): no lines, no fade under them (the user, 2026-11-24: 去掉渐变), each time
// centred on its moment, a 2 pt notch under it. How far apart they are follows the zoom, never closer than about 200 points: the hours and
// half hours at a 2 hours' view, 2 minutes at 10 minutes, seconds near a minute. On the minute, the hour or midnight
// (whichever is a step coarser) the time is brighter and bold; midnight says the day. Under a filter of apps or with
// gaps folded only the moments kept are marked, none in a seam. A time is left out where an app's name or 未录制 is in
// its way.

///|
/// The steps the moments marked may be apart (ms).
let tick_steps : Array[Double] = [
  1000.0, 2000.0, 5000.0, 10000.0, 15000.0, 30000.0, 60000.0, 120000.0, 300000.0, 600000.0, 900000.0, 1800000.0, 3600000.0,
  7200000.0, 10800000.0, 21600000.0, 43200000.0, 86400000.0,
]

///|
/// How near two times may come (points).
let tick_room : Double = 200.0

///|
/// The step for a view `len` long across `w` points: the finest that keeps the times tick_room apart.
fn tick_step(len : Double, w : Double) -> Double {
  let least = tick_room / @cmp.maximum(1.0, w) * len
  for s in tick_steps {
    if s >= least {
      return s
    }
  }
  tick_steps[tick_steps.length() - 1]
}

///|
/// What a step a coarser moment is to `step`: the minute under a minute, the hour under an hour, else midnight.
fn tick_major(step : Double) -> Double {
  if step < 60000.0 {
    60000.0
  } else if step < 3600000.0 {
    3600000.0
  } else {
    86400000.0
  }
}

///|
/// Whether moment `at` (ms into the buffer) is shown along the axis: under a filter of apps or with gaps folded, only
/// in a kept stretch.
fn tick_kept(at : Double) -> Bool {
  match axis() {
    None => true
    Some(a) => {
      let i = ax_find(a, at)
      i >= 0 && at <= a.ks[i].1
    }
  }
}

///|
/// A moment marked: ms into the buffer, its words, whether it is a coarser one.
#derive(Eq)
struct Tick {
  at : Double
  text : String
  major : Bool
}

///|
/// The moments to mark along the axis from `a` to `z` (its units), `step` apart on the lt clock.
fn ticks_in(a : Double, z : Double, step : Double) -> Array[Tick] {
  let out : Array[Tick] = []
  if segs.is_empty() {
    return out
  }
  let vl = @signals.untracked(view_len)
  let b0 = @cmp.maximum(0.0, ax_b(@cmp.maximum(0.0, a), vl))
  let b1 = @cmp.minimum(span(), ax_b(z, vl))
  if b1 <= b0 {
    return out
  }
  let off = rp_local_offset().to_double() * 60000.0
  let base = t0()
  let major = tick_major(step)
  let mut lt = ((base + b0 + off) / step).ceil() * step
  while lt - off - base <= b1 && out.length() < 400 {
    let at = lt - off - base
    if tick_kept(at) {
      let day = lt - (lt / 86400000.0).floor() * 86400000.0
      let text = if day == 0.0 {
        let (_, m, d) = civil_from_days((lt / 86400000.0).floor().to_int())
        month_day(m, d)
      } else if step < 60000.0 {
        wall(base + at)
      } else {
        wall(base + at, short=true)
      }
      let on_major = lt - (lt / major).floor() * major == 0.0
      out.push({ at, text, major: on_major })
    }
    lt += step
  }
  out
}

///|
/// How high the notch under a time is (points).
let tick_h : Double = 2.0
///|
/// The size the times are in.
let tick_size : Double = 10.0

///|
/// The times and their lines in the band (`parent`, `w` wide), under the apps' names.
fn time_ticks(parent : @view.View, w : () -> Double) -> Unit {
  parent.box(fn(o) {
    o.over(Is(true)).presses(Is(false)) |> ignore
    // (the moments in reach: the view's length on steps of 1.5x either side of it, so the list changes only as the
    // view moves on by a step or the zoom passes one; the step itself by the view's own length)
    let reach = @signals.computed(fn(_) {
      let (from, len) = shown(o)
      let width = @cmp.maximum(1.0, w())
      let q = min_view * @math.pow(1.5, (@math.ln(@cmp.maximum(1.0, len / min_view)) / @math.ln(1.5)).floor())
      let at = (from / q).floor() * q
      (at - q, at + 3.0 * q, tick_step(len, width))
    }, same=fn(a, b) { a == b })
    // (what is in a time's way, in the same reach: the stretches wide enough for their icon (their names' widths), and
    // the gaps wide enough for 未录制)
    let named = @signals.computed(fn(_) {
      let (a, z, _) = reach.get()
      let (_, len) = shown(o)
      let min_dur = 30.0 / @cmp.maximum(1.0, w()) * len
      let vl = view_len()
      let out : Array[(Double, Double, Double)] = []
      for p in pieces_now.get() {
        if p.2 == "" || p.1 - p.0 < min_dur {
          continue
        }
        let d0 = ax_d(p.0, vl)
        let d1 = ax_d(p.1, vl)
        if d1 - d0 >= min_dur && d1 > a && d0 < z {
          out.push((p.0, p.1, @sf.node_words_w(app_name(p.2), 12.0).ceil()))
        }
      }
      out
    })
    let gaps_in = @signals.computed(fn(_) {
      let (a, z, _) = reach.get()
      let vl = view_len()
      gaps_now.get().filter(fn(g) { ax_d(g.1, vl) > a && ax_d(g.0, vl) < z })
    })
    let gap_w = @sf.node_words_w(t("未录制"), 11.0).ceil()
    // (whether a time from `x0` to `x1` across the band meets a name, as piece_labels and gap_labels lay them)
    let in_way = fn(v : @view.View, x0 : Double, x1 : Double) -> Bool {
      let width = w()
      for p in named.get() {
        let a = clamp(x_drawn_of(v, p.0, width), 0.0, width)
        let z = clamp(x_drawn_of(v, p.1, width), 0.0, width)
        let room = z - a - 1.0
        if room < 30.0 || a > x1 {
          continue
        }
        let end = @cmp.minimum(a + room, a + 9.0 + 14.0 + (if room >= 52.0 { 7.0 + p.2 } else { 0.0 }) + 4.0)
        if end > x0 {
          return true
        }
      }
      for g in gaps_in.get() {
        let a = clamp(x_drawn_of(v, g.0, width), 0.0, width)
        let z = clamp(x_drawn_of(v, g.1, width), 0.0, width)
        if z - a - 1.0 >= 72.0 {
          let mid = (a + z) / 2.0
          if mid + gap_w / 2.0 + 4.0 > x0 && mid - gap_w / 2.0 - 4.0 < x1 {
            return true
          }
        }
      }
      false
    }
    o.each(fn() {
      let (a, z, step) = reach.get()
      data()
      axis_now.get() |> ignore
      ticks_in(a, z, step)
    }, fn(k) { "\{k.at}/\{k.text}" }, fn(row, k) {
      let tick = k.untracked()
      let tw = @sf.node_words_w(tick.text, tick_size, weight=if tick.major { 600 } else { 500 }).ceil()
      row.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
      let x = fn(v : @view.View) { x_drawn_of(v, tick.at, w()) }
      // (centred on its moment, kept inside the band; where a name or an icon is in the way, moved aside by up to 36
      // points, right first; else none)
      let place = fn(v : @view.View) -> Double? {
        let at = x(v)
        if at < 0.0 || at > w() {
          return None
        }
        for k in 0..=12 {
          let shift = (if k % 2 == 1 { 1.0 } else { -1.0 }) * ((k + 1) / 2).to_double() * 6.0
          let left = at - tw / 2.0 + shift
          if left >= 2.0 && left + tw <= w() - 2.0 && !in_way(v, left - 2.0, left + tw + 2.0) {
            return Some(left)
          }
        }
        None
      }
      row.box(fn(l) {
        l
        .over(Is(true))
        .width(Is(Some(1.0)))
        .height(Is(Some(tick_h)))
        .ground(By(fn() { if tick.major { tone(0xFFFFFF99L, 0x00000099L) } else { tone(0xFFFFFF66L, 0x00000066L) } }))
        .laid_nowhere(By(fn() { place(l) is None }))
        .offset(By(fn() { (x(l) - 0.5, strip_h - tick_h) }))
        |> ignore
      })
      |> ignore
      row.box(fn(b) {
        b
        .over(Is(true))
        .laid_nowhere(By(fn() { place(b) is None }))
        .offset(By(fn() { (place(b).unwrap_or(0.0), strip_h - 15.0) }))
        |> ignore
        words(b, fn() { tick.text }, tick_size, if tick.major { ui_text } else { ui_muted }, weight=if tick.major {
          600
        } else {
          500
        })
        |> ignore
      })
      |> ignore
    }, at_once=true)
  })
  |> ignore
}
