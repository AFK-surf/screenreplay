// The player (the user's 「现在就开工」, the reviewer's 53rd to 69th; the only one since 2026-11-14, the user's
// 「应该没有旧的播放器了吧」, 「为啥还留着webview2的旧播放器」): a file's samples (mp4.mbt) handed to an mbui stream the host
// decodes, drawn on mbui's canvas in the tree's order. Nothing of WebView2: the replay's picture and the saved clips'
// alike are a `Deck`, what it plays given it as pieces (the buffer's segments, or one saved clip) on a clock of its own.
//
// The picture: each sample handed over as the deck's clock comes to its time (`View::at_moment` at that moment, never a
// frame's loop), and the stream shows the last one decoded as each frame begins. Where the clock has passed a key frame
// further on than the next sample (a high speed, a decoder behind), it goes on from that key frame: no frame of these
// recordings is a B frame, so all from one key frame to the next are needed in turn, and none after one can be left
// out. A seek decodes from the key frame before, unseen, and shows the frame asked for (`deck_go`); the picture shown
// stays till then, never black between.
//
// The sound: the piece's AAC frames decoded here (replay_aac.cpp) and played by the stream (`Stream::audio`, 48 kHz
// stereo in 20 ms packets), kept 160 ms ahead of what it has played. While it plays, its clock is the deck's: how far
// it has played (`Stream::audio_played`) puts the clock where it says, the clock's rate bent a few percent to come to
// it, put there at once when more than 150 ms off (so the picture, paced by the clock, keeps to the sound). The host
// plays it at one rate only (XAudio2's voice at 48 kHz), so at another speed up to 4x what decodes is stretched first
// (replay_play.cpp's WSOLA, its pitch kept; the user, 2026-11-22: 「倍速播放的时候听不到声音」); past 4x there is no
// sound and the clock goes by the tree's time alone; so too where a piece has no sound, or nothing plays it.
//
// Dragged (the replay's playhead held on the timeline: `deck_scrub`), each move shows the key frame before where it
// is, decoded at once, one at a time (a move while one decodes waits for it, the last move's taken), and the frame
// itself once the hand rests 120 ms or lets go; never the index's picture (the user, 2026-11-14: 「画面会变糊而且有时候
// 有闪烁」).

///|
/// A file's bytes, the file kept open for the next read (replay_play.cpp).
#borrow(path)
extern "C" fn rp_play_read(path : Bytes, offset : Double, length : Int) -> Bytes = "rp_play_read"

///|
/// A file opened ahead, off the window's thread, for the reads to come.
#borrow(path)
extern "C" fn rp_play_warm(path : Bytes) -> Unit = "rp_play_warm"

///|
#borrow(asc)
extern "C" fn rp_aac_open(asc : Bytes, rate : Int, channels : Int) -> Int = "rp_aac_open"

///|
#borrow(data)
extern "C" fn rp_aac_decode(h : Int, data : Bytes) -> Bytes = "rp_aac_decode"

///|
extern "C" fn rp_aac_reset(h : Int) -> Unit = "rp_aac_reset"

///|
extern "C" fn rp_aac_close(h : Int) -> Unit = "rp_aac_close"

///|
extern "C" fn rp_ts_open(rate : Double) -> Int = "rp_ts_open"

///|
#borrow(data)
extern "C" fn rp_ts_feed(h : Int, data : Bytes, from : Int, flush : Int) -> Bytes = "rp_ts_feed"

///|
extern "C" fn rp_ts_lag(h : Int) -> Double = "rp_ts_lag"

///|
extern "C" fn rp_ts_close(h : Int) -> Unit = "rp_ts_close"

///|
/// Whether it sounds at speed `r` (stretched to it where not 1; past 4x too fast to follow, as a browser's).
fn sounds_at(r : Double) -> Bool {
  r >= 0.5 && r <= 4.0
}

///|
/// A deck's sound: the piece it reads (index, path, its track), the next AAC frame to decode, its decoder (0 none) and
/// the config it was made for; the 48 kHz frames still to leave out of what decodes next (a seek into a frame, the
/// encoder's priming); the packet being filled; the frames handed to the stream since it started, what the stream had
/// played then, and where on the deck's clock frames handed over were (from that frame on, in turn: a new piece, a
/// gap left out); where it ends (the frames handed over, -1 while more come).
struct Sound {
  mut on : Bool
  mut seg : Int
  mut path : String
  mut track : Mp4Track?
  mut next : Int
  mut dec : Int
  mut asc : Bytes
  mut skip : Int
  packet : FixedArray[Byte]
  mut fill : Int
  mut sent : Double
  mut zero : Double
  anchors : Array[(Double, Double)]
  mut ends : Double
  /// how far it had played when it last moved on, and when (a sound that does not play is given up)
  mut seen : Double
  mut seen_at : Double
  /// when the trace last said how far the clock was off it
  mut told_at : Double
  mut due : (() -> Unit)?
  /// whether anything of it has been heard since it started (the clock goes by it only then)
  mut heard_any : Bool
  /// its start asked for again, a while after it was given up (its cancel)
  mut retry : (() -> Unit)?
  /// the speed it plays at, and what stretches it to that (0 none: at 1)
  mut rate : Double
  mut ts : Int
}

///|
fn Sound::new() -> Sound {
  {
    on: false,
    seg: -1,
    path: "",
    track: None,
    next: 0,
    dec: 0,
    asc: b"",
    skip: 0,
    packet: FixedArray::make(3840, b'\x00'),
    fill: 0,
    sent: 0.0,
    zero: 0.0,
    anchors: [],
    ends: -1.0,
    seen: 0.0,
    seen_at: 0.0,
    told_at: 0.0,
    due: None,
    heard_any: false,
    retry: None,
    rate: 1.0,
    ts: 0,
  }
}

///|
/// What a deck plays and where it is. Its pieces (`count`, each's `file`, `start` on its clock and `dur`, all of it
/// `span` long), its clock (`play`), whether it is asked to play (`wants`) and whether the hand holds it (`held`), what
/// it does as its clock reaches an end (`stops`, given the clock: true where it stopped; `ended` at the last piece's
/// end) and after each step on (`went`); the picture's shape it says (`shape`).
struct Deck {
  count : () -> Int
  file : (Int) -> String
  start : (Int) -> Double
  dur : (Int) -> Double
  span : () -> Double
  play : @signals.Signal[Play]
  speed : () -> Double
  wants : () -> Bool
  held : () -> Bool
  stops : (Double) -> Bool
  ended : () -> Unit
  went : () -> Unit
  shape : @signals.Signal[Double]
  mut stream : @ui.Stream?
  /// the piece its picture reads, its track, the next sample to hand over, the record the decoder was configured with
  mut seg : Int
  mut path : String
  mut track : Mp4Track?
  mut next : Int
  mut config : Bytes
  mut configured : Bool
  /// the sample shown last (its piece's path and number)
  mut shown_path : String
  mut shown_k : Int
  /// what is due next (its cancel); a drag's rest
  mut due : (() -> Unit)?
  mut rest : (() -> Unit)?
  /// a drag's key frame decoding (its time as handed over; -1 none), since when; the move waiting for it
  mut waiting : Double
  mut waited_at : Double
  /// the decoder drained (a still frame shown: a seek or a drag's while stopped): it gives nothing more till the next
  /// key frame it is handed, so playing on from there begins again at the key frame before
  mut drained : Bool
  /// played on from a seek: the frame asked for (its time as handed over; -1 none), where the clock waits for it to be
  /// shown (the frames before it decoding unseen), and since when
  mut warm : Double
  mut warm_pos : Double
  mut warm_since : Double
  /// frames handed to the hardware decoder whose `shown` callback has not arrived yet (bounded during playback so a busy GPU cannot accumulate multi-second lag)
  in_flight : Array[Double]
  mut in_flight_at : Double
  mut stalled_pump : Bool
  mut later : Double?
  /// a still frame asked for while the one before it still decodes (where and `near`): asked for once that one is shown
  mut step_to : (Double, Bool)?
  sound : Sound
}

///|
fn Deck::new(
  count~ : () -> Int,
  file~ : (Int) -> String,
  start~ : (Int) -> Double,
  dur~ : (Int) -> Double,
  span~ : () -> Double,
  play~ : @signals.Signal[Play],
  speed? : () -> Double = fn() { 1.0 },
  wants~ : () -> Bool,
  held? : () -> Bool = fn() { false },
  stops? : (Double) -> Bool = fn(_) { false },
  ended~ : () -> Unit,
  went? : () -> Unit = fn() {  },
  shape~ : @signals.Signal[Double],
) -> Deck {
  {
    count,
    file,
    start,
    dur,
    span,
    play,
    speed,
    wants,
    held,
    stops,
    ended,
    went,
    shape,
    stream: None,
    seg: -1,
    path: "",
    track: None,
    next: 0,
    config: b"",
    configured: false,
    shown_path: "",
    shown_k: -1,
    due: None,
    rest: None,
    waiting: -1.0,
    waited_at: 0.0,
    drained: false,
    warm: -1.0,
    warm_pos: 0.0,
    warm_since: 0.0,
    in_flight: [],
    in_flight_at: 0.0,
    stalled_pump: false,
    later: None,
    step_to: None,
    sound: Sound::new(),
  }
}

///|
/// REPLAY_FPS=1: how the picture plays, said every 2 s while it plays ("REPLAY_FPS shown=… dropped=… gaps p50/p95/p99/max"):
/// the frames handed over to be shown and those decoded unseen to catch up, and the gaps between the shown ones' being
/// drawn (rp_now, as `shown` says them). For measuring only: nothing of it otherwise.
let fps_on : Ref[Int] = Ref(-1)

///|
fn fps_log() -> Bool {
  if fps_on.val < 0 {
    fps_on.val = if @ui.env("REPLAY_FPS") == "1" { 1 } else { 0 }
  }
  fps_on.val == 1
}

///|
priv struct FpsCount {
  /// the times (as handed over) of frames to be shown, not drawn yet
  wanted : Array[Double]
  mut handed_shown : Int
  mut handed_unseen : Int
  mut last_drawn : Double
  gaps : Array[Double]
  mut since : Double
}

///|
let fps_count : FpsCount = {
  wanted: [],
  handed_shown: 0,
  handed_unseen: 0,
  last_drawn: 0.0,
  gaps: [],
  since: 0.0,
}

///|
fn fps_handed(ts : Double, show : Bool) -> Unit {
  let c = fps_count
  if show {
    c.handed_shown = c.handed_shown + 1
    c.wanted.push(ts)
    if c.wanted.length() > 64 {
      c.wanted.remove(0) |> ignore
    }
  } else {
    c.handed_unseen = c.handed_unseen + 1
  }
}

///|
fn fps_drawn(ts : Double, playing : Bool) -> Unit {
  let c = fps_count
  let mut found = -1
  for i, w in c.wanted {
    if (w - ts).abs() < 1.0 {
      found = i
      break
    }
  }
  if found < 0 {
    return
  }
  c.wanted.remove(found) |> ignore
  let t = rp_now()
  if playing && c.last_drawn > 0.0 && t - c.last_drawn < 1000.0 {
    c.gaps.push(t - c.last_drawn)
  }
  c.last_drawn = t
  if c.since == 0.0 {
    c.since = t
  }
  if t - c.since >= 2000.0 {
    fps_say(t)
  }
}

///|
fn fps_say(t : Double) -> Unit {
  let c = fps_count
  let g = c.gaps.copy()
  g.sort()
  let at = fn(q : Double) -> Double {
    if g.is_empty() {
      0.0
    } else {
      g[@cmp.minimum(g.length() - 1, (q * g.length().to_double()).to_int())]
    }
  }
  let secs = (t - c.since) / 1000.0
  let drawn = g.length() + 1
  @ui.log(
    "REPLAY_FPS secs=\{secs} drawn_fps=\{drawn.to_double() / secs} handed_shown=\{c.handed_shown} handed_unseen=\{c.handed_unseen} gaps_ms p50=\{at(0.5)} p95=\{at(0.95)} p99=\{at(0.99)} max=\{at(1.0)}",
  )
  c.handed_shown = 0
  c.handed_unseen = 0
  c.gaps.clear()
  c.since = t
}

///|
fn ntrace(words : String) -> Unit {
  if @ui.env("REPLAY_TRACE") == "1" {
    @ui.log("REPLAY native " + words)
  }
}

///|
/// The deck's stream, made once (its volume the window's).
fn Deck::stream(self : Deck) -> @ui.Stream {
  match self.stream {
    Some(s) => s
    None => {
      let d = self
      let s = @ui.Stream::new(
        shown=fn(ts) {
          if fps_log() {
            fps_drawn(ts, d.play.untracked().going)
          }
          // Settle this frame and any older frames from the same flush epoch.
          for i in 0..<d.in_flight.length() {
            if (d.in_flight[i] - ts).abs() < 1.0 {
              let left : Array[Double] = []
              for j in (i + 1)..<d.in_flight.length() {
                left.push(d.in_flight[j])
              }
              d.in_flight.clear()
              d.in_flight.append(left)
              d.in_flight_at = now()
              break
            }
          }
          // (a drag's key frame decoded or let go: the move that waited for it now)
          if ts == d.waiting {
            d.waiting = -1.0
            match (d.step_to, d.later) {
              (Some((at, near)), _) => {
                d.step_to = None
                d.go(at, near)
              }
              (None, Some(at)) => {
                d.later = None
                d.show_near(at)
              }
              _ => ()
            }
          }
          // A seek's target frame just finished decoding: release the held clock and start audio in sync.
          if d.warm >= 0.0 && (ts - d.warm).abs() < 1.0 {
            d.warm = -1.0
            if (d.wants)() && !(d.held)() {
              d.play.set({ ..d.play.untracked(), pos: d.warm_pos, at: now() })
              d.sound_start(d.warm_pos)
              d.pump()
            }
          } else if d.stalled_pump && d.in_flight.length() < 8 {
            d.stalled_pump = false
            d.pump()
          }
        },
        broken=fn() {
          // (its decoder lost its state: on from the next key frame, as `Stream::frame` lets go till one)
          d.in_flight.clear()
          d.stalled_pump = false
          d.warm = -1.0
          ntrace("broken")
        },
      )
      self.stream = Some(s)
      s.audio_volume(volume_now())
      s
    }
  }
}

///|
/// The volume the window's control says (muted: none).
fn volume_now() -> Double {
  let (v, m) = @signals.untracked(fn() { (volume.get(), muted.get()) })
  if m || v <= 0.0 {
    0.0
  } else {
    v
  }
}

///|
/// The picture's node: the stream drawn whole in it (it is laid out at the picture's shape).
fn Deck::picture(self : Deck, pic : @view.View) -> @view.View {
  @ui.stream(pic, self.stream(), fit=@ui.FitContain, closes=false)
}

///|
/// Where its clock is drawn by node `v`: as the clock goes while it plays (bound to the clock then), else where it
/// stands.
fn Deck::pos_drawn(self : Deck, v : @view.View) -> Double {
  let p = self.play.get()
  if !p.going {
    return p.pos
  }
  let t = v.drawn_while(fn(_) { p.going })
  if t > 1.0e300 {
    p.pos
  } else {
    clamp(p.pos + (t - p.at) * p.rate, 0.0, (self.span)())
  }
}

///|
/// Where its clock is now, for what is done (not bound).
fn Deck::pos(self : Deck) -> Double {
  let p = self.play.untracked()
  if p.going {
    clamp(p.pos + (now() - p.at) * p.rate, 0.0, (self.span)())
  } else {
    p.pos
  }
}

///|
/// The piece holding `at` (ms on its clock), or the next one after a gap; and where in it.
fn Deck::locate(self : Deck, at : Double) -> (Int, Double) {
  let n = (self.count)()
  // (the last piece starting at or before `at`, found by halving: asked as the clock goes, over hundreds of pieces;
  // where pieces overlap by a hair the later one's, as the walk it replaces took)
  let mut lo = 0
  let mut hi = n
  while lo < hi {
    let mid = (lo + hi) / 2
    if (self.start)(mid) <= at {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  let i = lo - 1
  if i < 0 {
    return (0, 0.0)
  }
  let a = (self.start)(i)
  if at < a + (self.dur)(i) {
    return (i, at - a)
  }
  // (in a gap after it: the next one's start)
  if i + 1 < n {
    return (i + 1, 0.0)
  }
  (n - 1, @cmp.maximum(0.0, (self.dur)(n - 1) - 100.0))
}

///|
/// Piece `i`, read as `path`, where it is now (the buffer's oldest go as the recorder lets them go): -1 gone.
fn Deck::index(self : Deck, i : Int, path : String) -> Int {
  let n = (self.count)()
  if i >= 0 && i < n && (self.file)(i) == path {
    return i
  }
  for j in 0..<n {
    if (self.file)(j) == path {
      return j
    }
  }
  -1
}

///|
/// The tracks of the last few files read (the picture and the sound read the same piece).
let tracks_read : Map[String, Array[Mp4Track]] = Map([])

///|
fn tracks_of(path : String) -> Array[Mp4Track] {
  match tracks_read.get(path) {
    Some(t) => t
    None => {
      // (a saved GIF: its frames as a track of their own, gif.mbt)
      let t = if is_gif_path(path) { gif_tracks(path) } else { mp4_tracks(path) }
      if tracks_read.length() >= 64 {
        tracks_read.clear()
      }
      // (one still being written has none yet: read again next time)
      if !t.is_empty() {
        tracks_read[path] = t
      }
      t
    }
  }
}

///|
fn track_of(path : String, kind : String) -> Mp4Track? {
  for t in tracks_of(path) {
    if t.kind == kind && !t.samples.is_empty() && !t.config.is_empty() {
      return Some(t)
    }
  }
  None
}

///|
/// A sample's time in ms into its piece.
fn sample_ms(t : Mp4Track, k : Int) -> Double {
  t.samples[k].pts.to_double() * 1000.0 / t.timescale.to_double()
}

///|
/// The last key frame at or before sample `k`.
fn key_before(t : Mp4Track, k : Int) -> Int {
  let mut i = @cmp.minimum(k, t.samples.length() - 1)
  while i > 0 && !t.samples[i].key {
    i = i - 1
  }
  i
}

///|
/// The last sample whose time is at or before `ms` into the piece (-1: none).
fn sample_at(t : Mp4Track, ms : Double) -> Int {
  let mut lo = 0
  let mut hi = t.samples.length() - 1
  if hi < 0 || sample_ms(t, 0) > ms {
    return -1
  }
  while lo < hi {
    let mid = (lo + hi + 1) / 2
    if sample_ms(t, mid) <= ms {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  lo
}

///|
/// The picture's track of piece `i` read (none where it is still being written, or has no picture), the decoder
/// configured for it where its record differs from the last.
fn Deck::open(self : Deck, i : Int) -> Bool {
  let path = (self.file)(i)
  if self.path == path && self.track is Some(_) {
    self.seg = i
    return true
  }
  self.seg = i
  self.path = path
  self.next = 0
  self.track = track_of(path, "vide")
  match self.track {
    Some(t) => {
      let s = self.stream()
      // (the decoder kept where the record is the same: the next piece's key frame goes on in it)
      if t.codec == "gif" {
        // (a GIF's frames are pictures of their own, handed over whole: nothing to configure)
        ()
      } else if !self.configured || self.config != t.config {
        if t.codec.has_prefix("hv") || t.codec.has_prefix("he") {
          s.hevc(t.config, t.shown_w, t.shown_h)
        } else if t.codec == "av01" {
          // (only where the system decodes AV1: elsewhere the clip is not opened here, plays_here)
          s.av1(t.config, t.shown_w, t.shown_h)
        } else {
          s.h264(t.config, t.shown_w, t.shown_h)
        }
        self.config = t.config
        self.configured = true
      }
      if t.shown_h > 0 {
        self.shape.set(t.shown_w.to_double() / t.shown_h.to_double())
      }
      // (its sound's decoder made with the first picture, and the host's sound woken by a packet of silence taken back
      // at once (never started: it starts at 100 ms queued), not as play is pressed: the two took ~60 ms then)
      match track_of(path, "soun") {
        Some(a) if self.sound.dec == 0 && a.codec == "mp4a" && self.sound_decoder(a) => {
          s.audio(Bytes::make(3840, b'\x00'))
          s.audio(b"")
        }
        _ => ()
      }
      true
    }
    None => false
  }
}

///|
/// Sample `k` of the open track handed to the decoder; its time, in µs on the deck's clock, the frame's.
fn Deck::hand(self : Deck, t : Mp4Track, k : Int, show? : Bool = true) -> Double {
  let x = t.samples[k]
  let ts = (((self.start)(self.seg) + sample_ms(t, k)) * 1000.0).round()
  if t.codec == "gif" {
    // (a GIF's frame composed whole: only the one shown is made; none goes before it in a decoder)
    if show {
      self.stream().jpeg(rp_gif_frame(cstr(self.path), k, 0), ts)
      self.shown_path = self.path
      self.shown_k = k
    }
    return ts
  }
  let data = rp_play_read(cstr(self.path), x.at, x.size)
  if fps_log() {
    fps_handed(ts, show)
  }
  self.in_flight.push(ts)
  self.in_flight_at = now()
  self.stream().frame(data, x.key, ts, show~)
  if show {
    self.shown_path = self.path
    self.shown_k = k
  }
  ts
}

///|
fn Deck::cancel(self : Deck) -> Unit {
  match self.due {
    Some(stop) => stop()
    None => ()
  }
  self.due = None
}

///|
fn Deck::cancel_rest(self : Deck) -> Unit {
  match self.rest {
    Some(stop) => stop()
    None => ()
  }
  self.rest = None
}

///|
/// The picture put at `at` (ms on its clock): its piece opened, its key frame before it and all after it up to it
/// handed over unseen, that one shown (`near`: the key frame alone); while it plays (and the hand does not hold it), the
/// rest handed over as their moments come, and its sound from there.
fn Deck::go(self : Deck, at : Double, near : Bool) -> Unit {
  self.cancel()
  self.cancel_rest()
  self.later = None
  let n = (self.count)()
  if n == 0 {
    return
  }
  let (i, inside) = self.locate(@cmp.maximum(0.0, @cmp.minimum(at, (self.span)() - 50.0)))
  let pos = (self.start)(i) + inside
  let going = (self.wants)() && !(self.held)()
  self.play.set({ pos, at: now(), rate: (self.speed)(), going })
  self.sound_stop()
  self.step_to = None
  // (still, and the frame asked for before still decoding: the playhead there now, the picture once that one is shown,
  // the last asked for alone; each handed over at once, a key held down queued more than the decoder got through, and
  // it went on stepping for a while once let go (the user, 2026-11-15: 「按住左/右……按键抬起时，还会继续跳帧」))
  if !going && self.waiting >= 0.0 && now() - self.waited_at < 300.0 {
    self.step_to = Some((at, near))
    // (that one never told shown in 300 ms: taken as lost, this one asked for then)
    match the_root.val {
      Some(r) => {
        let d = self
        let w = self.waiting
        r.at_moment(self.waited_at + 300.0, fn() {
          if d.step_to is Some((a, n)) && d.waiting == w {
            d.waiting = -1.0
            d.step_to = None
            d.go(a, n)
          }
        })
        |> ignore
      }
      None => ()
    }
    return
  }
  if !self.open(i) {
    return
  }
  guard self.track is Some(t) else { return }
  // (half a millisecond of slack: a time worked out of a sample's may come back a hair under it)
  let k = @cmp.maximum(0, sample_at(t, inside + 0.5))
  ntrace("go seg=\{i} inside=\{inside} k=\{k} near=\{near}")
  let key = key_before(t, k)
  let last = if near { key } else { k }
  // (what was on its way to the decoder let go, the picture shown kept; the frames from the key frame to the one
  // asked for decoded unseen, that one alone shown; where it is not to play on, drained: the decoder holds back the
  // last frame given it till another comes)
  let s = self.stream()
  s.flush()
  self.in_flight.clear()
  self.stalled_pump = false
  self.waiting = -1.0
  for j in key..=last {
    let ts = self.hand(t, j, show=j == last)
    if j == last && !going && t.codec != "gif" {
      self.waiting = ts
      self.waited_at = now()
    }
  }
  if !going {
    s.flush(drain=true)
  }
  self.drained = !going
  self.next = last + 1
  self.warm = -1.0
  if going {
    // (what it plays read into the system's cache ahead of it; not while dragged: a drag crosses many)
    rp_play_warm(cstr(self.path))
    // (the clock and the sound held at the frame after the one asked for, handed over now, till it is shown: going on
    // at once, the picture stood on the frame shown before for the ~100 ms the decoder took over the frames from the
    // key frame, then leapt (the user, 2026-11-15: 「跳帧后还是会复读那么100毫秒」); `shown` and `pump` let them go. That frame,
    // not the one asked for: a still frame's seek shows that one already, from the decoding before)
    if last + 1 < t.samples.length() {
      self.warm = self.hand(t, last + 1)
      self.warm_pos = (self.start)(i) + sample_ms(t, last + 1)
      self.warm_since = now()
      self.next = last + 2
    } else {
      self.sound_start(pos)
    }
  }
  self.pump()
}

///|
/// The hand holding the playhead moved it to `at`: the clock stands there; the key frame before it shown, decoded at
/// once where none is decoding (else once that one is: the last move's), unless the picture is of its stretch already;
/// the frame itself once the hand rests.
fn Deck::scrub(self : Deck, at : Double) -> Unit {
  self.step_to = None
  self.warm = -1.0
  self.stalled_pump = false
  self.cancel()
  self.sound_stop()
  let p = self.play.untracked()
  self.play.set({ ..p, pos: at, at: now(), going: false })
  self.cancel_rest()
  match the_root.val {
    Some(r) => {
      let d = self
      self.rest = Some(
        r.at_moment(now() + 120.0, fn() {
          d.rest = None
          if (d.held)() {
            d.go(at, false)
          }
        }),
      )
    }
    None => ()
  }
  // (one decoding: this move waits for it, unless it has been 300 ms, when it is taken as lost)
  if self.waiting >= 0.0 && now() - self.waited_at < 300.0 {
    self.later = Some(at)
    return
  }
  self.show_near(at)
}

///|
/// The key frame before `at` shown (not where the picture shows one of its stretch: never back to it from a frame
/// after it).
fn Deck::show_near(self : Deck, at : Double) -> Unit {
  if (self.count)() == 0 {
    return
  }
  let (i, inside) = self.locate(@cmp.maximum(0.0, @cmp.minimum(at, (self.span)() - 50.0)))
  if !self.open(i) {
    return
  }
  guard self.track is Some(t) else { return }
  let key = key_before(t, @cmp.maximum(0, sample_at(t, inside + 0.5)))
  if self.shown_path == self.path && self.shown_k >= 0 && key_before(t, self.shown_k) == key {
    return
  }
  let s = self.stream()
  s.flush()
  self.in_flight.clear()
  self.stalled_pump = false
  self.waiting = self.hand(t, key)
  self.waited_at = now()
  s.flush(drain=true)
  self.drained = true
  self.next = key + 1
}

///|
/// While it plays: what the clock has come to handed over, and the next sample's moment asked for. Past the piece's
/// last sample, on into the next (a gap not recorded skipped); past the last, or where `stops` says, stopped.
fn Deck::pump(self : Deck) -> Unit {
  self.cancel()
  guard (self.wants)() && !(self.held)() && self.track is Some(t) else { return }
  let i = self.index(self.seg, self.path)
  if i < 0 {
    return
  }
  self.seg = i
  if self.warm >= 0.0 {
    // (the frame asked for not shown yet, 400 ms at most: the clock held there until `shown` clears `self.warm`)
    self.play.set({ ..self.play.untracked(), pos: self.warm_pos, at: now() })
    if now() - self.warm_since < 400.0 {
      match the_root.val {
        Some(r) => self.due = Some(r.at_moment(now() + 4.0, fn() { self.pump() }, later=true))
        None => ()
      }
      return
    }
    self.warm = -1.0
    self.sound_start(self.warm_pos)
  }
  let base = (self.start)(i)
  let p = self.pos()
  if (self.stops)(p) {
    return
  }
  let root = match the_root.val {
    Some(r) => r
    None => return
  }
  let rate = @cmp.maximum(0.01, self.play.untracked().rate)
  let end = base + (self.dur)(i)
  if self.in_flight.length() >= 8 && now() - self.in_flight_at > 500.0 {
    ntrace("in_flight timeout (\{self.in_flight.length()}), clearing")
    self.in_flight.clear()
  }
  // (half a millisecond's slack: the clock's ms and a sample's, worked out of different units, meet a hair apart)
  let inside = p - base + 0.5
  let reached = sample_at(t, inside)
  let n = t.samples.length()
  let mut backed_up = false
  if reached >= self.next {
    // (a key frame further on than the next sample, passed already: flush backed-up work and jump straight to it)
    let key = key_before(t, reached)
    if key > self.next {
      if !self.in_flight.is_empty() {
        self.stream().flush()
        self.in_flight.clear()
        self.stalled_pump = false
      }
      self.next = key
      for j in key..=reached {
        self.hand(t, j, show=j == reached) |> ignore
      }
      self.next = reached + 1
    } else {
      let room = 8 - self.in_flight.length()
      if room <= 0 {
        backed_up = true
      } else {
        let last = @cmp.minimum(reached, self.next + room - 1)
        for j in self.next..=last {
          self.hand(t, j, show=j == last) |> ignore
        }
        self.next = last + 1
        if last < reached {
          backed_up = true
        }
      }
    }
  }
  (self.went)()
  // (the next piece opened ahead, a few seconds before it plays)
  if i + 1 < (self.count)() && end - p < 3000.0 * rate {
    rp_play_warm(cstr((self.file)(i + 1)))
  }
  if p >= end - 1.0 && i + 1 < (self.count)() {
    // the piece's end: on into the next (at once where it starts later: the gap skipped)
    if backed_up && !self.in_flight.is_empty() {
      self.stream().flush()
      self.in_flight.clear()
    }
    self.stalled_pump = false
    let next_at = (self.start)(i + 1)
    if next_at > p {
      self.play.set({ ..self.play.untracked(), pos: next_at, at: now() })
    }
    if self.open(i + 1) {
      self.next = 0
      // (the sound gone quiet at a piece without it, or where it stopped: from here)
      if !self.sound.on && sounds_at((self.speed)()) {
        self.sound_start(self.pos())
      }
      self.pump()
    }
  } else if backed_up {
    self.stalled_pump = true
    self.due = Some(root.at_moment(now() + 10.0, fn() { self.pump() }, later=true))
  } else if self.next < n {
    let wait = (sample_ms(t, self.next) - (p - base)) / rate
    self.due = Some(root.at_moment(now() + @cmp.maximum(1.0, wait), fn() { self.pump() }, later=true))
  } else if p < end - 1.0 {
    self.due = Some(root.at_moment(now() + @cmp.maximum(1.0, (end - p) / rate), fn() { self.pump() }, later=true))
  } else {
    (self.ended)()
  }
}

///|
/// Played or stopped where it is.
fn Deck::set_playing(self : Deck, on : Bool) -> Unit {
  let p = self.pos()
  self.play.set({ pos: p, at: now(), rate: (self.speed)(), going: on && !(self.held)() })
  if on {
    let i = if (self.count)() > 0 { self.locate(p).0 } else { -1 }
    // (after a still frame the decoder gives nothing till a key frame comes: played on from there, the picture stood
    // still up to the next one, 0-2 s, and leapt to it (the user, 2026-11-15: 「timeline上跳到某一帧后，似乎播放会瞬间抖动一
    // 下」); from the key frame before, the frames to here unseen, it goes on from here)
    if self.track is None || i < 0 || (self.file)(i) != self.path || self.drained {
      self.go(p, false)
    } else {
      rp_play_warm(cstr(self.path))
      self.sound_start(p)
      self.pump()
    }
  } else {
    self.warm = -1.0
    self.stalled_pump = false
    self.cancel()
    self.sound_stop()
  }
}

///|
/// Played at `r` times its speed from where it is: its sound where it sounds at that speed.
fn Deck::set_rate(self : Deck, r : Double) -> Unit {
  let p = self.pos()
  let was = self.play.untracked()
  // (the speed it is at picked again: nothing changes, its sound not cut and begun again)
  if r == was.rate || (self.sound.on && self.sound.rate == r) {
    return
  }
  self.play.set({ ..was, pos: p, at: now(), rate: r })
  if was.going && sounds_at(r) {
    self.sound_start(p)
  } else {
    self.sound_stop()
  }
  self.pump()
}

///|
/// Let go of all it holds (a saved clip's player closed).
fn Deck::close(self : Deck) -> Unit {
  self.warm = -1.0
  self.stalled_pump = false
  self.in_flight.clear()
  self.cancel()
  self.cancel_rest()
  self.sound_stop()
  if self.sound.dec != 0 {
    rp_aac_close(self.sound.dec)
    self.sound.dec = 0
  }
  match self.stream {
    Some(s) => s.close()
    None => ()
  }
  self.stream = None
}

///|
/// What it holds while it rests let go of (the resident window put away): its sound's decoder (made again as it next
/// sounds), the files kept open for its reads. Its stream and its picture stay: the window shown again shows at once.
fn Deck::rest(self : Deck) -> Unit {
  self.cancel()
  self.cancel_rest()
  self.sound_stop()
  if self.sound.dec != 0 {
    rp_aac_close(self.sound.dec)
    self.sound.dec = 0
    self.sound.asc = b""
  }
  self.sound.track = None
}

// ---- the sound ----

///|
fn Deck::sound_stop(self : Deck) -> Unit {
  let s = self.sound
  match s.due {
    Some(stop) => stop()
    None => ()
  }
  s.due = None
  match s.retry {
    Some(stop) => stop()
    None => ()
  }
  s.retry = None
  if s.on {
    // (an empty packet: what is queued stops at once)
    self.stream().audio(b"")
  }
  s.on = false
  if s.ts != 0 {
    rp_ts_close(s.ts)
    s.ts = 0
  }
}

///|
/// Its sound from `at` (ms on its clock), where it sounds at the speed, the host plays sound and the piece there has some.
fn Deck::sound_start(self : Deck, at : Double) -> Unit {
  self.sound_stop()
  let s = self.sound
  let rate = (self.speed)()
  if !@ui.stream_audio_here() || !sounds_at(rate) || (self.count)() == 0 {
    return
  }
  let (i, inside) = self.locate(at)
  let path = (self.file)(i)
  guard track_of(path, "soun") is Some(t) && t.codec == "mp4a" else { return }
  if !self.sound_decoder(t) {
    return
  }
  // from the AAC frame before the one `at` is in (decoded only so the next comes out whole), what is before `at` left out
  let k = sample_at(t, inside)
  let from = @cmp.maximum(0, k - 1)
  let skip_ms = @cmp.maximum(0.0, inside - sample_ms(t, from))
  s.seg = i
  s.path = path
  s.track = Some(t)
  s.next = from
  s.skip = (skip_ms * 48.0).round().to_int()
  s.fill = 0
  s.sent = 0.0
  let st = self.stream()
  s.zero = st.audio_played()
  s.seen = 0.0
  s.seen_at = now()
  s.heard_any = false
  s.ends = -1.0
  s.rate = rate
  if rate != 1.0 {
    s.ts = rp_ts_open(rate)
  }
  // (stretched, where the first of it is heard: half a frame of the stretch's on, rp_ts_lag)
  let first = if s.ts != 0 { rp_ts_lag(s.ts) / rate } else { 0.0 }
  s.anchors.clear()
  s.anchors.push((first, (self.start)(i) + sample_ms(t, from) + skip_ms))
  s.on = true
  ntrace("sound from \{at} seg=\{i} k=\{from} skip=\{s.skip}")
  self.sound_tick()
}

///|
/// A decoder for track `t`'s config, ready from nothing.
fn Deck::sound_decoder(self : Deck, t : Mp4Track) -> Bool {
  let s = self.sound
  if s.dec != 0 && s.asc == t.config {
    rp_aac_reset(s.dec)
    return true
  }
  if s.dec != 0 {
    rp_aac_close(s.dec)
  }
  s.dec = rp_aac_open(t.config, t.rate, @cmp.maximum(1, t.channels))
  s.asc = t.config
  if s.dec == 0 {
    ntrace("sound: no decoder")
  }
  s.dec != 0
}

///|
/// What decodes put in packets, each handed over as it fills (`pad`: the last one filled out with silence).
fn Deck::sound_put(self : Deck, pcm : Bytes, pad? : Bool = false) -> Unit {
  let s = self.sound
  let mut i = 0
  let mut pcm = pcm
  let mut n = pcm.length()
  if s.skip > 0 {
    let leave = @cmp.minimum(s.skip * 4, n - n % 4)
    i = leave
    s.skip = s.skip - leave / 4
  }
  // (at another speed, stretched to it: what it gives, after what was left out)
  if s.ts != 0 {
    pcm = rp_ts_feed(s.ts, pcm, i, if pad { 1 } else { 0 })
    n = pcm.length()
    i = 0
  }
  while i < n {
    let take = @cmp.minimum(3840 - s.fill, n - i)
    for j in 0..<take {
      s.packet[s.fill + j] = pcm[i + j]
    }
    s.fill = s.fill + take
    i = i + take
    if s.fill == 3840 {
      self.sound_send()
    }
  }
  if pad && s.fill > 0 {
    for j in s.fill..<3840 {
      s.packet[j] = b'\x00'
    }
    s.fill = 3840
    self.sound_send()
  }
}

///|
fn Deck::sound_send(self : Deck) -> Unit {
  let s = self.sound
  self.stream().audio(Bytes::makei(3840, fn(i) { s.packet[i] }))
  s.fill = 0
  s.sent = s.sent + 960.0
}

///|
/// The next AAC frame decoded and put in packets; at the piece's end, on into the next where it has sound (a gap
/// between them left out, the clock told where its sound goes on). False at its end.
fn Deck::sound_more(self : Deck) -> Bool {
  let s = self.sound
  guard s.track is Some(t) else { return false }
  if s.next < t.samples.length() {
    let x = t.samples[s.next]
    s.next = s.next + 1
    self.sound_put(rp_aac_decode(s.dec, rp_play_read(cstr(s.path), x.at, x.size)))
    return true
  }
  let i = self.index(s.seg, s.path) + 1
  if i <= 0 || i >= (self.count)() {
    return false
  }
  let path = (self.file)(i)
  guard track_of(path, "soun") is Some(n) && n.codec == "mp4a" else { return false }
  if !self.sound_decoder(n) {
    return false
  }
  // (its encoder's priming, before 0, left out)
  let first = sample_ms(n, 0)
  s.skip = s.skip + (@cmp.maximum(0.0, -first) * 48.0).round().to_int()
  // (where the stretch has it heard: after what is in it still, at its speed)
  let lag = if s.ts != 0 { rp_ts_lag(s.ts) / s.rate } else { 0.0 }
  s.anchors.push((s.sent + (s.fill / 4).to_double() + lag, (self.start)(i) + @cmp.maximum(0.0, first)))
  s.seg = i
  s.path = path
  s.track = Some(n)
  s.next = 0
  true
}

///|
/// Where its sound is on the deck's clock, by what the stream has played; None where none plays (stopped, played to
/// its end, or not playing at all).
fn Deck::sound_pos(self : Deck) -> Double? {
  let s = self.sound
  if !s.on {
    return None
  }
  let played = self.stream().audio_played() - s.zero
  if s.ends >= 0.0 && played >= s.ends {
    self.sound_stop()
    return None
  }
  // (what the stream has played not moving on by at least 1 ms for 500 ms while there is sound queued: nothing plays it;
  // requiring +48 samples prevents +/-2 sample output-latency jitter on a stopped voice from resetting the watchdog.
  // Before the first of it is heard, 2 s: what lies between the voice and the ear (a Bluetooth headset's buffer, a
  // device waking) is not counted as played, and a slow first sound was taken for none, the rest of the piece silent:
  // the user, 2026-11-21, 「只有前0.5秒才有声音」. Given up, it is asked for again a second later, not left silent)
  if played > s.seen + 48.0 {
    s.seen = played
    s.seen_at = now()
    s.heard_any = true
  } else if now() - s.seen_at > (if s.heard_any { 500.0 } else { 2000.0 }) {
    ntrace("sound: not played, the clock alone (asked again in 1 s)")
    self.sound_stop()
    self.sound_retry()
    return None
  }
  // (nothing heard yet: the clock alone, not put back to where the sound starts while what was sent is on its way)
  if !s.heard_any {
    return None
  }
  while s.anchors.length() > 1 && s.anchors[1].0 <= played {
    s.anchors.remove(0) |> ignore
  }
  let (from, at) = s.anchors[0]
  Some(at + @cmp.maximum(0.0, played - from) / 48.0 * s.rate)
}

///|
/// Its clock's times moved on by `by` ms (the buffer's oldest segments let go: load's shift): where its sound is on that
/// clock moved with them. Left as they were, the sound said the playhead was a whole segment off and put it there, and
/// back again as the sound went into the next one (with 8 s segments, every 8 s).
fn Deck::shifted(self : Deck, by : Double) -> Unit {
  // (a still frame waiting to be asked for: where it is, on the clock moved with the rest)
  if self.step_to is Some((at, near)) {
    self.step_to = Some((at + by, near))
  }
  if self.warm >= 0.0 {
    self.warm_pos = self.warm_pos + by
  }
  let s = self.sound
  for i in 0..<s.anchors.length() {
    let (from, at) = s.anchors[i]
    s.anchors[i] = (from, at + by)
  }
}

///|
/// Every 40 ms while it sounds: kept at least 160 ms queued, and 40 ms past what the host wants queued before it
/// starts (`Stream::audio_wanted`: Windows' reserve, which a gap between two packets raises to 300 ms and calm brings
/// back; mbui #6344), and the clock brought to it. Checking `audio_queued()` directly ensures the voice always receives
/// enough packets to restart even though `audio_played()` subtracts output device latency (~40-100 ms); previously
/// `s.sent - played` hit the 300 ms cap at 280 ms queued (1 packet short of reserve), deadlocking audio forever after a
/// UI stall.
fn Deck::sound_tick(self : Deck) -> Unit {
  let s = self.sound
  s.due = None
  if !s.on {
    return
  }
  let st = self.stream()
  let want_ms = @cmp.maximum(160.0, st.audio_wanted() + 40.0)
  // (what is queued says when more is wanted; this bound only keeps a voice that takes nothing from being sent
  // without end. It counts what was sent and not heard yet, so it holds the output's own delay too: 120 ms over what
  // is wanted cut a headset's sound off for good where its delay was more, nothing sent once the first was queued)
  let max_ahead = 48.0 * (want_ms + 1000.0)
  let mut n = 0
  // (24 AAC frames are 512 ms at 1x, a quarter of that at 4x: as many more at a higher speed)
  let limit = (24.0 * @cmp.maximum(1.0, s.rate)).ceil().to_int()
  while s.ends < 0.0 && st.audio_queued() < want_ms && s.sent - (st.audio_played() - s.zero) < max_ahead && n < limit {
    if !self.sound_more() {
      self.sound_put(b"", pad=true)
      s.ends = s.sent
    }
    n = n + 1
  }
  match self.sound_pos() {
    Some(heard) => {
      let p = self.play.untracked()
      if p.going {
        let ours = self.pos()
        let off = heard - ours
        // (how far off on the wall's clock: what is heard and what is seen, at the speed it plays)
        let wall = off / s.rate
        if now() - s.told_at >= 1000.0 {
          s.told_at = now()
          ntrace("sound off=\{off} rate=\{p.rate} queued=\{st.audio_queued()} inflight=\{self.in_flight.length()}")
        }
        if wall.abs() > 150.0 {
          ntrace("sound: clock put at \{heard} (was \{ours})")
          self.play.set({ pos: heard, at: now(), rate: s.rate, going: true })
          self.pump()
        } else {
          let r = s.rate * (if wall.abs() < 12.0 { 1.0 } else { 1.0 + clamp(wall / 500.0, -0.08, 0.08) })
          if r != p.rate {
            self.play.set({ pos: ours, at: now(), rate: r, going: true })
          }
        }
      }
    }
    None => if !s.on { return }
  }
  match the_root.val {
    Some(r) => {
      let d = self
      s.due = Some(r.at_moment(now() + 40.0, fn() { d.sound_tick() }, later=true))
    }
    None => ()
  }
}

///|
/// Its sound asked for again in a second (given up as not playing: a device changed or woke slowly), where it still
/// plays at its own speed then; once each time it is given up.
fn Deck::sound_retry(self : Deck) -> Unit {
  match the_root.val {
    Some(r) => {
      let d = self
      self.sound.retry = Some(
        r.at_moment(now() + 1000.0, fn() {
          d.sound.retry = None
          let p = d.play.untracked()
          if p.going && !d.sound.on && sounds_at((d.speed)()) && (d.wants)() && !(d.held)() {
            d.sound_start(d.pos())
          }
        }),
      )
    }
    None => ()
  }
}

// ---- the replay's deck ----

///|
let native_made : Ref[Deck?] = Ref(None)

///|
/// The replay's: the buffer's segments on its timeline, its clock the playhead's (made as it is first asked for).
fn native() -> Deck {
  match native_made.val {
    Some(d) => d
    None => {
      let d = native_deck()
      native_made.val = Some(d)
      d
    }
  }
}

///|
fn native_deck() -> Deck {
  Deck::new(
  count=fn() { segs.length() },
  file=fn(i) { segs[i].path },
  start=fn(i) { segs[i].start - t0() },
  dur=fn(i) { segs[i].dur },
  span~,
  play~,
  speed=fn() { speed.untracked() },
  wants=fn() { want_play.untracked() },
  held=fn() { (grabbed.untracked() == 3 && scrub_dragged.untracked()) || key_seeking.val },
  stops=fn(p) {
    // (the clip's end while one is picked)
    if clipping.untracked() && p >= clip_b.untracked() {
      set_playing(false)
      seek_to(clip_b.untracked())
      true
    } else {
      // (under a filter of apps: on past the stretches of those not ticked, app_filter.mbt)
      filter_skip(p)
    }
  },
  ended=fn() { set_playing(false) },
  went=native_went,
  shape=picture_aspect,
)
}

///|
/// After each step on: the segment it plays the current one, the view following the playhead.
fn native_went() -> Unit {
  current.val = native().seg
  follow_playhead()
}

///|
/// While it plays, the playhead kept in view: the view turns over as it runs off its right end, and goes to it where
/// it went out of it (a filter's skip to another app's stretch, the end of a gap): a tenth of the view from its left
/// (the user, 2026-11-15: 「开filter或者不开filter播放时，应该自动滚动timeline保证可见」). Not for 3 s after the hand
/// moved the view (a pan away from it is kept that long), nor while the overview's frame is held.
fn follow_playhead() -> Unit {
  if want_play.untracked() && grabbed.untracked() == 0 && !follow_latest.untracked() && !view_dragging.untracked() &&
    now() - view_by_hand.val > 3000.0 {
    let len = @signals.untracked(view_len)
    let from = view_from.untracked()
    let p = ax_d(pos_now(), len)
    if p > from + len || p < from {
      glide()
      view_from.set(p - len * 0.1)
      keep_view()
    }
  }
}

///|
/// When stepping last asked the recorder to close its piece (rp_now's ms).
let step_flushed : Ref[Double] = Ref(0.0)

///|
/// A frame on or back (`,` `.`): the sample after or before the one the playhead is on, its own time (these recordings'
/// frames come when the screen changes, not at a rate), into the next or the last segment at either end.
fn native_step(dir : Int) -> Unit {
  set_playing(false)
  if segs.is_empty() {
    return
  }
  let (i, inside) = locate(@cmp.maximum(0.0, @cmp.minimum(pos_now(), span() - 50.0)))
  // (stepped on into the last second recorded: the recorder asked to close the piece it writes, so what was recorded
  // since comes and stepping goes on into it (the user, 2026-11-15: 「按住右，到了某个时间点就不继续往右了」); once in
  // 2 s at most)
  if dir > 0 && i == segs.length() - 1 && pos_now() >= span() - 1000.0 && rp_now() - step_flushed.val > 2000.0 {
    step_flushed.val = rp_now()
    ask_flush()
  }
  if !native().open(i) {
    return
  }
  guard native().track is Some(t) else { return }
  let k = sample_at(t, inside + 0.5) + dir
  if k >= 0 && k < t.samples.length() {
    go(segs[i].start - t0() + sample_ms(t, k), false)
    fine_time.set(true)
  } else if k < 0 && i > 0 && native().open(i - 1) {
    guard native().track is Some(p) else { return }
    go(segs[i - 1].start - t0() + sample_ms(p, p.samples.length() - 1), false)
    fine_time.set(true)
  } else if k >= t.samples.length() && i + 1 < segs.length() && native().open(i + 1) {
    guard native().track is Some(n) else { return }
    go(segs[i + 1].start - t0() + sample_ms(n, 0), false)
    fine_time.set(true)
  }
}
