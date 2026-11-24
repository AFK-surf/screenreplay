// The sound's loudness on the timeline (the design review's letter 15, the user's wish to see the volume): the
// recorder keeps beside each segment a `.levels` file, one byte every 100 ms (the loudest track's RMS, -50 dB 0 and
// 0 dB 255: recording/SegmentWriter.cs), gone with the segment. Drawn as thin bars along the foot of the apps'
// stretches, lighter where already played; nothing where it is quiet or a segment has none (older recordings).
// Beside it an `.input` file the same way: how busy the mouse and the keyboard were (counts only, 0 none, 255 as busy
// as it gets: recording/InputActivity.cs), drawn as a heat lane over the stretches (timeline_view.mbt's heat_picture).

///|
let level_step : Double = 100.0

///|
/// Each segment's levels and 16-sample (1.6 s) peaks, read once (empty when it has none).
let levels_of : Map[String, (Bytes, Bytes)] = Map([])

///|
/// Each segment's input activity and 16-sample (1.6 s) peaks, read once (empty when it has none).
let input_of : Map[String, (Bytes, Bytes)] = Map([])

///|
/// Each 16 samples' (1.6 s) peak of `b`, so a wide view's scan steps by 1.6 s instead of 100 ms.
fn make_mip(b : Bytes) -> Bytes {
  let n = b.length()
  if n == 0 {
    return b""
  }
  let m = (n + 15) / 16
  Bytes::makei(m, fn(blk) {
    let start = blk * 16
    let end = @cmp.minimum(n, start + 16)
    let mut best = 0
    for k in start..<end {
      let v = b[k].to_int()
      if v > best {
        best = v
      }
    }
    best.to_byte()
  })
}

///|
/// A segment's sidecar `ext`, read once into `cache` (empty when it has none).
fn seg_sidecar(cache : Map[String, (Bytes, Bytes)], s : Seg, ext : String) -> (Bytes, Bytes) {
  match cache.get(s.path) {
    Some(pair) => pair
    None => {
      let path = s.path[:s.path.length() - 4].to_owned() + ext
      let b = rp_read(cstr(path), 0.0, 0x100000)
      let pair = (b, make_mip(b))
      cache[s.path] = pair
      pair
    }
  }
}

///|
/// A segment let go of: what was read of it with it.
fn sidecars_drop(path : String) -> Unit {
  levels_of.remove(path)
  input_of.remove(path)
  sidecars_rev.val = -1
}

///|
/// All cached sidecar buffers dropped while the resident window is hidden (reloaded lazily on next show).
fn sidecars_clear() -> Unit {
  levels_of.clear()
  input_of.clear()
  lv_raw.clear()
  lv_raw.shrink_to_fit()
  lv_mip.clear()
  lv_mip.shrink_to_fit()
  in_raw.clear()
  in_raw.shrink_to_fit()
  in_mip.clear()
  in_mip.shrink_to_fit()
  sidecars_rev.val = -1
}

///|
/// The segments' sidecars in `segs` order, kept in step with `rev` so a column scan indexes them directly without
/// hashing paths or searching `segs` at each column.
let sidecars_rev : Ref[Int] = Ref(-1)

///|
let lv_raw : Array[Bytes] = []

///|
let lv_mip : Array[Bytes] = []

///|
let in_raw : Array[Bytes] = []

///|
let in_mip : Array[Bytes] = []

///|
fn sync_sidecars() -> Unit {
  let r = rev.untracked()
  if sidecars_rev.val == r && lv_raw.length() == segs.length() {
    return
  }
  sidecars_rev.val = r
  lv_raw.clear()
  lv_mip.clear()
  in_raw.clear()
  in_mip.clear()
  for s in segs {
    let (lr, lm) = seg_sidecar(levels_of, s, ".levels")
    lv_raw.push(lr)
    lv_mip.push(lm)
    let (ir, im) = seg_sidecar(input_of, s, ".input")
    in_raw.push(ir)
    in_mip.push(im)
  }
}

///|
/// The peak byte of `raw` (with 16-sample peaks `mip`) over indices `from0..=to0`.
fn seg_peak(raw : Bytes, mip : Bytes, from0 : Int, to0 : Int) -> Int {
  let n = raw.length()
  if n == 0 {
    return -1
  }
  let from = @cmp.maximum(0, from0)
  let to = @cmp.minimum(n - 1, to0)
  if from > to {
    return -1
  }
  let mut best = 0
  let mut k = from
  if to - from >= 32 {
    let b0 = (from + 15) >> 4
    let b1 = (to + 1) >> 4
    if b0 < b1 {
      let head_end = b0 << 4
      while k < head_end {
        let v = raw[k].to_int()
        if v > best {
          best = v
        }
        k += 1
      }
      let mut blk = b0
      while blk < b1 {
        let v = mip[blk].to_int()
        if v > best {
          best = v
        }
        blk += 1
      }
      k = b1 << 4
    }
  }
  while k <= to {
    let v = raw[k].to_int()
    if v > best {
      best = v
    }
    k += 1
  }
  best
}

///|
/// The peak (0..255) of each column `k0 + idx` (`idx` in `0..<n`, each `cell` ms wide) walked in one pass along
/// `segs`, and whether any column was above 0.
fn peaks_grid(k0 : Double, n : Int, cell : Double, is_input : Bool) -> (Array[Int], Bool) {
  sync_sidecars()
  let out = Array::make(n, 0)
  let n_segs = segs.length()
  if n <= 0 || n_segs == 0 {
    return (out, false)
  }
  let raws = if is_input { in_raw } else { lv_raw }
  let mips = if is_input { in_mip } else { lv_mip }
  let base = t0()
  let a0 = base + k0 * cell
  let mut lo = 0
  let mut hi = n_segs
  while lo < hi {
    let mid = (lo + hi) / 2
    if segs[mid].start + segs[mid].dur <= a0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  let mut seg_i = lo
  let mut any = false
  for idx in 0..<n {
    let a = base + (k0 + idx.to_double()) * cell
    let b = a + cell
    while seg_i < n_segs && segs[seg_i].start + segs[seg_i].dur <= a {
      seg_i += 1
    }
    let mut j = seg_i
    let mut best = 0
    while j < n_segs && segs[j].start < b {
      let s = segs[j]
      let raw = raws[j]
      if raw.length() > 0 {
        let from = ((a - s.start) / level_step).floor().to_int()
        let to = ((b - s.start) / level_step).floor().to_int()
        let v = seg_peak(raw, mips[j], from, to)
        if v > best {
          best = v
        }
      }
      j += 1
    }
    if best > 0 {
      any = true
      out[idx] = best
    }
  }
  (out, any)
}
