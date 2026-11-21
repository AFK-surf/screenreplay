// Saving a clip, as Steam's export does it: as recorded (cut without encoding again, at once), to a size (encoded
// again in H.264 at the largest picture that size allows: for a chat), or as asked (its format first: H.264, H.265,
// AV1 where the GPU encodes it, or a GIF; then resolution, frame rate, quality). The length and the size it will come
// to shown as the choices change; encoding runs on a thread of its own (replay_export.cpp), its progress drawn and
// cancellable; when done, the note that it was saved, the file copied too when asked. The format and a GIF's frame
// rate last chosen are kept (viewer.json: theme.mbt), H.264 the first time.

///|
#borrow(plan, output, crops)
extern "C" fn rp_export_start(plan : Bytes, output : Bytes, width : Int, height : Int, fps : Int, bitrate : Int, codec : Int, crops : Bytes, scale : Double) -> Int = "rp_export_start"

///|
extern "C" fn rp_av1_here() -> Int = "rp_av1_here"

///|
#borrow(plan, crops)
extern "C" fn rp_gif_estimate_start(plan : Bytes, width : Int, height : Int, fps : Int, crops : Bytes, scale : Double) -> Unit = "rp_gif_estimate_start"

///|
extern "C" fn rp_gif_estimate() -> Double = "rp_gif_estimate"

///|
extern "C" fn rp_export_state() -> Int = "rp_export_state"

///|
extern "C" fn rp_export_progress() -> Double = "rp_export_progress"

///|
extern "C" fn rp_export_failure() -> Int = "rp_export_failure"

///|
extern "C" fn rp_export_cancel() -> Unit = "rp_export_cancel"

///|
extern "C" fn rp_export_reset() -> Unit = "rp_export_reset"

///|
#borrow(plan, output)
extern "C" fn rp_concat_start(plan : Bytes, output : Bytes) -> Int = "rp_concat_start"

///|
extern "C" fn rp_concat_state() -> Int = "rp_concat_state"

///|
extern "C" fn rp_concat_progress() -> Double = "rp_concat_progress"

///|
extern "C" fn rp_concat_take() -> Int = "rp_concat_take"

///|
extern "C" fn rp_concat_cancel() -> Unit = "rp_concat_cancel"

///|
#borrow(path)
extern "C" fn rp_copy_file(path : Bytes) -> Int = "rp_copy_file"

///|
#borrow(from, to)
extern "C" fn rp_rename(from : Bytes, to : Bytes) -> Int = "rp_rename"

///|
#borrow(path)
extern "C" fn rp_delete(path : Bytes) -> Unit = "rp_delete"

///|
let export_open : @signals.Signal[Bool] = @signals.signal(false)

///|
/// 0 as recorded, 1 to a size, 2 as asked.
let export_mode : @signals.Signal[Int] = @signals.signal(0)

///|
// (Steam's stops, up to 1 GB: the user, 2026-11-17 「改成类似于steam这种的slider，最大1G」)
let size_choices : Array[Double] = [10.0, 25.0, 35.0, 50.0, 100.0, 250.0, 500.0, 1024.0]

///|
let export_size : @signals.Signal[Int] = @signals.signal(1)

///|
/// As asked: the height (0 the recording's), the frame rate (0 the recording's), the quality (0 low, 1 medium,
/// 2 high), the format (export_format), a GIF's frame rate.
let export_height : @signals.Signal[Int] = @signals.signal(0)

///|
let export_fps : @signals.Signal[Int] = @signals.signal(0)

///|
let export_quality : @signals.Signal[Int] = @signals.signal(2)

///|
/// 0 H.264, 1 H.265, 2 AV1, 3 a GIF (as rp_export_start's codec).
let export_format : @signals.Signal[Int] = @signals.signal(0)

///|
let gif_fps : @signals.Signal[Int] = @signals.signal(15)

///|
/// The formats as viewer.json keeps them.
let format_names : Array[String] = ["h264", "h265", "av1", "gif"]

///|
/// The formats offered: AV1 only where the GPU encodes it and the system decodes it (the clip saved then plays here, in
/// the saved clips' player, as the others do).
fn formats() -> Array[Int] {
  if av1_saved_here() {
    [0, 1, 2, 3]
  } else {
    [0, 1, 3]
  }
}

///|
/// The format in force (to a size, H.264; AV1 kept from a PC that encodes it is H.264 on one that does not).
fn format() -> Int {
  let f = export_format.get()
  if mode() == 1 || (f == 2 && !av1_saved_here()) {
    0
  } else {
    f
  }
}

///|
/// Whether a clip is saved as AV1 here: the GPU encodes it (rp_av1_here) and the system decodes it (mbui's
/// av1_here), else it would be saved as a file this window could not play.
fn av1_saved_here() -> Bool {
  rp_av1_here() == 1 && @ui.av1_here()
}

///|
fn format_label(f : Int) -> String {
  ["H.264", "H.265", "AV1", "GIF"][f]
}

///|
/// What a codec needs of H.264's bitrate for the same picture: H.265 1/1.5 (as the recorder has it), AV1 about 0.75 of
/// H.265's.
fn codec_factor(codec : Int) -> Double {
  match codec {
    1 => 1.0 / 1.5
    2 => 1.0 / 1.5 * 0.75
    _ => 1.0
  }
}

///|
/// What a GIF's picture is scaled by: no wider than 960, never larger than recorded.
fn gif_scale(w : Double) -> Double {
  if w > 960.0 {
    960.0 / w
  } else {
    1.0
  }
}

///|
/// An encode under way: its file ("" none), whether it goes on the clipboard when done, how far it is (0..1).
let export_out : @signals.Signal[String] = @signals.signal("")

///|
let export_copy : Ref[Bool] = Ref(false)

///|
let export_done : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })

///|
let export_error : @signals.Signal[String] = @signals.signal("")

///|
/// The recording's picture size and frame rate (the player's, else the recorder's word, else 1080p30).
fn source_format() -> (Double, Double, Int) {
  let info = recording_info()
  picture_aspect.get() |> ignore
  let (pw, ph) = match native().track {
    Some(t) => (t.shown_w.to_double(), t.shown_h.to_double())
    None => (0.0, 0.0)
  }
  let w = if pw > 0.0 { pw } else if info.width > 0 { info.width.to_double() } else { 1920.0 }
  let h = if ph > 0.0 { ph } else if info.height > 0 { info.height.to_double() } else { 1080.0 }
  // (the frame rate the clip's start was recorded at, its segment says; else what the settings ask now)
  let fps = match seg_at(t0() + clip_a.get()) {
    Some(i) if segs[i].fps > 0 => fps_of(segs[i].fps.to_double())
    _ => fps_of(sets().fps.to_double())
  }
  (w, h, fps)
}

///|
/// Each segment's picture codec as its file says it ("" not yet: one still being written), read once each.
let seg_codecs : Map[String, String] = Map([])

///|
/// The codecs of what the clip covers as recorded (H.264, H.265…, each once, in their order): what 原样 copies, which the
/// codec chosen in the settings need not be (the recordings before it was changed are as they were). The settings'
/// word where no segment can say yet.
fn clip_codecs() -> Array[String] {
  let (a, b) = (clip_a.get(), clip_b.get())
  let base = t0()
  let out : Array[String] = []
  for s in segs {
    let from = s.start - base
    if from + s.dur <= a || from >= b {
      continue
    }
    let name = match seg_codecs.get(s.path) {
      Some(n) => n
      None => {
        let n = codec_name(mp4_video_codec(s.path))
        if n != "" {
          seg_codecs[s.path] = n
        }
        n
      }
    }
    if name != "" && !out.contains(name) {
      out.push(name)
    }
  }
  if out.is_empty() {
    out.push(if recording_info().codec == "H264" || sets().codec == "h264" { "H.264" } else { "H.265" })
  }
  out
}

///|
/// The bitrate the recorder gives a picture and rate at high quality in H.264 (recording/Bitrate.cs):
/// 3 Mbps × (pixels / 10⁶)^0.8 × (fps / 30)^0.6 × 1.5, held to 1…150 Mbps. Scaled by a quality (0.5 low, 0.75
/// medium, 1 high, 1.6 ultra) and by the codec's (codec_factor).
fn h264_estimate(w : Double, h : Double, fps : Int) -> Double {
  let megapixels = @cmp.maximum(2.0, w) * @cmp.maximum(2.0, h) / 1000000.0
  let rate = 3000000.0 *
    @math.pow(megapixels, 0.8) *
    @math.pow(@cmp.maximum(1, fps).to_double() / 30.0, 0.6) *
    1.5
  @cmp.minimum(150000000.0, @cmp.maximum(1000000.0, rate))
}

///|
/// The way of saving in force: one window's part cannot be saved as recorded (it is encoded again), so 原样 is 自定义
/// then.
fn mode() -> Int {
  if cropping() && export_mode.get() == 0 {
    2
  } else {
    export_mode.get()
  }
}

///|
/// An H.264 picture's frame rate held to what its highest level takes (5.2: 2 073 600 macroblocks a second; the
/// encoder refuses more, MF_E_INVALIDMEDIATYPE: 4K at 120 or 90 is H.264's 60, H.265 and AV1 taking them).
fn h264_fps(codec : Int, w : Int, h : Int, fps : Int) -> Int {
  if codec != 0 {
    return fps
  }
  let blocks = ((w + 15) / 16) * ((h + 15) / 16)
  if blocks <= 0 {
    return fps
  }
  let most = 2073600 / blocks
  if fps <= most {
    fps
  } else if most >= 90 {
    90
  } else if most >= 60 {
    60
  } else {
    30
  }
}

///|
/// The encode the choices make: width, height, frame rate, bitrate (none for a GIF), codec.
fn export_plan() -> (Int, Int, Int, Double, Int) {
  let (sw, sh, sfps) = source_format()
  let secs = @cmp.maximum(1.0, clip_kept() / 1000.0)
  let quality = [0.5, 0.75, 1.0][export_quality.get()]
  let codec = format()
  if codec == 3 {
    // the recording's picture, or its part cut out, no wider than 960; 15 or 10 frames a second
    let (bw, bh) = if cropping() {
      let (_, cw, ch) = crop_now(sw, sh)
      (cw.to_double(), ch.to_double())
    } else {
      (sw, sh)
    }
    let k = gif_scale(bw)
    return (even(bw * k), even(bh * k), @cmp.minimum(gif_fps.get(), sfps), 0.0, 3)
  }
  if cropping() {
    // one window or a region: its part at the recording's own pixels
    let (_, cw, ch) = crop_now(sw, sh)
    let fps = if mode() == 1 {
      sfps
    } else if export_fps.get() > 0 {
      @cmp.minimum(export_fps.get(), sfps)
    } else {
      sfps
    }
    let rate = if mode() == 1 {
      @cmp.minimum(
        h264_estimate(cw.to_double(), ch.to_double(), fps),
        @cmp.maximum(250000.0, size_choices[export_size.get()] * 1048576.0 * 8.0 * 0.95 / secs - 128000.0),
      )
    } else {
      h264_estimate(cw.to_double(), ch.to_double(), fps) * quality * codec_factor(codec)
    }
    let fps = h264_fps(codec, cw, ch, fps)
    return (cw, ch, fps, rate, codec)
  }
  if export_mode.get() == 1 {
    // the largest picture the size allows at about 0.04 bits a pixel a frame, at the recording's own frame rate (not
    // held to 30: the user, 2026-11-17 「感觉也别限制帧数？」), H.264's level holding it where it must
    let fps = sfps
    let target = @cmp.maximum(250000.0, size_choices[export_size.get()] * 1048576.0 * 8.0 * 0.95 / secs - 128000.0)
    let mut h = 480.0
    for cand in [sh, 1440.0, 1080.0, 720.0] {
      if cand <= sh && target / (sw * cand / sh * cand * fps.to_double()) >= 0.04 {
        h = cand
        break
      }
    }
    h = @cmp.minimum(h, sh)
    // (never more than that picture needs: a short clip under a large cap is not blown up to the cap)
    let fps = h264_fps(0, even(sw * h / sh), even(h), fps)
    let rate = @cmp.minimum(target, h264_estimate(sw * h / sh, h, fps))
    (even(sw * h / sh), even(h), fps, rate, 0)
  } else {
    let h = if export_height.get() > 0 && export_height.get().to_double() < sh {
      export_height.get().to_double()
    } else {
      sh
    }
    let fps = if export_fps.get() > 0 { @cmp.minimum(export_fps.get(), sfps) } else { sfps }
    let fps = h264_fps(codec, even(sw * h / sh), even(h), fps)
    let w = sw * h / sh
    let rate = h264_estimate(w, h, fps) * quality * codec_factor(codec)
    (even(w), even(h), fps, rate, codec)
  }
}

///|
/// The crop for the encoder and the picture it makes: the region's, else the picked window's (crop_plan).
fn crop_now(sw : Double, sh : Double) -> (String, Int, Int) {
  match region_on() {
    Some(r) => region_crop(r)
    None => crop_plan(sw, sh)
  }
}

///|
#borrow(path, identity)
extern "C" fn rp_crop_thumb(path : Bytes, identity : Bytes, ms : Double, x : Int, y : Int, w : Int, h : Int) -> Bytes = "rp_crop_thumb"

///|
/// Bumped to look again for a crop's preview being made.
let crop_thumb_rev : @signals.Signal[Int] = @signals.signal(0)

///|
/// The save dialog's preview while cropping (a region, a window picked): the clip's first frame cut to the crop it
/// starts with, at the recording's own pixels (the index's pictures are 384 wide: a region cut out of one was a blur),
/// made in the background (rp_crop_thumb); None while it is made or where there is none, the whole picture's then
/// (the user, 2026-11-16: 「导出dialog preview这里不是area select区域的预览」).
fn crop_thumb_key() -> String? {
  crop_thumb_rev.get() |> ignore
  let (sw, sh) = rec_size()
  let (plan, _, _) = crop_now(sw, sh)
  let first = plan.split("\n").next().map(fn(l) { l.to_owned() }).unwrap_or("")
  let parts = first.split("\t").map(fn(p) { p.to_owned() }).collect()
  guard parts.length() == 5 else { return None }
  let num = fn(i : Int) {
    let j : Json? = try Some(@json.parse(parts[i])) catch { _ => None }
    match j {
      Some(Json::Number(n, ..)) => n.round().to_int()
      _ => 0
    }
  }
  let (x, y, w, h) = (num(1), num(2), num(3), num(4))
  guard w > 0 && h > 0 else { return None }
  let at = clip_a.get()
  guard seg_at(t0() + at) is Some(i) else { return None }
  let s = segs[i]
  let inside = t0() + at - s.start
  let identity = "\{s.path}|\{inside}|\{x},\{y},\{w},\{h}"
  let key = "mem:crop-" + identity
  if @ui.has_image(key) {
    return Some(key)
  }
  let bmp = rp_crop_thumb(cstr(s.path), cstr(identity), inside, x, y, w, h)
  if bmp.length() > 1 {
    @ui.add_image(key, bmp)
    crop_images.keep(key)
    Some(key)
  } else {
    if bmp.length() == 1 && bmp[0] == 0 {
      match the_root.val {
        Some(r) => r.at_moment(now() + 50.0, fn() { crop_thumb_rev.set(crop_thumb_rev.untracked() + 1) }) |> ignore
        None => ()
      }
    }
    None
  }
}

///|
/// What the clip will take: as recorded, its segments' bytes in it; encoded, its bitrate over its length (H.264's and
/// H.265's 5% more); a GIF, as estimated (gif_estimate; -1 while that is made).
fn export_bytes() -> Double {
  let (a, b) = (clip_a.get(), clip_b.get())
  let secs = (b - a) / 1000.0
  if mode() == 0 {
    data()
    let base = t0()
    let mut bytes = 0.0
    for s in segs {
      let from = s.start - base
      let x = @cmp.maximum(from, a)
      let y = @cmp.minimum(from + s.dur, b)
      if y > x && s.dur > 0.0 {
        bytes += s.size * (y - x) / s.dur
      }
    }
    bytes
  } else if format() == 3 {
    gif_estimate.get()
  } else {
    let (_, _, _, rate, codec) = export_plan()
    let bytes = (rate + 128000.0) * secs / 8.0
    // (H.264 and H.265 come out ~3% over their bitrate on a busy screen: said 5% over, so the size said is not passed;
    // AV1's is a ceiling already, its QP held under it)
    if codec == 2 {
      bytes
    } else {
      bytes * 1.05
    }
  }
}

///|
/// The size said: "约 …", that it is being estimated, or a dash where it could not be.
fn size_text() -> String {
  let bytes = export_bytes()
  if bytes == -1.0 {
    t("估算中…")
  } else if bytes < 0.0 {
    "—"
  } else {
    tf("约 {0}", [bytes_text(bytes)])
  }
}

///|
/// A GIF's size, estimated by measuring a few seconds of it (rp_gif_estimate_start: a GIF's size follows what moves on
/// the screen and how, which neither its length nor the recording's bytes tell); -1 while it is made, -2 none.
let gif_estimate : @signals.Signal[Double] = @signals.signal(-1.0, same=fn(a, b) { a == b })

///|
/// What the estimate is made for: the GIF's picture, rate, crops and plan ("" no GIF asked for).
fn gif_estimate_key() -> String {
  if !clipping.get() || mode() != 2 || format() != 3 {
    return ""
  }
  let (w, h, fps, _, _) = export_plan()
  let (crops, scale) = gif_crops()
  "\{w}x\{h}@\{fps} \{scale}\n\{crops}\n" + clip_plan(clip_a.get(), clip_b.get())
}

///|
/// The crops a GIF is cut by and what the recording is scaled by first ("" and 1 for the whole picture).
fn gif_crops() -> (String, Double) {
  if cropping() {
    let (sw, sh, _) = source_format()
    let (c, cw, _) = crop_now(sw, sh)
    (c, gif_scale(cw.to_double()))
  } else {
    ("", 1.0)
  }
}

///|
/// The estimate made again as what it is made for changes, and followed (asked every 100 ms) till it is there.
fn keep_gif_estimate(root : @view.View) -> Unit {
  root.reacts(gif_estimate_key, fn(key) {
    match gif_estimate_due.val {
      Some(stop) => stop()
      None => ()
    }
    gif_estimate_due.val = None
    if key == "" {
      return
    }
    gif_estimate.set(-1.0)
    // (with the save dialog closed, made once the clip has rested 600 ms: each move of a clip's end dragged in clip mode
    // started one, and a GIF's estimate decodes and encodes up to 8 seconds of it)
    let wait = if export_open.untracked() { 0.0 } else { 600.0 }
    gif_estimate_due.val = Some(
      root.at_moment(now() + wait, fn() {
        gif_estimate_due.val = None
        if @signals.untracked(gif_estimate_key) != key {
          return
        }
        let (w, h, fps, _, _) = @signals.untracked(export_plan)
        let (crops, scale) = @signals.untracked(gif_crops)
        rp_gif_estimate_start(cstr(clip_plan(clip_a.untracked(), clip_b.untracked())), w, h, fps, cstr(crops), scale)
        follow_gif_estimate(root, key)
      }),
    )
  })
}

///|
/// The estimate asked for once the clip rests (its cancel).
let gif_estimate_due : Ref[(() -> Unit)?] = Ref(None)

///|
fn follow_gif_estimate(root : @view.View, key : String) -> Unit {
  if @signals.untracked(gif_estimate_key) != key {
    return
  }
  let v = rp_gif_estimate()
  if v == -1.0 {
    root.at_moment(now() + 100.0, fn() { follow_gif_estimate(root, key) }) |> ignore
  } else {
    gif_estimate.set(v)
  }
}

///|
/// What of `a` … `b` (ms into the buffer) a clip keeps: along a folded axis (a filter of apps, or the gaps not recorded
/// folded: axis.mbt) only the kept stretches in it, what the seams leave out left out of the clip too (the user,
/// 2026-11-19: 「得做呀」); else all of it.
fn clip_spans(a : Double, b : Double) -> Array[(Double, Double)] {
  match axis() {
    None => [(a, b)]
    Some(ax) => {
      let out : Array[(Double, Double)] = []
      for k in ax.ks {
        let s = @cmp.maximum(a, k.0)
        let e = @cmp.minimum(b, k.1)
        if e > s {
          out.push((s, e))
        }
      }
      if out.is_empty() {
        [(a, b)]
      } else {
        out
      }
    }
  }
}

///|
/// How long the clip comes to (ms), what the seams leave out not counted (bound).
fn clip_kept() -> Double {
  let mut n = 0.0
  for s in clip_spans(clip_a.get(), clip_b.get()) {
    n += s.1 - s.0
  }
  n
}

///|
/// The clip's segments for rp_concat (and the export's encoder): a line each, `path\toffsetMs\ttrimStartMs\tendMs`, the first trimmed
/// to the clip's start, the last ended at its end, the time between them kept within each of clip_spans' stretches and
/// left out between them. A line's offset is where its trim lands in the clip, the first's trim added (the first's own
/// offset 0): in one stretch, as before, where its segment starts after the first's start.
fn clip_plan(a : Double, b : Double) -> String {
  let base = t0()
  let lines : Array[String] = []
  let mut first_trim = 0.0
  // (where the stretch being laid starts in the clip, and where the clip has come to)
  let mut out = 0.0
  for sp in @signals.untracked(fn() { clip_spans(a, b) }) {
    let (sa, sb) = sp
    let mut origin : Double? = None
    let mut reach = out
    for s in segs {
      let from = s.start - base
      let to = from + s.dur
      if to <= sa || from >= sb {
        continue
      }
      let trim = @cmp.maximum(0.0, sa - from)
      let end = @cmp.minimum(s.dur, sb - from)
      if end <= trim {
        continue
      }
      let o = match origin {
        Some(o) => o
        None => {
          origin = Some(from + trim)
          from + trim
        }
      }
      let at = out + (from + trim - o)
      if lines.is_empty() {
        first_trim = trim
        lines.push("\{s.path}\t0\t\{trim}\t\{end}")
      } else {
        lines.push("\{s.path}\t\{at + first_trim}\t\{trim}\t\{end}")
      }
      reach = @cmp.maximum(reach, at + (end - trim))
    }
    out = reach
  }
  lines.join("\n")
}

///|
/// A new clip's file: "回放 <its start>.mp4" (or ".gif"), " (2)", " (3)"… after it when that is taken (a clip saved
/// before is never written over).
fn new_clip_path(ext? : String = ".mp4") -> String {
  let dir = clips_dir()
  rp_mkdirs(cstr(dir)) |> ignore
  let base = dir + "\\" + (if @signals.untracked(is_english) { "Replay " } else { "回放 " }) + stamp(t0() + clip_a.untracked())
  let mut path = base + ext
  let mut n = 2
  while rp_size(cstr(path)) > 0.0 || rp_size(cstr(path + ".partial" + ext)) > 0.0 {
    path = base + " (\{n})" + ext
    n += 1
  }
  path
}

///|
/// The clip saved as recorded; `copy`: put on the clipboard as a file as well (pasted into a chat, it is the video).
fn save_clip(copy? : Bool = false) -> Unit {
  // (one save at a time: an encode or a join under way)
  if export_out.untracked() != "" {
    return
  }
  let out = new_clip_path()
  let partial = out + ".partial.mp4"
  set_playing(false)
  let (a, b) = (clip_a.untracked(), clip_b.untracked())
  // (joined in the background, its progress the dialog's like an encode's: a few minutes of 4K is some hundreds of MB
  // written, which on the window's thread held it still and white till done)
  if rp_concat_start(cstr(clip_plan(a, b)), cstr(partial)) == 0 {
    return
  }
  export_out.set(out)
  export_copy.val = copy
  export_done.set(0.0)
  export_error.set("")
  // (no dialog to show it in: the note says it is being saved)
  if !export_open.untracked() {
    saved.set(t("正在保存…"))
    saved_path.set("")
  }
  follow_concat(out, partial, b - a)
}

///|
/// A join followed (asked every 100 ms while it runs): done, the clip renamed into place, the note and the clipboard;
/// cancelled, its part file gone; failed, why.
fn follow_concat(out : String, partial : String, len : Double) -> Unit {
  match rp_concat_state() {
    2 => {
      let mut r = rp_concat_take()
      let cancelled = r == -2147467260 // (E_ABORT: 取消)
      if r == 0 && rp_rename(cstr(partial), cstr(out)) != 1 {
        r = -2000
      }
      if r != 0 {
        rp_delete(cstr(partial))
      }
      export_out.set("")
      if r == 0 {
        let copied = export_copy.val && rp_copy_file(cstr(out)) == 1
        saved.set(tf(if copied { "已保存并复制 {0} 的片段" } else { "已保存 {0} 的片段" }, [clock(len)]))
        saved_path.set(out)
        export_open.set(false)
        clipping.set(false)
      } else if !cancelled {
        if export_open.untracked() {
          export_error.set(tf("没能保存（{0}）", [r.to_string()]))
        } else {
          saved.set(tf("没能保存（{0}）", [r.to_string()]))
          saved_path.set("")
        }
      }
      @ui.log("REPLAY save \{r} \{out}")
    }
    _ => {
      export_done.set(rp_concat_progress())
      match the_root.val {
        Some(root) => root.at_moment(now() + 100.0, fn() { follow_concat(out, partial, len) }) |> ignore
        None => ()
      }
    }
  }
}

///|
fn open_export() -> Unit {
  if !clipping.untracked() {
    start_clip()
  }
  set_playing(false)
  export_error.set("")
  export_open.set(true)
}

///|
/// The clip saved as the dialog says: as recorded at once, else its encode started (and followed: follow_export).
fn export_now(copy : Bool) -> Unit {
  if @signals.untracked(mode) == 0 {
    save_clip(copy~)
    return
  }
  let (w, h, fps, rate, codec) = @signals.untracked(export_plan)
  let out = new_clip_path(ext=if codec == 3 { ".gif" } else { ".mp4" })
  let (sw, sh, _) = @signals.untracked(source_format)
  let (crops, cw) = if @signals.untracked(cropping) {
    @signals.untracked(fn() {
      let (c, cw, _) = crop_now(sw, sh)
      (c, cw)
    })
  } else {
    ("", 0)
  }
  // (a GIF of a part: the recording scaled first, so the part cut out is the GIF's size)
  let scale = if codec == 3 && cw > 0 { gif_scale(cw.to_double()) } else { 1.0 }
  let plan = clip_plan(clip_a.untracked(), clip_b.untracked())
  let r = rp_export_start(cstr(plan), cstr(out), w, h, fps, rate.to_int(), codec, cstr(crops), scale)
  let said = crops.replace_all(old="\t", new=",").replace_all(old="\n", new=";")
  @ui.log("REPLAY export \{r} \{format_label(codec)} \{w}x\{h}@\{fps} rate=\{rate.to_int()} est=\{@signals.untracked(export_bytes).to_int()} crops=\{said} \{out}")
  if r == 0 {
    export_out.set(out)
    export_copy.val = copy
    export_error.set("")
    export_done.set(0.0)
    match the_root.val {
      Some(root) => follow_export(root)
      None => ()
    }
  } else {
    export_error.set(tf("没能开始保存（{0}）", [r.to_string()]))
  }
}

///|
/// An encode followed (the encoder tells nothing: asked every 100 ms while it runs): done, the note and the clipboard;
/// failed, why.
fn follow_export(root : @view.View) -> Unit {
  let out = export_out.untracked()
  if out == "" {
    return
  }
  match rp_export_state() {
    1 => {
      export_done.set(rp_export_progress())
      root.at_moment(now() + 100.0, fn() { follow_export(root) }) |> ignore
    }
    2 => {
      let copied = export_copy.val && rp_copy_file(cstr(out)) == 1
      let len = @signals.untracked(clip_kept)
      saved.set(
        tf(if copied { "已保存并复制 {0} 的片段 · {1}" } else { "已保存 {0} 的片段 · {1}" }, [
          clock(len),
          bytes_text(rp_size(cstr(out))),
        ]),
      )
      saved_path.set(out)
      export_out.set("")
      export_open.set(false)
      clipping.set(false)
      rp_export_reset()
    }
    -2 => {
      export_out.set("")
      rp_export_reset()
    }
    -1 => {
      export_error.set(tf("保存失败（{0}）", ["0x" + rp_export_failure().reinterpret_as_uint().to_string(radix=16)]))
      export_out.set("")
      rp_export_reset()
    }
    _ => root.at_moment(now() + 100.0, fn() { follow_export(root) }) |> ignore
  }
}

///|
/// A GIF past 20 seconds or 25 MB, once its size is estimated (bound).
fn gif_too_big() -> Bool {
  format() == 3 && export_bytes() >= 0.0 && (clip_kept() > 20000.0 || export_bytes() > 25.0 * 1048576.0)
}

///|
/// The line under the format: where it plays, what it gives up.
fn format_hint(f : Int) -> String {
  match f {
    1 => t("比 H.264 小，但部分电脑、聊天软件和网页可能播不了")
    2 => t("比 H.265 还小，但部分电脑、聊天软件和网页可能播不了")
    3 => t("没有声音的动图，最宽 960；适合几秒钟的短片段")
    _ => t("哪里都能播")
  }
}

// ---- the dialog ----

///|
/// One of a few: a track (radius 7, 2 in), the chosen one's ground sliding to it over 180 ms as the choice changes;
/// its options equal columns as wide as the widest of their words (12, 500) and 10 either side, 48 at least.
fn segmented(parent : @view.View, labels : () -> Array[String], chosen : () -> Int, choose : (Int) -> Unit) -> Unit {
  let col = fn() {
    labels().fold(init=48.0, fn(m, l) { @cmp.maximum(m, @sf.node_words_w(l, 12.0, weight=500).ceil() + 20.0) })
  }
  // (as wide as its options, whatever lays it out: a row of its own round it)
  parent.box(fn(line) { line.row(Is(true)) |> ignore ; segmented_track(line, labels, chosen, choose, col) }) |> ignore
}

///|
/// An option's words; "" for one going as the options become fewer (its cell is let go after its words are asked).
fn label_at(labels : () -> Array[String], i : Int) -> String {
  let ls = labels()
  if i < ls.length() {
    ls[i]
  } else {
    ""
  }
}

///|
fn segmented_track(parent : @view.View, labels : () -> Array[String], chosen : () -> Int, choose : (Int) -> Unit, col : () -> Double) -> Unit {
  parent.box(fn(track) {
    track.row(Is(true)).pad(Is(2.0)).radius(Is(7.0)).ground(By(fn() { tone(c_bg(), c_s2()) })) |> ignore
    let slide = @motion.NodeWay::new(@signals.untracked(chosen).to_double())
    track.reacts(chosen, fn(i) {
      // (it slides only as the choice changes; made, it is where it is)
      slide.go_ms(track, i.to_double(), if motion_off() { 1.0 } else { 180.0 })
    })
    track.box(fn(o) {
      o.over(Is(true)).padding(Is((2.0, 2.0, 2.0, 2.0))).lines_up(Is(Some(Start))) |> ignore
      o.box(fn(g) {
        g
        .height(Is(Some(24.0)))
        .radius(Is(5.0))
        .ground(By(fn() { tone(c_s4(), 0xFFFFFFFFL) }))
        .shadow(By(fn() { if is_dark() { (0.0, 0.0, 0L) } else { (2.0, 1.0, 0x1112142EL) } }))
        .width(By(fn() { Some(col()) }))
        .offset(By(fn() { (slide.shown(g) * col(), 0.0) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    track.each(fn() { Array::makei(labels().length(), fn(i) { i }) }, fn(i) { i }, fn(cell, i) {
      let i = i.untracked()
      pressable(cell, fn() { label_at(labels, i) }, fn() { choose(i) }, fn(b) {
        b
        .height(Is(Some(24.0)))
        .width(By(fn() { Some(col()) }))
        .radius(Is(5.0))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .cursor(Is(Some(Arrow)))
        .ground(By(fn() { if chosen() != i && b.pointed() { tone(c_s2(), c_s3()) } else { 0L } }))
        |> ignore
        b.box(fn(w) {
          w
          .words(By(fn() { label_at(labels, i) }), look={ ..@view.words_plain, size: 12.0, weight: 500, line: 17.0, wrap: false })
          .ink(By(fn() { if chosen() == i { ui_text() } else { ui_muted() } }))
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
/// A row of a card: its title (13) and note (12, subtle) on the left, its control on the right; a hairline over all
/// but the first.
fn setting_row(parent : @view.View, first : Bool, title : () -> String, note : () -> String, control : (@view.View) -> Unit) -> Unit {
  if !first {
    rule(parent, hair)
  }
  parent.box(fn(r) {
    r.row(Is(true)).min_height(Is(Some(52.0))).padding(Is((14.0, 8.0, 14.0, 8.0))).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
    r.box(fn(l) {
      l.grow(Is(1.0)).basis(Is(Some(0.0))).gap(Is(1.0)) |> ignore
      words(l, title, 13.0, ui_text, weight=500) |> ignore
      l.show(fn() { note() != "" }, fn(n) {
        n.box(fn(w) {
          w.words(By(note), look={ ..@view.words_plain, size: 12.0, line: 17.0, wrap: true }).ink(By(ui_subtle)) |> ignore
        })
        |> ignore
      }, at_once=true)
    })
    |> ignore
    control(r)
  })
  |> ignore
}

///|
/// The format's row: its title and its control, and under both its line (12, subtle) as wide as the card, so where a
/// format plays is said on one line beside a control of four.
fn format_row(parent : @view.View, note : () -> String, control : (@view.View) -> Unit) -> Unit {
  parent.box(fn(r) {
    r.padding(Is((14.0, 10.0, 14.0, 10.0))).gap(Is(4.0)) |> ignore
    r.box(fn(top) {
      top.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
      top.box(fn(l) {
        l.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
        words(l, fn() { t("格式") }, 13.0, ui_text, weight=500) |> ignore
      })
      |> ignore
      control(top)
    })
    |> ignore
    r.box(fn(w) { w.words(By(note), look={ ..@view.words_plain, size: 12.0, line: 17.0, wrap: true }).ink(By(ui_subtle)) |> ignore })
    |> ignore
  })
  |> ignore
}

///|
/// A dialog over the window while `open()`: the scrim (fading in 140 ms, out 120 ms) and its sheet in the middle (s1,
/// radius 12, a hairline, a shadow; in over 180 ms from 97%, out over 120 ms), `w` wide. A press on the scrim closes
/// it where `can_close()`. Modal while it shows: what is under it takes nothing. `over` puts what more the layer holds
/// over the scrim (the first run's sheet: the title bar's keys).
fn sheet(
  root : @view.View,
  open : () -> Bool,
  close : () -> Unit,
  w : Double,
  body : (@view.View) -> Unit,
  can_close? : () -> Bool = fn() { true },
  h? : Double = 0.0,
  bare? : Bool = false,
  keys? : Array[String] = ["escape"],
  over? : (@view.View) -> Unit = fn(_) {  },
) -> Unit {
  root.box(fn(layer) {
    layer.over(Is(true)).over_all(Is(true)) |> ignore
    let way = @motion.NodeWay::new(0.0)
    layer.reacts(open, fn(on) {
      way.go_ms(layer, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else if on { 140.0 } else { 120.0 })
    })
    layer.show(fn() { open() || way.shown(layer) > 0.0 }, fn(s) {
      s
      .over(Is(true))
      .modal(By(open))
      .presses(Is(true))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .ground(By(fn() { mix(clear(scrim_ground()), scrim_ground(), way.shown(s)) }))
      .on_press(fn() { if @signals.untracked(can_close) { close() } })
      |> ignore
      layer_keys(s, keys)
      s.box(fn(card) {
        card
        .width(Is(Some(w)))
        .ground(By(c_s1))
        .edge(By(fn() { (1.0, hair2()) }))
        .radius(Is(12.0))
        .padding(Is(if bare { (0.0, 0.0, 0.0, 0.0) } else { (24.0, 20.0, 24.0, 20.0) }))
        .gap(Is(if bare { 0.0 } else { 12.0 }))
        .height(Is(if h > 0.0 { Some(h) } else { None }))
        .clips(Is(bare))
        .presses(Is(true))
        .on_press(fn() {  })
        .shadow(By(fn() { (60.0, 20.0, sheet_shadow()) }))
        .alpha(By(fn() { way.shown(card) }))
        .scale(By(fn() { 0.97 + 0.03 * way.shown(card) }))
        |> ignore
        body(card)
      })
      |> ignore
      over(s)
    }, at_once=true)
  })
  |> ignore
}

///|
/// A fact of the clip in the dialog's head: its name over its value.
fn export_fact(parent : @view.View, name : () -> String, value : () -> String) -> Unit {
  parent.box(fn(f) {
    f.gap(Is(3.0)) |> ignore
    words(f, name, 12.0, ui_subtle) |> ignore
    words(f, value, 15.0, ui_text, weight=600) |> ignore
  })
  |> ignore
}

///|
/// The save dialog: its title; a card with the clip's first picture and what it will be (length, size, picture,
/// codec); the ways in a segmented control; the way's choices in a card of rows; where it goes, save and copy
/// (secondary) and save (primary); while an encode runs, its progress and cancel.
fn export_dialog(root : @view.View) -> Unit {
  let running = fn() { export_out.get() != "" }
  keep_gif_estimate(root)

  sheet(root, fn() { export_open.get() }, fn() { export_open.set(false) }, 560.0, can_close=fn() { !running() }, keys=[
    "escape", "save", "save-copy",
  ], fn(card) {
    card.box(fn(head) {
      head.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
      words(head, fn() { t("保存片段") }, 15.0, ui_text, weight=600) |> ignore
      spring(head)
      head.show(fn() { !running() }, fn(b) {
        icon_button(b, fn() { "close" }, fn() { t("关闭") }, fn() { export_open.set(false) }, size=12.0) |> ignore
      }, at_once=true)
    })
    |> ignore
    card.box(fn(info) {
      info.row(Is(true)).pad(Is(10.0)).gap(Is(16.0)).radius(Is(10.0)).ground(By(c_s2)).lines_up(Is(Some(Middle))) |> ignore
      info.box(fn(pic) {
        pic
        .width(Is(Some(160.0)))
        .height(Is(Some(90.0)))
        .radius(Is(6.0))
        .clips(Is(true))
        .ground(Is(picture_ground))
        |> ignore
        // (the picture in a box of its own, square: a crop narrower than the frame had the frame's round corners on
        // its own (the user, 2026-11-16: 「不需要有圆角」); the frame's corners round it only where it reaches them)
        pic.box(fn(img) {
          img
          .width(Is(Some(160.0)))
          .height(Is(Some(90.0)))
          .image(By(fn() {
            data()
            idx_tick.get() |> ignore
            // (cropping: the crop's own picture, none till it is made, never the whole picture meanwhile)
            if cropping() {
              return crop_thumb_key().map(fn(k) { (k, "", 400) })
            }
            let k = thumb_key(clip_a.get())
            if k == "" {
              None
            } else {
              Some((k, "", 400))
            }
          }))
          .image_contains(Is(true))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      info.box(fn(facts) {
        // (held to the card: a long window's name or codec line ends in an ellipsis, never past its edge)
        facts.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).gap(Is(10.0)) |> ignore
        facts.box(fn(r) {
          r.row(Is(true)).gap(Is(28.0)) |> ignore
          export_fact(r, fn() { t("时长") }, fn() { clock(clip_kept()) })
          export_fact(r, fn() { t("大小") }, size_text)
        })
        |> ignore
        words(
          facts,
          fn() {
            let (sw, sh, sfps) = source_format()
            // (a clip across a change of codec: both, as it holds both)
            let recorded_codec = clip_codecs().join(" + ")
            if mode() == 0 {
              "\{sw.to_int()}×\{sh.to_int()} · \{sfps} fps · \{recorded_codec} · " + t("不重新编码")
            } else {
              let (w, h, fps, _, codec) = export_plan()
              "\{w}×\{h} · \{fps} fps · " + format_label(codec) + " · " + (if codec == 3 { t("没有声音") } else { t("重新编码") })
            }
          },
          12.0,
          ui_muted,
        )
        .min_width(Is(Some(0.0)))
        .allow_ellipsis(Is(true))
        |> ignore
        // (laid out nowhere while there is none, not a `show`: its slot does not give way, and the line ran past the card)
        facts.box(fn(r) {
          r
          .row(Is(true))
          .gap(Is(7.0))
          .lines_up(Is(Some(Middle)))
          .min_width(Is(Some(0.0)))
          .laid_nowhere(By(fn() { picked_hwnd.get() == 0L }))
          |> ignore
          r.pick(fn() { picked_process.get() }, fn(i, p) { app_icon(i, p) }, at_once=true)
          words(r, fn() { tf("只导出 {0}", [picked_name.get()]) }, 12.0, ui_text)
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          .allow_ellipsis(Is(true))
          |> ignore
        })
        |> ignore
        words(facts, fn() { t("只导出自定义区域") + " · " + region_label() }, 12.0, ui_text)
        .min_width(Is(Some(0.0)))
        .allow_ellipsis(Is(true))
        .laid_nowhere(By(fn() { region_on() is None }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    segmented(
      card,
      fn() {
        if cropping() {
          [t("按大小"), t("自定义")]
        } else {
          [t("原样"), t("按大小"), t("自定义")]
        }
      },
      fn() { if cropping() { mode() - 1 } else { export_mode.get() } },
      fn(i) {
        if export_out.untracked() == "" {
          export_mode.set(if @signals.untracked(cropping) { i + 1 } else { i })
        }
      },
    )
    card.pick(fn() { mode() }, fn(b, m) {
      if m == 0 {
        b.box(fn(w) {
          w
          .words(
            By(fn() {
              let h265 = clip_codecs().contains("H.265")
              t("和录像一模一样，瞬间完成。") +
              (if h265 { t("H.265 在部分聊天软件和手机上可能播不了，要发出去可以选「按大小」。") } else { "" })
            }),
            look={ ..@view.words_plain, size: 12.0, line: 17.0, wrap: true },
          )
          .ink(By(ui_subtle))
          |> ignore
        })
        |> ignore
      } else {
        b.gap(Is(12.0)) |> ignore
        b.box(fn(rows) {
          rows.radius(Is(10.0)).ground(By(c_s2)).clips(Is(true)) |> ignore
          if m == 1 {
            size_slider(rows)
          } else {
            // the format first, as what else there is to choose follows it (a GIF has no resolution or quality to
            // choose, its frame rates its own)
            let one = @signals.untracked(cropping)
            let gif = fn() { format() == 3 }
            format_row(rows, fn() { format_hint(format()) }, fn(c) {
              segmented(c, fn() { formats().map(format_label) }, fn() { index_of(formats(), format(), 0) }, fn(i) {
                export_format.set(@signals.untracked(formats)[i])
                save_prefs()
              })
            })
            if !one {
              rows.show(fn() { !gif() }, fn(b) {
                setting_row(b, false, fn() { t("分辨率") }, fn() { "" }, fn(c) {
                  let opts = [0, 1440, 1080, 720]
                  segmented(c, fn() { [t("原始"), "1440p", "1080p", "720p"] }, fn() { index_of(opts, export_height.get(), 0) }, fn(
                    i,
                  ) {
                    export_height.set(opts[i])
                  })
                })
              }, at_once=true)
            }
            setting_row(rows, false, fn() { t("帧率") }, fn() { "" }, fn(c) {
              // (90 or 120 offered under 原始 where the recording has as many: one recorded at 120 brought down to 90)
              let opts = fn() {
                let sfps = source_format().2
                let above = if sfps >= 120 { [90] } else { [] }
                [0, ..above, 60, 30]
              }
              let gif_opts = [15, 10]
              segmented(
                c,
                fn() {
                  if gif() {
                    ["15", "10"]
                  } else {
                    opts().map(fn(f) { if f == 0 { t("原始") } else { f.to_string() } })
                  }
                },
                fn() { if gif() { index_of(gif_opts, gif_fps.get(), 0) } else { index_of(opts(), export_fps.get(), 0) } },
                fn(i) {
                  if @signals.untracked(gif) {
                    gif_fps.set(gif_opts[i])
                    save_prefs()
                  } else {
                    export_fps.set(@signals.untracked(opts)[i])
                  }
                },
              )
            })
            rows.show(fn() { !gif() }, fn(b) {
              setting_row(b, false, fn() { t("画质") }, fn() { t("这次导出压缩得多细；不会比录像本身更清楚") }, fn(c) {
                segmented(c, fn() { [t("低"), t("中"), t("高")] }, fn() { export_quality.get() }, fn(i) { export_quality.set(i) })
              })
            }, at_once=true)
          }
        })
        |> ignore
        // a GIF that is long or large: a video says it better
        b.show(fn() { m == 2 && gif_too_big() }, fn(n) {
          n.box(fn(w) {
            w
            .words(
              By(fn() {
                // (large: a video is smaller; long only: a GIF has no sound and cannot be scrubbed)
                if export_bytes() > 25.0 * 1048576.0 {
                  tf("存成 GIF 约 {0}，太大了；存成视频会小得多，也更清楚", [bytes_text(export_bytes())])
                } else {
                  tf("这段有 {0}；GIF 没有声音、不能拖动，长片段存成视频更好", [clock(clip_kept())])
                }
              }),

              look={ ..@view.words_plain, size: 12.0, line: 17.0, wrap: true },
            )
            .ink(By(warn))
            |> ignore
          })
          |> ignore
        }, at_once=true)
        b.show(fn() { m == 1 && export_bytes() > size_choices[export_size.get()] * 1048576.0 }, fn(n) {
          n.box(fn(w) {
            w
            .words(
              By(fn() {
                tf("这段太长，压不到 {0} MB 以内，会是约 {1}；可以剪短一些，或选大一档", [
                  size_choices[export_size.get()].to_int().to_string(),
                  bytes_text(export_bytes()),
                ])
              }),
              look={ ..@view.words_plain, size: 12.0, line: 17.0, wrap: true },
            )
            .ink(By(warn))
            |> ignore
          })
          |> ignore
        }, at_once=true)
      }
    }, at_once=true)
    card.pick(running, fn(b, on) {
      if on {
        b.gap(Is(8.0)).padding(Is((0.0, 4.0, 0.0, 0.0))) |> ignore
        b.box(fn(bar) {
          bar.height(Is(Some(6.0))).radius(Is(3.0)).ground(By(c_bg)).clips(Is(true)).lines_up(Is(Some(Start))) |> ignore
          // (its fill follows each step told every 100 ms over 150 ms, so it grows smoothly, not by jumps)
          let fill = @motion.NodeWay::new(export_done.untracked())
          bar.reacts(fn() { export_done.get() }, fn(v) { fill.go_ms(bar, v, if motion_off() { 1.0 } else { 150.0 }) })
          bar.box(fn(f) { f.height(Is(Some(6.0))).ground(By(ui_text)).width_share(By(fn() { fill.shown(f) })) |> ignore }) |> ignore
        })
        |> ignore
        b.box(fn(r) {
          r.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
          words(r, fn() { tf("正在保存 {0}%", [(export_done.get() * 100.0).floor().to_int().to_string()]) }, 12.0, ui_muted) |> ignore
          spring(r)
          text_button(r, fn() { t("取消") }, fn() {
              rp_export_cancel()
              rp_concat_cancel()
            }, ghost=true)
          |> ignore
        })
        |> ignore
      } else {
        b.row(Is(true)).gap(Is(8.0)).padding(Is((0.0, 4.0, 0.0, 0.0))).lines_up(Is(Some(Middle))) |> ignore
        b.box(fn(w) {
          w.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).cuts(Is(true)) |> ignore
          words(w, fn() {
              if export_error.get() != "" {
                export_error.get()
              } else {
                tf("存到 {0}", [clips_dir()])
              }
            }, 12.0, fn() {
              if export_error.get() != "" {
                warn()
              } else {
                ui_subtle()
              }
            })
          |> ignore
        })
        |> ignore
        b.box(fn(k) {
          k.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
          text_button(k, fn() { t("保存并复制") }, fn() { export_now(true) }, icon="copy") |> ignore
          solid_button(k, fn() { t("保存") }, fn() { export_now(false) }, icon="download") |> ignore
        })
        |> ignore
      }
    }, at_once=true)
  })
}

///|
/// The note that a clip was saved, over the picture's top right corner under the title bar (coming down 8 and fading
/// in over 180 ms, out over 140 ms), clear of what is at the picture's foot (a taskbar recorded, the clip bar): the card
/// the tray's saves show (note_card.mbt note_body, the user, 2026-11-18: 「这个卡片应该在回放窗口使用也是通用的」), or
/// one line while it is being saved or where it failed.
fn saved_note(parent : @view.View) -> Unit {
  parent.box(fn(o) {
    o.over(Is(true)).lines_up(Is(Some(End))).lies_along(Is(Start)).padding(Is((16.0, 16.0, 16.0, 16.0))).takes(fn(_, _, _) { [] }) |> ignore
    let way = @motion.NodeWay::new(0.0)
    // (what it says kept while it fades out)
    let kept : Ref[(String, String)] = Ref(("", ""))
    let now_said = fn() {
      if saved.get() != "" {
        kept.val = (saved.get(), saved_path.get())
      }
      kept.val
    }
    o.reacts(fn() { saved.get() != "" }, fn(on) {
      way.go_ms(o, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else if on { 180.0 } else { 140.0 })
    })
    o.box(fn(n) {
      n
      .width(Is(Some(note_w)))
      .radius(Is(8.0))
      .ground(By(c_s2))
      .edge(By(fn() { (1.0, hair2()) }))
      .shadow(By(fn() { (18.0, 4.0, sheet_shadow()) }))
      .presses(By(fn() { saved.get() != "" }))
      .alpha(By(fn() { way.shown(n) }))
      .laid_nowhere(By(fn() { way.shown(n) <= 0.0 && saved.get() == "" }))
      .offset(By(fn() { (0.0, -8.0 * (1.0 - way.shown(n))) }))
      |> ignore
      n.pick(fn() { now_said().1 }, fn(b, path) {
        b.height(Is(Some(if path == "" { note_line_h } else { note_clip_h }))) |> ignore
        note_body(b, fn() { now_said().0 }, path, fn() { open_clip_player(path) }, fn() { rp_reveal(cstr(path)) }, fn() {
          saved.set("")
        }, warning=path == "" && now_said().0.has_prefix(t("没能")), mark=if path == "" { "info" } else { "check-circle" })
      }, at_once=true)
    })
    |> ignore
  })
  |> ignore
}

///|
/// A size as its stop says it: "25 MB", "1 GB".
fn size_label(mb : Double) -> String {
  if mb >= 1024.0 {
    "\{(mb / 1024.0).round().to_int()} GB"
  } else {
    "\{mb.to_int()} MB"
  }
}

///|
/// The size a clip is made to fit: its title and line over a slider of Steam's stops (10 MB … 1 GB), each stop's size
/// under it where it is along the track; the stop moved to by a press or a drag along it, the arrow keys, a screen
/// reader's step.
fn size_slider(parent : @view.View) -> Unit {
  let n = size_choices.length()
  // (the knob 16 wide: the track's ends 8 in, so the first and last stops sit under its middle)
  let knob = 16.0
  parent.box(fn(r) {
    r.padding(Is((14.0, 12.0, 14.0, 12.0))).gap(Is(10.0)) |> ignore
    r.box(fn(l) {
      l.gap(Is(1.0)) |> ignore
      words(l, fn() { t("最大文件大小") }, 13.0, ui_text, weight=500) |> ignore
      l.box(fn(w) {
        w.words(By(fn() { t("为发到聊天压缩成 H.264，按大小自动选清晰度") }), look={ ..@view.words_plain, size: 12.0, line: 17.0, wrap: true })
        .ink(By(ui_subtle))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    r.by_room(fn(held, room) {
      let w = fn() { room.width() }
      let along = fn() { @cmp.maximum(1.0, w() - knob) }
      let x_of = fn(i : Int) { knob / 2.0 + along() * i.to_double() / (n - 1).to_double() }
      @headless.slider(
        held,
        fn() { t("最大文件大小") },
        fn() { export_size.get().to_double() },
        min=0.0,
        max=(n - 1).to_double(),
        step=1.0,
        thumb_room=knob,
        value_text=fn(v) { size_label(size_choices[clamp(v, 0.0, (n - 1).to_double()).to_int()]) },
        fn(v) { export_size.set(clamp(v.round(), 0.0, (n - 1).to_double()).to_int()) },
        fn(s, state) {
          s.height(Is(Some(20.0))).cursor(Is(Some(Arrow))) |> ignore
          // the track, its part up to the knob filled
          s.box(fn(o) {
            o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
            o.box(fn(tr) {
              tr
              .width(By(fn() { Some(along()) }))
              .height(Is(Some(4.0)))
              .radius(Is(2.0))
              .ground(By(c_s4))
              .offset(Is((knob / 2.0, 8.0)))
              |> ignore
            })
            |> ignore
          })
          |> ignore
          s.box(fn(o) {
            o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
            o.box(fn(f) {
              f
              .width(By(fn() { Some(along() * state.part()) }))
              .height(Is(Some(4.0)))
              .radius(Is(2.0))
              .ground(By(ui_text))
              .offset(Is((knob / 2.0, 8.0)))
              |> ignore
            })
            |> ignore
          })
          |> ignore
          s.box(fn(o) {
            o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
            o.box(fn(k) {
              k
              .width(Is(Some(knob)))
              .height(Is(Some(knob)))
              .radius(Is(knob / 2.0))
              .ground(By(ui_text))
              .edge(By(fn() { if state.focus_shown() { (2.0, ui_subtle()) } else { (0.0, 0) } }))
              .offset(By(fn() { (along() * state.part(), 2.0) }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        },
      )
      |> ignore
      // each stop's tick and size under the track, where the stop is
      held.box(fn(marks) {
        marks.height(Is(Some(30.0))) |> ignore
        for i in 0..<n {
          let i = i
          marks.box(fn(o) {
            o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
            o.box(fn(tick) {
              tick.width(Is(Some(1.0))).height(Is(Some(4.0))).ground(By(c_s4)).offset(By(fn() { (x_of(i) - 0.5, 0.0) })) |> ignore
            })
            |> ignore
            o.box(fn(lab) {
              lab
              .width(Is(Some(60.0)))
              .lies_along(Is(Middle))
              .row(Is(true))
              .offset(By(fn() { (x_of(i) - 30.0, 10.0) }))
              |> ignore
              words(lab, fn() { size_label(size_choices[i]) }, 11.0, fn() { if export_size.get() == i { ui_text() } else { ui_subtle() } }, weight=500)
              |> ignore
            })
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Moment `t` (ms into the buffer) on the clip's own times, what clip_spans leaves out not counted: in what is left
/// out, where the next stretch starts in the clip (bound).
fn clip_time(t : Double) -> Double {
  let mut n = 0.0
  for s in clip_spans(clip_a.get(), clip_b.get()) {
    if t <= s.0 {
      return n
    }
    if t < s.1 {
      return n + (t - s.0)
    }
    n += s.1 - s.0
  }
  n
}
