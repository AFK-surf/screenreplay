// The replay window: the background recording's last hours on one timeline, played back, and a range of it saved as
// a video. Opened by the recorder (its tray icon, Ctrl+Alt+R), which says where the buffer is (REPLAY_ROOT).
//
// Made once as nodes of the window's tree (mbui's view): the title bar, the picture (the player, a native view of its
// own in the tree), and under it one dock: the timeline and the controls. What changes is bound to the signals it is
// worked out of (state.mbt); what the hand and the keys do is done in their handlers.

///|
extern "C" fn rp_exe_dir() -> Bytes = "rp_exe_dir"

///|
extern "C" fn rp_system_menu(x : Double, y : Double) -> Unit = "rp_system_menu"

///|
fn exe_dir() -> String {
  @utf8.decode_lossy(rp_exe_dir()[:])
}

///|
let title_h : Double = 40.0

///|
let key_w : Double = 46.0

///|
/// The folder read again every 3 s while the window is open (the recorder keeps adding to it and tells nothing); the
/// first time, the recorder asked to close what it is writing and the playhead put 30 s before the end.
fn refresh(root : @view.View, first : Bool) -> Unit {
  load()
  if clipping.untracked() {
    load_windows()
  } else if !snaps.is_empty() {
    // (clip mode left: the windows noted and the clip's steps let go of till it is entered again, which reads them anew)
    clear_windows()
    clip_history_free()
  }
  status_rev.set(status_rev.untracked() + 1)
  if rp_take_request(cstr(root_dir() + "\\settings.request")) != 0 {
    load_settings()
    settings_open.set(true)
  }
  if first {
    ask_flush()
    consent_check()
  } else if rp_window_shown() == 1 && !segs.is_empty() && @signals.untracked(recorder_status).1 &&
    rp_now() - (t0() + span()) > 6000.0 {
    // (while the window shows, what is being written closed whenever it is more than 6 s behind, so the timeline's
    // end keeps up with now: the user, 2026-11-14 「感觉timeline的更新好像有点慢」; a segment is closed only when it
    // has been 30 s long otherwise)
    ask_flush()
  }
  if current.val < 0 && !segs.is_empty() {
    keep_view()
    seek_to(span() - 30000.0)
  } else {
    keep_view()
  }
  again(root, 3000.0, fn() { refresh(root, false) })
}

///|
/// A recorder's status code in words (the recorder's own table: recorder/Program.cs, L.Status).
fn status_words(code : String, arg : String) -> String {
  match code {
    "recording" => t("后台录制中")
    "locked" => t("已锁屏，暂停中")
    "paused" => tf("已暂停，{0} 继续", [arg])
    "fullscreen" => t("全屏应用在前台，暂停中")
    "disabled" => t("后台录制已关闭")
    "diskLow" => t("磁盘空间不足，暂停录制")
    "noDisplay" => t("找不到主显示器")
    "startFailed" => t("录制没能开始")
    "noEncoder" => t("显卡不支持硬件视频编码，无法录制")
    _ => t("启动中…")
  }
}

///|
/// A window button: its glyph centred, its ground under the pointer (close: Windows' red, its glyph white).
fn window_key(
  parent : @view.View,
  label : () -> String,
  icon : () -> String,
  press : () -> Unit,
  close? : Bool = false,
  snap? : Bool = false,
) -> Unit {
  pressable(parent, label, press, fn(b) {
    // (the maximize key: the pointer over it is the host's (its snap layouts), which says how it stands on it)
    let lit = fn() { b.pointed() || b.pressed() || (snap && @ui.window_snap_state() != 0) }
    let held = fn() { b.pressed() || (snap && @ui.window_snap_state() == 2) }
    b
    .width(Is(Some(key_w)))
    .height(Is(Some(title_h)))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .cursor(Is(Some(Arrow)))
    .ground(By(fn() {
      let on = lit()
      if !on {
        0L
      } else if close {
        if held() { 0xB0271AFFL } else { 0xC42B1CFFL }
      } else if held() {
        tone(0xFFFFFF0FL, 0x0000000AL)
      } else {
        press_ground()
      }
    }))
    |> ignore
    @sf.icon_node(b, "", 12.0, By(fn() {
        let on = lit()
        if on && close {
          0xFFFFFFFFL
        } else if on {
          ui_text()
        } else {
          ui_muted()
        }
      }), name_now=icon)
    |> ignore
  })
  |> ignore
}

///|
/// The title bar, 40 high: the app's mark and name; in the middle the moment the playhead is at and how long ago; the
/// window's buttons as Windows 11 draws them. Its empty room moves the window (a double click maximizes it).
fn title_bar(parent : @view.View) -> Unit {
  parent.box(fn(bar) {
    bar.row(Is(true)).height(Is(Some(title_h))).lines_up(Is(Some(Middle))).ground(By(c_bg)) |> ignore
    // (empty room in the bar moves the window; a right click on it: the window's own menu, as on a system title bar)
    let moves = fn(v : @view.View) {
      v
      .presses(Is(true))
      .moves_window(Is(true))
      .on_menu(fn(m) { rp_system_menu(m.wx * v.pixel_scale(), m.wy * v.pixel_scale()) })
      |> ignore
    }
    // (the two sides one width, the wider's: so the middle is on the window's middle and never under either. Their
    // contents measured once laid out, again when what they say changes: a side grown by grow from basis 0 is laid out
    // narrower than what it holds where the room is short, mbui keeping no item at least as wide as its content)
    let side_need : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })
    let left_box : Ref[@view.View?] = Ref(None)
    let right_box : Ref[@view.View?] = Ref(None)
    // (not laid out yet, 0: looked at again 100 ms on)
    fn measure() -> Unit {
      match (left_box.val, right_box.val) {
        (Some(l), Some(r)) => {
          let w = @cmp.maximum(l.laid_size().0, r.laid_size().0).ceil()
          if w <= 0.0 {
            bar.at_moment(now() + 100.0, measure, later=true) |> ignore
          } else {
            side_need.set(w)
          }
        }
        _ => ()
      }
    }
    bar.reacts(fn() { recorder_status().0 + "|" + library_open.get().to_string() + "|" + is_english().to_string() }, fn(_) {
      bar.at_moment(now() + 30.0, measure, later=true) |> ignore
    })
    // the left side: the app's mark and name (the saved clips: back and their count)
    bar.box(fn(side) {
      side.row(Is(true)).grow(Is(1.0)).basis(Is(Some(0.0))).min_width(By(fn() { Some(side_need.get()) })).height(Is(Some(title_h))).lines_up(Is(Some(Middle))) |> ignore
      moves(side)
      side.box(fn(left) {
        left_box.val = Some(left)
        left.row(Is(true)).padding(Is((14.0, 0.0, 8.0, 0.0))).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
        left.pick(fn() { library_open.get() }, fn(b, lib) {
          b.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
          if lib {
            // (in the saved clips: back, and their count)
            icon_button(b, fn() { "chevron-left" }, fn() { t("回放") }, fn() { library_open.set(false) }, side=Bottom) |> ignore
            words(b, fn() { t("已保存片段") }, 12.0, ui_text, weight=500) |> ignore
            words(b, fn() {
              clips_rev.get() |> ignore
              tf("共 {0} 个", [clip_files.length().to_string()])
            }, 12.0, ui_subtle)
            |> ignore
          } else {
            app_logo(b, 16.0)
            words(b, fn() { "ScreenReplay" }, 12.0, ui_muted) |> ignore
          }
        }, at_once=true)
      })
      |> ignore
    })
    |> ignore
    // the middle: the moment the playhead is at, how long ago and the app then; in clip mode a pill, 剪辑. Between two
    // sides of one width (each half of what it leaves), so on the window's middle; where a side needs more than its
    // half (a narrow window, a long word of the recorder's), the middle gives way, the app's name first, never under it
    // (the user, 2026-11-14: 「文字有重叠」)
    bar.box(fn(o) {
      o.row(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)).gap(Is(10.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).clips(Is(true)) |> ignore
      moves(o)
      // (its parts laid out or not, not made anew: a part a pick makes sits in a slot of its own that never gives way,
      // so the app's name in one could not end in an ellipsis where the room is short)
      let kind = fn() { if library_open.get() || !has_segs() { 0 } else if clipping.get() { 1 } else { 2 } }
      let app_now = fn() {
        data()
        app_at(pos_drawn(o))
      }
      o.box(fn(pill) {
        pill
        .laid_nowhere(By(fn() { kind() != 1 }))
        .height(Is(Some(22.0)))
        .padding(Is((10.0, 0.0, 10.0, 0.0)))
        .radius(Is(11.0))
        .ground(By(c_s3))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        |> ignore
        words(pill, fn() { t("剪辑") }, 12.0, ui_text, weight=500) |> ignore
      })
      |> ignore
      words(o, fn() {
        let at = t0() + pos_drawn(o)
        day_name(at) + " " + wall(at)
      }, 12.0, ui_text, weight=500)
      .laid_nowhere(By(fn() { kind() != 2 }))
      .shrink(Is(0.01))
      .min_width(Is(Some(0.0)))
      .allow_ellipsis(Is(true))
      |> ignore
      // (giving way the app's name first, then how long ago, the moment last)
      words(o, fn() { ago(t0() + pos_drawn(o)) }, 12.0, ui_muted)
      .laid_nowhere(By(fn() { kind() != 2 }))
      .shrink(Is(0.05))
      .min_width(Is(Some(0.0)))
      .allow_ellipsis(Is(true))
      |> ignore
      // (the dot before it one with it: it goes as the name does)
      words(o, fn() { "·   " + app_name(app_now()) }, 12.0, ui_muted)
      .laid_nowhere(By(fn() { kind() != 2 || app_now() == "" }))
      .shrink(Is(400.0))
      .min_width(Is(Some(0.0)))
      .allow_ellipsis(Is(true))
      |> ignore
    })
    |> ignore
    // the right side: the recorder's chip, the folder and settings keys, the window's keys
    bar.box(fn(side) {
      side.row(Is(true)).grow(Is(1.0)).basis(Is(Some(0.0))).min_width(By(fn() { Some(side_need.get()) })).height(Is(Some(title_h))).lines_up(Is(Some(Middle))).lies_along(Is(End)) |> ignore
      moves(side)
      side.box(fn(content) {
        right_box.val = Some(content)
        content.row(Is(true)).height(Is(Some(title_h))).lines_up(Is(Some(Middle))) |> ignore
        content.box(fn(tools) {
          tools.row(Is(true)).gap(Is(2.0)).padding(Is((0.0, 0.0, 6.0, 0.0))).lines_up(Is(Some(Middle))) |> ignore
          recorder_chip(tools)
          // (the saved clips' key, a stack of clips (the folder read as 「open a folder」: the user, 2026-11-15); on
          // their page, the key that opens their folder)
          icon_button(tools, fn() { if library_open.get() { "folder" } else { "clips" } }, fn() { if library_open.get() { t("打开文件夹") } else { t("已保存片段") } }, fn() {
            if library_open.untracked() {
              rp_mkdirs(cstr(clips_dir())) |> ignore
              if rp_launch(cstr(clips_dir())) == 0 {
                library_message.set(t("文件夹未能打开"))
              }
              return
            }
            set_playing(false)
            clips_read()
            library_open.set(true)
          }, side=Bottom)
          |> ignore
          icon_button(tools, fn() { "settings" }, fn() { t("设置") }, fn() {
            load_settings()
            purge_state.set(0)
            settings_open.set(true)
          }, shortcut="settings", side=Bottom)
          |> ignore
        })
        |> ignore
        window_key(content, fn() { t("最小化") }, fn() { "minus" }, fn() { @ui.window_act(1) })
        window_key(content, fn() { if @ui.window_zoomed() { t("还原") } else { t("最大化") } }, fn() {
          if @ui.window_zoomed() {
            "copy"
          } else {
            "square"
          }
        }, fn() { @ui.window_act(2) }, snap=true)
        window_key(content, fn() { t("关闭") }, fn() { "close" }, fn() { @ui.window_act(3) }, close=true)
      })
      |> ignore
    })
    |> ignore
    // (the maximize button the host's as well, for Snap Layouts: the second from the right)
    let snap = bar.by_room(fn(_, room) {
      bar.reacts(fn() { room.width() }, fn(w) { @ui.window_snap(w - key_w * 2.0, 0.0, key_w, title_h) })
    })
    snap.over(Is(true)).presses(Is(false)) |> ignore
  })
  |> ignore
}

///|
/// The picture on the stage, in the well, as large as it fits with no margin, corner or hairline round it (the user,
/// 2026-11-14: 「视频的四周的padding感觉不需要」), at its own shape; filling the screen edge to edge in full screen. A press plays or pauses, a double
/// press fills the screen or comes back.
fn picture(parent : @view.View) -> Unit {
  parent.box(fn(stage) {
    stage
    .grow(Is(1.0))
    .over(By(fn() { full_screen.get() }))
    .ground(By(fn() { if full_screen.get() { picture_ground } else { well() } }))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .clips(Is(true))
    |> ignore
    stage.pick(fn() { has_segs() }, fn(b, any) {
      if any {
        b.grow(Is(1.0)).fills_across(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
        b.box(fn(pic) {
          pic
          .aspect(By(fn() { picture_aspect.get() }))
          .height_share(Is(1.0))
          .max_width(Is(None), within=true)
          .ground(Is(picture_ground))
          .clips(Is(true))
          .presses(Is(true))
          .on_press(fn() { set_playing(!want_play.untracked()) })
          .on_double_press(fn() { set_full_screen(!full_screen.untracked()) })
          .on_wheel_moves(pic_wheel)
          .on_menu(fn(m) { open_moment_menu(m.wx, m.wy, pos_now(), true) })
          .on_pointer_moved(fn() {
            (pointer_moved.val)()
            // (where it is over the picture, for the window picker as clip mode begins under a still pointer)
            picker_at.set(pic.pointer_here())
          })
          |> ignore
          // (dragged, the real frames: never the index's picture over it, the user's 「画面会变糊…有闪烁」 of 2026-11-14)
          native()
          .picture(pic)
          .grow(Is(1.0))
          .ground(Is(picture_ground))
          |> pic_zoomed_node
          play_state_over(pic)
          pic_zoom_pill(pic)
          window_picker(pic)
        })
        |> ignore
      } else {
        b.show(fn() { !awaiting_first_show.get() }, fn(e) {
          e.lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
          @sf.icon_node(e, "monitor", 32.0, By(ui_subtle)) |> ignore
          words(e, fn() { t("还没有录像") }, 15.0, ui_text, weight=600) |> ignore
          words(e, fn() { t("后台录制开始后，最近的录像会出现在这里") }, 12.0, ui_subtle) |> ignore
        }, at_once=true)
        |> ignore
      }
    }, at_once=true)
    saved_note(stage)
    told_layer(stage)
  })
  |> ignore
}

///|
/// The window filling its screen (1), back (0), or only asked (-1): whether it fills it now.
extern "C" fn rp_fullscreen(on : Int) -> Int = "rp_fullscreen"

///|
fn set_full_screen(on : Bool) -> Unit {
  full_screen.set(rp_fullscreen(if on { 1 } else { 0 }) == 1)
}

///|
/// The row under the timeline, 40 high: left the marker, full screen and the volume; the play key in the middle with
/// back and on; right back to the newest and the clip.
fn controls(parent : @view.View) -> Unit {
  parent.box(fn(row) {
    // (as tall as its tallest key, 保存/剪辑's 32: 40 left room round them for nothing, the user, 2026-11-16)
    row.row(Is(true)).height(Is(Some(32.0))).margin(Is((0.0, 6.0, 0.0, 0.0))).lines_up(Is(Some(Middle))) |> ignore
    let play_key = fn(b : @view.View, press : () -> Unit) { play_button(b, press) }
    row.box(fn(left) {
      left.row(Is(true)).grow(Is(1.0)).basis(Is(Some(0.0))).gap(Is(2.0)).lines_up(Is(Some(Middle))).clips(Is(true)) |> ignore
      left.pick(fn() { clipping.get() }, fn(b, clip) {
        b.row(Is(true)).gap(Is(2.0)).lines_up(Is(Some(Middle))) |> ignore
        if clip {
          window_bar(b)
        } else {
          // (a toggle: filled where a marker is at the playhead, pressed it takes that one away)
          icon_button(b, fn() {
              match the_root.val {
                Some(r) if mark_at_playhead(r) is Some(_) => "bookmark-on"
                _ => "bookmark"
              }
            }, fn() {
              match the_root.val {
                Some(r) if mark_at_playhead(r) is Some(_) => t("移除这里的标记")
                _ => t("在当前位置加标记")
              }
            }, fn() {
              match the_root.val {
                Some(r) => toggle_marker(r)
                None => ()
              }
            }, shortcut="mark")
          |> ignore
          icon_button(b, fn() { if full_screen.get() { "unfull" } else { "full" } }, fn() {
              if full_screen.get() {
                t("退出全屏")
              } else {
                t("全屏")
              }
            }, fn() {
              set_full_screen(!full_screen.untracked())
            }, shortcut="full")
          |> ignore
          volume_control(b)
        }
      }, at_once=true)
    })
    |> ignore
    // the middle: the play key at the very middle of the window, back and forward either side of it, and beyond them
    // two slots of one width, so what is in them never moves the play key (the user, 2026-11-14: 「好像没居中」): on its
    // left in clip mode where the playhead is in the clip (0:12 / 0:30, as Steam's editor has it), on its right the
    // speed
    row.box(fn(mid) {
      mid.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
      let slot_w = 112.0
      mid.box(fn(l) {
        l.row(Is(true)).width(Is(Some(slot_w))).lines_up(Is(Some(Middle))).lies_along(Is(End)).padding(Is((0.0, 0.0, 6.0, 0.0))) |> ignore
        l.show(fn() { clipping.get() }, fn(b) {
          // (its digits all one width (the theme's tabular figures), so nothing shifts as the seconds go)
          words(b, fn() {
            // (on the clip's own times: what the seams leave out not counted, as the saved clip has it)
            let (a, z) = (clip_a.get(), clip_b.get())
            let at = clip_time(clamp(pos_drawn(b), a, z))
            clock(at) + " / " + clock(clip_kept())
          }, 13.0, ui_muted, weight=500) |> ignore
        }, at_once=true)
        |> ignore
      })
      |> ignore
      icon_button(mid, fn() { "back-15" }, fn() { t("后退 15 秒") }, fn() { jump_by(-15000.0) }, shortcut="back15") |> ignore
      // (in clip mode play goes on from where it was in the clip, from its start past it)
      play_key(mid, fn() {
        if clipping.untracked() {
          if want_play.untracked() {
            set_playing(false)
          } else {
            play_clip()
          }
        } else {
          set_playing(!want_play.untracked())
        }
      })
      icon_button(mid, fn() { "forward-15" }, fn() { t("前进 15 秒") }, fn() { jump_by(15000.0) }, shortcut="on15") |> ignore
      mid.box(fn(r) {
        r.row(Is(true)).width(Is(Some(slot_w))).lines_up(Is(Some(Middle))).lies_along(Is(Start)).padding(Is((6.0, 0.0, 0.0, 0.0))) |> ignore
        speed_key(r)
      })
      |> ignore
    })
    |> ignore
    row.box(fn(right) {
      right.row(Is(true)).grow(Is(1.0)).basis(Is(Some(0.0))).gap(Is(10.0)).lines_up(Is(Some(Middle))).lies_along(Is(End)) |> ignore
      right.pick(fn() { clipping.get() }, fn(b, clip) {
        b.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
        if clip {
          window_options_button(b)
          // (undo and redo, as Ctrl+Z and Ctrl+Y: the user, 2026-11-14 「需要加上手动历史前进后退按钮」)
          b.box(fn(h) {
            h.row(Is(true)).gap(Is(2.0)).lines_up(Is(Some(Middle))) |> ignore
            for step in [("undo", true), ("redo", false)] {
              let (name, back) = step
              let can = fn() { if back { clip_can_undo() } else { clip_can_redo() } }
              icon_button(h, fn() { name }, fn() { if back { t("撤销") } else { t("重做") } }, fn() {
                if back {
                  clip_undo() |> ignore
                } else {
                  clip_redo() |> ignore
                }
              }, shortcut=name)
              .alpha(By(fn() { if can() { 1.0 } else { 0.35 } }))
              .presses(By(can))
              |> ignore
            }
          })
          |> ignore
          text_button(b, fn() { t("取消") }, fn() { clipping.set(false) }, ghost=true) |> ignore
          let save_k = solid_button(b, fn() { t("保存…") }, open_export, icon="download", small=fn() {
            if cropping() {
              let (w, h, _, _, _) = export_plan()
              "\{w}×\{h} · " + size_text()
            } else {
              clock(clip_kept())
            }
          })
          tip(save_k, fn() { t("保存片段") }, shortcut="save")
        } else {
          // (under a filter of apps: how many of its stretches the timeline shows and how long they come to)
          b.show(fn() { filter_on() && ax_on() }, fn(x) {
            x.padding(Is((0.0, 0.0, 2.0, 0.0))) |> ignore
            words(x, filter_summary, 12.0, ui_subtle) |> ignore
          }, at_once=true)
          apps_key(b)
          zoom_key(b)
          b.show(fn() { !follow_latest.get() }, fn(x) {
            text_button(x, fn() { t("回到最新") }, show_latest, ghost=true) |> ignore
          }, at_once=true)
          let clip = text_button(b, fn() { t("剪辑") }, start_clip, icon="scissors")
          tip(clip, fn() { t("剪辑") }, shortcut="clip")
        }
      }, at_once=true)
    })
    |> ignore
  })
  |> ignore
}

///|
/// How fast it plays, pressed for the next speed (0.5× … 4×): the replay's, or what `now` and `set` say (a saved
/// clip's, on its dark `stage`).
fn speed_key(
  parent : @view.View,
  now? : () -> Double = fn() { speed.get() },
  set? : (Double) -> Unit = set_speed,
  stage? : Bool = false,
) -> Unit {
  let label = fn() {
    let s = now()
    if s == s.floor() {
      "\{s.to_int()}×"
    } else {
      "\{s}×"
    }
  }
  // (a menu of the speeds over it, up to 10× (the user, 2026-11-13: 「最快应该能到x10」「需要dropdown」), the one now
  // ticked)
  let key : Ref[@view.View?] = Ref(None)
  let k = pressable(parent, label, fn() {
    guard key.val is Some(b) else { return }
    let chosen = @signals.untracked(now)
    open_menu_under(
      b,
      speeds.map(fn(s) {
        let name = if s == s.floor() { "\{s.to_int()}×" } else { "\{s}×" }
        Some({ label: name, key: if s == chosen { "✓" } else { "" }, act: fn() { set(s) } })
      }),
      above=true,
    )
  }, fn(b) {
    let (hand, _) = answer(b)
    b
    .row(Is(true))
    .gap(Is(2.0))
    .padding(Is((8.0, 0.0, 5.0, 0.0)))
    .height(Is(Some(28.0)))
    .radius(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() {
      let on = if stage { stage_hover } else { c_s3() }
      mix(clear(on), on, hand.shown(b))
    }))
    |> ignore
    words(b, label, 12.0, fn() {
      if stage {
        mix(stage_muted, stage_text, hand.shown(b))
      } else {
        mix(ui_muted(), ui_text(), hand.shown(b))
      }
    }, weight=500)
    |> ignore
    b.box(fn(c) {
      c.width(Is(Some(10.0))).height(Is(Some(10.0))).picture(Is(Some(vector("M2.5 3.75 5 6.25 7.5 3.75", 10.0, 10.0, stroke=1.25)))).tint(By(fn() {
        if stage {
          mix(stage_subtle, stage_muted, hand.shown(b))
        } else {
          mix(ui_subtle(), ui_muted(), hand.shown(b))
        }
      })) |> ignore
    })
    |> ignore
  })
  key.val = Some(k)
}

///|
/// The zoom key (the user, 2026-11-13: 「找一个地方放一下缩放比例」, 「放控制行右边」): a magnifier, how long the view
/// is (as it changes: the wheel, the overview's ends, the keys), a chevron; pressed, a menu over it of 1, 5, 10, 30
/// minutes, an hour and all of it (none longer than the buffer), the one the view is ticked.
fn zoom_key(parent : @view.View) -> Unit {
  let key : Ref[@view.View?] = Ref(None)
  let k = pressable(parent, fn() { t("时间线缩放 · Ctrl+滚轮") }, fn() {
    guard key.val is Some(b) else { return }
    let total = view_total()
    let len = @signals.untracked(view_len)
    let entries : Array[MenuEntry?] = []
    for step in [(60000.0, "1 分钟"), (300000.0, "5 分钟"), (600000.0, "10 分钟"), (1800000.0, "30 分钟"), (3600000.0, "1 小时")] {
      if step.0 < total {
        entries.push(Some({ label: t(step.1), key: if (len - step.0).abs() < 1.0 { "✓" } else { "" }, act: fn() { zoom_to(step.0) } }))
      }
    }
    entries.push(Some({ label: t("全部"), key: if len >= total - 1.0 { "✓" } else { "" }, act: fn() { zoom_to(total) } }))
    open_menu_under(b, entries, above=true)
  }, fn(b) {
    let (hand, _) = answer(b)
    let ink = fn() { mix(ui_muted(), ui_text(), hand.shown(b)) }
    b
    .row(Is(true))
    .gap(Is(5.0))
    .padding(Is((8.0, 0.0, 8.0, 0.0)))
    .height(Is(Some(28.0)))
    .radius(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .ground(By(fn() { mix(clear(c_s3()), c_s3(), hand.shown(b)) }))
    // (nothing recorded, nothing to zoom: no 「0 秒」)
    .laid_nowhere(By(fn() { !has_segs() }))
    |> ignore
    b.box(fn(g) {
      g
      .width(Is(Some(14.0)))
      .height(Is(Some(14.0)))
      .picture(Is(Some(vectors(14.0, 14.0, [("M1.8 6a4.2 4.2 0 1 0 8.4 0a4.2 4.2 0 1 0-8.4 0z", 1.5), ("M9.2 9.2 12.5 12.5", 1.5)]))))
      .tint(By(ink))
      |> ignore
    })
    |> ignore
    words(b, fn() { view_len_words(view_len()) }, 12.0, ink, weight=500) |> ignore
    b.box(fn(c) {
      c.width(Is(Some(8.0))).height(Is(Some(8.0))).picture(Is(Some(vector("M1.5 3 4 5.5 6.5 3", 8.0, 8.0, stroke=1.25)))).tint(By(ink)) |> ignore
    })
    |> ignore
  })
  tip(k, fn() { t("时间线缩放 · Ctrl+滚轮") })
  key.val = Some(k)
}

///|
/// The dock: a hairline over it, 26 over, 20 either side, 10 under; the timeline and the controls row.
fn dock(parent : @view.View) -> Unit {
  rule(parent, hair)
  parent.box(fn(d) {
    // (its 18 over the timeline are the timeline's own: the pointer anywhere over the heat lane and the room above it
    // shows the hover card, the user, 2026-11-17 「触发preview的区域太小了，实际上应该也能包含heatmap以及上方padding部分」)
    d.ground(By(c_bg)).padding(Is((20.0, 0.0, 20.0, 6.0))) |> ignore
    d.show(fn() { has_segs() }, fn(b) { timeline(b) }, at_once=true)
    d.show(fn() { !has_segs() }, fn(b) { b.height(Is(Some(dock_over))) |> ignore }, at_once=true)
    controls(d)
  })
  |> ignore
}

///|
/// The replay's keys, as actions the keymap binds (none while a dialog is open).
fn key_bindings() -> @view.Keymap {
  let k = fn(code : Int, action : String, mods : Int) -> @view.Binding {
    { keys: [{ code, mods }], action, when: Always }
  }
  let ch = fn(c : Char, action : String, mods : Int) { k(@ui.key_of_char(c), action, mods) }
  let shift = @ui.mod_shift_key
  let keys = [
    k(@ui.key_space, "play", 0),
    ch('k', "play", 0),
    ch('f', "full", 0),
    k(@ui.key_escape, "escape", 0),
    k(@ui.key_code_enter, "save", 0),
    k(@ui.key_code_enter, "save-copy", shift),
    // (the arrows a frame, as an editor's; with Shift 5 s: the user, 2026-11-14 「键盘左右按键应该是按照帧来跳」)
    k(@ui.key_code_left, "frame-back", 0),
    k(@ui.key_code_right, "frame-on", 0),
    k(@ui.key_code_left, "back5", shift),
    k(@ui.key_code_right, "on5", shift),
    ch('j', "back15", 0),
    ch('l', "on15", 0),
    ch(',', "frame-back", 0),
    ch('.', "frame-on", 0),
    k(@ui.key_code_home, "home", 0),
    k(@ui.key_code_end, "latest", 0),
    // (a saved clip's player: the clip before and after)
    k(@ui.key_code_page_up, "page-back", 0),
    k(@ui.key_code_page_down, "page-on", 0),
    ch('=', "zoom-in", 0),
    ch('=', "zoom-in", shift),
    ch('+', "zoom-in", 0),
    ch('+', "zoom-in", shift),
    ch('-', "zoom-out", 0),
    ch('0', "pic-fit", 0),
    ch('[', "mark-back", 0),
    ch(']', "mark-on", 0),
    ch('i', "clip-start", 0),
    ch('o', "clip-end", 0),
    ch('c', "clip", 0),
    // (the frame shown, onto the clipboard: the user, 2026-11-16 「copy frame 感觉应该加个快捷键，比如ctrl c」)
    k(@ui.key_code_copy, "copy-frame", @ui.mod_ctrl),
    ch(',', "settings", @ui.mod_ctrl),
    ch('m', "mark", 0),
  ]
  keys.append(region_bindings())
  @view.Keymap::new(keys)
}

///|
/// What each of the replay's actions does, by its name (replay_actions).
let actions : Map[String, () -> Unit] = Map([])

///|
/// The actions a layer over the rest (a modal one: the keys reach nothing under it) does itself, as the window does
/// them (Escape closing what is open, Enter saving in the save dialog).
fn layer_keys(v : @view.View, names : Array[String]) -> Unit {
  for name in names {
    v.on_action(name, fn(_) {
      match actions.get(name) {
        Some(f) => {
          f()
          true
        }
        None => false
      }
    })
    |> ignore
  }
}

///|
/// What each of the replay's actions does. While the saved clips' page is over the replay, only Escape: the player
/// under it neither plays nor moves for its keys.
fn replay_actions(root : @view.View) -> Unit {
  let on = fn(name : String, f : () -> Unit) {
    actions.set(name, f)
    root.on_action(name, fn(_) {
      // (Escape and Settings work whether there is anything recorded or not)
      if (segs.is_empty() || library_open.untracked()) && name != "escape" && name != "settings" {
        return false
      }
      f()
      true
    })
    |> ignore
  }
  on("settings", fn() {
    if !consent_open.untracked() && !export_open.untracked() && clip_playing.untracked() == "" {
      load_settings()
      purge_state.set(0)
      settings_open.set(!settings_open.untracked())
    }
  })
  on("play", fn() {
    if clipping.untracked() {
      if want_play.untracked() {
        set_playing(false)
      } else {
        play_clip()
      }
    } else {
      set_playing(!want_play.untracked())
    }
  })
  on("full", fn() { set_full_screen(!full_screen.untracked()) })
  on("save", fn() { if export_open.untracked() { export_now(false) } else if clipping.untracked() { open_export() } })
  // (in export dialog: honor the dialog's chosen mode and copy; outside it: instant lossless save+copy when not cropping)
  on("save-copy", fn() {
    if export_open.untracked() {
      export_now(true)
    } else if clipping.untracked() {
      if !@signals.untracked(cropping) {
        save_clip(copy=true)
      } else {
        open_export()
        export_now(true)
      }
    }
  })
  on("escape", fn() {
    if window_options_open.untracked() {
      // (the window's options over their key (a menu of a kind: menu_up): they close, the window stays picked)
      window_options_open.set(false)
      menu_up.set(false)
    } else if menu_up.untracked() {
      close_menu()
    } else if av1_note.untracked() != "" {
      av1_note.set("")
    } else if consent_open.untracked() {
      // (the first run's sheet: the window hidden, as its close does, nothing written; read again, the sheet closes)
      if consent_reading.untracked() {
        consent_open.set(false)
      } else {
        @ui.window_act(3)
      }
    } else if clip_playing.untracked() != "" {
      // (full screen left before the player is closed)
      if full_screen.untracked() {
        set_full_screen(false)
      } else {
        close_clip_player()
      }
    } else if export_open.untracked() {
      if export_out.untracked() != "" {
        rp_export_cancel()
        rp_concat_cancel()
      } else {
        export_open.set(false)
      }
    } else if settings_open.untracked() {
      if purge_state.untracked() == 1 {
        purge_state.set(0)
      } else {
        purge_state.set(0)
        settings_open.set(false)
      }
    } else if library_open.untracked() {
      if delete_pending.untracked() != "" {
        delete_pending.set("")
      } else {
        library_open.set(false)
      }
    } else if clipping.untracked() && region.untracked() is Some(_) {
      clear_region()
    } else if full_screen.untracked() {
      // (full screen left before the window picked is let go)
      set_full_screen(false)
    } else if picked_hwnd.untracked() != 0L {
      pick_window(None)
    } else if clipping.untracked() {
      clipping.set(false)
    } else {
      saved.set("")
    }
  })
  // (the arrows move a selected region, else the playhead)
  on("back5", fn() {
    if region_selected.untracked() {
      clip_mark()
    }
    if !region_nudge(-10.0, 0.0) {
      jump_to(pos_now() - 5000.0)
    }
  })
  on("on5", fn() {
    if region_selected.untracked() {
      clip_mark()
    }
    if !region_nudge(10.0, 0.0) {
      jump_to(pos_now() + 5000.0)
    }
  })
  on("back1", fn() {
    if region_selected.untracked() {
      clip_mark()
    }
    if !region_nudge(-10.0, 0.0) {
      jump_to(pos_now() - 1000.0)
    }
  })
  on("on1", fn() {
    if region_selected.untracked() {
      clip_mark()
    }
    if !region_nudge(10.0, 0.0) {
      jump_to(pos_now() + 1000.0)
    }
  })
  on("back15", fn() { jump_by(-15000.0) })
  on("on15", fn() { jump_by(15000.0) })
  on("frame-back", fn() {
    if region_selected.untracked() {
      clip_mark()
    }
    if !region_nudge(-1.0, 0.0) {
      native_step(-1)
    }
  })
  on("frame-on", fn() {
    if region_selected.untracked() {
      clip_mark()
    }
    if !region_nudge(1.0, 0.0) {
      native_step(1)
    }
  })
  // (in clip mode Home and End go to the clip's start and end)
  on("home", fn() { jump_to(if clipping.untracked() { clip_a.untracked() } else { 0.0 }) })
  on("latest", fn() { if clipping.untracked() { jump_to(clip_b.untracked()) } else { show_latest() } })
  on("zoom-in", fn() { zoom_by(2.0) })
  on("zoom-out", fn() { zoom_by(0.5) })
  on("pic-fit", pic_fit)
  on("mark-back", fn() {
    match next_mark(-1) {
      Some(at) => jump_to(at)
      None => ()
    }
  })
  on("mark-on", fn() {
    match next_mark(1) {
      Some(at) => jump_to(at)
      None => ()
    }
  })
  on("clip-start", fn() {
    clip_mark()
    set_clip_start(pos_now())
  })
  on("clip-end", fn() {
    clip_mark()
    set_clip_end(pos_now())
  })
  on("clip", fn() { if clipping.untracked() { clipping.set(false) } else { start_clip() } })
  on("mark", fn() { toggle_marker(root) })
  on("copy-frame", fn() { copy_frame(pos_now(), shown=true) })
}

///|
/// The window as made once.
fn make_window(root : @view.View) -> Unit {
  the_root.val = Some(root)
  // (the arrow over what is pressed, as Windows' own apps keep it: no hand anywhere, the user's, 2026-11-14)
  root.tree.hand_over_presses(false)
  // (the window's parts drawn in still.fail's theme, its digits all one width among them (a time running keeps its
  // width): told as the tree is made, as still.fail's app does; told before @ui.run it was forgotten as the window's
  // own was made (mbui window_kept.mbt), the tree in mbui's plain theme, its digits the font's own, 2026-11-17)
  @ui.set_tree_theme(@sf.ui_theme_now)
  load_prefs()
  ask_system(root)
  keep_theme(root)
  index_start()
  root.ground(By(c_bg)).keymap(Is(key_bindings())) |> ignore
  replay_actions(root)
  region_keys(root)
  watch_pointer(root)
  dev_pointer(root)
  // (a test window's saved note shown at once, for its picture: REPLAY_DEV_SAVED, the clip's path; "-" its line alone)
  let dev_saved = @ui.env("REPLAY_DEV_SAVED")
  if dev_saved != "" {
    saved.set(if dev_saved == "-" { t("正在保存…") } else { tf("已保存 {0} 的片段", ["0:30"]) })
    saved_path.set(if dev_saved == "-" { "" } else { dev_saved })
  }
  let top = root.box(fn(b) {
    title_bar(b)
    rule(b, fn() { tone(0x00000080L, 0x00000014L) })
  })
  chrome(root, top)
  picture(root)
  // (in full screen the picture is over all of the window: the dock kept at its foot)
  root.box(fn(s) { s.grow(Is(1.0)).laid_nowhere(By(fn() { !full_screen.get() })) |> ignore }) |> ignore
  let foot = root.box(fn(b) { dock(b) })
  chrome(root, foot)
  library_layer(root)
  settings_dialog(root)
  window_options_layer(root)
  export_dialog(root)
  clip_player_layer(root)
  av1_note_layer(root)
  consent_sheet(root)
  apps_layer(root)
  menu_layer(root)
  index_watch(root)
  perf_watch(root)
  update_watch(root)
  // (the folder first read once the window is up, a moment after it is made)
  if hidden_unshown() {
    awaiting_first_show.set(true)
  }
  root.reacts(fn() { ((c_bg() >> 8) & 0xFFFFFFL).to_int() }, fn(rgb) { rp_set_bg_rgb(rgb) })
  root.at_moment(now() + 1.0, fn() {
    // (started hidden by the recorder and not shown yet: frame 1 is now presented while cloaked, so hide it and wait
    // to read or decode the folder till its first real show, resident.mbt)
    if hidden_unshown() {
      first_show_waits.val = Some(root)
      stay_resident(root)
      rp_alt_arrows() |> ignore
      rp_resident_primed()
      return
    }
    refresh(root, true)
    stay_resident(root)
    rp_alt_arrows() |> ignore
    load_clips()
  })
  |> ignore
}

///|
fn main {
  if demux_dump() {
    return
  }
  @sf.set_shortcuts(shortcut_words)
  // (the recorder's note: a card by the tray, shown once drawn, gone by itself: note_card.mbt)
  if note_mode() != "" {
    rp_start_hidden()
    @hostapi.window_setup(note_w, note_h(), note_w, note_h(), inset=true)
    @ui.run_legacy_ctx("ScreenReplay", fn(c) { c.set_clear((@signals.untracked(c_s2) >> 8) & 0xFFFFFFL) }, tree=note_window)
    return
  }
  // (the tray's panel: the same program, its own small window, hidden till the recorder shows it)
  if tray_mode() {
    rp_start_hidden()
    @hostapi.window_setup(tray_w, tray_h, tray_w, tray_h, inset=true)
    @ui.run_legacy_ctx("ScreenReplay", fn(c) { c.set_clear((@signals.untracked(c_s2) >> 8) & 0xFFFFFFL) }, tree=tray_window)
    return
  }
  rp_set_bg_rgb(((@signals.untracked(c_bg) >> 8) & 0xFFFFFFL).to_int())
  start_hidden()
  // (no title bar of the system's: the app's own)
  @hostapi.window_setup(1000.0, 720.0, 1440.0, 900.0, inset=true)
  // (what the host clears to and what shows where nothing of the tree draws its own ground: the window's, as the
  // theme has it; left as mbui's own near-white, the hairlines between the title bar, the picture and the dock were
  // drawn over white: bright lines in the dark, the reviewer's 52nd, 24)
  @ui.run_legacy_ctx("ScreenReplay", fn(c) { c.set_clear((@signals.untracked(c_bg) >> 8) & 0xFFFFFFL) }, tree=make_window)
}
