// What the recorder left in REPLAY_ROOT: the buffer's segments (`Buffer\<yyyyMMdd-HHmmss-fff>-<id>.mp4`, each with a
// `.json` beside it saying its `durationMs`: recording/SegmentStore.cs), the markers (`markers.jsonl`, `{"at"}`)
// and the app in front as it changed (`apps.jsonl`, `{"at","app"}`), times in ms since the epoch (UTC).

///|
#borrow(dir)
extern "C" fn rp_list(dir : Bytes) -> Bytes = "rp_list"

///|
#borrow(path)
extern "C" fn rp_size(path : Bytes) -> Double = "rp_size"

///|
#borrow(path)
extern "C" fn rp_read(path : Bytes, offset : Double, length : Int) -> Bytes = "rp_read"

///|
#borrow(path, data)
extern "C" fn rp_write(path : Bytes, data : Bytes) -> Int = "rp_write"

///|
#borrow(path)
extern "C" fn rp_mkdirs(path : Bytes) -> Int = "rp_mkdirs"

///|
extern "C" fn rp_local_offset_now() -> Int = "rp_local_offset"

///|
/// How far local time is ahead of UTC (minutes), asked of Windows at most once a second: the title bar's moment
/// and the axis asked it three times a frame while playing, each a walk of the time zone's rules.
let local_offset_read : Ref[(Double, Int)] = Ref((-1.0e18, 0))

///|
fn rp_local_offset() -> Int {
  let t = rp_now()
  let (at, v) = local_offset_read.val
  if t - at < 1000.0 && t >= at {
    return v
  }
  let v = rp_local_offset_now()
  local_offset_read.val = (t, v)
  v
}

///|
extern "C" fn rp_now() -> Double = "rp_now"

///|
#borrow(path)
extern "C" fn rp_reveal(path : Bytes) -> Unit = "rp_reveal"

///|
fn cstr(s : String) -> Bytes {
  @utf8.encode(s + "\u{0}")
}

///|
fn env_or(name : String, fallback : String) -> String {
  let v = @ui.env(name)
  if v != "" {
    v
  } else {
    fallback
  }
}

///|
fn root_dir() -> String {
  env_or(
    "REPLAY_ROOT",
    if is_mac() {
      pjoin(@ui.env("HOME"), "Library/Application Support/ScreenReplay")
    } else {
      @ui.env("LOCALAPPDATA") + "\\Replay"
    },
  )
}

///|
fn buffer_dir() -> String {
  env_or("REPLAY_DIR", pjoin(root_dir(), "Buffer"))
}

///|
/// The folders segments are in: the recorder's buffers.json (where it writes now, then those it wrote into before,
/// till what is there expires), else buffer_dir().
fn buffer_dirs() -> Array[String] {
  match parse(read_text(pjoin(root_dir(), "buffers.json"))) {
    Some(Object(o)) => {
      let out : Array[String] = []
      match o.get("current") {
        Some(String(v)) if v != "" => out.push(v)
        _ => ()
      }
      match o.get("old") {
        Some(Array(a)) =>
          for x in a {
            match x {
              String(v) if v != "" && !out.contains(v) => out.push(v)
              _ => ()
            }
          }
        _ => ()
      }
      if out.is_empty() { [buffer_dir()] } else { out }
    }
    _ => [buffer_dir()]
  }
}

///|
struct Seg {
  path : String
  /// when it began, ms since the epoch (UTC)
  start : Double
  dur : Double
  size : Double
  /// the frame rate it was recorded at (its .json's; 0: not said, a segment from before 90 and 120)
  fps : Int
}

///|
let segs : Array[Seg] = []

///|
/// When 删除全部录像 was last asked (ms since the epoch): what began before it is no longer read.
let purged_before : Ref[Double] = Ref(0.0)

///|
/// 删除全部录像 asked: what is shown of the recordings gone at once, not left till the recorder has deleted them (the
/// reviewer's 88th): playing stopped, the segments, markers and apps let go, each segment's index, levels and input with them;
/// the window shows it has nothing; what the recorder writes after it comes as ever.
fn purge_now() -> Unit {
  purged_before.val = rp_now()
  set_playing(false)
  for seg in segs {
    rp_idx_drop(cstr(seg.path))
    sidecars_drop(seg.path)
  }
  segs.clear()
  marks.clear()
  marks_read.val = 0.0
  marks_tail.val = ""
  marks_head.val = ""
  apps.clear()
  apps_read.val = 0.0
  apps_tail.val = ""
  apps_head.val = ""
  clear_windows()
  current.val = -1
  data_changed()
}

///|
/// The markers, ms since the epoch.
let marks : Array[Double] = []

///|
let marks_read : Ref[Double] = Ref(0.0)

///|
let marks_tail : Ref[String] = Ref("")

///|
let marks_head : Ref[String] = Ref("")

///|
/// The app in front from each time on: (ms since the epoch, its process name).
let apps : Array[(Double, String)] = []

///|
let apps_read : Ref[Double] = Ref(0.0)

///|
let apps_tail : Ref[String] = Ref("")

///|
let apps_head : Ref[String] = Ref("")

///|
fn digits(s : String, from : Int, n : Int) -> Int? {
  let mut v = 0
  for i in from..<(from + n) {
    if i >= s.length() {
      return None
    }
    let ch = s[i].to_int()
    if ch < '0'.to_int() || ch > '9'.to_int() {
      return None
    }
    v = v * 10 + (ch - '0'.to_int())
  }
  Some(v)
}

///|
/// Days since 1970-01-01 of a civil date (Howard Hinnant's days_from_civil).
fn days_from_civil(y0 : Int, m : Int, d : Int) -> Int {
  let y = if m <= 2 { y0 - 1 } else { y0 }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let mp = if m > 2 { m - 3 } else { m + 9 }
  let doy = (153 * mp + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468
}

///|
/// The civil date of a day since 1970-01-01 (Howard Hinnant's civil_from_days).
fn civil_from_days(z0 : Int) -> (Int, Int, Int) {
  let z = z0 + 719468
  let era = (if z >= 0 { z } else { z - 146096 }) / 146097
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  ((if m <= 2 { y + 1 } else { y }), m, d)
}

///|
/// A segment's start by its name, `yyyyMMdd-HHmmss-fff-…`.
fn start_of(name : String) -> Double? {
  match
    (
      digits(name, 0, 4),
      digits(name, 4, 2),
      digits(name, 6, 2),
      digits(name, 9, 2),
      digits(name, 11, 2),
      digits(name, 13, 2),
      digits(name, 16, 3),
    ) {
    (Some(y), Some(mo), Some(d), Some(h), Some(mi), Some(s), Some(ms)) => {
      let days = days_from_civil(y, mo, d).to_double()
      Some(
        days * 86400000.0 +
        (h * 3600 + mi * 60 + s).to_double() * 1000.0 +
        ms.to_double(),
      )
    }
    _ => None
  }
}

///|
fn read_text(path : String) -> String {
  // (opened once: its size and its bytes from the one handle, rp_read reading no more than the file holds)
  let bytes = rp_read(cstr(path), 0.0, 256 * 1024 * 1024)
  if bytes.length() == 0 {
    return ""
  }
  let text = @utf8.decode_lossy(bytes[:])
  // (a byte-order mark first, as .NET's UTF-8 writes one, is not part of the words)
  if text.has_prefix("\u{FEFF}") {
    text[1:].to_owned()
  } else {
    text
  }
}

///|
fn parse(text : String) -> Json? {
  try Some(@json.parse(text)) catch {
    _ => None
  }
}

///|
fn duration_of(json_path : String) -> (Double, Int)? {
  match parse(read_text(json_path)) {
    Some(Object(o)) =>
      match o.get("durationMs") {
        Some(Number(v, ..)) =>
          Some(
            (
              v,
              match o.get("fps") {
                Some(Number(f, ..)) => f.to_int()
                _ => 0
              },
            ),
          )
        _ => None
      }
    _ => None
  }
}

///|
/// What the folder holds now: its segments (in order), the markers, the apps.
fn load() -> Unit {
  index_start()
  let old_base = t0()
  let current_path = if current.val >= 0 && current.val < segs.length() { segs[current.val].path } else { "" }
  let known : Map[String, Seg] = Map([])
  for seg in segs { known[seg.path] = seg }
  let found : Array[Seg] = []
  // (each folder the recorder writes or wrote into: buffers.json, the one now and those before it, still expiring)
  for dir in buffer_dirs() {
  let names = @utf8.decode_lossy(rp_list(cstr(dir))[:])
  for name in names.split("\n") {
    let name = name.to_owned()
    if name.length() < 5 {
      continue
    }
    let path = pjoin(dir, name)
    match known.get(path) {
      Some(seg) => { found.push(seg); continue }
      None => ()
    }
    let stem = name[:name.length() - 4].to_owned()
    match (start_of(name), duration_of(pjoin(dir, stem + ".json"))) {
      // (none from before 删除全部录像 was asked: the recorder may not have deleted them yet)
      (Some(start), Some(dur)) if start >= purged_before.val => {
        found.push({ path, start, dur: dur.0, size: rp_size(cstr(path)), fps: dur.1 })
        rp_idx_add(cstr(path), dur.0)
      }
      _ => ()
    }
  }
  }
  found.sort_by(fn(a, b) { a.start.compare(b.start) })
  let mut changed = found.length() != segs.length()
  if !changed {
    for i, seg in found { if seg.path != segs[i].path { changed = true; break } }
  }
  if changed {
    let kept : Map[String, Bool] = Map([])
    for seg in found {
      kept[seg.path] = true
    }
    for seg in segs {
      if !kept.contains(seg.path) {
        rp_idx_drop(cstr(seg.path))
        sidecars_drop(seg.path)
        // (its pictures handed to mbui and its codec read once, let go of with it)
        seg_images_forget(seg.path)
        seg_codecs.remove(seg.path)
      }
    }
    segs.clear()
    segs.append(found)
    // Keep all coordinates at their absolute times when old segments expire.
    let shift = if old_base > 0.0 { old_base - t0() } else { 0.0 }
    if shift != 0.0 {
      let p = play.untracked()
      play.set({ ..p, pos: p.pos + shift })
      match native_made.val {
        Some(d) => d.shifted(shift)
        None => ()
      }
      view_from.set(view_from.untracked() + shift)
      clip_a.set(clip_a.untracked() + shift)
      clip_b.set(clip_b.untracked() + shift)
    }
    if current_path != "" {
      current.val = -1
      for i, seg in segs { if seg.path == current_path { current.val = i; break } }
      if current.val < 0 && !segs.is_empty() {
        // (the segment shown expired: to the oldest kept)
        seek_to(0.0)
      }
    }
    if @ui.env("REPLAY_TRACE") == "1" {
      @ui.log("REPLAY_REFRESH segments=\{segs.length()} from=\{view_from.untracked()} current=\{current.val}")
    }
  }
  if load_marks_incremental() {
    changed = true
  }
  if load_apps_incremental() {
    changed = true
  }
  if changed {
    data_changed()
  }
}

///|
/// Incrementally reads appended lines from `markers.jsonl` (re-reading from scratch if pruned/rewritten).
fn load_marks_incremental() -> Bool {
  let path = pjoin(root_dir(), "markers.jsonl")
  let size = rp_size(cstr(path))
  if size <= 0.0 {
    let had = !marks.is_empty()
    marks.clear()
    marks_read.val = 0.0
    marks_tail.val = ""
    marks_head.val = ""
    return had
  }
  let head = @utf8.decode_lossy(rp_read(cstr(path), 0.0, @cmp.minimum(48, size.to_int()))[:])
  let mut reset = false
  if size < marks_read.val || (marks_head.val != "" && head != marks_head.val) {
    marks.clear()
    marks_read.val = 0.0
    marks_tail.val = ""
    reset = true
  }
  marks_head.val = head
  if size <= marks_read.val {
    return reset
  }
  let n = (size - marks_read.val).to_int()
  let text = marks_tail.val + @utf8.decode_lossy(rp_read(cstr(path), marks_read.val, n)[:])
  marks_read.val = size
  let lines : Array[String] = []
  for l in text.split("\n") {
    lines.push(l.to_owned())
  }
  marks_tail.val = lines[lines.length() - 1]
  let had = marks.length()
  for i in 0..<(lines.length() - 1) {
    match parse(lines[i]) {
      Some({ "at": Number(at, ..), .. }) if at >= purged_before.val => marks.push(at)
      _ => ()
    }
  }
  if marks.length() != had || reset {
    marks.sort()
    true
  } else {
    false
  }
}

///|
/// Incrementally reads appended lines from `apps.jsonl` (re-reading from scratch if pruned/rewritten).
fn load_apps_incremental() -> Bool {
  let path = pjoin(root_dir(), "apps.jsonl")
  let size = rp_size(cstr(path))
  if size <= 0.0 {
    let had = !apps.is_empty()
    apps.clear()
    apps_read.val = 0.0
    apps_tail.val = ""
    apps_head.val = ""
    return had
  }
  let head = @utf8.decode_lossy(rp_read(cstr(path), 0.0, @cmp.minimum(48, size.to_int()))[:])
  let mut reset = false
  if size < apps_read.val || (apps_head.val != "" && head != apps_head.val) {
    apps.clear()
    apps_read.val = 0.0
    apps_tail.val = ""
    reset = true
  }
  apps_head.val = head
  if size <= apps_read.val {
    return reset
  }
  let n = (size - apps_read.val).to_int()
  let text = apps_tail.val + @utf8.decode_lossy(rp_read(cstr(path), apps_read.val, n)[:])
  apps_read.val = size
  let lines : Array[String] = []
  for l in text.split("\n") {
    lines.push(l.to_owned())
  }
  apps_tail.val = lines[lines.length() - 1]
  let had = apps.length()
  for i in 0..<(lines.length() - 1) {
    match parse(lines[i]) {
      Some({ "at": Number(at, ..), "app": String(app), .. }) if at >= purged_before.val => apps.push((at, app))
      _ => ()
    }
  }
  apps.length() != had || reset
}

///|
/// Asks the recorder to close the segment it is writing, so the replay reaches up to now.
fn ask_flush() -> Unit {
  rp_write(cstr(pjoin(root_dir(), "flush.request")), b"1") |> ignore
}

///|
fn t0() -> Double {
  if segs.is_empty() {
    0.0
  } else {
    segs[0].start
  }
}

///|
/// The buffer's span, ms from its first segment's start to its last one's end.
fn span() -> Double {
  if segs.is_empty() {
    1.0
  } else {
    let last = segs[segs.length() - 1]
    @cmp.maximum(1.0, last.start + last.dur - t0())
  }
}

///|
fn two(n : Int) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    n.to_string()
  }
}

///|
/// `m:ss` or `h:mm:ss` of a length.
fn clock(ms : Double) -> String {
  // (a length: rounded, 29.97 s is 0:30; moments of the day are cut to their second: wall)
  let total = (@cmp.maximum(0.0, ms) / 1000.0).round().to_int()
  let h = total / 3600
  let m = total % 3600 / 60
  let s = total % 60
  if h > 0 {
    "\{h}:\{two(m)}:\{two(s)}"
  } else {
    "\{m}:\{two(s)}"
  }
}

///|
/// The milliseconds of `at` (.mmm), to follow `wall`'s HH:MM:SS.
fn ms_words(at : Double) -> String {
  let ms = (at - (at / 1000.0).floor() * 1000.0).floor().to_int()
  let m = if ms < 10 { "00\{ms}" } else if ms < 100 { "0\{ms}" } else { ms.to_string() }
  "." + m
}

///|
/// The local time of day of a moment (ms since the epoch), `HH:mm:ss` (`HH:mm` with `short`).
fn wall(at : Double, short? : Bool = false) -> String {
  let here = at + rp_local_offset().to_double() * 60000.0
  let day_ms = here - (here / 86400000.0).floor() * 86400000.0
  let s = (day_ms / 1000.0).floor().to_int()
  if short {
    "\{two(s / 3600)}:\{two(s % 3600 / 60)}"
  } else {
    "\{two(s / 3600)}:\{two(s % 3600 / 60)}:\{two(s % 60)}"
  }
}

///|
/// A local `yyyy-MM-dd HH-mm-ss` for file names.
fn stamp(at : Double) -> String {
  let here = at + rp_local_offset().to_double() * 60000.0
  let days = (here / 86400000.0).floor()
  let (y, m, d) = civil_from_days(days.to_int())
  let s = ((here - days * 86400000.0) / 1000.0).floor().to_int()
  "\{y}-\{two(m)}-\{two(d)} \{two(s / 3600)}-\{two(s % 3600 / 60)}-\{two(s % 60)}"
}
