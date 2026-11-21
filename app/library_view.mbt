// The saved clips, a page of their own under the title bar: the clips as cards four across, two rows a page; a card
// its first frame large with its length on its corner (pressed, played here), its name and size under it with copy,
// show in the folder and delete (asked again). A saved clip plays over the window on a dark scrim.

///|
/// Told as the clips are read again, and as a card's picture is made.
let clips_rev : @signals.Signal[Int] = @signals.signal(0)

///|
fn clips_read() -> Unit {
  load_clips()
  clips_rev.set(clips_rev.untracked() + 1)
}

///|
/// Where a clip saved as recorded starts in its file, ms: the frames from the keyframe before the moment asked for,
/// which its edit list passes over (rp_concat) and Media Foundation's reader does not; 0 for others.
fn clip_lead(path : String) -> Double {
  if is_gif_path(path) {
    return 0.0
  }
  match clip_leads.get(path) {
    Some(ms) => ms
    None => {
      let ms = match track_of(path, "vide") {
        Some(t) => @cmp.maximum(0.0, -sample_ms(t, 0))
        None => 0.0
      }
      clip_leads[path] = ms
      ms
    }
  }
}

///|
/// Each clip's lead (clip_lead), read once: its first picture is asked for every 50 ms till it is made.
let clip_leads : Map[String, Double] = Map([])

///|
/// A clip's first picture as an image key, made in the background (rp_clip_thumb); "" while it is made (looked for
/// again in 50 ms), "!" where there is none.
fn clip_thumb(path : String) -> String {
  let identity = "\{path}|\{rp_size(cstr(path))}|\{rp_modified(cstr(path))}"
  let key = "mem:saved-clip-" + identity
  if @ui.has_image(key) {
    return key
  }
  // (the frame at the clip's start: its reader takes the first within 40 ms before the time asked for, so asked 39 ms on)
  let lead = clip_lead(path)
  let bmp = rp_clip_thumb(cstr(path), cstr(identity), if lead > 0.0 { lead + 39.0 } else { 0.0 })
  if bmp.length() > 1 {
    @ui.add_image(key, bmp)
    clip_thumb_kept(path, key)
    key
  } else if bmp.length() == 1 && bmp[0] == 1 {
    "!"
  } else {
    // (looked for again in 50 ms: once for all the cards waiting, not a timer of each card's, each telling every card
    // to look again)
    if !clip_thumb_due.val {
      match the_root.val {
        Some(r) => {
          clip_thumb_due.val = true
          r.at_moment(now() + 50.0, fn() {
            clip_thumb_due.val = false
            clips_rev.set(clips_rev.untracked() + 1)
          })
          |> ignore
        }
        None => ()
      }
    }
    ""
  }
}

///|
/// Whether the cards' pictures are to be looked for again already.
let clip_thumb_due : Ref[Bool] = Ref(false)

///|
fn clip_card(parent : @view.View, name : String) -> Unit {
  let path = clips_dir() + "\\" + name
  parent.box(fn(card) {
    card.gap(Is(10.0)) |> ignore
    pressable(card, fn() { clip_title(name) }, fn() { open_clip_player(path) }, fn(pic) {
      pic
      .aspect(Is(16.0 / 9.0))
      .radius(Is(8.0))
      .clips(Is(true))
      .ground(Is(picture_ground))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .edge(By(fn() { (1.0, if pic.pointed() { tone(0xFFFFFF33L, 0x00000040L) } else { hair2() }) }))
      .image(By(fn() {
        clips_rev.get() |> ignore
        let k = if av1_unplayable(path) { "!" } else { clip_thumb(path) }
        if k == "" || k == "!" {
          None
        } else {
          Some((k, "", 640))
        }
      }))
      .image_contains(Is(true))
      |> ignore
      words(pic, fn() {
        clips_rev.get() |> ignore
        // (an AV1 clip where nothing decodes AV1: said so, its press telling what to install)
        if av1_unplayable(path) {
          return t("需要 AV1 视频扩展")
        }
        match clip_thumb(path) {
          "" => t("加载预览…")
          "!" => t("暂无预览")
          _ => ""
        }
      }, 11.0, ui_muted)
      |> ignore
      // its length on its corner
      pic.box(fn(o) {
        o.over(Is(true)).pad(Is(8.0)).lines_up(Is(Some(End))).lies_along(Is(End)) |> ignore
        let ms = clip_duration(path)
        if ms > 0.0 {
          o.box(fn(tag) {
            tag.height(Is(Some(20.0))).padding(Is((6.0, 0.0, 6.0, 0.0))).radius(Is(4.0)).ground(Is(0x000000B3L)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
            words(tag, fn() { clock(ms) }, 11.0, fn() { 0xFFFFFFFFL }, weight=500) |> ignore
          })
          |> ignore
        }
      })
      |> ignore
      // under the pointer, a play mark over it
      pic.box(fn(o) {
        o
        .over(Is(true))
        .presses(Is(false))
        .ground(Is(0x00000040L))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .alpha(By(fn() { if pic.pointed() { 1.0 } else { 0.0 } }))
        |> ignore
        o.box(fn(c) {
          c.width(Is(Some(40.0))).height(Is(Some(40.0))).radius(Is(20.0)).ground(Is(0xFFFFFFE6L)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
          @sf.icon_node(c, "play", 18.0, Is(0x0F1011FFL)) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    card.box(fn(foot) {
      foot.row(Is(true)).height(Is(Some(34.0))).gap(Is(2.0)).lines_up(Is(Some(Middle))) |> ignore
      foot.box(fn(n) {
        n.grow(Is(1.0)).basis(Is(Some(0.0))).gap(Is(2.0)).clips(Is(true)) |> ignore
        words(n, fn() { clip_title(name) }, 13.0, ui_text, weight=500) |> ignore
        words(n, fn() {
          let mb = (rp_size(cstr(path)) / 1048576.0).to_int()
          if mb < 1 {
            t("小于 1 MB")
          } else {
            "\{mb} MB"
          }
        }, 12.0, ui_subtle)
        |> ignore
      })
      |> ignore
      foot.pick(fn() { delete_pending.get() == name }, fn(b, asking) {
        b.row(Is(true)).gap(Is(2.0)).lines_up(Is(Some(Middle))) |> ignore
        if asking {
          text_button(b, fn() { t("取消") }, fn() { delete_pending.set("") }, ghost=true) |> ignore
          text_button(b, fn() { t("移到回收站") }, fn() {
            let result = rp_recycle(cstr(path))
            library_message.set(
              if result == 0 {
                t("已移到回收站，可在回收站恢复")
              } else {
                tf("未能移到回收站（{0}），文件仍保留", [result.to_string()])
              },
            )
            delete_pending.set("")
            clips_read()
          }, danger=true)
          |> ignore
        } else {
          icon_button(b, fn() { "copy" }, fn() { t("复制") }, fn() {
            library_message.set(
              if rp_copy_file(cstr(path)) == 1 {
                tf("已复制「{0}」，可直接粘贴到聊天或文件夹", [clip_title(name)])
              } else {
                t("没能复制到剪贴板")
              },
            )
          })
          |> ignore
          icon_button(b, fn() { "folder" }, fn() { t("打开位置") }, fn() { rp_reveal(cstr(path)) }) |> ignore
          icon_button(b, fn() { "trash" }, fn() { t("删除") }, fn() { delete_pending.set(name) }) |> ignore
        }
      }, at_once=true)
    })
    |> ignore
  })
  |> ignore
}

///|
/// The library over the window under the title bar while it is open.
fn library_layer(root : @view.View) -> Unit {
  root.box(fn(o) {
    o.over(Is(true)).over_all(By(fn() { library_open.get() })).padding(Is((0.0, title_h + 1.0, 0.0, 0.0))) |> ignore
    o.show(fn() { library_open.get() }, fn(page) {
      page.grow(Is(1.0)).ground(By(c_bg)).presses(Is(true)).padding(Is((28.0, 24.0, 28.0, 16.0))).gap(Is(16.0)) |> ignore
      // (read again every 3 s while it shows: a clip saved meanwhile, by Ctrl+Alt+S or elsewhere, comes in)
      fn again() -> Unit {
        page.at_moment(now() + 3000.0, fn() {
          clips_read()
          again()
        }, later=true)
        |> ignore
      }
      again()
      let pages = fn() {
        clips_rev.get() |> ignore
        @cmp.maximum(1, (clip_files.length() + clips_per_page - 1) / clips_per_page)
      }
      page.pick(fn() {
        clips_rev.get() |> ignore
        clip_files.is_empty()
      }, fn(b, empty) {
        b.grow(Is(1.0)) |> ignore
        if empty {
          b.lines_up(Is(Some(Middle))).lies_along(Is(Middle)).gap(Is(12.0)) |> ignore
          @sf.icon_node(b, "folder", 32.0, By(ui_subtle)) |> ignore
          words(b, fn() { t("还没有保存的片段") }, 15.0, ui_text, weight=600) |> ignore
          words(b, fn() { t("在回放里按 C 选取一段，按 Enter 保存，就会出现在这里。") }, 13.0, ui_muted) |> ignore
        } else {
          b.gap(Is(28.0)) |> ignore
          for row in 0..<2 {
            b.box(fn(r) {
              r.row(Is(true)).gap(Is(20.0)) |> ignore
              for col in 0..<4 {
                r.box(fn(cell) {
                  cell.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
                  cell.pick(fn() {
                    clips_rev.get() |> ignore
                    let i = library_page.get() * clips_per_page + row * 4 + col
                    if i < clip_files.length() {
                      clip_files[i]
                    } else {
                      ""
                    }
                  }, fn(x, name) { if name != "" { clip_card(x, name) } }, at_once=true)
                })
                |> ignore
              }
            })
            |> ignore
          }
        }
      }, at_once=true)
      page.box(fn(foot) {
        foot.row(Is(true)).height(Is(Some(28.0))).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
        words(foot, fn() { library_message.get() }, 12.0, ui_muted) |> ignore
        spring(foot)
        foot.show(fn() { pages() > 1 }, fn(b) {
          b.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
          icon_button(b, fn() { "chevron-left" }, fn() { t("上一页") }, fn() {
            library_page.set(@cmp.maximum(0, library_page.untracked() - 1))
          })
          |> ignore
          words(b, fn() { "\{library_page.get() + 1} / \{pages()}" }, 12.0, ui_muted) |> ignore
          icon_button(b, fn() { "chevron-right" }, fn() { t("下一页") }, fn() {
            library_page.set(@cmp.minimum(@signals.untracked(pages) - 1, library_page.untracked() + 1))
          })
          |> ignore
        }, at_once=true)
      })
      |> ignore
    }, at_once=true)
  })
  |> ignore
}

///|
/// An AV1 clip pressed where the system decodes no AV1 (no AV1 Video Extension, no GPU of its own for it): what it is,
/// what to install and a button to the Store's page of it (the free extension, Microsoft's), never another app opened
/// with the clip. Closed by Esc, its close or a press beside it.
fn av1_note_layer(root : @view.View) -> Unit {
  sheet(root, fn() { av1_note.get() != "" }, fn() { av1_note.set("") }, 440.0, fn(card) {
    card.box(fn(head) {
      head.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
      words(head, fn() { t("这个片段是 AV1 格式") }, 15.0, ui_text, weight=600) |> ignore
      spring(head)
      icon_button(head, fn() { "close" }, fn() { t("关闭") }, fn() { av1_note.set("") }, size=12.0) |> ignore
    })
    |> ignore
    wrapped(
      card,
      fn() { t("这台电脑还不能解码 AV1，所以没法在这里播放和预览它。从 Microsoft Store 装上免费的「AV1 视频扩展」，再打开这个片段就能播放。") },
      13.0,
      19.0,
      ui_muted,
    )
    card.box(fn(foot) {
      foot.row(Is(true)).gap(Is(8.0)).padding(Is((0.0, 8.0, 0.0, 0.0))).lines_up(Is(Some(Middle))) |> ignore
      spring(foot)
      text_button(foot, fn() { t("关闭") }, fn() { av1_note.set("") }, ghost=true) |> ignore
      solid_button(foot, fn() { t("在 Microsoft Store 获取") }, fn() {
        rp_launch(cstr(av1_store_page)) |> ignore
        av1_note.set("")
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// The saved clip's stage: how far in from the window's sides, over its top row and under its transport row; how tall
/// the top row is with the room under it, the bar's band with the room over it, the transport row.
let stage_side : Double = 48.0

///|
let stage_top : Double = 14.0

///|
let stage_foot : Double = 10.0

///|
let stage_head_h : Double = 48.0

///|
let stage_bar_h : Double = 22.0

///|
let stage_row_h : Double = 44.0

///|
/// The picture's size on the stage: as large as fits at its own shape, between the top row and the bar (in full screen
/// all of the screen, the rows over it).
fn clip_fit(v : @view.View) -> (Double, Double) {
  let (w, h) = v.window()
  let a = @cmp.maximum(0.1, clip_aspect.get())
  let (room_w, room_h) = if full_screen.get() {
    (w, h)
  } else {
    (w - 2.0 * stage_side, h - stage_top - stage_head_h - stage_bar_h - stage_row_h - stage_foot)
  }
  let vw = @cmp.maximum(0.0, @cmp.minimum(room_w, room_h * a))
  (vw, vw / a)
}

///|
/// A shade over the picture's edge in full screen, behind the rows drawn over it: black from 62% at that edge (`at_top`
/// its top) to none, eased, in 16 bands.
fn edge_shade(parent : @view.View, at_top : Bool) -> Unit {
  parent.box(fn(o) {
    o.over(Is(true)).presses(Is(false)).laid_nowhere(By(fn() { !full_screen.get() })) |> ignore
    let n = 16
    for i in 0..<n {
      // (0 at the edge, 1 farthest in)
      let k = (if at_top { i } else { n - 1 - i }).to_double() / (n - 1).to_double()
      let a = (0.62 * (1.0 - k) * (1.0 - k) * 255.0).round().to_int64()
      o.box(fn(b) { b.grow(Is(1.0)).basis(Is(Some(0.0))).ground(Is(a)) |> ignore }) |> ignore
    }
  })
  |> ignore
}

///|
/// A saved clip played over the window, on a stage dark in both themes as the replay's picture is: the picture as large
/// as fits at its own shape, square cornered (the user, 2026-11-14: 「视频本身也不需要圆角了」), a soft shadow under it. Over it on the left the clip's name and, muted, its size
/// and length; on the right copy, show in the folder and close (Esc, which leaves full screen first; or a press beside
/// it). Under it its bar (clip_progress) as wide as the picture, then the transport row bare on the stage as the
/// replay's: the clip before, play and pause (Space), the clip after, where it is of how long; its speed, the volume
/// (the window's), full screen (F, or a double press on the picture). In full screen the picture fills the screen and
/// both rows are drawn over it on a shade, fading out 2 s after the pointer last moved (as the replay's bars do) and
/// back as it moves. Its keys as the replay's: ← → a frame, Shift 5 s, , . a frame too, Home End, [ ] or PageUp PageDown the
/// clip before and after. Played to its end, the key is play again, from its start.
fn clip_player_layer(root : @view.View) -> Unit {
  root.box(fn(o) {
    o.over(Is(true)).over_all(By(fn() { clip_playing.get() != "" })) |> ignore
    o.pick(fn() { clip_playing.get() }, fn(s, path) {
      if path == "" {
        return
      }
      guard clip_deck.val is Some(d) else { return }
      let name = path[clips_dir().length() + 1:].to_owned()
      let fs = fn() { full_screen.get() }
      // (in full screen: the rows shown while the pointer moved in the last 2 s, or is over them, or the bar is held,
      // or a menu is up)
      let (moved, lately) = s.holds_for(2000.0, later=true)
      let rows_way = @motion.NodeWay::new(1.0)
      let head_ref : Ref[@view.View?] = Ref(None)
      let foot_ref : Ref[@view.View?] = Ref(None)
      let over_rows = fn() {
        (match head_ref.val {
          Some(v) => v.pointer_within()
          None => false
        }) ||
        (match foot_ref.val {
          Some(v) => v.pointer_within()
          None => false
        })
      }
      let rows_wanted = fn() { !fs() || lately() || clip_held.get() || menu_up.get() || over_rows() }
      let rows_shown = fn(v : @view.View) { rows_way.shown(v) }
      s
      .grow(Is(1.0))
      .modal(Is(true))
      .presses(Is(true))
      .on_press(fn() { if !full_screen.untracked() { close_clip_player() } })
      .on_pointer_moved(fn() { moved() })
      .ground(By(fn() { if fs() { 0x000000FFL } else { stage_ground } }))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      |> ignore
      let toggle = clip_toggle
      let act = fn(action : String, f : () -> Unit) {
        s.on_action(action, fn(_) {
          f()
          true
        })
        |> ignore
      }
      act("play", toggle)
      act("escape", fn() { if full_screen.untracked() { set_full_screen(false) } else { close_clip_player() } })
      act("full", fn() { set_full_screen(!full_screen.untracked()) })
      act("back5", fn() { clip_seek(d.pos() - 5000.0) })
      act("on5", fn() { clip_seek(d.pos() + 5000.0) })
      act("back1", fn() { clip_seek(d.pos() - 1000.0) })
      act("on1", fn() { clip_seek(d.pos() + 1000.0) })
      act("frame-back", fn() { clip_step(-1) })
      act("frame-on", fn() { clip_step(1) })
      act("home", fn() { clip_seek(0.0) })
      act("latest", fn() {
        // (its last frame, stopped there)
        clip_pause()
        clip_seek((d.span)())
      })
      act("mark-back", fn() { clip_go_beside(-1) })
      act("mark-on", fn() { clip_go_beside(1) })
      act("page-back", fn() { clip_go_beside(-1) })
      act("page-on", fn() { clip_go_beside(1) })
      // the picture and the rows, a column as wide as the picture (in full screen all of the window, the rows over it)
      s.box(fn(col) {
        col
        .width(By(fn() { Some(if fs() { col.window().0 } else { clip_fit(col).0 }) }))
        .height(By(fn() { if fs() { Some(col.window().1) } else { None } }))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        |> ignore
        // over it: the name, its size and length; copy, the folder, close
        col.box(fn(head) {
          head
          .over(By(fs))
          .fills_across(Is(true))
          .lies_along(Is(Start))
          .alpha(By(fn() { rows_shown(head) }))
          .laid_nowhere(By(fn() { fs() && rows_shown(head) <= 0.0 }))
          |> ignore
          head.box(fn(band) {
            band.fills_across(Is(true)) |> ignore
            edge_shade(band, true)
          band.box(fn(row) {
            head_ref.val = Some(row)
            row
            .row(Is(true))
            .fills_across(Is(true))
            .height(Is(Some(36.0)))
            .margin(By(fn() { if fs() { (20.0, 14.0, 14.0, 56.0) } else { (0.0, 0.0, 0.0, stage_head_h - 36.0) } }))
            .gap(Is(2.0))
            .lines_up(Is(Some(Middle)))
            .presses(Is(true))
            .on_press(fn() {  })
            .on_pointer_moved(fn() { moved() })
            |> ignore
            row.box(fn(n) {
              n.row(Is(true)).grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).gap(Is(10.0)).cuts(Is(true)).lines_up(Is(Some(Middle))) |> ignore
              words(n, fn() { clip_title(name) }, 13.0, fn() { stage_text }, weight=600) |> ignore
              words(n, fn() {
                // (as its card on the clips page says it)
                let mb = (rp_size(cstr(path)) / 1048576.0).to_int()
                let size = if mb < 1 { t("小于 1 MB") } else { "\{mb} MB" }
                size + " · " + clock((d.span)())
              }, 12.0, fn() { stage_muted })
              |> ignore
            })
            |> ignore
            let (copied, copied_lately) = row.holds_for(1600.0, later=true)
            icon_button(row, fn() { if copied_lately() { "check" } else { "copy" } }, fn() { t("复制") }, fn() {
              if rp_copy_file(cstr(path)) == 1 {
                copied()
              }
            }, stage=true, tip_words=fn() { if copied_lately() { t("已复制") } else { t("复制到剪贴板") } })
            |> ignore
            icon_button(row, fn() { "folder" }, fn() { t("打开位置") }, fn() { rp_reveal(cstr(path)) }, stage=true, tip_words=fn() {
              t("在文件夹中显示")
            })
            |> ignore
            icon_button(row, fn() { "close" }, fn() { t("关闭") }, close_clip_player, stage=true, shortcut="escape") |> ignore
          })
          |> ignore
          })
          |> ignore
        })
        |> ignore
        // the picture
        col.box(fn(pic) {
          pic
          .width(By(fn() { Some(clip_fit(pic).0) }))
          .height(By(fn() { Some(clip_fit(pic).1) }))
          .ground(Is(picture_ground))
          .shadow(By(fn() { if fs() { (0.0, 0.0, 0L) } else { (40.0, 12.0, 0x00000099L) } }))
          .clips(Is(true))
          .presses(Is(true))
          .on_press(toggle)
          .on_double_press(fn() { set_full_screen(!full_screen.untracked()) })
          .on_pointer_moved(fn() { moved() })
          |> ignore
          d.picture(pic).grow(Is(1.0)) |> ignore
          play_state_over(pic, told=clip_told, playing=fn() { clip_view_playing.get() }, badge_may=fn() { true })
        })
        |> ignore
        // under it: the bar, then the transport row
        col.box(fn(foot) {
          foot
          .over(By(fs))
          .fills_across(Is(true))
          .lies_along(Is(End))
          .alpha(By(fn() { rows_shown(foot) }))
          .laid_nowhere(By(fn() { fs() && rows_shown(foot) <= 0.0 }))
          |> ignore
          foot.box(fn(band) {
            band.fills_across(Is(true)) |> ignore
            edge_shade(band, false)
          band.box(fn(rows) {
            foot_ref.val = Some(rows)
            rows
            .fills_across(Is(true))
            .margin(By(fn() { if fs() { (20.0, 64.0, 20.0, 10.0) } else { (0.0, 0.0, 0.0, 0.0) } }))
            .presses(Is(true))
            .on_press(fn() {  })
            .on_pointer_moved(fn() { moved() })
            |> ignore
            clip_progress(rows, d, path, moved)
            rows.box(fn(row) {
              row.row(Is(true)).height(Is(Some(stage_row_h))).gap(Is(2.0)).lines_up(Is(Some(Middle))) |> ignore
              let beside = fn(dir : Int) {
                fn() {
                  clip_playing.get() |> ignore
                  clips_rev.get() |> ignore
                  clip_beside(dir) is Some(_)
                }
              }
              let before = beside(-1)
              let after = beside(1)
              // (the transport's left: the clip before, play and pause, the clip after, where it is of how long)
              row.box(fn(b) {
                b.row(Is(true)).margin(Is((-6.0, 0.0, 0.0, 0.0))) |> ignore
                let k = icon_button(b, fn() { "skip-back" }, fn() { t("上一个片段") }, fn() { clip_go_beside(-1) }, stage=true, shortcut="clip-before")
                k.alpha(By(fn() { if before() { 1.0 } else { 0.3 } })).presses(By(before)) |> ignore
              })
              |> ignore
              play_button(row, toggle, playing=fn() { clip_view_playing.get() }, stage=true)
              row.box(fn(b) {
                let k = icon_button(b, fn() { "skip-forward" }, fn() { t("下一个片段") }, fn() { clip_go_beside(1) }, stage=true, shortcut="clip-after")
                k.alpha(By(fn() { if after() { 1.0 } else { 0.3 } })).presses(By(after)) |> ignore
              })
              |> ignore
              row.box(fn(time) {
                time.row(Is(true)).margin(Is((12.0, 0.0, 0.0, 0.0))).gap(Is(5.0)).lines_up(Is(Some(Middle))) |> ignore
                words(time, fn() { clock(d.pos_drawn(time)) }, 12.0, fn() { stage_text }, weight=500) |> ignore
                words(time, fn() { "/" }, 12.0, fn() { stage_subtle }) |> ignore
                words(time, fn() { clock((d.span)()) }, 12.0, fn() { stage_muted }) |> ignore
              })
              |> ignore
              spring(row)
              speed_key(row, now=fn() { clip_speed.get() }, set=set_clip_speed, stage=true)
              row.box(fn(g) { g.width(Is(Some(4.0))) |> ignore }) |> ignore
              volume_control(row, stage=true)
              row.box(fn(b) {
                b.row(Is(true)).margin(Is((0.0, 0.0, -6.0, 0.0))) |> ignore
                icon_button(b, fn() { if fs() { "unfull" } else { "full" } }, fn() { if fs() { t("退出全屏") } else { t("全屏") } }, fn() {
                  set_full_screen(!full_screen.untracked())
                }, stage=true, shortcut="full")
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      s.reacts(rows_wanted, fn(on) {
        rows_way.go_ms(s, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else if on { 120.0 } else { 200.0 })
        if !on {
          rp_hide_cursor()
        }
      })
    }, at_once=true)
  })
  |> ignore
}

///|
/// Where the pointer's last drag on the clip's bar went down (a move 4 points from it is a drag: the picture follows by
/// the scrub's way; a press goes there exactly).
let clip_bar_down : Ref[Double] = Ref(0.0)

///|
/// Where the hand holding the bar is (what its time is told by while it drags: the pointer is its then).
let clip_bar_x : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })

///|
/// The hover preview's picture: its width (points; its height by the clip's shape) and how many pixels it is asked at
/// (the index's pictures are 384 wide).
let clip_card_w : Double = 240.0

///|
let clip_card_px : Double = 384.0

///|
/// The saved clip's bar, as wide as the picture, 22 high to the hand: a track 4 high (the stage's hairline-light),
/// what has played of it near-white; under the pointer or held, 6 high (over 120 ms) with a 12 knob at the playhead,
/// the stretch up to the pointer a step lighter. Pressed, the clip goes there exactly; dragged, the picture follows by
/// the scrub's way (its real frames). Over it while the pointer is over it or holds it, the hover preview: the picture
/// of that moment (the index's key frame at or before it: rp_idx_add_clip) with its time under it, at the pointer,
/// kept inside the bar's width, fading in and out over 100 ms as the replay's hover card does.
fn clip_progress(parent : @view.View, d : Deck, path : String, moved : () -> Unit) -> Unit {
  parent.by_room(fn(held, room) {
    let at_x = fn(x : Double) { clamp(x / @cmp.maximum(1.0, room.width()), 0.0, 1.0) * (d.span)() }
    held.box(fn(hit) {
      hit
      .height(Is(Some(stage_bar_h)))
      .presses(Is(true))
      .cursor(Is(Some(Arrow)))
      .says(Is(Some(@view.said(Slider, label="position"))))
      .lies_along(Is(Middle))
      .on_pointer_moved(moved)
      .on_drag(fn(e) {
        let at = at_x(e.x)
        match e.kind {
          Down => {
            clip_bar_down.val = e.x
            clip_bar_x.set(clamp(e.x, 0.0, room.width()))
            clip_seek(at)
          }
          Moved =>
            if clip_held.untracked() || (e.x - clip_bar_down.val).abs() >= 4.0 {
              clip_bar_x.set(clamp(e.x, 0.0, room.width()))
              clip_held.set(true)
              d.scrub(at)
            }
          Up | Off =>
            if clip_held.untracked() {
              clip_held.set(false)
              clip_seek(at)
            }
        }
      }, captures=true)
      |> ignore
      // (where the pointer is along it, a quarter of a point at least; None off it, held: where the hand is)
      let hover = fn() {
        if clip_held.get() {
          return Some(clip_bar_x.get())
        }
        let q = hit.pointer_piece(fn(x, _) { (@cmp.maximum(0.0, x) * 4.0).round().to_int() })
        if q < 0 || !hit.pointer_within() {
          None
        } else {
          Some(clamp(q.to_double() / 4.0, 0.0, room.width()))
        }
      }
      // (what has played, a share of it: while it is held, where the hand is)
      let share = fn() {
        if clip_held.get() {
          clamp(clip_bar_x.get() / @cmp.maximum(1.0, room.width()), 0.0, 1.0)
        } else {
          clamp(d.pos_drawn(hit) / @cmp.maximum(1.0, (d.span)()), 0.0, 1.0)
        }
      }
      let lit = @motion.NodeWay::new(0.0)
      hit.reacts(fn() { hover() is Some(_) }, fn(on) {
        lit.go_ms(hit, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else { 120.0 })
      })
      let thick = fn(v : @view.View) { 4.0 + 2.0 * lit.shown(v) }
      hit.box(fn(track) {
        track
        .height(By(fn() { Some(thick(track)) }))
        .fills_across(Is(true))
        .radius(By(fn() { thick(track) / 2.0 }))
        .ground(Is(stage_track))
        .clips(Is(true))
        .lines_up(Is(Some(Start)))
        |> ignore
        // (up to the pointer, a step lighter)
        track.box(fn(o) {
          o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(f) {
            f
            .height(By(fn() { Some(thick(f)) }))
            .ground(Is(0xFFFFFF24L))
            .width_share(By(fn() {
              match hover() {
                Some(x) if !clip_held.get() => clamp(x / @cmp.maximum(1.0, room.width()), 0.0, 1.0)
                _ => 0.0
              }
            }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        track.box(fn(o) {
          o.over(Is(true)).lines_up(Is(Some(Start))) |> ignore
          o.box(fn(f) { f.height(By(fn() { Some(thick(f)) })).ground(Is(stage_text)).width_share(By(share)) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
      // the knob at the playhead while the pointer is over the bar or holds it
      hit.box(fn(o) {
        o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))).lies_along(Is(Middle)) |> ignore
        o.box(fn(k) {
          k
          .width(Is(Some(12.0)))
          .height(Is(Some(12.0)))
          .radius(Is(6.0))
          .ground(Is(0xFFFFFFFFL))
          .shadow(Is((6.0, 1.0, 0x00000073L)))
          .alpha(By(fn() { lit.shown(k) }))
          .scale(By(fn() { 0.5 + 0.5 * lit.shown(k) }))
          .offset(By(fn() { (share() * room.width() - 6.0, 0.0) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // the hover preview over the bar
      let pic_h = fn() { clamp(clip_card_w / @cmp.maximum(0.1, clip_aspect.get()), 90.0, 180.0) }
      let card_w = clip_card_w + 8.0
      let card_h = fn() { pic_h() + 4.0 + 26.0 }
      // (the moment it shows, kept while it fades out; the last picture shown, kept while the one wanted is made)
      let shown_at : Ref[Double] = Ref(0.0)
      let last_key : Ref[String] = Ref("")
      hit.box(fn(o) {
        o.over(Is(true)).presses(Is(false)).lines_up(Is(Some(Start))).lies_along(Is(Start)) |> ignore
        // (the pointer's leaving the bar kept for 120 ms, as the replay's hover card keeps it: no moment of no pointer
        // between two moves over it takes the card away)
        let (left, left_lately) = o.holds_for(120.0)
        o.reacts(fn() { hover() is Some(_) }, fn(over) { if !over { left() } })
        let fade = @motion.NodeWay::new(0.0)
        o.reacts(fn() { hover() is Some(_) || left_lately() }, fn(on) {
          fade.go_ms(o, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else { 100.0 })
        })
        let at = fn() {
          match hover() {
            Some(x) => {
              let a = at_x(x)
              shown_at.val = a
              a
            }
            None => shown_at.val
          }
        }
        let x_of = fn() {
          match hover() {
            Some(x) => x
            None => shown_at.val / @cmp.maximum(1.0, (d.span)()) * room.width()
          }
        }
        o.box(fn(card) {
          card
          .width(Is(Some(card_w)))
          .height(By(fn() { Some(card_h()) }))
          .padding(Is((4.0, 4.0, 4.0, 0.0)))
          .radius(Is(8.0))
          .ground(Is(stage_card))
          .edge(Is((1.0, 0xFFFFFF1FL)))
          .shadow(Is((28.0, 8.0, 0x000000A6L)))
          .alpha(By(fn() { fade.shown(card) }))
          .laid_nowhere(By(fn() { fade.shown(card) <= 0.0 }))
          .offset(By(fn() {
            let x = x_of()
            (clamp(x - card_w / 2.0, 0.0, @cmp.maximum(0.0, room.width() - card_w)), -card_h() - 6.0)
          }))
          |> ignore
          card.box(fn(p) {
            p
            .height(By(fn() { Some(pic_h()) }))
            .radius(Is(5.0))
            .clips(Is(true))
            .ground(Is(picture_ground))
            .image(By(fn() {
              idx_tick.get() |> ignore
              let a = at()
              // (the seconds round it asked ahead, there as the pointer comes to them; a GIF's next second alone: each
              // of its frames is composed here, on the window's thread, from the canvas kept before it)
              let steps = if is_gif_path(path) { [1000.0] } else { [1000.0, -1000.0, 2000.0, -2000.0] }
              for step in steps {
                let k = clip_frame_key(path, a + step)
                if k != "" {
                  p.image_ask(k, clip_card_px)
                }
              }
              let want = clip_frame_key(path, a)
              if want == "" {
                return if last_key.val == "" { None } else { Some((last_key.val, "", clip_card_px.to_int())) }
              }
              // (the one wanted shown once decoded; the last one meanwhile, never an empty frame between two)
              let ready = p.image_ready(want, clip_card_px)
              let stand_in = last_key.val
              if ready {
                last_key.val = want
              }
              Some((want, if ready { "" } else { stand_in }, clip_card_px.to_int()))
            }))
            .image_contains(Is(true))
            |> ignore
          })
          |> ignore
          card.box(fn(foot) {
            foot.height(Is(Some(26.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
            words(foot, fn() { clock(at()) }, 12.0, fn() { stage_text }, weight=500) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
