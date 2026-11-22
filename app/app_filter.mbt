// The apps in front over the buffer, counted, and a filter of them (the user, 2026-11-15: 「给过去的这段时间加上统计，
// 快速过滤或者只看某个或者某些个app的录制片段」; the mock they took, 「照这个做（整个缓冲、不压缩）」): a key in the
// dock's row by the zoom opens a list over it of each app's time in front over the whole buffer, longest first; ticking
// apps filters. While a filter is on, the band dims the stretches of the apps not ticked (the timeline is not cut
// short), playing skips them, and the keys' and buttons' jumps of 15 s land in the ticked apps' stretches. A press on
// the band goes where it is pressed, whatever the filter. Clips are what is framed, as before.

///|
/// The apps ticked (by the names they are shown by: app_name); none: no filter.
let app_filter : @signals.Signal[Array[String]] = @signals.signal([], same=fn(a, b) { a == b })

///|
/// The list is up.
let apps_open : @signals.Signal[Bool] = @signals.signal(false)

///|
/// The key it stands over.
let apps_anchor : Ref[@view.NodeId?] = Ref(None)

///|
/// The apps under the share shown on rows of their own, shown too (the 「其它」 row pressed).
let apps_more : @signals.Signal[Bool] = @signals.signal(false)

///|
fn filter_on() -> Bool {
  !app_filter.get().is_empty()
}

///|
fn toggle_app(app : String) -> Unit {
  let now = app_filter.untracked()
  if now.contains(app) {
    set_filter(now.filter(fn(a) { a != app }))
  } else {
    let next = now.copy()
    next.push(app)
    set_filter(next)
  }
}

///|
/// The apps ticked set: the playhead brought into a ticked stretch where it is not in one (the next, else the last
/// before), and the view about it along the timeline's new axis (axis.mbt).
fn set_filter(apps : Array[String]) -> Unit {
  app_filter.set(apps)
  let mut p = pos_now()
  if !apps.is_empty() {
    match kept_at(p, 1) {
      Some(q) => p = q
      None =>
        match kept_at(p, -1) {
          Some(q) => p = q
          None => ()
        }
    }
    if p != pos_now() {
      seek_to(p)
    }
  }
  follow_latest.set(false)
  let len = @signals.untracked(view_len)
  view_from.set(ax_d(p, len) - len / 2.0)
  keep_view()
}

///|
/// Each app's time in front over the buffer (ms, only where something was recorded), longest first: by the name it
/// is shown by (two processes of one name, as an app and its helper, one row), with the process whose icon it shows
/// (the one in front longest); and all of it.
let app_stats : @signals.Computed[(Array[(String, Double, String)], Double)] = @signals.computed(fn(_) {
  let by : Map[String, Double] = Map([])
  let icon : Map[String, (String, Double)] = Map([])
  let per : Map[String, Double] = Map([])
  let mut total = 0.0
  for p in pieces_now.get() {
    let d = p.1 - p.0
    total += d
    if p.2 != "" {
      let name = app_name(p.2)
      by[name] = by.get(name).unwrap_or(0.0) + d
      let own = per.get(p.2).unwrap_or(0.0) + d
      per[p.2] = own
      if own > icon.get(name).map(fn(x) { x.1 }).unwrap_or(-1.0) {
        icon[name] = (p.2, own)
      }
    }
  }
  let rows : Array[(String, Double, String)] = []
  by.each(fn(k, v) { rows.push((k, v, icon.get(k).map(fn(x) { x.0 }).unwrap_or(""))) })
  rows.sort_by(fn(a, b) { if a.1 > b.1 { -1 } else if a.1 < b.1 { 1 } else { 0 } })
  (rows, total)
})

///|
/// The ticked apps' stretches (ms into the buffer), in order, those either side of a gap under 1.5 s taken as one.
let kept_now : @signals.Computed[Array[(Double, Double)]] = @signals.computed(fn(_) {
  let f = app_filter.get()
  let out : Array[(Double, Double)] = []
  if f.is_empty() {
    return out
  }
  for p in pieces_now.get() {
    if p.2 == "" || !f.contains(app_name(p.2)) {
      continue
    }
    if out.length() > 0 && p.0 - out[out.length() - 1].1 <= 1500.0 {
      let last = out[out.length() - 1]
      out[out.length() - 1] = (last.0, @cmp.maximum(last.1, p.1))
    } else {
      out.push((p.0, p.1))
    }
  }
  out
})

///|
/// Where `at` (ms into the buffer) is to be under the filter going `dir` (1 on, -1 back): itself where it is in a
/// ticked app's stretch (or there is no filter); else the start of the next such stretch on (1), the last second of the
/// one before (-1); None where there is none that way.
fn kept_at(at : Double, dir : Int) -> Double? {
  if app_filter.untracked().is_empty() {
    return Some(at)
  }
  let ks = @signals.untracked(fn() { kept_now.get() })
  for k in ks {
    if at >= k.0 && at < k.1 {
      return Some(at)
    }
  }
  if dir > 0 {
    for k in ks {
      if k.0 > at {
        // (a hair into it: the clock's ms and a sample's meet a hair apart)
        return Some(k.0 + 1.0)
      }
    }
    None
  } else {
    let mut found : Double? = None
    for k in ks {
      if k.1 <= at {
        found = Some(@cmp.maximum(k.0 + 1.0, k.1 - 1000.0))
      }
    }
    found
  }
}

///|
/// A jump of `by` ms from the playhead (J, L, the buttons either side of play): under a filter, to where kept_at says
/// that way, staying put where there is no ticked stretch that way.
fn jump_by(by : Double) -> Unit {
  let at = pos_now() + by
  match kept_at(at, if by >= 0.0 { 1 } else { -1 }) {
    Some(q) => jump_to(q)
    None => ()
  }
}

///|
/// While it plays under a filter (the replay's deck's `stops`): at a stretch of an app not ticked, on to the next
/// ticked one, or stopped where there is none. True where it went elsewhere or stopped.
fn filter_skip(p : Double) -> Bool {
  if app_filter.untracked().is_empty() || clipping.untracked() {
    return false
  }
  match kept_at(p, 1) {
    Some(q) if q == p => false
    Some(q) => {
      seek_to(q)
      true
    }
    None => {
      set_playing(false)
      true
    }
  }
}

///|
/// The band's stretches of the apps not ticked dimmed (the window's ground at 75% and a faint hatching), as one picture
/// `w` wide for the view from `from` `len` long; None with no filter.
fn filter_dim_picture(w : Double, from : Double, len : Double, f : Array[String]) -> @pixels.Vector? {
  if f.is_empty() || w <= 0.0 || len <= 0.0 || segs.is_empty() {
    return None
  }
  let x_of = fn(at : Double) { clamp((at - from) / len * w, 0.0, w) }
  let fill = StringBuilder()
  let lines = StringBuilder()
  for p in pieces_now.get() {
    if p.2 != "" && f.contains(app_name(p.2)) {
      continue
    }
    let a = x_of(p.0)
    let b = x_of(p.1)
    if b - a >= 1.0 {
      fill.write_string(rect_d(a, 0.0, b - a, strip_h))
      lines.write_string(hatch_d(a, b - a, strip_h))
    }
  }
  Some({
    w,
    h: strip_h,
    layers: [
      layer(fill.to_string(), tone(0x1B1C1FC0L, 0xF2F3F5C0L)),
      layer(lines.to_string(), 0L, stroke=tone(0xFFFFFF10L, 0x00000012L), width=1.0),
    ],
  })
}

///|
/// A time in front in words: under a second 「不到 1 秒」, under a minute seconds, else minutes, past an hour hours and minutes.
fn front_words(ms : Double) -> String {
  if ms < 1000.0 {
    t("不到 1 秒")
  } else if ms < 60000.0 {
    let s = (ms / 1000.0).round().to_int()
    if s >= 60 {
      tf("{0} 分", ["1"])
    } else {
      tf("{0} 秒", [s.to_string()])
    }
  } else {
    let m = (ms / 60000.0).round().to_int()
    if m < 60 {
      tf("{0} 分", [m.to_string()])
    } else {
      tf("{0} 小时 {1} 分", [(m / 60).to_string(), (m % 60).to_string()])
    }
  }
}

///|
/// The key in the dock's row (by the zoom): 「应用」 with a funnel; with a filter on, the apps ticked (two named, else
/// how many) on s3, and an × that lets the filter go.
fn apps_key(parent : @view.View) -> Unit {
  let k = pressable(parent, fn() { t("按应用统计和过滤") }, fn() {
    apps_more.set(false)
    apps_open.set(true)
  }, fn(b) {
    let (hand, _) = answer(b)
    let ink = fn() { if filter_on() { ui_text() } else { mix(ui_muted(), ui_text(), hand.shown(b)) } }
    b
    .row(Is(true))
    .gap(Is(5.0))
    .padding(Is((8.0, 0.0, 4.0, 0.0)))
    .height(Is(Some(28.0)))
    .radius(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .ground(By(fn() {
      if filter_on() {
        mix(c_s3(), c_s4(), hand.shown(b))
      } else {
        mix(clear(c_s3()), c_s3(), hand.shown(b))
      }
    }))
    .laid_nowhere(By(fn() { !has_segs() }))
    |> ignore
    b.show(fn() { !filter_on() }, fn(x) {
      x.box(fn(g) {
        g
        .width(Is(Some(14.0)))
        .height(Is(Some(14.0)))
        .picture(Is(Some(vector("M2 2.8h10L8.2 7.4V11L5.8 12.2V7.4Z", 14.0, 14.0, stroke=1.4))))
        .tint(By(ink))
        |> ignore
      })
      |> ignore
    }, at_once=true)
    |> ignore
    // with a filter on, the ticked apps' icons in place of the funnel (the user, 2026-11-15: 「加上app图标」), as many
    // as are named, three where it says how many
    b.show(fn() { filter_on() }, fn(x) {
      x.box(fn(ic) {
        ic.row(Is(true)).gap(Is(3.0)).lines_up(Is(Some(Middle))) |> ignore
        ic.each(fn() {
          let f = app_filter.get()
          if f.length() <= 2 { f } else { f[:3].to_owned() }
        }, fn(n) { n }, fn(slot, n) {
          let name = @signals.untracked(fn() { n.get() })
          let process = @signals.untracked(fn() {
            app_stats.get().0.iter().find_first(fn(r) { r.0 == name }).map(fn(r) { r.2 }).unwrap_or("")
          })
          app_icon(slot, process, size=16.0)
        }, at_once=true)
        |> ignore
      })
      |> ignore
    }, at_once=true)
    |> ignore
    b.box(fn(n) {
      n.max_width(Is(Some(180.0))).cuts(Is(true)).padding(Is((0.0, 0.0, 4.0, 0.0))) |> ignore
      words(n, fn() {
        let f = app_filter.get()
        if f.is_empty() {
          t("应用")
        } else if f.length() <= 2 {
          f.join(t("、"))
        } else {
          tf("{0} 个应用", [f.length().to_string()])
        }
      }, 12.0, ink, weight=500)
      |> ignore
    })
    |> ignore
    b.show(fn() { filter_on() }, fn(x) {
      pressable(x, fn() { t("清除过滤") }, fn() { set_filter([]) }, fn(c) {
        let (h2, _) = answer(c)
        c
        .width(Is(Some(18.0)))
        .height(Is(Some(18.0)))
        .radius(Is(4.0))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .ground(By(fn() { mix(clear(c_s4()), c_s4(), h2.shown(c)) }))
        |> ignore
        c.box(fn(g) {
          g
          .width(Is(Some(10.0)))
          .height(Is(Some(10.0)))
          .picture(Is(Some(vector("M2.5 2.5l5 5M7.5 2.5l-5 5", 10.0, 10.0, stroke=1.4))))
          .tint(By(fn() { mix(ui_subtle(), ui_text(), h2.shown(c)) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }, at_once=true)
    |> ignore
  })
  apps_anchor.val = Some(k.id())
}

///|
/// A tick box, 16 square, radius 4: ticked the accent with a check, else a 1.5 wide edge of s4.
fn tick_box(parent : @view.View, on : () -> Bool) -> Unit {
  parent.box(fn(c) {
    c
    .width(Is(Some(16.0)))
    .height(Is(Some(16.0)))
    .radius(Is(4.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() { if on() { ui_accent() } else { 0L } }))
    .edge(By(fn() { if on() { (0.0, 0L) } else { (1.5, ui_subtle()) } }))
    |> ignore
    c.show(on, fn(g) {
      g
      .width(Is(Some(11.0)))
      .height(Is(Some(11.0)))
      .picture(Is(Some(vector("M2.3 5.8l2.2 2.2 4.3-4.6", 11.0, 11.0, stroke=1.8))))
      .tint(By(ui_on_accent))
      |> ignore
    }, at_once=true)
    |> ignore
  })
  |> ignore
}

///|
/// Processes that are the OS's own shell, or this app: never a row of their own (on the 「其它」 row).
fn shell_process(process : String, name : String) -> Bool {
  let p = process.to_lower()
  let n = name.to_lower()
  [
    "screenreplay", "screenreplayviewer", "screenreplay helper", "screenreplayhelper",
    "shellexperiencehost", "shellhost", "sihost", "startmenuexperiencehost", "searchhost",
    "searchapp", "lockapp", "textinputhost", "applicationframehost", "systemsettings", "taskmgr",
    "windowserver", "dock", "control center", "controlcenter", "notificationcenter", "notification center",
    "spotlight", "systemuiserver", "loginwindow", "universalcontrol", "wallpaper",
  ].contains(p) ||
  [
    "screenreplay", "screenreplay helper", "windowserver", "dock", "control center",
    "notification center", "notificationcenter", "spotlight",
  ].contains(n) ||
  name.has_prefix("Microsoft® Windows®")
}

///|
/// The rows shown: the apps in front enough of the buffer (at least 1 minute or 5% of a shorter buffer, and 1% of the
/// time; Windows' shell and this app never), eight at most, ticked ones always; if none qualify (e.g. a very short
/// buffer), the top non-shell apps (or top rows if only shell apps exist) are still shown so the list never collapses
/// to only an 「其他」 row. The rest sit on one 「其他」 row, or all of them once it was pressed.
fn apps_rows() -> (Array[(String, Double, String)], Int, Double) {
  let (rows, total) = app_stats.get()
  let f = app_filter.get()
  let more = apps_more.get()
  let min_ms = @cmp.minimum(60000.0, total * 0.05)
  let shown : Array[(String, Double, String)] = []
  let mut rest = 0
  let mut rest_ms = 0.0
  for r in rows {
    let big = r.1 >= min_ms && (total <= 0.0 || r.1 / total >= 0.01) && !shell_process(r.2, r.0)
    if f.contains(r.0) || (big && shown.length() < 8) || more {
      shown.push(r)
    } else {
      rest += 1
      rest_ms += r.1
    }
  }
  if shown.is_empty() && !rows.is_empty() {
    rest = 0
    rest_ms = 0.0
    let has_non_shell = rows.iter().any(fn(r) { !shell_process(r.2, r.0) })
    for r in rows {
      let pick = (!has_non_shell || !shell_process(r.2, r.0)) && shown.length() < 8
      if pick {
        shown.push(r)
      } else {
        rest += 1
        rest_ms += r.1
      }
    }
  }
  (shown, rest, rest_ms)
}

///|
/// One app's row, 34 high: its tick, icon and name; its time in front (muted) and share (subtle, in a column of its
/// own) at its end (a bar of the share behind the row was tried: grey blocks behind the ticks); s2 under the pointer.
/// Pressed it is ticked or not; under the pointer 「只看它」 in place of its time, which ticks it alone.
fn app_row(parent : @view.View, name : String, process : String, ms_get : () -> Double) -> Unit {
  pressable(parent, fn() { name }, fn() { toggle_app(name) }, fn(b) {
    b
    .height(Is(Some(34.0)))
    .radius(Is(6.0))
    .ground(By(fn() { if b.pointed() || b.focus_shown() { c_s2() } else { 0L } }))
    |> ignore
    b.box(fn(top) {
      top
      .row(Is(true))
      .height(Is(Some(34.0)))
      .padding(Is((10.0, 0.0, 10.0, 0.0)))
      .gap(Is(10.0))
      .lines_up(Is(Some(Middle)))
      |> ignore
      tick_box(top, fn() { app_filter.get().contains(name) })
      app_icon(top, process, size=16.0)
      top.box(fn(n) {
        n.grow(Is(1.0)).basis(Is(Some(0.0))).cuts(Is(true)).min_width(Is(Some(0.0))) |> ignore
        words(n, fn() { name }, 13.0, ui_text) |> ignore
      })
      |> ignore
      top.pick(fn() { b.pointed() }, fn(r, over) {
        r.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
        if over {
          pressable(r, fn() { t("只看它") }, fn() { set_filter([name]) }, fn(c) {
            let (h2, _) = answer(c)
            c
            .height(Is(Some(22.0)))
            .padding(Is((7.0, 0.0, 7.0, 0.0)))
            .radius(Is(5.0))
            .lines_up(Is(Some(Middle)))
            .ground(By(fn() { mix(c_s3(), c_s4(), h2.shown(c)) }))
            |> ignore
            words(c, fn() { t("只看它") }, 12.0, ui_text, weight=500) |> ignore
          })
          |> ignore
        } else {
          words(r, fn() { front_words(ms_get()) }, 12.0, ui_muted) |> ignore
          r.box(fn(pc) {
            pc.row(Is(true)).width(Is(Some(34.0))).lines_up(Is(Some(Middle))).lies_along(Is(End)) |> ignore
            words(pc, fn() {
              let total = app_stats.get().1
              share_words(if total > 0.0 { ms_get() / total } else { 0.0 })
            }, 12.0, ui_subtle) |> ignore
          })
          |> ignore
        }
      }, at_once=true)
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A share in whole percents, under one 「<1%」.
fn share_words(share : Double) -> String {
  if share < 0.01 {
    "<1%"
  } else {
    (share * 100.0).round().to_int().to_string() + "%"
  }
}

///|
/// The list over the key: s1, a hairline, radius 10, a shadow, 384 wide; its head (「前台应用」 and the buffer's
/// reach), the rows, its foot (what the filter does, 「清除」). Pressed outside it, it goes; Escape too.
fn apps_layer(root : @view.View) -> Unit {
  root.box(fn(o) {
    o.over(Is(true)).over_all(Is(true)) |> ignore
    o.show(fn() { apps_open.get() }, fn(m) {
      let close = fn() { apps_open.set(false) }
      m.over(Is(true)).modal(Is(true)).presses(Is(true)).lines_up(Is(Some(Start))).on_press(close) |> ignore
      m.on_action("escape", fn(_) {
        close()
        true
      })
      |> ignore
      m.box(fn(panel) {
        let open = @motion.NodeWay::new(0.0)
        open.go_ms(panel, 1.0, if motion_off() { 1.0 } else { 120.0 })
        panel
        .alpha(By(fn() { open.shown(panel) }))
        .scale(By(fn() { if motion_off() { 1.0 } else { 0.96 + 0.04 * open.shown(panel) } }), about=At(1.0, 1.0))
        .width(Is(Some(384.0)))
        .padding(Is((6.0, 10.0, 6.0, 8.0)))
        .ground(By(c_s1))
        .radius(Is(10.0))
        .edge(By(fn() { (1.0, hair2()) }))
        .shadow(By(fn() { (32.0, 12.0, sheet_shadow()) }))
        .presses(Is(true))
        |> ignore
        match apps_anchor.val {
          Some(a) => panel.beside(a, side=Top, along=End, offset=6.0) |> ignore
          None => ()
        }
        // the head
        panel.box(fn(h) {
          h.row(Is(true)).padding(Is((10.0, 2.0, 10.0, 8.0))).lines_up(Is(Some(Middle))) |> ignore
          h.box(fn(l) {
            l.grow(Is(1.0)) |> ignore
            words(l, fn() { t("前台应用") }, 13.0, ui_text, weight=600) |> ignore
          })
          |> ignore
          words(h, fn() {
            tf("过去 {0} · 共录 {1}", [view_len_words(span()), front_words(app_stats.get().1)])
          }, 12.0, ui_subtle)
          |> ignore
        })
        |> ignore
        // the rows (scrollable when expanded past ~10 apps so it never overflows a 720 pt window)
        panel.box(fn(sc) {
          sc.max_height(Is(Some(400.0))) |> ignore
          sc.scrolls(@view.Scroll::new(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(list) {
            list.each(fn() { apps_rows().0 }, fn(r) { r.0 }, fn(row, r) {
              let snap = @signals.untracked(fn() { r.get() })
              app_row(row, snap.0, snap.2, fn() { r.get().1 })
            }, at_once=true)
            |> ignore
            list.show(fn() { apps_rows().0.is_empty() && apps_rows().1 == 0 }, fn(x) {
              x.box(fn(e) {
                e.height(Is(Some(34.0))).padding(Is((10.0, 0.0, 10.0, 0.0))).lines_up(Is(Some(Middle))) |> ignore
                words(e, fn() { t("暂无应用记录") }, 12.0, ui_subtle) |> ignore
              })
              |> ignore
            }, at_once=true)
            |> ignore
            list.show(fn() { apps_rows().1 > 0 }, fn(x) {
              pressable(x, fn() { t("显示全部") }, fn() { apps_more.set(true) }, fn(b) {
                b
                .row(Is(true))
                .height(Is(Some(34.0)))
                .padding(Is((10.0, 0.0, 10.0, 0.0)))
                .gap(Is(10.0))
                .radius(Is(6.0))
                .lines_up(Is(Some(Middle)))
                .edge(By(fn() { if b.focus_shown() { (1.5, focus_ring()) } else { (0.0, 0L) } }))
                .ground(By(fn() { if b.pointed() || b.focus_shown() { c_s2() } else { 0L } }))
                |> ignore
                b.box(fn(n) {
                  n.grow(Is(1.0)).padding(Is((52.0, 0.0, 0.0, 0.0))) |> ignore
                  words(n, fn() {
                    let count = apps_rows().1
                    if count == 1 {
                      t("其他 1 个")
                    } else {
                      tf("其他 {0} 个", [count.to_string()])
                    }
                  }, 13.0, ui_muted) |> ignore
                })
                |> ignore
                words(b, fn() { front_words(apps_rows().2) }, 12.0, ui_subtle) |> ignore
                // (the share column's room, so its time stands with the rows' times)
                b.box(fn(sp) { sp.width(Is(Some(30.0))) |> ignore }) |> ignore
              })
              |> ignore
            }, at_once=true)
            |> ignore
          })
          |> ignore
        })
        |> ignore
        rule(panel, hair)
        // the foot
        panel.box(fn(f) {
          f.row(Is(true)).padding(Is((10.0, 8.0, 6.0, 0.0))).lines_up(Is(Some(Middle))) |> ignore
          f.box(fn(l) {
            l.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
            words(l, fn() {
              if filter_on() {
                t("播放和前进/后退 15 秒只经过所选应用")
              } else {
                t("勾选应用后，只看它们的时段")
              }
            }, 12.0, ui_subtle)
            |> ignore
          })
          |> ignore
          f.show(fn() { filter_on() }, fn(x) {
            text_button(x, fn() { t("清除") }, fn() { set_filter([]) }, ghost=true, small=true) |> ignore
          }, at_once=true)
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }, at_once=true)
  })
  |> ignore
}
