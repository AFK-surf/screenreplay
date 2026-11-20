// A saved GIF in the window's player (the user, 2026-11-14: no other app opened for it): its frames composed by WIC
// (replay_gif.cpp) and played by the same Deck as a video, a track of its own made of them (each frame a sample, its
// time its delays added up, every one a key frame), each frame handed to the deck's stream as a picture of its own
// (`Stream::jpeg`, which the Windows host decodes by WIC whatever the picture's format: a BMP here). No sound. Played to
// its end it goes on from its start, as a GIF does; its controls, keys and hover preview the player's.

///|
#borrow(path)
extern "C" fn rp_gif_info(path : Bytes) -> Bytes = "rp_gif_info"

///|
#borrow(path)
extern "C" fn rp_gif_frame(path : Bytes, k : Int, max_w : Int) -> Bytes = "rp_gif_frame"

///|
#borrow(path)
extern "C" fn rp_gif_drop(path : Bytes) -> Unit = "rp_gif_drop"

///|
fn is_gif_path(path : String) -> Bool {
  path.has_suffix(".gif")
}

///|
/// The GIF at `path` as a deck reads a file: one picture track, codec "gif", in ms, a sample a frame (`at` its number);
/// none where it cannot be read.
fn gif_tracks(path : String) -> Array[Mp4Track] {
  let info = @utf8.decode_lossy(rp_gif_info(cstr(path)))
  let parts = info.split(" ").map(fn(s) { s.to_owned() }).collect()
  guard parts.length() >= 3 else { return [] }
  let num = fn(s : String) { digits(s, 0, s.length()).unwrap_or(0) }
  let w = num(parts[0])
  let h = num(parts[1])
  let samples = []
  let mut t = 0L
  for i in 2..<parts.length() {
    let k = i - 2
    samples.push({ pts: t, dts: t, at: k.to_double(), size: 0, key: true })
    t = t + num(parts[i]).to_int64()
  }
  // (its end: a last sample's time plus its delay is where it stops; held as the track's length by gif_length)
  gif_lengths[path] = t.to_double()
  [
    {
      kind: "vide",
      codec: "gif",
      timescale: 1000,
      width: w,
      height: h,
      shown_w: w,
      shown_h: h,
      config: b"gif",
      channels: 0,
      rate: 0,
      samples,
    },
  ]
}

///|
/// Each GIF read's length (ms): its frames' delays added up.
let gif_lengths : Map[String, Double] = Map([])

///|
/// The image key of the hover preview's picture for moment `at` (ms) of the GIF at `path`: the frame shown at the
/// whole second before it, small (a second's frame made once each, at most as many as its seconds).
fn gif_frame_key(path : String, at : Double) -> String {
  guard track_of(path, "vide") is Some(t) else { return "" }
  let k = @cmp.maximum(0, sample_at(t, (at / 1000.0).floor() * 1000.0 + 0.5))
  let key = "gx:\{path}|\{clip_modified.val}:\{k}"
  if !@ui.has_image(key) {
    let bmp = rp_gif_frame(cstr(path), k, 320)
    if bmp.length() == 0 {
      return ""
    }
    @ui.add_image(key, bmp)
  }
  key
}
