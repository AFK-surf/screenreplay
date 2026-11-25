// How the timeline looks and answers the hand, as nodes made once, bound to the view, the buffer and the playhead.
// One band: the apps that were in front, each a stretch with its name, where nothing was recorded hatched; the
// loudness's outline standing in each stretch; the markers over it, the clip framed, the playhead. Under it the time of
// day, and the overview of the whole buffer.
//
// What is drawn by the view (its start and length) is worked out where it is drawn: as the view glides it follows the
// clock (state.mbt's `shown`), and the playhead follows the clock while it plays (`pos_drawn`), drawn off by parts of
// a pixel (View::drawn_off's exact): the capsule, its time, its neck and line one layer moving smoothly.

///|
let strip_h : Double = 32.0

///|
/// The app names found (process, lower case), and when one not found yet was last looked for.
let app_names : Map[String, String] = Map([])

///|
let app_names_missed : Map[String, Double] = Map([])

///|
/// What a person calls the app a process belongs to: its name as Windows gives it in the system's language (the
/// program's description, kept by the recorder in AppIcons\<process>.txt), else the process's own name.
fn app_name(process : String) -> String {
  let key = process.to_lower()
  match app_names.get(key) {
    Some(n) => return n
    None => ()
  }
  let now = rp_now()
  if now - app_names_missed.get(key).unwrap_or(-10000.0) < 5000.0 {
    return process
  }
  let text = read_text(pjoin(pjoin(root_dir(), "AppIcons"), key + ".txt")).trim().to_owned()
  // (none, or a window's title of a page or a document kept by an earlier recorder: the program's name instead)
  if text == "" || text.contains(" - ") || text.contains(" — ") || text.contains(" – ") || text.contains(" | ") {
    app_names_missed[key] = now
    return process
  }
  app_names[key] = text
  text
}

///|
/// The app in front at `at` (ms into the buffer), "" none known.
fn app_at(at : Double) -> String {
  // (the last noted at or before it, found by halving: apps.jsonl's lines are in time's order; the title bar asks it
  // each frame while playing, and a long buffer has thousands)
  let abs = t0() + at
  let mut lo = 0
  let mut hi = apps.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if apps[mid].0 <= abs {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo == 0 {
    ""
  } else {
    apps[lo - 1].1
  }
}

///|
/// The stretches recorded without a break (ms into the buffer), gaps under 1.5 s let pass.
fn recorded_runs() -> Array[(Double, Double)] {
  let base = t0()
  let runs : Array[(Double, Double)] = []
  for s in segs {
    let from = s.start - base
    let to = from + s.dur
    if runs.length() > 0 && from - runs[runs.length() - 1].1 <= 1500.0 {
      let last = runs[runs.length() - 1]
      runs[runs.length() - 1] = (last.0, @cmp.maximum(last.1, to))
    } else {
      runs.push((from, to))
    }
  }
  runs
}

///|
/// The apps' stretches cut where nothing was recorded: (from, to, the app's process), ms into the buffer.
fn app_pieces() -> Array[(Double, Double, String)] {
  let base = t0()
  let stretches : Array[(Double, Double, String)] = []
  for i, e in apps {
    let (at, app) = e
    let next = if i + 1 < apps.length() { apps[i + 1].0 } else { base + span() }
    stretches.push((@cmp.maximum(0.0, at - base), next - base, app))
  }
  if stretches.is_empty() && !segs.is_empty() {
    stretches.push((0.0, span(), ""))
  } else if !stretches.is_empty() && stretches[0].0 > 0.0 {
    stretches.insert(0, (0.0, stretches[0].0, ""))
  }
  let runs = recorded_runs()
  let pieces : Array[(Double, Double, String)] = []
  for st in stretches {
    for r in runs {
      let from = @cmp.maximum(st.0, r.0)
      let to = @cmp.minimum(st.1, r.1)
      if to > from {
        pieces.push((from, to, st.2))
      }
    }
  }
  pieces
}

///|
/// The stretches recorded without a break, worked out again only as the buffer changes (bound).
let runs_now : @signals.Computed[Array[(Double, Double)]] = @signals.computed(fn(_) {
  data()
  recorded_runs()
})

///|
/// The apps' stretches as the buffer has them now, worked out again only as it changes (bound).
let pieces_now : @signals.Computed[Array[(Double, Double, String)]] = @signals.computed(fn(_) {
  data()
  app_pieces()
})

///|
/// The app's stretch at `at` (ms into the buffer): from where it came to the front to where it left it, its pieces
/// either side of a short gap taken as one (bound).
fn stretch_at(at : Double) -> (Double, Double)? {
  let ps = pieces_now.get()
  let mut k = -1
  for i, p in ps {
    if at >= p.0 && at < p.1 {
      k = i
    }
  }
  if k < 0 || ps[k].2 == "" {
    return None
  }
  let app = ps[k].2
  let mut a = k
  while a > 0 && ps[a - 1].2 == app && ps[a].0 - ps[a - 1].1 <= 1500.0 {
    a -= 1
  }
  let mut z = k
  while z + 1 < ps.length() && ps[z + 1].2 == app && ps[z + 1].0 - ps[z].1 <= 1500.0 {
    z += 1
  }
  Some((ps[a].0, ps[z].1))
}

///|
/// The gaps where nothing was recorded (over 1.5 s), ms into the buffer.
fn gaps() -> Array[(Double, Double)] {
  let base = t0()
  let out : Array[(Double, Double)] = []
  let mut end = 0.0
  for s in segs {
    let from = s.start - base
    if from - end > 1500.0 {
      out.push((end, from))
    }
    end = from + s.dur
  }
  out
}

///|
/// The gaps where nothing was recorded (over 1.5 s), worked out again only as the buffer changes (bound).
let gaps_now : @signals.Computed[Array[(Double, Double)]] = @signals.computed(fn(_) {
  data()
  gaps()
})

///|
fn rect_d(x : Double, y : Double, w : Double, h : Double) -> String {
  let r = fn(v : Double) { (v * 10.0).round() / 10.0 }
  let x0 = r(x)
  let y0 = r(y)
  "M\{x0} \{y0}H\{r(x + w)}V\{r(y + h)}H\{x0}Z"
}

///|
fn layer(d : String, fill : Int64, stroke? : Int64 = 0L, width? : Double = 0.0) -> @pixels.VectorPath {
  { d, fill, stroke, width, even_odd: false, sx: 1.0, sy: 1.0, tx: 0.0, ty: 0.0 }
}

///|
/// Hatching inside `x` … `x + w` by `h` (1 wide lines 7 apart at 135°), each line cut to the box.
fn hatch_d(x : Double, w : Double, h : Double) -> String {
  let b = StringBuilder()
  let r = fn(v : Double) { (v * 10.0).round() / 10.0 }
  // (a line from (u, h) to (u + h, 0), cut to x … x + w)
  let mut u = -h - 7.0 + ((x / 7.0).floor() * 7.0 - x) + x
  while u < x + w {
    let x0 = u
    let x1 = u + h
    let a = @cmp.maximum(x0, x)
    let c = @cmp.minimum(x1, x + w)
    if c > a {
      b.write_string("M\{r(a)} \{r(h - (a - x0))}L\{r(c)} \{r(h - (c - x0))}")
    }
    u += 7.0
  }
  b.to_string()
}

///|
/// The least width (points) a stretch is cut off from the next at: two stretches touching are drawn as one where
/// either is narrower (the user, 2026-11-24, of a long view: 「细线就会很密集，其实没啥必要」, then 「两种线都减」).
let cut_min_w : Double = 6.0

///|
/// The stretches in the view from `from` `len` long across `w` as drawn: (left, right) points, the pixel apart at
/// each cut not taken off yet; touching ones joined where one of them is narrower than cut_min_w.
fn drawn_spans(w : Double, from : Double, len : Double) -> Array[(Double, Double)] {
  let x_of = fn(at : Double) { clamp((at - from) / len * w, 0.0, w) }
  let out : Array[(Double, Double)] = []
  let mut last_end = -1.0e300
  let mut last_w = 0.0
  for p in pieces_now.get() {
    if p.1 <= from || p.0 >= from + len {
      continue
    }
    let a = x_of(p.0)
    let b = x_of(p.1)
    let touching = out.length() > 0 && p.0 - last_end <= 1.0
    if touching && (b - a < cut_min_w || last_w < cut_min_w) {
      let k = out.length() - 1
      out[k] = (out[k].0, b)
    } else {
      out.push((a, b))
    }
    last_end = p.1
    last_w = b - a
  }
  out
}

///|
/// The band's grounds as one picture `w` wide, for the view from `from` `len` long: each app's stretch square, a pixel
/// apart (drawn_spans: not where they are too narrow); where nothing was recorded a faint hatching and a hairline inside.
fn grounds_picture(w : Double, from : Double, len : Double) -> @pixels.Vector? {
  if w <= 0.0 || len <= 0.0 || segs.is_empty() {
    return None
  }
  let x_of = fn(at : Double) { clamp((at - from) / len * w, 0.0, w) }
  let fill = StringBuilder()
  let hatches = StringBuilder()
  let boxes = StringBuilder()
  for sp in drawn_spans(w, from, len) {
    let (a, b) = sp
    if b - a >= 2.0 {
      fill.write_string(rect_d(a, 0.0, b - a - 1.0, strip_h))
    }
  }
  for g in gaps_now.get() {
    if g.1 <= from || g.0 >= from + len {
      continue
    }
    let a = x_of(g.0)
    let b = x_of(g.1)
    if b - a >= 2.0 {
      hatches.write_string(hatch_d(a, b - a - 1.0, strip_h))
      boxes.write_string(rect_d(a + 0.5, 0.5, b - a - 2.0, strip_h - 1.0))
    }
  }
  let layers : Array[@pixels.VectorPath] = []
  let fd = fill.to_string()
  if fd != "" {
    layers.push(layer(fd, c_s2()))
  }
  let hd = hatches.to_string()
  if hd != "" {
    layers.push(layer(hd, 0L, stroke=tone(0xFFFFFF17L, 0x00000017L), width=1.0))
  }
  let bd = boxes.to_string()
  if bd != "" {
    layers.push(layer(bd, 0L, stroke=hair(), width=1.0))
  }
  Some({ w, h: strip_h, layers })
}

///|
/// The loudness standing in each stretch, sampled once on a grid fixed in time (`cell` ms, about 3 points: panning
/// moves the shape, never reshapes it; smoothed 1:4:1, 6 under the top at the loudest), cut to each stretch and drawn
/// as one layer in `ink`.
fn loud_picture(w : Double, from : Double, len : Double, ink : Int64) -> @pixels.Vector? {
  if w <= 0.0 || len <= 0.0 || segs.is_empty() {
    return None
  }
  let cell = 3.0 / w * len
  let k0 = (from / cell).floor() - 1.0
  let k1 = ((from + len) / cell).ceil() + 1.0
  let n = (k1 - k0).to_int() + 1
  if n < 2 {
    return None
  }
  let (raw, any_raw) = peaks_grid(k0, n, cell, false)
  if !any_raw {
    return None
  }
  let r = fn(v : Double) { (v * 10.0).round() / 10.0 }
  let xs = Array::makei(n, fn(i) { ((k0 + i.to_double()) * cell - from) / len * w })
  let top_y = Array::make(n, strip_h)
  let mut any = false
  for i in 0..<n {
    let s = (raw[@cmp.maximum(0, i - 1)] + 4 * raw[i] + raw[@cmp.minimum(n - 1, i + 1)]).to_double() / 6.0
    if s >= 26.0 {
      any = true
      // (the levels are decibels, -50 to 0 dB over 0 to 255; raised to 1.6 so that ordinary sound, about -20 dB, stands
      // half way up and only the loudest near its top (the reviewer's 52nd, 25: flat tops where all was loud))
      top_y[i] = r(strip_h - @math.pow(s / 255.0, 1.6) * (strip_h - 6.0))
    }
  }
  if !any {
    return None
  }
  let all_d = StringBuilder()
  for sp in drawn_spans(w, from, len) {
    let a = sp.0
    let b = sp.1 - 1.0
    if b - a < 1.0 {
      continue
    }
    let i0 = @cmp.maximum(0, ((from + a / w * len) / cell - k0).floor().to_int() - 1)
    let i1 = @cmp.minimum(n - 1, ((from + b / w * len) / cell - k0).ceil().to_int() + 1)
    if i1 - i0 < 1 {
      continue
    }
    let mut piece_any = false
    for i in i0..=i1 {
      if top_y[i] < strip_h {
        piece_any = true
        break
      }
    }
    if !piece_any {
      continue
    }
    all_d.write_string("M\{r(clamp(xs[i0], a, b))} \{strip_h}")
    for i in i0..=i1 {
      all_d.write_string("L\{r(clamp(xs[i], a, b))} \{top_y[i]}")
    }
    all_d.write_string("L\{r(clamp(xs[i1], a, b))} \{strip_h}Z")
  }
  let d = all_d.to_string()
  let layers : Array[@pixels.VectorPath] = if d == "" { [] } else { [layer(d, ink)] }
  Some({ w, h: strip_h, layers })
}

///|
/// The activity's heat lane: 8 high, right on the track (the user's pick, 2026-11-14: 「H1 轨道上方独立热力条」; 4 over it
/// till 2026-11-16, the user: 「热力图和timeline的中间的gap有啥必要吗」).
let heat_h : Double = 8.0

///|
let heat_gap : Double = 0.0

///|
/// How many strengths the heat is drawn in (one layer each).
let heat_steps : Int = 32

///|
/// A strength of the heat (0 to 1) as its ink, cold to hot: clear, amber, orange, red (the mock's stops: amber at 45%
/// by 0.3, orange at 65% by 0.65, red at 85% at the top: a hot stretch reads, never shouts).
fn heat_ink(v : Double) -> Int64 {
  let stops : Array[(Double, Int64)] = [(0.0, 0xFFC44000L), (0.3, 0xFFC4405CL), (0.65, 0xFF8C28A6L), (1.0, 0xEB3232D9L)]
  for k in 1..<stops.length() {
    let (b, cb) = stops[k]
    if v <= b {
      let (a, ca) = stops[k - 1]
      return mix(ca, cb, (v - a) / (b - a))
    }
  }
  stops[stops.length() - 1].1
}

///|
/// How busy the mouse, the keyboard and the controller were, as a heat lane over each stretch, apart from the track
/// (the user's pick after a tint, dots and fine dots read poorly: a heatmap, 「感觉还是得用heatmap那种形式」, H1):
/// its strength the busiest 100 ms of it averaged twice over about 0.75 s either way, so it warms and cools softly;
/// inked cold to hot (heat_ink), at full heat only at the busiest. Nothing where nothing was done, a segment has no
/// `.input` or nothing was recorded. Worked out once for both sides of the playhead (whole where played, 0.6 ahead).
fn heat_pictures(w : Double, from : Double, len : Double) -> (@pixels.Vector?, @pixels.Vector?) {
  if w <= 0.0 || len <= 0.0 || segs.is_empty() {
    return (None, None)
  }
  let cell = 2.0 / w * len
  let half = @cmp.maximum(4, (750.0 / cell).ceil().to_int())
  let k0 = (from / cell).floor() - 2.0 * half.to_double() - 1.0
  let n = ((from + len) / cell).ceil().to_int() - k0.to_int() + 2 * half + 2
  if n <= 4 * half + 1 {
    return (None, None)
  }
  let (raw, any) = peaks_grid(k0, n, cell, true)
  if !any {
    return (None, None)
  }
  // (the samples' running sums, so each average is two reads)
  let sum = Array::make(n + 1, 0.0)
  for i in 0..<n {
    sum[i + 1] = sum[i] + raw[i].to_double()
  }
  // (averaged twice over the same reach, a triangle's weights: one box left a stripe each burst and holes between
  // them, the user, 2026-11-16: 「热力条为啥颜色这么不连续」「是否能更平滑一点」)
  let box = fn(sums : Array[Double], i : Int) {
    let lo = @cmp.maximum(0, i - half)
    let hi = @cmp.minimum(n - 1, i + half)
    (sums[hi + 1] - sums[lo]) / (hi - lo + 1).to_double()
  }
  let sum2 = Array::make(n + 1, 0.0)
  for i in 0..<n {
    sum2[i + 1] = sum2[i] + box(sum, i)
  }
  let steps = Array::makei(n, fn(i) {
    let v = box(sum2, i)
    (@cmp.minimum(1.0, v / 255.0) * heat_steps.to_double()).round().to_int()
  })
  let x_of = fn(at : Double) { clamp((at - from) / len * w, 0.0, w) }
  let paths = Array::makei(heat_steps + 1, fn(_) { StringBuilder() })
  // (over each stretch recorded without a break, never cut where the app changes: cut there as the track's blocks are,
  // a 1 point gap at each switch made it a row of stripes, the user, 2026-11-16: 「热力条应该是平滑变化的，而不能单独一条一条画」)
  for p in runs_now.get() {
    if p.1 <= from || p.0 >= from + len {
      continue
    }
    let a = x_of(p.0)
    let b = x_of(p.1)
    if b - a < 1.0 {
      continue
    }
    // (the columns over the stretch, runs of one strength laid as one box, cut to the stretch)
    let first = @cmp.maximum(0, ((from + a / w * len) / cell - k0).floor().to_int())
    let last = @cmp.minimum(n - 1, ((from + b / w * len) / cell - k0).ceil().to_int())
    let mut i = first
    while i <= last {
      let s = steps[i]
      let mut j = i + 1
      while j <= last && steps[j] == s {
        j += 1
      }
      if s > 0 {
        let x0 = clamp(((k0 + i.to_double()) * cell - from) / len * w, a, b)
        let x1 = clamp(((k0 + j.to_double()) * cell - from) / len * w, a, b)
        if x1 > x0 {
          // (on over the next run by most of a point: the inks are solid, so where two meet the pixel they share is
          // covered whole, never a lighter line between them as two see-through edges each half over it left)
          paths[s].write_string(rect_d(x0, 0.0, @cmp.minimum(b, x1 + 0.75) - x0, heat_h))
        }
      }
      i = j
    }
  }
  let bg = c_bg()
  let played_layers : Array[@pixels.VectorPath] = []
  let ahead_layers : Array[@pixels.VectorPath] = []
  for s in 1..=heat_steps {
    let d = paths[s].to_string()
    if d != "" {
      // (each ink laid solid on the dock's ground, as it would show over it)
      let c = heat_ink(s.to_double() / heat_steps.to_double())
      let a = (c & 0xFFL).to_double() / 255.0
      let solid = c | 0xFFL
      played_layers.push(layer(d, mix(bg, solid, a)))
      ahead_layers.push(layer(d, mix(bg, solid, a * 0.6)))
    }
  }
  (Some({ w, h: heat_h, layers: played_layers }), Some({ w, h: heat_h, layers: ahead_layers }))
}

///|
/// The playhead's time capsule: as wide as its words (HH:MM:SS, its digits all one width) and 8 either side.
let capsule_w : Double = 62.0

///|
/// The playhead's time to the millisecond (HH:MM:SS.mmm), its capsule wider for it: after a step by a frame, till it
/// plays or goes elsewhere (the user, 2026-11-15: 「逐帧跳的时候，给 playhead 加上更精确的时间戳」).
let fine_time : @signals.Signal[Bool] = @signals.signal(false)

///|
/// How much wider the capsule is with the milliseconds: as wide as they are (their digits all one width), so the
/// words stand as far in on the right as on the left (a fixed 26 for 24 wide words left them ~4 more on the right: the
/// user, 2026-11-16 「右边的padding似乎比左边大」).
fn fine_words_w() -> Double {
  @sf.node_words_w(".000", 11.0, weight=600).ceil()
}

///|
/// The playhead (letters 24 and 25) over the band `w` wide: one continuous shape in the accent, no edge: a capsule with
/// the time (11, 600, in the accent's opposite) whose foot is 4 over the track, a tangent concave neck drawn in to a 2
/// wide line down to the track's foot. Near an end of the view the capsule stops and the line slides along its foot to
/// its side: that side's bottom corner and neck half merge smoothly into a continuous taper until the line sits flush
/// with the capsule's edge as a flag. All of it is one vector path drawn off by parts of a pixel (View::drawn_off's
/// exact), smooth, with zero seam between capsule, neck and line.
fn playhead(band : @view.View, w : () -> Double) -> Unit {
  // (the milliseconds coming in and going: the capsule widening and they wiping in, faded, 160 ms eased out; the user,
  // 2026-11-15 「有渐变动画吗」)
  let fine = @motion.NodeWay::new(0.0)
  let fine_w = fine_words_w()
  let cw = fn(v : @view.View) { capsule_w + fine_w * fine.shown(v) }
  // (where the line is across the band, as drawn; None where it is out of view)
  let x_drawn = fn(v : @view.View) -> Double? {
    let (from, len) = shown(v)
    let p = ax_d(pos_drawn(v), view_len())
    if p < from || p > from + len {
      None
    } else {
      // (its 2 wide line kept inside the band at its ends: flush with the capsule's side there, never past it)
      Some(clamp((p - from) / len * w(), 1.0, @cmp.maximum(1.0, w() - 1.0)))
    }
  }
  let cap_x = fn(v : @view.View, x : Double) { clamp(x - cw(v) / 2.0, 0.0, @cmp.maximum(0.0, w() - cw(v))) }
  let cap_h = 19.0
  let total_h = 23.0 + strip_h
  // its time, in the middle of the capsule (digits have no descent: centred by their line they sit low, so lifted)
  let time = fn(b : @view.View) {
    b.lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    b.box(fn(lift) {
      lift.row(Is(true)).padding(Is((0.0, 0.0, 0.0, 0.5))) |> ignore
      words(lift, fn() { wall(t0() + pos_drawn(lift)) }, 11.0, ui_on_accent, weight=600) |> ignore
      lift.box(fn(m) {
        m.width(By(fn() { Some(fine_w * fine.shown(m)) })).shrink(Is(0.0)).clips(Is(true)) |> ignore
        // (laid out whole at their own width, the box over them widening: a wipe, never words cut short)
        m.box(fn(f) {
          f.width(Is(Some(fine_w))).shrink(Is(0.0)) |> ignore
          words(f, fn() { ms_words(t0() + pos_drawn(f)) }, 11.0, fn() { mix(clear(ui_on_accent()), ui_on_accent(), fine.shown(f)) }, weight=600)
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }
  band.box(fn(layer) {
    layer.over(Is(true)).presses(Is(false)) |> ignore
    layer.show(fn() { has_segs() }, fn(ph) {
      ph.over(Is(true)) |> ignore
      ph.reacts(fn() { fine_time.get() }, fn(on) { fine.go_ms(ph, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else { 160.0 }) })
      // the capsule, its neck, its line and its time as one node, off by parts of a pixel (B, the capsule on whole
      // pixels, was tried and taken back by the user, 2026-11-13: 「不如之前」)
      ph.box(fn(o) {
        o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
        o.box(fn(b) {
          // (in the middle of the band `sl = c / 2 - 1` stays constant as the playhead moves, so the picture is rebuilt
          // only while the stem slides near an edge or the capsule widens for milliseconds)
          let shape = @signals.computed(fn(_) {
            let c = cw(b)
            let x = x_drawn(b).unwrap_or(0.0)
            let cx = cap_x(b, x)
            let sl = clamp(x - 1.0 - cx, 0.0, @cmp.maximum(0.0, c - 2.0))
            ((c * 20.0).round() / 20.0, (sl * 20.0).round() / 20.0)
          }, same=fn(a, b) { a == b })
          b
          .width(By(fn() { Some(cw(b)) }))
          .height(Is(Some(total_h)))
          .laid_nowhere(By(fn() { x_drawn(b) is None }))
          .drawn_off(By(fn() { (cap_x(b, x_drawn(b).unwrap_or(0.0)), -23.0) }), exact=true)
          .picture(By(fn() {
            let (c, sl) = shape.get()
            Some(vector(playhead_path(c, cap_h, total_h, sl), c, total_h))
          }))
          .tint(By(ui_accent))
          |> ignore
          b.box(fn(cap) {
            cap.width(By(fn() { Some(cw(cap)) })).height(Is(Some(cap_h))) |> ignore
            time(cap)
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
/// The playhead as one closed SVG path `w` × `total_h`: a `cap_h`-tall squircle capsule seamlessly joined into a 2-wide
/// stem whose left edge is at `sl`. On each side of the stem, where room >= 13 pt (`c_max + f_max`), a full squircle
/// corner meets a tangent concave neck; where room is tighter near a timeline edge, the corner and neck merge into two
/// G1-continuous cubics whose shared inflection tangent eases from horizontal to vertical, tapering smoothly down to a
/// flush flag at room = 0 with no square overhang or notch.
fn playhead_path(w : Double, cap_h : Double, total_h : Double, sl : Double) -> String {
  let f = fn(v : Double) { (v * 100.0).round() / 100.0 }
  let q = 0.36
  let lim = @cmp.minimum(w, cap_h) / 2.0
  let top_r = @cmp.minimum(9.0, lim)
  let c_max = @cmp.minimum(9.0, cap_h / 2.0)
  let f_max = 4.0
  let fy_max = 4.0
  let span_full = c_max + f_max
  let sr = sl + 2.0
  let dl = sl
  let dr = w - sr
  let b = StringBuilder()
  // top edge + top-right squircle
  b.write_string("M\{f(top_r)} 0H\{f(w - top_r)}C\{f(w - top_r * q)} 0 \{f(w)} \{f(top_r * q)} \{f(w)} \{f(top_r)}")
  // right side: capsule right wall -> stem right wall
  if dr <= 0.01 {
    b.write_string("V\{f(cap_h)}L\{f(sr)} \{f(cap_h)}V\{f(total_h)}")
  } else if dr >= span_full {
    b.write_string(
      "V\{f(cap_h - c_max)}C\{f(w)} \{f(cap_h - c_max * q)} \{f(w - c_max * q)} \{f(cap_h)} \{f(w - c_max)} \{f(cap_h)}H\{f(sr + f_max)}C\{f(sr + f_max * 0.32)} \{f(cap_h)} \{f(sr)} \{f(cap_h + fy_max * 0.36)} \{f(sr)} \{f(cap_h + fy_max)}V\{f(total_h)}",
    )
  } else {
    let t = dr / span_full
    let u_m = f_max * t
    let s_small = @cmp.minimum(1.0, t / 0.45)
    let alpha = 1.5707963267948966 * (1.0 - (1.0 - s_small) * (1.0 - s_small))
    let tu = -@math.sin(alpha)
    let ty = @math.cos(alpha)
    let cy = c_max * (t * 0.65 + @math.pow(t, 0.72) * 0.35)
    let fy = fy_max * (t * 0.55 + @math.pow(t, 0.6) * 0.45)
    let l0 = cy * (1.0 - q)
    let du = dr - u_m
    let l1 = (du * du + cy * cy).sqrt() * 0.452548
    let l2 = (u_m * u_m + fy * fy).sqrt() * 0.480833
    let l3 = fy * (1.0 - 0.36)
    b.write_string(
      "V\{f(cap_h - cy)}C\{f(w)} \{f(cap_h - cy + l0)} \{f(sr + u_m - l1 * tu)} \{f(cap_h - l1 * ty)} \{f(sr + u_m)} \{f(cap_h)}C\{f(sr + u_m + l2 * tu)} \{f(cap_h + l2 * ty)} \{f(sr)} \{f(cap_h + fy - l3)} \{f(sr)} \{f(cap_h + fy)}V\{f(total_h)}",
    )
  }
  // stem foot
  b.write_string("H\{f(sl)}")
  // left side: stem left wall -> capsule left wall (mirror of right side, reversed)
  if dl <= 0.01 {
    b.write_string("V\{f(cap_h)}L0 \{f(cap_h)}V\{f(top_r)}")
  } else if dl >= span_full {
    b.write_string(
      "V\{f(cap_h + fy_max)}C\{f(sl)} \{f(cap_h + fy_max * 0.36)} \{f(sl - f_max * 0.32)} \{f(cap_h)} \{f(sl - f_max)} \{f(cap_h)}H\{f(c_max)}C\{f(c_max * q)} \{f(cap_h)} 0 \{f(cap_h - c_max * q)} 0 \{f(cap_h - c_max)}V\{f(top_r)}",
    )
  } else {
    let t = dl / span_full
    let u_m = f_max * t
    let s_small = @cmp.minimum(1.0, t / 0.45)
    let alpha = 1.5707963267948966 * (1.0 - (1.0 - s_small) * (1.0 - s_small))
    let tu = -@math.sin(alpha)
    let ty = @math.cos(alpha)
    let cy = c_max * (t * 0.65 + @math.pow(t, 0.72) * 0.35)
    let fy = fy_max * (t * 0.55 + @math.pow(t, 0.6) * 0.45)
    let l0 = cy * (1.0 - q)
    let du = dl - u_m
    let l1 = (du * du + cy * cy).sqrt() * 0.452548
    let l2 = (u_m * u_m + fy * fy).sqrt() * 0.480833
    let l3 = fy * (1.0 - 0.36)
    b.write_string(
      "V\{f(cap_h + fy)}C\{f(sl)} \{f(cap_h + fy - l3)} \{f(sl - (u_m + l2 * tu))} \{f(cap_h + l2 * ty)} \{f(sl - u_m)} \{f(cap_h)}C\{f(sl - (u_m - l1 * tu))} \{f(cap_h - l1 * ty)} 0 \{f(cap_h - cy + l0)} 0 \{f(cap_h - cy)}V\{f(top_r)}",
    )
  }
  // top-left squircle
  b.write_string("C0 \{f(top_r * q)} \{f(top_r * q)} 0 \{f(top_r)} 0Z")
  b.to_string()
}

///|
/// Which edge of the clip a press at `at` takes (10 points either side): 1 its start, 2 its end, 0 neither.
fn near_edge(at : Double, w : Double) -> Int {
  if !clipping.untracked() || w <= 0.0 {
    return 0
  }
  let room = 10.0 / w * @signals.untracked(view_len)
  let near_a = (at - clip_a.untracked()).abs()
  let near_b = (at - clip_b.untracked()).abs()
  if near_a <= near_b && near_a < room {
    1
  } else if near_b < room {
    2
  } else {
    0
  }
}

///|
/// In clip mode, the playhead dragged within 6 points of an end of the clip lands on that end exactly.
fn snap_to_clip(at : Double, w : Double) -> Double {
  if !clipping.untracked() || w <= 0.0 {
    return at
  }
  let room = 6.0 / w * @signals.untracked(view_len)
  let (a, b) = (clip_a.untracked(), clip_b.untracked())
  if (at - a).abs() < room {
    a
  } else if (at - b).abs() < room {
    b
  } else {
    at
  }
}

///|
/// The clip's start when a drag of it began, and whether it has moved since.
let clip_origin : Ref[Double] = Ref(0.0)

///|
let clip_moved : Ref[Bool] = Ref(false)

///|
let band_down_x : Ref[Double] = Ref(0.0)

///|
/// Whether the playhead held on the band has been dragged (4 points from where it went down): only then does the
/// picture follow it by the scrub's way (native_player.mbt's `Deck::scrub`). A click seeks exactly.
let scrub_dragged : @signals.Signal[Bool] = @signals.signal(false)

///|
/// Where on the band the press went down, in the timeline's time: a clip held inside keeps that much of it before the
/// pointer, however far the view has scrolled under it since.
let band_down_at : Ref[Double] = Ref(0.0)

///|
/// Where the pointer is on the band while it is held, and whether the view is being scrolled for it at an edge.
let edge_x : Ref[Double] = Ref(0.0)

///|
let edge_running : Ref[Bool] = Ref(false)

///|
/// How near the band's ends (points) a held clip end or clip scrolls the view (the user, 2026-11-16: 「clip移动区域鼠标
/// 到达边缘时候应该能滚动timeline」).
let edge_room : Double = 40.0

///|
/// How fast the view scrolls at an edge: none at the zone's inner side, a view's length a second at the band's end and
/// past it (up to 2 views a second well past it).
fn edge_speed(x : Double, w : Double) -> Double {
  if x < edge_room {
    -clamp((edge_room - x) / edge_room, 0.0, 2.0)
  } else if x > w - edge_room {
    clamp((x - (w - edge_room)) / edge_room, 0.0, 2.0)
  } else {
    0.0
  }
}

///|
/// While a clip's end or the clip is held at an edge of the band, the view scrolls that way each frame (16 ms), and
/// what is held goes along with the pointer's place in the new view; it stops as it is let go or leaves the edge.
fn edge_scroll(w : Double) -> Unit {
  if edge_running.val {
    return
  }
  guard band_node.val is Some(band) else { return }
  fn step(last : Double) -> Unit {
    let g = grabbed.untracked()
    let v = edge_speed(edge_x.val, w)
    if !clipping.untracked() || (g != 1 && g != 2 && g != 4) || v == 0.0 {
      edge_running.val = false
      return
    }
    let t = now()
    let dt = clamp(t - last, 0.0, 50.0)
    pan_timeline(v * @signals.untracked(view_len) * dt / 1000.0)
    band_moved(edge_x.val, w)
    band.at_moment(t + 16.0, fn() { step(t) }, later=true) |> ignore
  }
  if edge_speed(edge_x.val, w) != 0.0 {
    edge_running.val = true
    let t = now()
    band.at_moment(t + 16.0, fn() { step(t) }, later=true) |> ignore
  }
}

///|
/// The pointer held on the band at `x` (of `w`): what is held follows it.
fn band_moved(x : Double, w : Double) -> Unit {
  let at = at_x(x, w)
  // (an end of the clip moves only once it is dragged 4 points: pressed and let go, it is a click that takes the
  // playhead to that end; the user, 2026-11-20 「在clip模式下，很难把playhead移动到开头」)
  let g = grabbed.untracked()
  if (g == 1 || g == 2 || g == 4) && !clip_moved.val {
    if (x - band_down_x.val).abs() < 4.0 {
      return
    }
    clip_moved.val = true
  }
  match g {
    // (an end dragged past the other: the two change places, the one in hand now the other end, as editors do;
    // the user, 2026-11-14 「右侧拖拽越过左侧时，需要调转左右」)
    1 =>
      if at > clip_b.untracked() {
        let b = clip_b.untracked()
        clip_a.set(b)
        clip_b.set(clamp(at, b + 1000.0, span()))
        grabbed.set(2)
      } else {
        clip_a.set(clamp(at, 0.0, clip_b.untracked() - 1000.0))
      }
    2 =>
      if at < clip_a.untracked() {
        let a = clip_a.untracked()
        clip_b.set(a)
        clip_a.set(clamp(at, 0.0, a - 1000.0))
        grabbed.set(1)
      } else {
        clip_b.set(clamp(at, clip_a.untracked() + 1000.0, span()))
      }
    3 =>
      if scrub_dragged.untracked() || (x - band_down_x.val).abs() >= 4.0 {
        scrub_dragged.set(true)
        scrub_to(snap_to_clip(at, w))
      }
    4 => {
      let length = clip_b.untracked() - clip_a.untracked()
      let start = clamp(clip_origin.val + (at - band_down_at.val), 0.0, span() - length)
      clip_a.set(start)
      clip_b.set(start + length)
      clip_moved.val = true
    }
    _ => ()
  }
}

///|
/// A press or a drag on the band `w` wide: a press moves the playhead there at once, a drag scrubs (the picture
/// following); in clip mode a press near an edge of the clip moves that edge, inside it a drag moves all of it.
fn band_drag(d : @view.Drag, w : Double) -> Unit {
  if w <= 0.0 {
    return
  }
  let at = at_x(d.x, w)
  match d.kind {
    Down => {
      clip_mark()
      // (a press on the timeline lets a selected region go)
      region_let_go()
      let edge = near_edge(at, w)
      let (a, b) = (clip_a.untracked(), clip_b.untracked())
      let inside = clipping.untracked() && edge == 0 && at > a && at < b
      clip_moved.val = false
      clip_origin.val = a
      // (where it went down: a raw event's own `ox` is where it is now)
      band_down_x.val = d.x
      band_down_at.val = at
      scrub_dragged.set(false)
      grabbed.set(if edge != 0 { edge } else if inside { 4 } else { 3 })
      follow_latest.set(false)
      // (exactly, at once: not by the scrub's nearest key frame; inside the clip the playhead waits for the release)
      if grabbed.untracked() == 3 {
        seek_to(at)
      }
    }
    Moved => {
      edge_x.val = d.x
      band_moved(d.x, w)
      edge_scroll(w)
    }
    Up | Off => {
      let was = grabbed.untracked()
      let dragged = scrub_dragged.untracked()
      grabbed.set(0)
      scrub_dragged.set(false)
      // (a press alone went there as it went down: not again as it lets go, which while playing began the sound again
      // from the same moment, the ~100 ms between heard twice (the user, 2026-11-15: 「声音，播放中点时间线」 of
      // 「跳帧后还是会复读那么100毫秒」); after a drag, to where it was let go, exactly)
      if d.kind == Up && ((was == 3 && dragged) || (was == 4 && !clip_moved.val)) {
        seek_to(if was == 3 { snap_to_clip(at, w) } else { at })
      } else if d.kind == Up && (was == 1 || was == 2) && !clip_moved.val {
        seek_to(if was == 1 { clip_a.untracked() } else { clip_b.untracked() })
      }
    }
  }
}

///|
/// The wheel over the timeline's block: it pans (down or right: later), a notch (100 points) a twentieth of the view,
/// as Steam's timeline does; with Ctrl, or a touchpad's pinch, it zooms about the pointer, a notch about a tenth.
fn block_wheel(e : @view.Wheel, x : Double, w : Double) -> Unit {
  if w <= 0.0 || (e.dx == 0.0 && e.dy == 0.0) {
    return
  }
  let len = @signals.untracked(view_len)
  if (e.mods & (@ui.wheel_mod_ctrl | @ui.wheel_mod_cmd | @ui.wheel_mod_pinch)) != 0 && e.dy != 0.0 {
    let (from, slen) = shown_now()
    zoom_about(@math.exp(-e.dy * 0.001), from + clamp(x / w, 0.0, 1.0) * slen)
  } else {
    pan_timeline((if e.dx != 0.0 { e.dx } else { e.dy }) * 0.0005 * len)
  }
}

///|
/// The timeline's block in `parent`: the band (40) with the playhead over it, the ruler under it.
fn timeline(parent : @view.View) -> Unit {
  parent.by_room(fn(held, room) {
    hover_node.val = Some(held)
    held.padding(Is((0.0, dock_over, 0.0, 0.0))) |> ignore
    let w = fn() { room.width() }
    held.on_wheel(fn(e) { block_wheel(e, e.x, room.width()) }) |> ignore
    // (a press or a drag on the heat lane and the room over the band seeks as one on the band does: the user,
    // 2026-11-17 「点击heatmap应该也能跳转到相应位置，就跟点击timeline一样」; the band's own, under it, go to the band)
    held.presses(Is(true)).on_drag(fn(d) { band_drag(d, room.width()) }, captures=true) |> ignore
    held.box(fn(band) {
      band_node.val = Some(band)
      band
      .height(Is(Some(strip_h)))
      .presses(Is(true))
      .cursor(By(fn() {
        Some(
          match grabbed.get() {
            1 | 2 => ResizeX
            3 | 4 => Arrow
            _ =>
              // (in clip mode: an edge of the clip under the pointer, it is resized; inside it, the clip is grabbed)
              match (clipping.get(), hover_now()) {
                (true, Some(x)) => {
                  let (_, len) = shown(band)
                  let at = at_x_drawn(band, x, w())
                  let room = 10.0 / w() * len
                  if (at - clip_a.get()).abs() < room || (at - clip_b.get()).abs() < room {
                    ResizeX
                  } else if at > clip_a.get() && at < clip_b.get() {
                    Arrow
                  } else {
                    Arrow
                  }
                }
                _ => Arrow
              }
          },
        )
      }))
      .on_drag(fn(d) { band_drag(d, @signals.untracked(w)) }, captures=true)
      |> ignore
      // the stretches, the input's activity, the loudness, the gaps: one picture, drawn again as the view or the buffer changes
      band.box(fn(s) {
        s
        .over(Is(true))
        .presses(Is(false))
        .clips(Is(true))
        |> ignore
        // (dimmed in clip mode, over 160 ms as it is entered or left)
        let dim = @motion.NodeWay::new(if clipping.untracked() { 0.45 } else { 1.0 })
        s.reacts(fn() { clipping.get() }, fn(on) { dim.go_ms(s, if on { 0.45 } else { 1.0 }, if motion_off() { 1.0 } else { 160.0 }) })
        s
        .alpha(By(fn() { dim.shown(s) }))
        |> ignore
        // (the band's pictures made over three of its widths, the view's and one either side of it, once; slid where
        // they are drawn as the view moves along within them (a drag, the wheel, the overview), made again only as it
        // leaves them, as it is zoomed, or the buffer changes: their start and length, and how wide they are)
        let cover = @signals.computed(fn(_) {
          let (from, len) = shown(s)
          if view_resizing.get() {
            (from, len, w())
          } else {
            let at = (from / len).floor() * len
            (at - len, 3.0 * len, 3.0 * w())
          }
        }, same=fn(a, b) { a == b })
        let slid = fn(v : @view.View) {
          let (from, len) = shown(v)
          ((cover.get().0 - from) / len * w(), 0.0)
        }
        // the stretches' grounds and the gaps
        s.box(fn(o) {
          o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(g) {
            g
            .height(Is(Some(strip_h)))
            .width(By(fn() { Some(cover.get().2) }))
            .drawn_off(By(fn() { slid(g) }), exact=true)
            .picture(By(fn() {
              data()
              let (at, len, cw) = cover.get()
              // (under a filter of apps, its stretches side by side and its seams between: axis.mbt)
              let g = ax_picture(cw, at, len, grounds_picture)
              match (g, seams_picture(cw, at, len, strip_h)) {
                (Some(p), Some(s)) => Some({ ..p, layers: p.layers + s.layers })
                (None, s) => s
                (p, None) => p
              }
            }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // the stretch under the playhead a step lighter
        current_piece(s, w)
        // the loudness (one picture, in the ink each draws it in): ahead of the playhead, and over it, cut at the
        // playhead, played
        // (the loudness's own reach: while the overview's viewfinder is dragged it is not made again each time the
        // band's pictures are, only once the view is no longer all inside what it was made for, and as the drag lets
        // go: made again every few moves of a fast drag, each time a frame lost. Held past that, the band showed no
        // loudness where the view had gone: the user, 2026-11-14 「拖拽 timeline 的时候音频线有时候不渲染」)
        let loud_held : Ref[(Double, Double, Double)?] = Ref(None)
        let loud_cover = @signals.computed(fn(_) {
          let c = cover.get()
          let (from, len) = shown(s)
          match (view_dragging.get(), loud_held.val) {
            (true, Some(h)) if h.1 == c.1 && h.2 == c.2 && from >= h.0 && from + len <= h.0 + h.1 => h
            _ => {
              loud_held.val = Some(c)
              c
            }
          }
        }, same=fn(a, b) { a == b })
        let loud_slid = fn(v : @view.View) {
          let (from, len) = shown(v)
          ((loud_cover.get().0 - from) / len * w(), 0.0)
        }
        let loud = @signals.computed(fn(_) {
          data()
          let (at, len, cw) = loud_cover.get()
          ax_picture(cw, at, len, fn(w, f, l) { loud_picture(w, f, l, 0x000000FFL) })
        })
        // the input's activity, a heat lane over the stretches, apart from the track (in the band, not in its clipped
        // pictures): whole where played, 0.6 of it ahead of the playhead; each side cut at the playhead, never one laid
        // over the other
        let heat_both = @signals.computed(fn(_) {
          data()
          let (at, len, cw) = loud_cover.get()
          if axis_now.get() is None {
            heat_pictures(cw, at, len)
          } else {
            (
              ax_picture(cw, at, len, fn(w, f, l) { heat_pictures(w, f, l).0 }),
              ax_picture(cw, at, len, fn(w, f, l) { heat_pictures(w, f, l).1 }),
            )
          }
        })
        let head_x = fn(v : @view.View) {
          let (from, len) = shown(v)
          clamp((ax_d(pos_drawn(v), view_len()) - from) / len * w(), 0.0, w())
        }
        for played in [true, false] {
          band.box(fn(o) {
            // (clipped to the band: the played side reaches a band's width left of the playhead, and with heat recorded
            // before the view it showed out past the band's start, the user, 2026-11-25 「热力条有问题」)
            o
            .over(Is(true))
            .presses(Is(false))
            .lines_up(Is(Some(Start)))
            .offset(Is((0.0, -heat_gap - heat_h)))
            .width(By(fn() { Some(w()) }))
            .height(Is(Some(heat_h)))
            .clips(Is(true))
            |> ignore
            // (a box as wide as the band, its far edge at the playhead (played) or its near edge there (ahead), what it
            // holds slid back as far)
            o.box(fn(c) {
              c
              .height(Is(Some(heat_h)))
              .clips(Is(true))
              .width(By(fn() { Some(w()) }))
              .drawn_off(By(fn() { (if played { head_x(c) - w() } else { head_x(c) }, 0.0) }), exact=true)
              |> ignore
              c.box(fn(l) {
                l
                .width(By(fn() { Some(loud_cover.get().2) }))
                .height(Is(Some(heat_h)))
                .drawn_off(
                  By(fn() { ((if played { w() - head_x(l) } else { -head_x(l) }) + loud_slid(l).0, 0.0) }),
                  exact=true,
                )
                .picture(By(fn() { if played { heat_both.get().0 } else { heat_both.get().1 } }))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore
        }
        s.box(fn(o) {
          o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(l) {
            l
            .height(Is(Some(strip_h)))
            .width(By(fn() { Some(loud_cover.get().2) }))
            .drawn_off(By(fn() { loud_slid(l) }), exact=true)
            .picture(By(fn() { loud.get() }))
            .tint(By(fn() { tone(0xEDEEF033L, 0x17181B29L) }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        s.box(fn(cut) {
          cut
          .over(Is(true))
          .lines_up(Is(Some(Start)))
          |> ignore
          // (cut by a box as wide as the band slid left to the playhead, what it holds slid back as far: moved where it is
          // drawn alone as the playhead goes, never laid out again)
          let played = fn(v : @view.View) {
            let (from, len) = shown(v)
            clamp((ax_d(pos_drawn(v), view_len()) - from) / len * w(), 0.0, w())
          }
          cut.box(fn(c) {
            c
            .height(Is(Some(strip_h)))
            .clips(Is(true))
            .width(By(fn() { Some(w()) }))
            .drawn_off(By(fn() { (played(c) - w(), 0.0) }), exact=true)
            |> ignore
            c.box(fn(l) {
              l
              .width(By(fn() { Some(loud_cover.get().2) }))
              .height(Is(Some(strip_h)))
              .drawn_off(By(fn() { (w() - played(l) + loud_slid(l).0, 0.0) }), exact=true)
              .picture(By(fn() { loud.get() }))
              .tint(By(fn() { tone(0xEDEEF046L, 0x17181B37L) }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        time_ticks(s, w)
        piece_labels(s, w)
        gap_labels(s, w)
        // the stretches of the apps not ticked dimmed, over their names too, while a filter of apps is on
        s.box(fn(o) {
          o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(g) {
            g
            .height(Is(Some(strip_h)))
            .width(By(fn() { Some(cover.get().2) }))
            .drawn_off(By(fn() { slid(g) }), exact=true)
            .picture(By(fn() {
              data()
              let (at, len, cw) = cover.get()
              let f = app_filter.get()
              ax_picture(cw, at, len, fn(w, from, l) { filter_dim_picture(w, from, l, f) })
            }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      marks_layer(band, w)
      clip_layer(band, w)
      hover_line(band, w)
      playhead(band, w)
      away_chip(band, w)
      band
      .on_menu(fn(m) { open_moment_menu(m.wx, m.wy, at_x(m.x, @signals.untracked(w)), false) })
      |> ignore
      hover_card(band, w)
      seam_tip(band, w)
    })
    |> ignore
    window_strip(held, w)
    overview(held)
  })
  |> ignore
}
