// What the window asks of its player (native_player.mbt's `native`, the replay's deck): seek, scrub, play, stop,
// speed. The web page that played the buffer in WebView2's <video>s till 2026-11-14 is gone (the user: 「应该没有旧的
// 播放器了吧」).

///|
/// The segment (index in `segs`) the playhead is in.
let current : Ref[Int] = Ref(-1)

///|
let speeds : Array[Double] = [0.5, 1.0, 1.5, 2.0, 4.0, 8.0, 10.0]

///|
/// The picture's shape (width for height), as its track's SPS says.
let picture_aspect : @signals.Signal[Double] = @signals.signal(16.0 / 9.0, same=fn(a, b) { a == b })

///|
/// The segment holding `at` (ms into the buffer), or the next one after a gap; and where in it.
fn locate(at : Double) -> (Int, Double) {
  let base = t0()
  for i, s in segs {
    let a = s.start - base
    if at < a {
      return (i, 0.0)
    }
    // (where the next piece starts at or before `at`, the next's: pieces may overlap by a hair, and a step to the
    // next's first frame came back to this one's end, stuck there (the user, 2026-11-15: 「按住右……就不继续往右了」))
    if at < a + s.dur && !(i + 1 < segs.length() && at >= segs[i + 1].start - base) {
      return (i, at - a)
    }
  }
  let last = segs.length() - 1
  (last, @cmp.maximum(0.0, segs[last].dur - 100.0))
}

///|
fn go(at : Double, near : Bool) -> Unit {
  fine_time.set(false)
  head_jump(at)
  native().go(at, near)
  if native().seg >= 0 && native().seg < segs.length() {
    current.val = native().seg
  }
}

///|
fn seek_to(at : Double) -> Unit {
  go(at, false)
}

///|
/// The playhead dragged to `at`: the picture follows at the nearest key frames, exactly once the hand rests.
fn scrub_to(at : Double) -> Unit {
  fine_time.set(false)
  native().scrub(at)
}

///|
fn set_playing(on : Bool) -> Unit {
  if on {
    fine_time.set(false)
  }
  tell_playing(want_play.untracked(), on)
  want_play.set(on)
  native().set_playing(on)
}

///|
fn set_speed(r : Double) -> Unit {
  speed.set(r)
  native().set_rate(r)
}
