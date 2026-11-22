// The scrub index (replay_index.cpp): a small picture about each second of every segment, made once in the
// background and kept on disk, read by the filmstrip and the hover preview so neither ever waits on a decoder.

///|
#borrow(dir)
extern "C" fn rp_idx_dir(dir : Bytes) -> Unit = "rp_idx_dir"

///|
#borrow(path)
extern "C" fn rp_idx_add(path : Bytes, dur : Double) -> Unit = "rp_idx_add"

///|
#borrow(path)
extern "C" fn rp_idx_add_clip(path : Bytes, dur : Double) -> Unit = "rp_idx_add_clip"

///|
#borrow(path)
extern "C" fn rp_idx_drop(path : Bytes) -> Unit = "rp_idx_drop"

///|
#borrow(path)
extern "C" fn rp_idx_prefer(path : Bytes) -> Unit = "rp_idx_prefer"

///|
#borrow(path)
extern "C" fn rp_idx_at(path : Bytes, ms : Double) -> Double = "rp_idx_at"

///|
#borrow(path)
extern "C" fn rp_idx_jpeg(path : Bytes, ms : Double) -> Bytes = "rp_idx_jpeg"

///|
extern "C" fn rp_idx_pending() -> Int = "rp_idx_pending"

///|
let index_ready : Ref[Bool] = Ref(false)

///|
fn index_start() -> Unit {
  if !index_ready.val {
    index_ready.val = true
    rp_idx_dir(cstr(pjoin(root_dir(), "Thumbs")))
  }
}

///|
/// The segment recorded at `abs` (ms since the epoch), if one was.
fn seg_at(abs : Double) -> Int? {
  let mut lo = 0
  let mut hi = segs.length() - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    let s = segs[mid]
    if abs < s.start {
      hi = mid - 1
    } else if abs >= s.start + s.dur {
      lo = mid + 1
    } else {
      return Some(mid)
    }
  }
  None
}

///|
/// Whether the segment recorded at moment `at` (ms into the buffer) could not be made previews of.
fn thumb_failed(at : Double) -> Bool {
  match seg_at(t0() + at) {
    None => false
    Some(i) => rp_idx_at(cstr(segs[i].path), t0() + at - segs[i].start) == -2.0
  }
}

///|
/// The image key of the index's picture for moment `at` (ms into the buffer), handed to the image cache the first time;
/// "" when nothing was recorded then or its picture is not made yet (that segment then made first).
fn thumb_key(at : Double) -> String {
  match seg_at(t0() + at) {
    None => ""
    Some(i) => {
      let s = segs[i]
      let inside = t0() + at - s.start
      let p = cstr(s.path)
      let ms = rp_idx_at(p, inside)
      if ms < 0.0 {
        if ms == -1.0 {
          rp_idx_prefer(p)
        }
        return ""
      }
      let key = "ix:\{s.path}:\{ms}"
      if !@ui.has_image(key) {
        let jpeg = rp_idx_jpeg(p, inside)
        if jpeg.length() == 0 {
          return ""
        }
        @ui.add_image(key, jpeg)
        // (let go of as the segment leaves the buffer: kept_images.mbt)
        seg_image_kept(s.path, key)
      }
      key
    }
  }
}
