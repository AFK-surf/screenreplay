// The timeline's state as it is changed: the part of the buffer in view (its start and length; zoomed by the wheel
// about the pointer, panned sideways, following the newest recording until browsed away from), the clip being picked,
// and the markers' and the clip's moves. Each is done at its cause's moment (state.mbt's `now`).

///|
/// When the view was last moved by the hand (a pan, the wheel's zoom, the overview's frame): playing does not take it
/// back to the playhead for 3 s after (follow_playhead).
let view_by_hand : Ref[Double] = Ref(-1.0e18)

///|
/// Browsing clamped without pulling the view back to the playhead.
fn keep_view() -> Unit {
  @signals.untracked(fn() {
    let len = view_len()
    let total = ax_span(len)
    let mut from = view_from.get()
    if follow_latest.get() {
      from = total - len
    }
    view_from.set(@cmp.maximum(0.0, @cmp.minimum(from, total - len)))
  })
}

///|
/// Zoomed by `k` (> 1 in) about `anchor` (along the view's axis: ms into the buffer, or a filter's, axis.mbt), which
/// stays where it is across the view.
fn zoom_about(k : Double, anchor : Double) -> Unit {
  view_by_hand.val = now()
  @signals.untracked(fn() {
    let old = view_len()
    let along = (anchor - view_from.get()) / old
    // (the moment there: a filter's seams widen and narrow along its axis as the view's length changes)
    let at = ax_b(anchor, old)
    let at_end = view_from.get() + old >= ax_span(old) - 1.0
    let all = view_total()
    let mut d = @cmp.maximum(min_view, @cmp.minimum(all, old / k))
    if d >= all {
      // (zoomed all the way out: the scale is the whole buffer, growing with it)
      d = 86400000.0
    }
    view_duration.set(d)
    let len = view_len()
    view_from.set(ax_d(at, len) - along * len)
    follow_latest.set(follow_latest.get() && at_end)
  })
  keep_view()
}

///|
fn zoom_by(k : Double) -> Unit {
  glide()
  let (from, len) = @signals.untracked(fn() { (view_from.get(), view_len()) })
  let p = ax_d(pos_now(), len)
  let anchor = if p >= from && p <= from + len { p } else { from + len / 2.0 }
  zoom_about(k, anchor)
}

///|
/// The view `len` long (ms; at least the buffer's length: all of it), about the playhead where it is in view, else
/// about the view's middle; gliding there over 200 ms, kept within the buffer.
fn zoom_to(len : Double) -> Unit {
  glide()
  let (from, old) = @signals.untracked(fn() { (view_from.get(), view_len()) })
  let p = ax_d(pos_now(), old)
  let anchor = ax_b(if p >= from && p <= from + old { p } else { from + old / 2.0 }, old)
  if len >= view_total() {
    view_duration.set(86400000.0)
    view_from.set(0.0)
    follow_latest.set(true)
  } else {
    view_duration.set(@cmp.maximum(min_view, len))
    let l = @signals.untracked(view_len)
    let total = ax_span(l)
    view_from.set(@cmp.maximum(0.0, @cmp.minimum(ax_d(anchor, l) - l / 2.0, total - l)))
    follow_latest.set(view_from.untracked() + l >= total - 1.0)
  }
  keep_view()
}

///|
/// How long the view is, as the zoom key says it: 45 秒, 2.5 分钟 (a tenth under 10 minutes), 10 分钟, 1.5 小时.
fn view_len_words(len : Double) -> String {
  let tenth = fn(x : Double) -> String {
    let r = (x * 10.0).round() / 10.0
    if r == r.floor() {
      r.to_int().to_string()
    } else {
      r.to_string()
    }
  }
  if len < 60000.0 {
    tf("{0} 秒", [(len / 1000.0).round().to_int().to_string()])
  } else if len < 600000.0 {
    tf("{0} 分钟", [tenth(len / 60000.0)])
  } else if len < 3600000.0 {
    tf("{0} 分钟", [(len / 60000.0).round().to_int().to_string()])
  } else {
    tf("{0} 小时", [tenth(len / 3600000.0)])
  }
}

///|
fn pan_timeline(delta : Double) -> Unit {
  view_by_hand.val = now()
  @signals.untracked(fn() {
    view_from.set(view_from.get() + delta)
    follow_latest.set(view_from.get() + view_len() >= ax_span(view_len()) - 1.0 && delta > 0.0)
  })
  keep_view()
}

///|
fn show_latest() -> Unit {
  glide()
  follow_latest.set(true)
  keep_view()
  seek_to(span() - 1000.0)
}

///|
/// The view moved so `at` (ms into the buffer) is in it (a seek by the keys, a marker), not when it already is.
fn reveal(at : Double) -> Unit {
  let (from, len) = @signals.untracked(fn() { (view_from.get(), view_len()) })
  let at = ax_d(at, len)
  if at < from || at > from + len {
    glide()
    follow_latest.set(false)
    view_from.set(at - len / 2.0)
    keep_view()
  }
}

///|
/// A seek by the keys or a button: the view brought along.
fn jump_to(at : Double) -> Unit {
  // (a key held down (its repeats under 250 ms apart): each repeat shows the key frame before where it comes to, as
  // a drag does, and the frame itself once the key has been let go 150 ms; a seek to each exact frame in turn fell
  // behind the repeats, the picture going on moving after the key was let go: the user, 2026-11-14 「长时间按住左或者
  // 右，好像有预输入」)
  let t = now()
  let repeat = t - key_jump_at.val < 250.0
  key_jump_at.val = t
  if !repeat {
    seek_to(at)
    reveal(pos_now())
    return
  }
  key_seeking.val = true
  scrub_to(at)
  reveal(pos_now())
  match the_root.val {
    Some(r) =>
      r.at_moment(t + 150.0, fn() {
        if key_jump_at.val == t {
          key_seeking.val = false
          seek_to(pos_now())
        }
      })
      |> ignore
    None => {
      key_seeking.val = false
      seek_to(at)
    }
  }
}

///|
/// When the last key's jump came (jump_to), and whether its repeats are being shown as a drag's are.
let key_jump_at : Ref[Double] = Ref(-1000.0)

///|
let key_seeking : Ref[Bool] = Ref(false)

///|
/// The view's start and length set together (a frame's end dragged): its length at least the least, the whole buffer
/// the scale once it reaches it; following the newest when it reaches the end.
fn set_view(from : Double, len : Double) -> Unit {
  view_by_hand.val = now()
  let len = @cmp.maximum(min_view, len)
  view_duration.set(if len >= view_total() { 86400000.0 } else { len })
  view_from.set(from)
  let l = @signals.untracked(view_len)
  follow_latest.set(from + l >= ax_span(l) - 1.0)
  keep_view()
}

// ---- the clip ----

///|
fn start_clip() -> Unit {
  if clipping.untracked() {
    return
  }
  load_windows()
  clipping.set(true)
  // (a clip is the whole screen (整屏) until a window is picked or a region dragged out again)
  pick_window(None)
  clear_region()
  clip_kind.set(0)
  saved.set("")
  let total = span()
  // (from the playhead on, as Steam's: the user's choice, 2026-11-13; at the end, the last 30 s)
  let a = @cmp.maximum(0.0, pos_now())
  let mut b = @cmp.minimum(total, a + 30000.0)
  let mut a = a
  if b - a < 1000.0 {
    a = @cmp.maximum(0.0, b - 30000.0)
    b = total
  }
  clip_a.set(a)
  clip_b.set(b)
  frame_clip()
  clip_history_start()
}

///|
/// The view brought to the clip when it is a sliver of it: the clip about a third of the view, in its middle.
fn frame_clip() -> Unit {
  glide()
  let vl = @signals.untracked(view_len)
  let len = ax_d(clip_b.untracked(), vl) - ax_d(clip_a.untracked(), vl)
  if len * 6.0 < vl {
    view_duration.set(@cmp.maximum(min_view, len * 3.0))
    follow_latest.set(false)
    let l = @signals.untracked(view_len)
    view_from.set((ax_d(clip_a.untracked(), l) + ax_d(clip_b.untracked(), l)) / 2.0 - l / 2.0)
    keep_view()
  }
}

///|
/// The clip brought into the view: zoomed to it when it is a sliver of the view, and the view widened to hold it
/// when it does not.
fn show_clip() -> Unit {
  frame_clip()
  let vl = @signals.untracked(view_len)
  let len = ax_d(clip_b.untracked(), vl) - ax_d(clip_a.untracked(), vl)
  if len > vl * 0.9 {
    view_duration.set(len * 1.25)
  }
  let (from, vlen) = @signals.untracked(fn() { (view_from.get(), view_len()) })
  let (a, b) = (ax_d(clip_a.untracked(), vlen), ax_d(clip_b.untracked(), vlen))
  if a < from || b > from + vlen {
    follow_latest.set(false)
    view_from.set((a + b) / 2.0 - vlen / 2.0)
  }
  keep_view()
}

///|
fn set_clip_start(at : Double) -> Unit {
  if !clipping.untracked() {
    start_clip()
  }
  clip_a.set(@cmp.maximum(0.0, at))
  if clip_b.untracked() < clip_a.untracked() + 1000.0 {
    clip_b.set(@cmp.minimum(span(), clip_a.untracked() + 30000.0))
  }
}

///|
fn set_clip_end(at : Double) -> Unit {
  if !clipping.untracked() {
    start_clip()
  }
  clip_b.set(@cmp.minimum(span(), at))
  if clip_a.untracked() > clip_b.untracked() - 1000.0 {
    clip_a.set(@cmp.maximum(0.0, clip_b.untracked() - 30000.0))
  }
}

///|
/// The clip played from its start (the playhead stops at its end).
fn play_clip() -> Unit {
  // (from where it was paused when that is inside the clip, short of its last half second; else from its start: the
  // user, 2026-11-14 「clip状态暂停并播放好像会总是从头播放」)
  let (a, b) = (clip_a.untracked(), clip_b.untracked())
  let p = pos_now()
  if p >= a && p < b - 500.0 {
    set_playing(true)
    return
  }
  seek_to(a)
  reveal(a)
  set_playing(true)
}

// ---- markers ----

///|
fn next_mark(dir : Int) -> Double? {
  let base = t0()
  let p = pos_now()
  let mut best : Double? = None
  for m in marks {
    let at = m - base
    if dir > 0 && at > p + 500.0 {
      match best {
        Some(b) if b <= at => ()
        _ => best = Some(at)
      }
    }
    if dir < 0 && at < p - 500.0 {
      match best {
        Some(b) if b >= at => ()
        _ => best = Some(at)
      }
    }
  }
  best
}

///|
/// A marker at `at` (ms into the buffer), kept with the recorder's (markers.jsonl).
fn add_marker(at : Double) -> Unit {
  let abs = (t0() + at).round()
  if rp_append(cstr(root_dir() + "\\markers.jsonl"), @utf8.encode("{\"at\":\{abs.to_int64()}}\n")) == 1 {
    marks.push(abs)
    marks.sort()
    just_marked.val = abs
    data_changed()
    tell(tf("已在 {0} 加标记", [wall(abs)]), icon="check-circle")
  }
}

///|
/// The marker where the playhead is (within half a second of it), if there is one (bound).
fn mark_at_playhead(v : @view.View) -> Double? {
  data()
  let at = t0() + pos_drawn(v)
  for m in marks {
    if (m - at).abs() <= 500.0 {
      return Some(m)
    }
  }
  None
}

///|
/// The marker key: a toggle, a marker where the playhead is taken away, else one added there.
fn toggle_marker(v : @view.View) -> Unit {
  match @signals.untracked(fn() { mark_at_playhead(v) }) {
    Some(m) => {
      remove_marker(m)
      tell(tf("已移除 {0} 的标记", [wall(m)]), icon="check-circle")
    }
    None => add_marker(pos_now())
  }
}

///|
/// The marker added last from here: it comes in growing out of its place (band_parts.mbt's marks).
let just_marked : Ref[Double] = Ref(-1.0)

///|
/// The marker at `abs` (ms since the epoch) taken out of markers.jsonl (the recorder only ever adds to it).
fn remove_marker(abs : Double) -> Unit {
  let path = root_dir() + "\\markers.jsonl"
  let kept : Array[String] = []
  for line in read_text(path).split("\n") {
    let line = line.to_owned()
    match parse(line) {
      Some({ "at": Number(at, ..), .. }) if (at - abs).abs() < 1.0 => ()
      _ => if line.trim() != "" { kept.push(line) }
    }
  }
  rp_write(cstr(path), @utf8.encode(kept.join("\n") + (if kept.is_empty() { "" } else { "\n" }))) |> ignore
  match marks.search(abs) {
    Some(i) => marks.remove(i) |> ignore
    None => ()
  }
  data_changed()
}

///|
#borrow(path, data)
extern "C" fn rp_append(path : Bytes, data : Bytes) -> Int = "rp_append"

// ---- words for times ----

///|
/// How long ago a moment (ms since the epoch) was: 刚刚, 12 秒前, 8 分钟前, 1 小时 5 分前.
fn ago(at : Double) -> String {
  let s = ((rp_now() - at) / 1000.0).floor().to_int()
  if s < 5 {
    t("刚刚")
  } else if s < 60 {
    tf("{0} 秒前", [s.to_string()])
  } else if s < 3600 {
    tf("{0} 分钟前", [(s / 60).to_string()])
  } else if s % 3600 / 60 == 0 {
    tf("{0} 小时前", [(s / 3600).to_string()])
  } else {
    tf("{0} 小时 {1} 分前", [(s / 3600).to_string(), (s % 3600 / 60).to_string()])
  }
}

///|
/// 11月12日, or Nov 12.
fn month_day(m : Int, d : Int) -> String {
  let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  tf("{0}月{1}日", [m.to_string(), d.to_string(), names[(m - 1) % 12]])
}

///|
/// The local day of a moment (ms since the epoch), as days since 1970.
fn local_day(at : Double) -> Int {
  ((at + rp_local_offset().to_double() * 60000.0) / 86400000.0).floor().to_int()
}

///|
/// 今天, 昨天, or 11月12日.
fn day_name(at : Double) -> String {
  let d = local_day(at)
  let today = local_day(rp_now())
  if d == today {
    t("今天")
  } else if d == today - 1 {
    t("昨天")
  } else {
    let (_, m, dd) = civil_from_days(d)
    month_day(m, dd)
  }
}
