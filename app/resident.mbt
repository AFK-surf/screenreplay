// Resident (the user's ask, 2026-11-13: 「做成常驻，瞬开」): started by the recorder with REPLAY_RESIDENT=1, hidden, the
// window is kept from then on: closed, it is only hidden (replay_win.c's rp_stay_resident), and shown again by the
// recorder at once. Hidden, it stops and puts away what was open (playing, a dialog, a menu, clip mode, full screen);
// shown, it is as a window just opened: the folder read again, the recorder asked to close what it writes, the view
// on the newest, the playhead 30 s before it.

///|
extern "C" fn rp_stay_resident() -> Int = "rp_stay_resident"

///|
extern "C" fn rp_window_turns() -> Int = "rp_window_turns"

///|
/// The window's hides and shows as last seen.
let turns_seen : Ref[Int] = Ref(0)

///|
fn resident() -> Bool {
  @ui.env("REPLAY_RESIDENT") == "1"
}

///|
/// The window kept when closed, and watched (the host tells the app nothing of its window shown or hidden by another
/// program: asked every 200 ms, nothing drawn for it).
fn stay_resident(root : @view.View) -> Unit {
  if !resident() || rp_stay_resident() != 1 {
    return
  }
  turns_seen.val = rp_window_turns()
  watch_turns(root)
}

///|
fn watch_turns(root : @view.View) -> Unit {
  let now_turns = rp_window_turns()
  let was = turns_seen.val
  if now_turns != was {
    turns_seen.val = now_turns
    if now_turns >> 16 != was >> 16 {
      put_away()
    }
    if (now_turns & 0xFFFF) != (was & 0xFFFF) {
      as_opened()
    }
  }
  again(root, 200.0, fn() { watch_turns(root) })
}

///|
/// Hidden: playing stopped, what was open put away.
fn put_away() -> Unit {
  set_playing(false)
  close_menu()
  window_options_open.set(false)
  if export_out.untracked() == "" {
    export_open.set(false)
  }
  settings_open.set(false)
  consent_open.set(false)
  library_open.set(false)
  if clip_playing.untracked() != "" {
    close_clip_player()
  }
  clipping.set(false)
  clear_windows()
  saved.set("")
  if full_screen.untracked() {
    set_full_screen(false)
  }
}

///|
/// Shown: as a window just opened.
fn as_opened() -> Unit {
  ask_flush()
  // (the apps' names read again: the recorder may have found a better one meanwhile)
  app_names.clear()
  app_icons_found.clear()
  load()
  status_rev.set(status_rev.untracked() + 1)
  if rp_take_request(cstr(root_dir() + "\\settings.request")) != 0 {
    load_settings()
    settings_open.set(true)
  }
  consent_check()
  follow_latest.set(true)
  keep_view()
  if !segs.is_empty() {
    seek_to(span() - 30000.0)
  }
}

///|
extern "C" fn rp_start_hidden() -> Unit = "rp_start_hidden"

///|
/// Started hidden where the recorder starts it resident (REPLAY_HIDDEN=1): its window made but not shown.
fn start_hidden() -> Unit {
  if resident() && @ui.env("REPLAY_HIDDEN") == "1" {
    rp_start_hidden()
  }
}
