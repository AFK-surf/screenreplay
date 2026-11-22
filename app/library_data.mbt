///|
#borrow(path)
extern "C" fn rp_launch(path : Bytes) -> Int = "rp_launch"

///|
#borrow(path)
extern "C" fn rp_recycle(path : Bytes) -> Int = "rp_recycle"

///|
/// The saved clips' names in a folder: its videos and GIFs, a line each.
#borrow(dir)
extern "C" fn rp_list_clips(dir : Bytes) -> Bytes = "rp_list_clips"

///|
#borrow(path)
extern "C" fn rp_take_request(path : Bytes) -> Int = "rp_take_request"

///|
let library_open : @signals.Signal[Bool] = @signals.signal(false)

///|
let clip_files : Array[String] = []

///|
let library_page : @signals.Signal[Int] = @signals.signal(0)

///|
let delete_pending : @signals.Signal[String] = @signals.signal("")

///|
let library_message : @signals.Signal[String] = @signals.signal("")

///|
let clips_per_page : Int = 8

///|
#borrow(path, identity)
extern "C" fn rp_clip_thumb(path : Bytes, identity : Bytes, ms : Double) -> Bytes = "rp_clip_thumb"

///|
#borrow(path)
extern "C" fn rp_modified(path : Bytes) -> Double = "rp_modified"


///|
fn clips_dir() -> String {
  env_or("REPLAY_OUT", {
    if is_mac() {
      pjoin(@ui.env("HOME"), "Movies/ScreenReplay")
    } else {
      // (named in the window's language the first time; a folder already there keeps its name)
      let videos = @ui.env("USERPROFILE") + "\\Videos\\"
      if is_english() && rp_size(cstr(videos + "回放")) < 0.0 { videos + "Replay" } else { videos + "回放" }
    }
  })
}

///|
fn load_clips() -> Unit {
  clip_files.clear()
  let names = @utf8.decode_lossy(rp_list_clips(cstr(clips_dir())))
  for name in names.split("\n") {
    // (an encode's file left as it was stopped (the window ended while it ran): not a clip, taken away where none runs)
    if name.has_suffix(".partial.mp4") || name.has_suffix(".partial.gif") {
      if export_out.untracked() == "" {
        rp_delete(cstr(pjoin(clips_dir(), name.to_owned())))
      }
      continue
    }
    if name != "" { clip_files.push(name.to_owned()) }
  }
  clip_files.sort_by(fn(a, b) { b.compare(a) })
  // (what was kept of clips gone from the folder let go of: kept_images.mbt)
  clips_gone_forget(clips_dir(), clip_files)
  library_page.set(@cmp.minimum(library_page.untracked(), @cmp.maximum(0, (clip_files.length() - 1) / clips_per_page)))
}

///|
#borrow(path)
extern "C" fn rp_duration(path : Bytes) -> Double = "rp_duration"

///|
/// How long each saved clip plays (ms), read once per file.
let clip_durations : Map[String, Double] = Map([])

///|
fn clip_duration(path : String) -> Double {
  match clip_durations.get(path) {
    Some(ms) => ms
    None => {
      let ms = rp_duration(cstr(path))
      clip_durations[path] = ms
      ms
    }
  }
}

///|
/// A clip's name as a person reads it: "回放 2026-11-13 10-42-32.mp4" is "11月13日 10:42:32"; else its name without
/// ".mp4" (a GIF's keeps its ".gif", to be told from the video of the same moment).
fn clip_title(name : String) -> String {
  let stem = name.replace(old=".mp4", new="")
  if stem.has_suffix(".gif") {
    return clip_title(stem.replace(old=".gif", new="")) + " · GIF"
  }
  // ("Replay …" in English)
  let stem = if stem.has_prefix("Replay ") { "回放 " + stem[7:].to_owned() } else { stem }
  if !stem.has_prefix("回放 ") {
    return stem
  }
  match (digits(stem, 8, 2), digits(stem, 11, 2), digits(stem, 14, 2), digits(stem, 17, 2), digits(stem, 20, 2)) {
    (Some(m), Some(d), Some(h), Some(mi), Some(s)) => month_day(m, d) + " \{two(h)}:\{two(mi)}:\{two(s)}"
    _ => stem
  }
}

///|
/// The saved clip being played in the window (its path; "" none), and its player.
let clip_playing : @signals.Signal[String] = @signals.signal("")

///|
/// The saved clip's player (native_player.mbt's Deck: the clip alone, on a clock of its own), while one plays.
let clip_deck : Ref[Deck?] = Ref(None)

///|
/// Whether it is asked to play; whether it has played to its end (its key then plays it again from its start).
let clip_view_playing : @signals.Signal[Bool] = @signals.signal(false)

///|
let clip_done : @signals.Signal[Bool] = @signals.signal(false)

///|
let clip_play : @signals.Signal[Play] = @signals.signal({ pos: 0.0, at: 0.0, rate: 1.0, going: false }, same=fn(a, b) {
  a == b
})

///|
let clip_aspect : @signals.Signal[Double] = @signals.signal(16.0 / 9.0, same=fn(a, b) { a == b })

///|
/// How long the clip at `path` plays (ms): its picture's last frame's end.
fn clip_length(path : String) -> Double {
  if is_gif_path(path) && track_of(path, "vide") is Some(_) {
    return @cmp.maximum(1.0, gif_lengths.get(path).unwrap_or(1.0))
  }
  match track_of(path, "vide") {
    Some(t) => {
      let n = t.samples.length()
      let last = sample_ms(t, n - 1)
      let step = if n > 1 { (last - sample_ms(t, 0)) / (n - 1).to_double() } else { 0.0 }
      @cmp.maximum(1.0, last + step)
    }
    None => 1.0
  }
}

///|
fn open_clip_player(path : String) -> Unit {
  // (an AV1 clip where the system has no AV1 decoder: a note saying what to install; never another app opened with a
  // clip)
  if av1_unplayable(path) {
    av1_note.set(path)
    return
  }
  if !plays_here(path) {
    return
  }
  let gif = is_gif_path(path)
  close_clip_player()
  set_playing(false)
  let length = clip_length(path)
  let d = Deck::new(
    count=fn() { 1 },
    file=fn(_) { path },
    start=fn(_) { 0.0 },
    dur=fn(_) { length },
    span=fn() { length },
    play=clip_play,
    speed=fn() { clip_speed.untracked() },
    wants=fn() { clip_view_playing.untracked() },
    held=fn() { clip_held.untracked() },
    // (a GIF goes on from its start, as one does)
    ended=if gif { fn() { clip_seek(0.0) } } else { clip_ended },
    shape=clip_aspect,
  )
  clip_deck.val = Some(d)
  // (its key frames' pictures made in the background for the hover preview over its bar; a GIF's as they are asked,
  // gif_frame_key; its times the file's own, from the keyframe its edit list passes over: clip_lead)
  if !gif {
    rp_idx_add_clip(cstr(path), length + clip_lead(path))
  }
  clip_modified.val = rp_modified(cstr(path))
  clip_play.set({ pos: 0.0, at: now(), rate: clip_speed.untracked(), going: false })
  clip_done.set(false)
  clip_view_playing.set(true)
  clip_playing.set(path)
  d.go(0.0, false)
}

///|
/// How fast the saved clip plays (its speed menu: as the replay's), and whether the hand holds its playhead (its bar
/// dragged: the picture follows by the scrub's way, its sound and clock stopped).
let clip_speed : @signals.Signal[Double] = @signals.signal(1.0, same=fn(a, b) { a == b })

///|
let clip_held : @signals.Signal[Bool] = @signals.signal(false)

///|
fn set_clip_speed(r : Double) -> Unit {
  clip_speed.set(r)
  match clip_deck.val {
    Some(d) => d.set_rate(r)
    None => ()
  }
}

///|
/// The saved clip put at `at` (ms), exactly, playing on where it played; off its end, its key plays again.
fn clip_seek(at : Double) -> Unit {
  guard clip_deck.val is Some(d) else { return }
  clip_done.set(false)
  d.go(clamp(at, 0.0, (d.span)()), false)
}

///|
/// Stopped where it is (a frame stepped to is looked at, not played past).
fn clip_pause() -> Unit {
  if clip_view_playing.untracked() {
    clip_toggle()
  }
}

///|
/// The frame before (-1) or after (1) the one shown, stopped there.
fn clip_step(dir : Int) -> Unit {
  guard clip_deck.val is Some(d) else { return }
  guard track_of(clip_playing.untracked(), "vide") is Some(t) else { return }
  clip_pause()
  let k = clamp_int(sample_at(t, d.pos() + 0.5) + dir, 0, t.samples.length() - 1)
  clip_seek(sample_ms(t, k))
}

///|
fn clamp_int(v : Int, lo : Int, hi : Int) -> Int {
  @cmp.maximum(lo, @cmp.minimum(hi, v))
}

///|
/// The saved clip before (-1) or after (1) the one playing on the clips page, the window's player plays (one it cannot
/// is passed over); None at either end.
fn clip_beside(dir : Int) -> String? {
  let path = clip_playing.untracked()
  let mut i = -1
  for k, name in clip_files {
    if pjoin(clips_dir(), name) == path {
      i = k
    }
  }
  if i < 0 {
    return None
  }
  let mut k = i + dir
  while k >= 0 && k < clip_files.length() {
    let p = pjoin(clips_dir(), clip_files[k])
    if plays_here(p) {
      return Some(p)
    }
    k += dir
  }
  None
}

///|
/// The clip beside it played in its place, from its start, as it was asked to play or not.
fn clip_go_beside(dir : Int) -> Unit {
  match clip_beside(dir) {
    Some(p) => open_clip_player(p)
    None => ()
  }
}

///|
/// Whether the window's player plays the clip: an MP4 in H.264 or H.265, or in AV1 where the system decodes it (mbui's
/// stream by the system's AV1 decoder: the AV1 Video Extension, or the GPU's); a GIF whose frames are read (gif.mbt).
fn plays_here(path : String) -> Bool {
  if is_gif_path(path) {
    return track_of(path, "vide") is Some(_)
  }
  !is_av1_clip(path) || @ui.av1_here()
}

///|
/// Whether the saved clip's picture is AV1 (its sample entry `av01`).
fn is_av1_clip(path : String) -> Bool {
  if path.has_suffix(".gif") {
    return false
  }
  // (its sample entry alone, read once a clip: each card asked it twice as it was made, and each time its whole sample
  // tables were read where the 64 files' tracks kept had let it go)
  match saved_clip_codecs.get(path) {
    Some(c) => c == "av01"
    None => {
      let c = mp4_video_codec(path)
      // (one still being written has none yet: read again next time)
      if c != "" {
        saved_clip_codecs[path] = c
      }
      c == "av01"
    }
  }
}

///|
/// Each saved clip's picture codec (its sample entry), read once.
let saved_clip_codecs : Map[String, String] = Map([])

///|
/// An AV1 clip where the system decodes no AV1 (MBUI_NO_AV1=1 makes mbui's stream say so, to see it).
fn av1_unplayable(path : String) -> Bool {
  is_av1_clip(path) && !@ui.av1_here()
}

///|
/// The AV1 clip whose note is open (pressed where the system decodes no AV1: av1_note_layer); "" none.
let av1_note : @signals.Signal[String] = @signals.signal("")

///|
/// The Microsoft Store's page of the free AV1 Video Extension (Microsoft's), opened by the note's button.
let av1_store_page : String = "ms-windows-store://pdp/?ProductId=9MVZQVXJBQ9V"

///|
/// Played to its end: stopped there, its key to play it again.
fn clip_ended() -> Unit {
  tell_playing(clip_view_playing.untracked(), false, told=clip_told)
  clip_view_playing.set(false)
  clip_done.set(true)
  match clip_deck.val {
    Some(d) => d.set_playing(false)
    None => ()
  }
}

///|
/// Played or stopped (Space, its key); played to its end (or put there: End), again from its start.
fn clip_toggle() -> Unit {
  guard clip_deck.val is Some(d) else { return }
  let on = !clip_view_playing.untracked()
  tell_playing(!on, on, told=clip_told)
  clip_view_playing.set(on)
  if on && (clip_done.untracked() || d.pos() >= (d.span)() - 100.0) {
    clip_done.set(false)
    d.go(0.0, false)
  } else {
    d.set_playing(on)
  }
}

///|
fn close_clip_player() -> Unit {
  match clip_deck.val {
    Some(d) => d.close()
    None => ()
  }
  clip_deck.val = None
  clip_view_playing.set(false)
  clip_held.set(false)
  let was = clip_playing.untracked()
  if was != "" {
    rp_idx_drop(cstr(was))
    rp_gif_drop(cstr(was))
  }
  clip_playing.set("")
}

///|
/// When the saved clip playing was last written (rp_modified), read as it opens.
let clip_modified : Ref[Double] = Ref(0.0)

///|
/// The image key of the picture the hover preview shows for moment `at` (ms) of the saved clip at `path`: the key frame
/// at or before it, as the index made it; "" while it is not made yet.
fn clip_frame_key(path : String, at : Double) -> String {
  if is_gif_path(path) {
    return gif_frame_key(path, at)
  }
  let p = cstr(path)
  // (the index's times are the file's: a clip saved as recorded starts its lead after them)
  let at = at + clip_lead(path)
  let ms = rp_idx_at(p, at)
  if ms < 0.0 {
    return ""
  }
  // (its time on disk in the key: a clip saved again under the same name is not shown the old one's pictures)
  let key = "cx:\{path}|\{clip_modified.val}:\{ms}"
  if !@ui.has_image(key) {
    let jpeg = rp_idx_jpeg(p, at)
    if jpeg.length() == 0 {
      return ""
    }
    @ui.add_image(key, jpeg)
    hover_images.keep(key)
  }
  key
}

///|
/// A saved clip played over the window: the video on a dark scrim, under it play and pause, its place along it, its
/// name, copy, show in the folder and close (Esc, or a press beside it).
