// Whether it plays, told over the picture (the user's 「播放和停止状态不太明显」, B of the reviewer's 80th): as it starts
// or stops, its mark in the picture's middle a moment (a 64 disc, 55% black, the mark 28 white: what just happened),
// going from 0.8 to 1.25 as it fades from 95% over 500 ms; and while it stands, 「已暂停」 at the picture's top left
// (not while a part of the picture is kept for the clip: a window picked, a region).

///|
/// Each time playing truly starts or stops: a count, and whether it plays now.
let play_told : @signals.Signal[(Int, Bool)] = @signals.signal((0, false), same=fn(a, b) { a == b })

///|
/// Whether the window's bars are wanted now (chrome's): in full screen, gone as the bars go.
let bars_wanted : Ref[() -> Bool] = Ref(fn() { true })

///|
/// Playing started or stopped (`was` what it was): told where it changed.
fn tell_playing(was : Bool, now_on : Bool, told? : @signals.Signal[(Int, Bool)] = play_told) -> Unit {
  if was != now_on {
    told.set((told.untracked().0 + 1, now_on))
  }
}

///|
/// The saved clips' player's (library_view.mbt): told as its own plays or stops.
let clip_told : @signals.Signal[(Int, Bool)] = @signals.signal((0, false), same=fn(a, b) { a == b })

///|
/// The mark a moment in the picture's middle, and the badge at its top left; drawn over the picture, under the bars,
/// pressed through.
fn play_state_over(
  pic : @view.View,
  told? : @signals.Signal[(Int, Bool)] = play_told,
  playing? : () -> Bool = fn() { want_play.get() },
  // (not over a part of the picture kept for the clip: a window picked, a region drawn or being drawn)
  badge_may? : () -> Bool = fn() { has_segs() && (bars_wanted.val)() && !cropping() },
) -> Unit {
  let white = fn() { 0xFFFFFFFFL }
  pic.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    o.box(fn(f) {
      let way = @motion.NodeWay::new(1.0)
      f.reacts(fn() { told.get() }, fn(v) {
        if v.0 > 0 {
          // (REPLAY_SLOW_FLASH=1: ten times as long, for a picture of it taken by a tool slower than its frames)
          let slow = if @ui.env("REPLAY_SLOW_FLASH") == "1" { 10.0 } else { 1.0 }
          way.go_from(f, 0.0, 1.0, @motion.tween(slow * (if motion_off() { 300.0 } else { 500.0 }), ease=Out))
        }
      })
      f
      .width(Is(Some(64.0)))
      .height(Is(Some(64.0)))
      .radius(Is(32.0))
      .ground(Is(0x0000008CL))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .alpha(By(fn() {
        let e = way.shown(f)
        if e >= 1.0 {
          0.0
        } else if motion_off() {
          0.95
        } else {
          0.95 * (1.0 - e)
        }
      }))
      .scale(By(fn() { if motion_off() { 1.0 } else { 0.8 + 0.45 * way.shown(f) } }))
      |> ignore
      @sf.icon_node(f, "", 28.0, By(white), name_now=fn() { if told.get().1 { "play" } else { "pause" } })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  // the badge: while it stands with something recorded; not while the playhead or the timeline is held (back 300 ms
  // after), nor in full screen once the bars have gone
  let held_lately : @signals.Signal[Bool] = @signals.signal(false)
  pic.reacts(fn() { grabbed.get() != 0 }, fn(held) {
    if held {
      held_lately.set(true)
    } else {
      pic.at_moment(pic.cause_at() + 300.0, fn() { if grabbed.untracked() == 0 { held_lately.set(false) } }, later=true)
      |> ignore
    }
  })
  pic.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))) |> ignore
    o.box(fn(b) {
      let shows = fn() { !playing() && !held_lately.get() && badge_may() }
      let way = @motion.NodeWay::new(if @signals.untracked(shows) { 1.0 } else { 0.0 })
      b.reacts(shows, fn(on) { way.go_ms(b, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else { 120.0 }) })
      b
      .row(Is(true))
      .height(Is(Some(22.0)))
      .padding(Is((8.0, 0.0, 8.0, 0.0)))
      .gap(Is(6.0))
      .radius(Is(5.0))
      .ground(Is(0x00000099L))
      .lines_up(Is(Some(Middle)))
      .offset(Is((12.0, 12.0)))
      .alpha(By(fn() { way.shown(b) }))
      .laid_nowhere(By(fn() { way.shown(b) <= 0.0 }))
      |> ignore
      @sf.icon_node(b, "pause", 10.0, By(white)) |> ignore
      words(b, fn() { t("已暂停") }, 12.0, white) |> ignore
    })
    |> ignore
  })
  |> ignore
}
