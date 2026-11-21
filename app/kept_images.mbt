// The pictures handed to mbui (@ui.add_image) let go of again (@ui.forget_image) once nothing can show them: mbui keeps
// an image's encoded bytes as long as its key is named, its decodes under a budget of their own. Before, every
// thumbnail, hover preview and crop preview ever made was kept for the window's life (a resident window runs for
// days): a segment's index pictures (ix:) are let go of as the segment leaves the buffer; a saved clip's first
// picture (mem:saved-clip-) as the clip changes or leaves the folder; a GIF's or a clip's hover frames (gx:, cx:) and
// the crop previews (mem:crop-) are kept to the newest few (what shows is always the newest).

///|
/// The index pictures handed over, by the segment they are of.
let seg_images : Map[String, Array[String]] = Map([])

///|
/// A picture of segment `path` handed over as `key`.
fn seg_image_kept(path : String, key : String) -> Unit {
  match seg_images.get(path) {
    Some(keys) => keys.push(key)
    None => seg_images[path] = [key]
  }
}

///|
/// The pictures of segment `path` let go of (it has left the buffer).
fn seg_images_forget(path : String) -> Unit {
  match seg_images.get(path) {
    Some(keys) => {
      for k in keys {
        @ui.forget_image(k)
      }
      seg_images.remove(path)
    }
    None => ()
  }
}

///|
/// Pictures kept to the newest `cap` of their kind, oldest first.
priv struct Newest {
  cap : Int
  keys : Array[String]
}

///|
fn Newest::keep(self : Newest, key : String) -> Unit {
  self.keys.push(key)
  if self.keys.length() > self.cap {
    let drop = self.keys.length() - self.cap
    for i in 0..<drop {
      @ui.forget_image(self.keys[i])
    }
    let rest = self.keys[drop:].to_owned()
    self.keys.clear()
    self.keys.append(rest)
  }
}

///|
fn Newest::forget_all(self : Newest) -> Unit {
  for k in self.keys {
    @ui.forget_image(k)
  }
  self.keys.clear()
  self.keys.shrink_to_fit()
}

///|
/// The hover previews of saved clips and GIFs (cx:, gx:): one shows at a time.
let hover_images : Newest = { cap: 400, keys: [] }

///|
/// The save dialog's crop previews (mem:crop-): one shows at a time, each up to 480 x 270.
let crop_images : Newest = { cap: 6, keys: [] }

///|
/// Each saved clip's first picture as handed over (its key), by the clip's path.
let clip_thumb_keys : Map[String, String] = Map([])

///|
/// Clip `path`'s first picture handed over as `key`: one it had before under another key (the file changed) let go of.
fn clip_thumb_kept(path : String, key : String) -> Unit {
  match clip_thumb_keys.get(path) {
    Some(was) if was != key => @ui.forget_image(was)
    _ => ()
  }
  clip_thumb_keys[path] = key
}

///|
/// What is kept of clips no longer in the folder (`names`, the folder's now) let go of: their first pictures, their
/// lengths and leads read once.
fn clips_gone_forget(dir : String, names : Array[String]) -> Unit {
  let here : Map[String, Bool] = Map([])
  for n in names {
    here[dir + "\\" + n] = true
  }
  let gone : Array[String] = []
  for path, key in clip_thumb_keys {
    if !here.contains(path) {
      @ui.forget_image(key)
      gone.push(path)
    }
  }
  for path in gone {
    clip_thumb_keys.remove(path)
  }
  let stale : Array[String] = []
  for path, _ in clip_durations {
    if !here.contains(path) {
      stale.push(path)
    }
  }
  for path, _ in clip_leads {
    if !here.contains(path) {
      stale.push(path)
    }
  }
  for path, _ in gif_lengths {
    if !here.contains(path) {
      stale.push(path)
    }
  }
  for path, _ in saved_clip_codecs {
    if !here.contains(path) {
      stale.push(path)
    }
  }
  for path in stale {
    saved_clip_codecs.remove(path)
    clip_durations.remove(path)
    clip_leads.remove(path)
    gif_lengths.remove(path)
  }
}
