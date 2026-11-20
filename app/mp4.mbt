// A segment's tracks read out of its MP4 (the player's own decoding, native_player.mbt: the reviewer's 53rd and
// 57th, step 1): for each track its codec, timescale, the picture's size and decoder record (hvcC / avcC / av1C), and every
// sample's times, place in the file, size and whether it is a key frame. Only what a finished segment holds: one
// `moov` with its sample tables (the recorder's MF sink writer and ffmpeg both write it so); a segment still being
// written has none yet and reads as no tracks. Times are as ffmpeg's mov demuxer gives them (its edit list applied:
// the AAC encoder's priming starts before 0), so `REPLAY_DEMUX` can be held line for line to `ffprobe -show_packets`.

///|
struct Mp4Sample {
  pts : Int64
  dts : Int64
  at : Double
  size : Int
  key : Bool
}

///|
struct Mp4Track {
  kind : String // "vide", "soun", …
  codec : String // the sample entry's: "hvc1", "hev1", "avc1", "avc3", "av01", "mp4a", …
  timescale : Int
  width : Int // the sample entry's: coded, in whole blocks (the recorder's 4K: 3840x2176)
  height : Int
  shown_w : Int // as shown: the SPS's cropping applied (3840x2160); the entry's where the SPS is not read
  shown_h : Int
  config : Bytes // hvcC / avcC / av1C's record; mp4a's AudioSpecificConfig (its esds'); empty for others
  channels : Int // a sound's (its sample entry's), 0 for a picture
  rate : Int // a sound's samples a second (its timescale where the entry says none)
  samples : Array[Mp4Sample]
}

///|
fn be16(b : Bytes, i : Int) -> Int {
  (b[i].to_int() << 8) | b[i + 1].to_int()
}

///|
fn be32(b : Bytes, i : Int) -> Int64 {
  (b[i].to_int64() << 24) |
  (b[i + 1].to_int64() << 16) |
  (b[i + 2].to_int64() << 8) |
  b[i + 3].to_int64()
}

///|
/// A signed 32-bit field (ctts v1, elst's media time).
fn be32s(b : Bytes, i : Int) -> Int64 {
  let v = be32(b, i)
  if v >= 0x80000000L {
    v - 0x100000000L
  } else {
    v
  }
}

///|
fn be64(b : Bytes, i : Int) -> Int64 {
  (be32(b, i) << 32) | be32(b, i + 4)
}

///|
fn four(b : Bytes, i : Int) -> String {
  let s = StringBuilder()
  for k in 0..<4 {
    s.write_char(Int::unsafe_to_char(b[i + k].to_int()))
  }
  s.to_string()
}

///|
/// The boxes from `start` to `end`: each its kind and its content's start and end.
fn mp4_boxes(b : Bytes, start : Int, end : Int) -> Array[(String, Int, Int)] {
  let out = []
  let mut i = start
  while i + 8 <= end {
    let size = be32(b, i)
    let kind = four(b, i + 4)
    let (head, whole) = if size == 1L && i + 16 <= end {
      (16, be64(b, i + 8))
    } else if size == 0L {
      (8, (end - i).to_int64())
    } else {
      (8, size)
    }
    if whole < head.to_int64() || i.to_int64() + whole > end.to_int64() {
      break
    }
    out.push((kind, i + head, i + whole.to_int()))
    i = i + whole.to_int()
  }
  out
}

///|
/// The first box of a path down from `start`..`end`.
fn mp4_find(b : Bytes, start : Int, end : Int, path : Array[String]) -> (Int, Int)? {
  for box in mp4_boxes(b, start, end) {
    let (kind, s, e) = box
    if kind == path[0] {
      if path.length() == 1 {
        return Some((s, e))
      }
      match mp4_find(b, s, e, path[1:].to_owned()) {
        Some(r) => return Some(r)
        None => ()
      }
    }
  }
  None
}

///|
/// The `moov` of the file at `path`, found among its top boxes by their heads alone (the media data is not read).
fn mp4_moov(path : String) -> Bytes? {
  let p = cstr(path)
  let total = rp_size(p)
  let mut at = 0.0
  while at + 8.0 <= total {
    let h = rp_play_read(p, at, 16)
    if h.length() < 8 {
      return None
    }
    let size = be32(h, 0)
    let kind = four(h, 4)
    let (head, whole) = if size == 1L && h.length() >= 16 {
      (16.0, be64(h, 8).to_double())
    } else if size == 0L {
      (8.0, total - at)
    } else {
      (8.0, size.to_double())
    }
    if whole < head || at + whole > total {
      return None
    }
    if kind == "moov" {
      let b = rp_play_read(p, at + head, (whole - head).to_int())
      return if b.length().to_double() == whole - head { Some(b) } else { None }
    }
    at = at + whole
  }
  None
}

///|
/// The tracks of the segment at `path`; none where it has no `moov` (being written) or it is not read whole.
fn mp4_tracks(path : String) -> Array[Mp4Track] {
  let b = match mp4_moov(path) {
    Some(b) => b
    None => return []
  }
  let n = b.length()
  let movie_scale = match mp4_find(b, 0, n, ["mvhd"]) {
    Some((s, _)) => (if b[s] == 1 { be32(b, s + 20) } else { be32(b, s + 12) }).to_int()
    None => 1000
  }
  let out = []
  for box in mp4_boxes(b, 0, n) {
    let (kind, s, e) = box
    if kind == "trak" {
      match mp4_trak(b, s, e, movie_scale) {
        Some(t) => out.push(t)
        None => ()
      }
    }
  }
  out
}

///|
/// The picture's codec of the file at `path` as its sample entry names it ("avc1", "hvc1", "av01", …), its sample
/// tables not read; "" where it has no `moov` yet (being written) or no picture.
fn mp4_video_codec(path : String) -> String {
  guard mp4_moov(path) is Some(b) else { return "" }
  for box in mp4_boxes(b, 0, b.length()) {
    let (kind, s, e) = box
    if kind == "trak" &&
      mp4_find(b, s, e, ["mdia", "hdlr"]) is Some((hs, _)) &&
      four(b, hs + 8) == "vide" &&
      mp4_find(b, s, e, ["mdia", "minf", "stbl", "stsd"]) is Some((ds, de)) &&
      ds + 16 <= de {
      return four(b, ds + 12)
    }
  }
  ""
}

///|
/// A codec's name as the dialog says it: "avc1" H.264, "hvc1" H.265, …; "" for one it does not know.
fn codec_name(entry : String) -> String {
  if entry.has_prefix("avc") {
    "H.264"
  } else if entry.has_prefix("hv") || entry.has_prefix("he") {
    "H.265"
  } else if entry == "av01" {
    "AV1"
  } else {
    ""
  }
}

///|
fn mp4_trak(b : Bytes, s : Int, e : Int, movie_scale : Int) -> Mp4Track? {
  guard mp4_find(b, s, e, ["mdia", "mdhd"]) is Some((ms, _)) else { return None }
  let timescale = (if b[ms] == 1 { be32(b, ms + 20) } else { be32(b, ms + 12) }).to_int()
  guard timescale > 0 else { return None }
  let kind = match mp4_find(b, s, e, ["mdia", "hdlr"]) {
    Some((hs, _)) => four(b, hs + 8)
    None => ""
  }
  guard mp4_find(b, s, e, ["mdia", "minf", "stbl"]) is Some((ts, te)) else { return None }
  // the sample entry: its codec, and for a picture its size and decoder record
  guard mp4_find(b, ts, te, ["stsd"]) is Some((ds, de)) else { return None }
  let entry = ds + 8
  guard entry + 8 <= de else { return None }
  let entry_end = entry + be32(b, entry).to_int()
  let codec = four(b, entry + 4)
  let mut width = 0
  let mut height = 0
  let mut config = b""
  let mut channels = 0
  let mut rate = 0
  if kind == "soun" && codec == "mp4a" && entry + 36 <= entry_end {
    channels = be16(b, entry + 24)
    rate = be16(b, entry + 32)
    if rate == 0 {
      rate = timescale
    }
    match mp4_find(b, entry + 36, entry_end, ["esds"]) {
      Some((cs, ce)) => config = esds_config(b, cs + 4, ce)
      None => ()
    }
  }
  if kind == "vide" && entry + 8 + 78 <= entry_end {
    width = be16(b, entry + 8 + 24)
    height = be16(b, entry + 8 + 26)
    // (an AV1's av1C: its AV1CodecConfigurationRecord whole, which mbui's stream takes as it is; its size shown is the
    // entry's, there being no SPS to crop it)
    let rec = if codec.has_prefix("hv") || codec.has_prefix("he") {
      "hvcC"
    } else if codec == "av01" {
      "av1C"
    } else {
      "avcC"
    }
    match mp4_find(b, entry + 8 + 78, entry_end, [rec]) {
      Some((cs, ce)) => config = b[cs:ce].to_owned()
      None => ()
    }
  }
  // sizes
  guard mp4_find(b, ts, te, ["stsz"]) is Some((zs, _)) else { return None }
  let fixed = be32(b, zs + 4).to_int()
  let count = be32(b, zs + 8).to_int()
  let size_of = fn(i : Int) { if fixed != 0 { fixed } else { be32(b, zs + 12 + i * 4).to_int() } }
  // decode times
  let dts = Array::make(count, 0L)
  match mp4_find(b, ts, te, ["stts"]) {
    Some((ss, _)) => {
      let entries = be32(b, ss + 4).to_int()
      let mut i = 0
      let mut t = 0L
      for k in 0..<entries {
        let c = be32(b, ss + 8 + k * 8).to_int()
        let d = be32(b, ss + 12 + k * 8)
        for _ in 0..<c {
          if i < count {
            dts[i] = t
            i = i + 1
          }
          t = t + d
        }
      }
    }
    None => return None
  }
  // composition offsets
  let pts = dts.copy()
  match mp4_find(b, ts, te, ["ctts"]) {
    Some((cs, _)) => {
      let signed = b[cs] == 1
      let entries = be32(b, cs + 4).to_int()
      let mut i = 0
      for k in 0..<entries {
        let c = be32(b, cs + 8 + k * 8).to_int()
        let o = if signed { be32s(b, cs + 12 + k * 8) } else { be32(b, cs + 12 + k * 8) }
        for _ in 0..<c {
          if i < count {
            pts[i] = dts[i] + o
            i = i + 1
          }
        }
      }
    }
    None => ()
  }
  // key frames: all, where there is no stss
  let key = Array::make(count, true)
  match mp4_find(b, ts, te, ["stss"]) {
    Some((ks, _)) => {
      key.fill(false)
      let entries = be32(b, ks + 4).to_int()
      for k in 0..<entries {
        let at = be32(b, ks + 8 + k * 4).to_int() - 1
        if at >= 0 && at < count {
          key[at] = true
        }
      }
    }
    None => ()
  }
  // places: chunks' offsets, and how many samples each chunk holds
  let chunks : Array[Double] = []
  match mp4_find(b, ts, te, ["stco"]) {
    Some((cs, _)) =>
      for k in 0..<be32(b, cs + 4).to_int() {
        chunks.push(be32(b, cs + 8 + k * 4).to_double())
      }
    None =>
      match mp4_find(b, ts, te, ["co64"]) {
        Some((cs, _)) =>
          for k in 0..<be32(b, cs + 4).to_int() {
            chunks.push(be64(b, cs + 8 + k * 8).to_double())
          }
        None => return None
      }
  }
  guard mp4_find(b, ts, te, ["stsc"]) is Some((sc, _)) else { return None }
  let runs = be32(b, sc + 4).to_int()
  let at = Array::make(count, 0.0)
  let mut i = 0
  for r in 0..<runs {
    let first = be32(b, sc + 8 + r * 12).to_int() - 1
    let per = be32(b, sc + 12 + r * 12).to_int()
    let last = if r + 1 < runs {
      be32(b, sc + 8 + (r + 1) * 12).to_int() - 1
    } else {
      chunks.length()
    }
    for c in first..<@cmp.minimum(last, chunks.length()) {
      let mut place = chunks[c]
      for _ in 0..<per {
        if i < count {
          at[i] = place
          place = place + size_of(i).to_double()
          i = i + 1
        }
      }
    }
  }
  // the edit list, as ffmpeg's mov demuxer applies it: an empty edit first delays the track, the next edit's media
  // time is where it starts (AAC's priming before 0)
  let mut shift = 0L
  match mp4_find(b, s, e, ["edts", "elst"]) {
    Some((es, _)) => {
      let v1 = b[es] == 1
      let entries = be32(b, es + 4).to_int()
      let step = if v1 { 20 } else { 12 }
      let mut k = 0
      let mut done = false
      while k < entries && !done {
        let o = es + 8 + k * step
        let dur = if v1 { be64(b, o) } else { be32(b, o) }
        let media = if v1 { be64(b, o + 8) } else { be32s(b, o + 4) }
        if media == -1L {
          shift = shift + dur * timescale.to_int64() / movie_scale.to_int64()
        } else {
          shift = shift - media
          done = true
        }
        k = k + 1
      }
    }
    None => ()
  }
  let samples = Array::makei(count, fn(k) {
    { pts: pts[k] + shift, dts: dts[k] + shift, at: at[k], size: size_of(k), key: key[k] }
  })
  let (shown_w, shown_h) = match sps_shown(codec, config) {
    Some(wh) => wh
    None => (width, height)
  }
  Some({ kind, codec, timescale, width, height, shown_w, shown_h, config, channels, rate, samples })
}

///|
/// An esds' descriptors from `s` to `e`: its DecoderSpecificInfo (tag 5, inside the DecoderConfigDescriptor, tag 4,
/// inside the ES_Descriptor, tag 3), the AAC's AudioSpecificConfig; empty where there is none.
fn esds_config(b : Bytes, s : Int, e : Int) -> Bytes {
  let mut i = s
  while i + 2 <= e {
    let tag = b[i].to_int()
    i = i + 1
    // (its length: 7 bits a byte, the top bit saying another follows)
    let mut len = 0
    let mut more = true
    let mut n = 0
    while more && i < e && n < 4 {
      let v = b[i].to_int()
      len = (len << 7) | (v & 0x7F)
      more = (v & 0x80) != 0
      i = i + 1
      n = n + 1
    }
    match tag {
      3 => {
        // ES_ID, its flags, and what they say follows; then the descriptors it holds
        if i + 3 > e {
          return b""
        }
        let flags = b[i + 2].to_int()
        i = i + 3
        if (flags & 0x80) != 0 {
          i = i + 2
        }
        if (flags & 0x40) != 0 && i < e {
          i = i + 1 + b[i].to_int()
        }
        if (flags & 0x20) != 0 {
          i = i + 2
        }
      }
      // the object type, the stream's, its buffer and rates: 13 bytes, then the descriptors it holds
      4 => i = i + 13
      5 => return if i + len <= e { b[i:i + len].to_owned() } else { b"" }
      _ => i = i + len
    }
  }
  b""
}

///|
/// REPLAY_DEMUX=<segment> (development): its samples in `ffprobe -show_entries
/// packet=stream_index,pts,dts,size,pos,flags -of csv=p=0`'s lines (flags: K or _ only) into REPLAY_DEMUX_OUT.
fn demux_dump() -> Bool {
  let path = @ui.env("REPLAY_DEMUX")
  if path == "" {
    return false
  }
  let s = StringBuilder()
  let tracks = mp4_tracks(path)
  for ti, t in tracks {
    s.write_string(
      "# \{ti} \{t.kind} \{t.codec} \{t.timescale} \{t.width}x\{t.height} shown=\{t.shown_w}x\{t.shown_h} config=\{t.config.length()} samples=\{t.samples.length()}\n",
    )
  }
  for ti, t in tracks {
    for x in t.samples {
      s.write_string(
        "\{ti},\{x.pts},\{x.dts},\{x.size},\{x.at.to_int64()},\{if x.key { "K" } else { "_" }}\n",
      )
    }
  }
  rp_write(cstr(@ui.env("REPLAY_DEMUX_OUT")), @utf8.encode(s.to_string())) |> ignore
  true
}
