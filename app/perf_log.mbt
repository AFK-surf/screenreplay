// While it plays, a line every 5 s into the folder's perf.log (the reviewer's 64th: how much CPU in the user's own use,
// not a test window's behind others): the process's CPU (% of one core), whether the window was in front, minimized,
// shown, the speed. Nothing of what is shown or of other windows; kept under 1 MB. (Frames are not counted: the app
// sees no frame of its own, a binding being asked more than once a frame.)

///|
extern "C" fn rp_window_state() -> Int = "rp_window_state"

///|
fn perf_watch(root : @view.View) -> Unit {
  let last : Ref[(Double, Double)] = Ref((now(), @hostapi.cpu_ms()))
  fn tick() -> Unit {
    let t = now()
    let cpu = @hostapi.cpu_ms()
    let (t0_, c0) = last.val
    if want_play.untracked() && t > t0_ {
      let span = t - t0_
      let st = rp_window_state()
      let line = "{\"at\":\{rp_now().to_int64()},\"cpu\":\{((cpu - c0) * 100.0 / span).round()},\"front\":\{st & 1},\"min\":\{(st >> 1) & 1},\"shown\":\{(st >> 2) & 1},\"speed\":\{speed.untracked()}}\n"
      let path = pjoin(root_dir(), "perf.log")
      if rp_size(cstr(path)) > 1048576.0 {
        rp_write(cstr(path), @utf8.encode(line)) |> ignore
      } else {
        rp_append(cstr(path), @utf8.encode(line)) |> ignore
      }
    }
    last.val = (t, cpu)
    again(root, 5000.0, tick)
  }
  root.at_moment(now() + 5000.0, tick, later=true) |> ignore
}
