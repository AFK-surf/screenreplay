// Where the windows were (the recorder's windows.jsonl: a line each time what was on the screen changed, the
// windows front to back), read as it grows. In clip mode the window under the pointer on the picture is lit and a
// press picks it: the clip is then that window's part of the picture (encoded again, the crop following the window or
// the whole stretch it went over), and the timeline shows when it was fully in view, partly covered or not there.

///|
struct Win {
  hwnd : Int64
  owner : Int64
  process : String
  title : String
  x : Double
  y : Double
  w : Double
  h : Double
  /// 0 normal, 1 minimized, 2 maximized
  state : Int
}

///|
struct Snap {
  at : Double
  /// the primary display recorded, in the same pixels
  sx : Double
  sy : Double
  sw : Double
  sh : Double
  wins : Array[Win]
}

///|
let snaps : Array[Snap] = []

///|
/// How much of the file has been read, and what is left of a line not ended yet.
let snaps_read : Ref[Double] = Ref(0.0)

///|
let snaps_tail : Ref[String] = Ref("")

///|
/// The file's first bytes as last read: other ones, it was rewritten (pruned) and is read again from its start.
let snaps_head : Ref[String] = Ref("")

///|
fn num_at(a : Array[Json], i : Int) -> Double {
  match a.get(i) {
    Some(Number(v, ..)) => v
    _ => 0.0
  }
}

///|
fn text_at(a : Array[Json], i : Int) -> String {
  match a.get(i) {
    Some(String(v)) => v
    _ => ""
  }
}

///|
fn parse_snap(line : String) -> Snap? {
  match parse(line) {
    Some({ "at": Number(at, ..), "screen": Array(sc), "w": Array(ws), .. }) => {
      let wins : Array[Win] = []
      for item in ws {
        match item {
          Array(a) =>
            wins.push({
              hwnd: num_at(a, 0).to_int64(),
              owner: num_at(a, 1).to_int64(),
              process: text_at(a, 2),
              title: text_at(a, 3),
              x: num_at(a, 4),
              y: num_at(a, 5),
              w: num_at(a, 6),
              h: num_at(a, 7),
              state: num_at(a, 8).to_int(),
            })
          _ => ()
        }
      }
      Some({ at, sx: num_at(sc, 0), sy: num_at(sc, 1), sw: num_at(sc, 2), sh: num_at(sc, 3), wins })
    }
    _ => None
  }
}

///|
/// What was added to windows.jsonl since last read (all of it again when it was rewritten shorter: pruned).
fn load_windows() -> Unit {
  let path = root_dir() + "\\windows.jsonl"
  let size = rp_size(cstr(path))
  if size <= 0.0 {
    return
  }
  let head = @utf8.decode_lossy(rp_read(cstr(path), 0.0, @cmp.minimum(48, size.to_int()))[:])
  if size < snaps_read.val || (snaps_head.val != "" && head != snaps_head.val) {
    snaps.clear()
    snaps_read.val = 0.0
    snaps_tail.val = ""
  }
  snaps_head.val = head
  if size <= snaps_read.val {
    return
  }
  let n = (size - snaps_read.val).to_int()
  let text = snaps_tail.val + @utf8.decode_lossy(rp_read(cstr(path), snaps_read.val, n)[:])
  snaps_read.val = size
  let lines : Array[String] = []
  for l in text.split("\n") {
    lines.push(l.to_owned())
  }
  snaps_tail.val = lines[lines.length() - 1]
  let had = snaps.length()
  for i in 0..<(lines.length() - 1) {
    match parse_snap(lines[i]) {
      Some(s) => snaps.push(s)
      None => ()
    }
  }
  // (what is bound to the windows noted reads data(): the picker's taking presses)
  if snaps.length() != had {
    data_changed()
  }
}

///|
/// The snapshot in force at `abs` (ms since the epoch): the last at or before it.
fn snap_at(abs : Double) -> Snap? {
  let mut lo = 0
  let mut hi = snaps.length() - 1
  let mut found = -1
  while lo <= hi {
    let mid = (lo + hi) / 2
    if snaps[mid].at <= abs {
      found = mid
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  if found < 0 {
    None
  } else {
    Some(snaps[found])
  }
}

///|
fn win_shown(w : Win) -> Bool {
  w.state != 1
}

///|
/// The window under screen point (x, y) at `abs`, the frontmost; a menu or a dialog over its owner counts as its
/// owner (what a person means to pick is the app's window).
fn window_under(abs : Double, x : Double, y : Double) -> Win? {
  match snap_at(abs) {
    None => None
    Some(s) => {
      for w in s.wins {
        if win_shown(w) && x >= w.x && x < w.x + w.w && y >= w.y && y < w.y + w.h {
          if w.owner != 0L {
            for o in s.wins {
              if o.hwnd == w.owner && win_shown(o) {
                return Some(o)
              }
            }
          }
          return Some(w)
        }
      }
      None
    }
  }
}

///|
/// The window picked for the clip (0: the whole screen), its name for the head.
let picked_hwnd : @signals.Signal[Int64] = @signals.signal(0L)

///|
let picked_name : @signals.Signal[String] = @signals.signal("")

///|
/// The crop follows the window as it moves (else the whole stretch it went over); its menus and dialogs come too.
let follow_window : @signals.Signal[Bool] = @signals.signal(true)

///|
let with_popups : @signals.Signal[Bool] = @signals.signal(true)

///|
fn win_label(w : Win) -> String {
  let name = app_name(w.process)
  if w.title == "" || w.title == name {
    name
  } else {
    name + " · " + w.title
  }
}

///|
fn intersect(a : (Double, Double, Double, Double), b : (Double, Double, Double, Double)) -> (Double, Double, Double, Double)? {
  let x0 = @cmp.maximum(a.0, b.0)
  let y0 = @cmp.maximum(a.1, b.1)
  let x1 = @cmp.minimum(a.0 + a.2, b.0 + b.2)
  let y1 = @cmp.minimum(a.1 + a.3, b.1 + b.3)
  if x1 - x0 < 1.0 || y1 - y0 < 1.0 {
    None
  } else {
    Some((x0, y0, x1 - x0, y1 - y0))
  }
}

///|
/// The picked window's rect at a snapshot, in screen pixels cut to the display, its popups with it when asked; None
/// when it is not on the display then.
fn picked_rect(s : Snap) -> (Double, Double, Double, Double)? {
  let screen = (s.sx, s.sy, s.sw, s.sh)
  let mut r : (Double, Double, Double, Double)? = None
  for w in s.wins {
    if w.hwnd == picked_hwnd.get() && win_shown(w) {
      r = Some((w.x, w.y, w.w, w.h))
    }
  }
  match r {
    None => None
    Some(base) => {
      let mut u = base
      if with_popups.get() {
        for w in s.wins {
          if w.owner == picked_hwnd.get() && win_shown(w) {
            let x0 = @cmp.minimum(u.0, w.x)
            let y0 = @cmp.minimum(u.1, w.y)
            let x1 = @cmp.maximum(u.0 + u.2, w.x + w.w)
            let y1 = @cmp.maximum(u.1 + u.3, w.y + w.h)
            u = (x0, y0, x1 - x0, y1 - y0)
          }
        }
      }
      intersect(u, screen)
    }
  }
}

///|
/// How the picked window stands at a snapshot: 0 not there, 1 partly covered, 2 fully in view.
fn picked_view(s : Snap) -> Int {
  match picked_rect(s) {
    None => 0
    Some(r) => {
      for w in s.wins {
        if w.hwnd == picked_hwnd.get() {
          // (a part of it off the display is not fully in view)
          if r.2 < w.w - 1.0 || r.3 < w.h - 1.0 {
            return 1
          }
          return 2
        }
        if !win_shown(w) || w.owner == picked_hwnd.get() {
          continue
        }
        if intersect(r, (w.x, w.y, w.w, w.h)) is Some(_) {
          return 1
        }
      }
      2
    }
  }
}

///|
/// The stretches of [a, b) (ms into the buffer) by how the picked window stood: (from, to, view).
fn picked_runs(a : Double, b : Double) -> Array[(Double, Double, Int)] {
  let base = t0()
  let runs : Array[(Double, Double, Int)] = []
  let mut at = a
  let mut view = match snap_at(base + a) {
    Some(s) => picked_view(s)
    None => 0
  }
  for s in snaps {
    let t = s.at - base
    if t <= a {
      continue
    }
    if t >= b {
      break
    }
    let v = picked_view(s)
    if v != view {
      runs.push((at, t, view))
      at = t
      view = v
    }
  }
  runs.push((at, b, view))
  runs
}

///|
/// Whether the picked window moved or changed size in the clip; whether a menu or dialog of it showed.
fn picked_moved_and_popups() -> (Bool, Bool) {
  let base = t0()
  let mut first : (Double, Double, Double, Double)? = None
  let mut moved = false
  let mut popups = false
  let check = fn(s : Snap) {
    for w in s.wins {
      if w.owner == picked_hwnd.get() && win_shown(w) {
        popups = true
      }
      if w.hwnd == picked_hwnd.get() && win_shown(w) {
        let r = (w.x, w.y, w.w, w.h)
        match first {
          None => first = Some(r)
          Some(f) => if f != r { moved = true }
        }
      }
    }
  }
  match snap_at(base + clip_a.get()) {
    Some(s) => check(s)
    None => ()
  }
  for s in snaps {
    let t = s.at - base
    if t > clip_a.get() && t < clip_b.get() {
      check(s)
    }
  }
  (moved, popups)
}

///|
/// The crop in the recording's pixels, as a plan for the encoder (a line each change: ms into the clip, x, y, w, h)
/// and the picture it makes (w, h); the whole stretch the window went over when not following it.
fn crop_plan(rec_w : Double, rec_h : Double) -> (String, Int, Int) {
  let base = t0()
  let rects : Array[(Double, (Double, Double, Double, Double))] = []
  let mut scale = 1.0
  let mut ox = 0.0
  let mut oy = 0.0
  let add = fn(t : Double, s : Snap) {
    if s.sw > 0.0 {
      scale = rec_w / s.sw
      ox = s.sx
      oy = s.sy
    }
    match picked_rect(s) {
      Some(r) => rects.push((t, ((r.0 - ox) * scale, (r.1 - oy) * scale, r.2 * scale, r.3 * scale)))
      // (not there then: black, never what was behind it)
      None => rects.push((t, (0.0, 0.0, 0.0, 0.0)))
    }
  }
  match snap_at(base + clip_a.get()) {
    Some(s) => add(0.0, s)
    None => ()
  }
  for s in snaps {
    let t = s.at - base
    if t > clip_a.get() && t < clip_b.get() {
      add(clip_time(t), s)
    }
  }
  let mut any = false
  for e in rects {
    if e.1.2 > 0.0 {
      any = true
    }
  }
  if !any {
    return ("", even(rec_w), even(rec_h))
  }
  let mut mw = 0.0
  let mut mh = 0.0
  let mut ux0 = rec_w
  let mut uy0 = rec_h
  let mut ux1 = 0.0
  let mut uy1 = 0.0
  for e in rects {
    let r = e.1
    if r.2 <= 0.0 {
      continue
    }
    mw = @cmp.maximum(mw, r.2)
    mh = @cmp.maximum(mh, r.3)
    ux0 = @cmp.minimum(ux0, r.0)
    uy0 = @cmp.minimum(uy0, r.1)
    ux1 = @cmp.maximum(ux1, r.0 + r.2)
    uy1 = @cmp.maximum(uy1, r.1 + r.3)
  }
  let lines : Array[String] = []
  if follow_window.get() {
    for e in rects {
      let r = e.1
      // (edges on half pixels taken inward; its size from its own size alone, so a move by a fraction never changes it)
      lines.push("\{e.0}\t\{r.0.ceil()}\t\{r.1.ceil()}\t\{r.2.floor()}\t\{r.3.floor()}")
    }
    (lines.join("\n"), even(@cmp.minimum(mw, rec_w)), even(@cmp.minimum(mh, rec_h)))
  } else {
    for e in rects {
      if e.1.2 > 0.0 {
        lines.push("\{e.0}\t\{ux0.round()}\t\{uy0.round()}\t\{(ux1 - ux0).round()}\t\{(uy1 - uy0).round()}")
      } else {
        lines.push("\{e.0}\t0\t0\t0\t0")
      }
    }
    (lines.join("\n"), even(ux1 - ux0), even(uy1 - uy0))
  }
}

///|
/// The clip cut to where the window was there at all, or to its longest stretch fully in view.
fn trim_to_window(full : Bool) -> Unit {
  clip_mark()
  let runs = picked_runs(clip_a.get(), clip_b.get())
  if full {
    let mut best : (Double, Double)? = None
    for r in runs {
      if r.2 == 2 {
        match best {
          Some(b) if b.1 - b.0 >= r.1 - r.0 => ()
          _ => best = Some((r.0, r.1))
        }
      }
    }
    match best {
      Some(b) if b.1 - b.0 >= 1000.0 => {
        clip_a.set(b.0)
        clip_b.set(b.1)
      }
      _ => ()
    }
  } else {
    let mut a = -1.0
    let mut b = -1.0
    for r in runs {
      if r.2 != 0 {
        if a < 0.0 {
          a = r.0
        }
        b = r.1
      }
    }
    if a >= 0.0 && b - a >= 1000.0 {
      clip_a.set(a)
      clip_b.set(b)
    }
  }
}

///|
fn pick_window(w : Win?) -> Unit {
  match w {
    Some(w) => {
      picked_hwnd.set(w.hwnd)
      picked_name.set(win_label(w))
      picked_process.set(w.process)
    }
    None => {
      picked_hwnd.set(0L)
      picked_name.set("")
      picked_process.set("")
      window_options_open.set(false)
    }
  }
}

///|
/// The picked window's process (its icon, its app's name).
let picked_process : @signals.Signal[String] = @signals.signal("")

///|
/// The window options' popover open.
let window_options_open : @signals.Signal[Bool] = @signals.signal(false)

///|
fn even(v : Double) -> Int {
  @cmp.maximum(2, (v / 2.0).floor().to_int() * 2)
}
