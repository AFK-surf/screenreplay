// Undo and redo in clip mode (the user, 2026-11-14: 「ctrl z 之类的好像对 clip 状态无效」): what the clip is (its two
// ends, its kind, the region and its ratio, the window picked) taken before each thing done to it (a press on the band
// or the picture, a key that changes it, a kind or ratio chosen), and a step kept only where it changed something. So
// a drag is one step, however many moves it made. Ctrl+Z goes back, Ctrl+Y or Ctrl+Shift+Z forward; entering clip mode
// starts with none.

///|
#derive(Eq)
priv struct ClipSnap {
  a : Double
  b : Double
  kind : Int
  region : (Double, Double, Double, Double)?
  ratio : Int
  hwnd : Int64
  name : String
  process : String
}

///|
let clip_undos : Array[ClipSnap] = []

///|
let clip_redos : Array[ClipSnap] = []

///|
/// The clip as it was at the last mark.
let clip_marked : Ref[ClipSnap?] = Ref(None)

///|
/// Told each time the steps kept change (the bar's 撤销 and 重做 keys lit or not by it).
let clip_steps : @signals.Signal[Int] = @signals.signal(0)

///|
fn clip_steps_told() -> Unit {
  clip_steps.set(clip_steps.untracked() + 1)
}

///|
/// What the clip is now, read (bound where it is read by a binding).
fn clip_now() -> ClipSnap {
  {
    a: clip_a.get(),
    b: clip_b.get(),
    kind: clip_kind.get(),
    region: region.get(),
    ratio: region_ratio.get(),
    hwnd: picked_hwnd.get(),
    name: picked_name.get(),
    process: picked_process.get(),
  }
}

///|
/// Whether Ctrl+Z would change anything (bound): a step kept, or the clip changed since the last mark.
fn clip_can_undo() -> Bool {
  clip_steps.get() |> ignore
  !clip_undos.is_empty() ||
  (match clip_marked.val {
    Some(was) => was != clip_now()
    None => false
  })
}

///|
/// Whether Ctrl+Y would (bound): a step undone and nothing changed since.
fn clip_can_redo() -> Bool {
  clip_steps.get() |> ignore
  !clip_redos.is_empty() &&
  (match clip_marked.val {
    Some(was) => was == clip_now()
    None => true
  })
}

///|
fn clip_snap() -> ClipSnap {
  @signals.untracked(fn() {
    {
      a: clip_a.get(),
      b: clip_b.get(),
      kind: clip_kind.get(),
      region: region.get(),
      ratio: region_ratio.get(),
      hwnd: picked_hwnd.get(),
      name: picked_name.get(),
      process: picked_process.get(),
    }
  })
}

///|
/// A step begins: what changed since the last one kept (none kept where nothing did).
fn clip_mark() -> Unit {
  guard clipping.untracked() else { return }
  let now = clip_snap()
  match clip_marked.val {
    Some(was) if was != now => {
      clip_undos.push(was)
      clip_redos.clear()
    }
    _ => ()
  }
  clip_marked.val = Some(now)
  clip_steps_told()
}

///|
/// Clip mode entered: no steps yet, the clip as it starts the first mark.
fn clip_history_start() -> Unit {
  clip_undos.clear()
  clip_redos.clear()
  clip_marked.val = Some(clip_snap())
  clip_steps_told()
}

///|
fn clip_put(s : ClipSnap) -> Unit {
  clip_a.set(s.a)
  clip_b.set(s.b)
  clip_kind.set(s.kind)
  region.set(s.region)
  region_ratio.set(s.ratio)
  region_selected.set(false)
  region_grab.set(0)
  picked_hwnd.set(s.hwnd)
  picked_name.set(s.name)
  picked_process.set(s.process)
  clip_marked.val = Some(s)
  clip_steps_told()
}

///|
/// Ctrl+Z: the clip as it was before the last step; whether there was one.
fn clip_undo() -> Bool {
  guard clipping.untracked() else { return false }
  clip_mark()
  guard clip_undos.pop() is Some(s) else { return true }
  clip_redos.push(clip_snap())
  clip_put(s)
  true
}

///|
/// Ctrl+Y, Ctrl+Shift+Z: the step undone done again; whether in clip mode.
fn clip_redo() -> Bool {
  guard clipping.untracked() else { return false }
  clip_mark()
  guard clip_redos.pop() is Some(s) else { return true }
  clip_undos.push(clip_snap())
  clip_put(s)
  true
}
