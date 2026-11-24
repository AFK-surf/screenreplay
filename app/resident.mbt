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
extern "C" fn rp_tray_req_seq_get() -> Int = "rp_tray_req_seq_get"

///|
extern "C" fn rp_tray_req_x_get() -> Int = "rp_tray_req_x_get"

///|
extern "C" fn rp_tray_req_y_get() -> Int = "rp_tray_req_y_get"

///|
extern "C" fn rp_note_req_seq_get() -> Int = "rp_note_req_seq_get"

///|
extern "C" fn rp_prepare_popup(kind : Int) -> Unit = "rp_prepare_popup"

///|
extern "C" fn rp_style_tray_win(wid : Int, w_pt : Double, h_pt : Double, px : Int, py : Int) -> Int = "rp_style_tray_win"

///|
extern "C" fn rp_style_note_win(wid : Int, w_pt : Double, h_pt : Double) -> Int = "rp_style_note_win"

///|
/// The window's hides and shows as last seen.
let turns_seen : Ref[Int] = Ref(0)

///|
let tray_req_seen : Ref[Int] = Ref(0)

///|
let note_req_seen : Ref[Int] = Ref(0)

///|
let inproc_tray_wid : Ref[Int] = Ref(0)

///|
let inproc_tray_pos : Ref[(Int, Int)] = Ref((0, 0))

///|
let popups_wired : Ref[Bool] = Ref(false)

///|
fn resident() -> Bool {
  @ui.env("REPLAY_RESIDENT") == "1"
}

///|
fn make_popup_window(wid : Int, what : String) -> (@view.View) -> Unit {
  if what == "tray" {
    fn(root) { tray_popup_window(wid, root) }
  } else {
    fn(root) { note_popup_window(wid, root) }
  }
}

///|
fn wire_inproc_popups() -> Unit {
  if popups_wired.val {
    return
  }
  popups_wired.val = true
  @ui.set_window_tree(make_popup_window, around=fn(c) {
    c.set_clear((@signals.untracked(c_s2) >> 8) & 0xFFFFFFL)
  })
  @ui.when_window_closed(fn(wid) {
    if inproc_tray_wid.val == wid {
      inproc_tray_wid.val = 0
    }
    if inproc_note_wid.val == wid {
      inproc_note_wid.val = 0
      if rp_window_shown() == 0 {
        clip_thumbs_forget_all()
        rp_frame_release()
      }
    }
  })
}

///|
fn check_popup_requests() -> Unit {
  let tseq = rp_tray_req_seq_get()
  if tseq != tray_req_seen.val {
    tray_req_seen.val = tseq
    let px = rp_tray_req_x_get()
    let py = rp_tray_req_y_get()
    inproc_tray_pos.val = (px, py)
    load_settings()
    status_rev.set(status_rev.untracked() + 1)
    let h = tray_height_for(@signals.untracked(recorder_code))
    if inproc_tray_wid.val > 0 {
      rp_style_tray_win(inproc_tray_wid.val, tray_w, h, px, py) |> ignore
    } else if @ui.windows_here() {
      rp_prepare_popup(1)
      let wid = @ui.window_open_spec(@ui.WindowSpec::new(
        role="tray",
        title="ScreenReplay Tray",
        w=tray_w,
        h=h,
        min_w=tray_w,
        min_h=304.0,
        inset=Some(true),
        what="tray",
      ))
      rp_prepare_popup(0)
      if wid > 0 {
        inproc_tray_wid.val = wid
        rp_style_tray_win(wid, tray_w, h, px, py) |> ignore
      }
    }
  }
  let nseq = rp_note_req_seq_get()
  if nseq != note_req_seen.val {
    note_req_seen.val = nseq
    match note_file_ask() {
      Some(a) if a.mode != "" => {
        if inproc_note_wid.val == 0 && a.id == last_note_id_closed.val {
          return
        }
        load_settings()
        inproc_note_ask.set(Some(a))
        let h = note_ask_height(a)
        if inproc_note_wid.val > 0 {
          rp_style_note_win(inproc_note_wid.val, note_w, h) |> ignore
        } else if @ui.windows_here() {
          rp_prepare_popup(2)
          let wid = @ui.window_open_spec(@ui.WindowSpec::new(
            role="note",
            title="ScreenReplay Note",
            w=note_w,
            h=h,
            min_w=note_w,
            min_h=note_line_h,
            inset=Some(true),
            what="note",
          ))
          rp_prepare_popup(0)
          if wid > 0 {
            inproc_note_wid.val = wid
            rp_style_note_win(wid, note_w, h) |> ignore
          }
        }
      }
      _ => ()
    }
  }
}

///|
/// The window kept when closed, and watched (the host tells the app nothing of its window shown or hidden by another
/// program: checked on the frame woken by WM_CLOSE / SWP_SHOWWINDOW via on_frame_take, and every 200 ms as fallback).
fn stay_resident(root : @view.View) -> Unit {
  if !resident() || rp_stay_resident() != 1 {
    return
  }
  wire_inproc_popups()
  turns_seen.val = rp_window_turns()
  @ui.on_message_said("rp.wake", fn(_, _) {
    check_turns()
    true
  })
  watch_turns(root)
}

///|
fn check_turns() -> Unit {
  if @ui.current_window_id() != 0 {
    return
  }
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
  check_popup_requests()
}

///|
fn watch_turns(root : @view.View) -> Unit {
  check_turns()
  again(root, 200.0, fn() { watch_turns(root) })
}

///|
extern "C" fn rp_play_release() -> Unit = "rp_play_release"

///|
extern "C" fn rp_thumb_release() -> Unit = "rp_thumb_release"

///|
extern "C" fn rp_frame_release() -> Unit = "rp_frame_release"

///|
/// Started hidden and not shown yet: the folder not read, no picture decoded, the saved clips not listed till it
/// first shows (as_opened does it then), so a window kept for later holds no decoder, no index and no files (before,
/// it read and decoded all of it at once, 200 MB and 100 MB of the GPU's memory, for a window that may not be opened
/// for hours). The root its first show starts the folder's reading in.
let first_show_waits : Ref[@view.View?] = Ref(None)

///|
/// True while started hidden and before its first real show has loaded the buffer (keeps the primed frame from
/// flashing "Nothing recorded yet").
let awaiting_first_show : @signals.Signal[Bool] = @signals.signal(false)

///|
/// Whether it was started hidden and has not shown since.
fn hidden_unshown() -> Bool {
  resident() && @ui.env("REPLAY_HIDDEN") == "1" && rp_window_shown() == 0
}

///|
/// What it holds for playing let go of, kept as it shows: the sound's decoder, the files kept open, the thumbnail
/// worker's device and file, the copy's device, the tracks read, the pictures made for previews (each made again
/// when next asked for; the picture's stream stays, so showing it again is at once).
fn let_go_while_hidden() -> Unit {
  ntrace("put away: what it holds let go of")
  match native_made.val {
    Some(d) => d.rest()
    None => ()
  }
  rp_play_release()
  rp_thumb_release()
  rp_frame_release()
  tracks_read.clear()
  clip_history_free()
  hover_images.forget_all()
  seg_images_forget_all()
  clip_thumbs_forget_all()
  sidecars_clear()
  app_names.clear()
  app_names_missed.clear()
  // (a crop being exported keeps its dialog, and its preview)
  if export_out.untracked() == "" {
    crop_images.forget_all()
  }
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
  let_go_while_hidden()
  rp_resident_hidden()
}

///|
/// Shown: as a window just opened.
fn as_opened() -> Unit {
  // (started hidden, shown for the first time: the folder read every 3 s from now; saved clips deferred briefly so
  // the buffer and first video frame show ahead of scanning the clips folder)
  let mut defer_clips : @view.View? = None
  match first_show_waits.val {
    Some(root) => {
      first_show_waits.val = None
      awaiting_first_show.set(false)
      again(root, 3000.0, fn() { refresh(root, false) })
      defer_clips = Some(root)
    }
    None => ()
  }
  ask_flush()
  // (the apps' names read again: the recorder may have found a better one meanwhile)
  app_names.clear()
  app_icons_found.clear()
  load()
  status_rev.set(status_rev.untracked() + 1)
  if rp_take_request(cstr(pjoin(root_dir(), "settings.request"))) != 0 {
    load_settings()
    settings_open.set(true)
  }
  consent_check()
  follow_latest.set(true)
  keep_view()
  if !segs.is_empty() {
    seek_to(span() - 30000.0)
  }
  match defer_clips {
    Some(root) => root.at_moment(now() + 80.0, fn() { load_clips() }) |> ignore
    None => ()
  }
}

///|
extern "C" fn rp_start_hidden() -> Unit = "rp_start_hidden"

///|
extern "C" fn rp_start_resident_hidden() -> Unit = "rp_start_resident_hidden"

///|
extern "C" fn rp_resident_primed() -> Unit = "rp_resident_primed"

///|
extern "C" fn rp_resident_hidden() -> Unit = "rp_resident_hidden"

///|
extern "C" fn rp_set_bg_rgb(rgb : Int) -> Unit = "rp_set_bg_rgb"

///|
/// Started hidden where the recorder starts it resident (REPLAY_HIDDEN=1): its window made DWM-cloaked for its first
/// frame so shaders and the UI shell are already presented when first activated, then hidden cleanly.
fn start_hidden() -> Unit {
  if resident() && @ui.env("REPLAY_HIDDEN") == "1" {
    rp_start_resident_hidden()
  }
}
