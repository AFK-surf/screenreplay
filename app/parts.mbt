// The window's parts as nodes of its tree, made once (mbui's view): words, the design's glyphs drawn as pictures,
// buttons. Each answers the hand as letter 25 says: its ground coming in over 100 ms under the pointer (eased out from
// the moment it came), drawn at 97% while pressed; named for a screen reader by its label.

///|
/// Words in `parent`: `size` (11, 12, 13, 15), `weight`, in `ink`, on one line. The node.
fn words(
  parent : @view.View,
  text : () -> String,
  size : Double,
  ink : () -> Int64,
  weight? : Int = 400,
) -> @view.View {
  parent.box(fn(w) {
    w
    .words(By(text), look={ ..@view.words_plain, size, weight, line: (size * 1.4).round(), wrap: false })
    .ink(By(ink))
    |> ignore
  })
}

///|
/// One path `d` on a `vw` × `vh` grid as a picture (filled, or stroked `stroke` wide), black: drawn in its node's tint.
fn vector(d : String, vw : Double, vh : Double, stroke? : Double = 0.0) -> @pixels.Vector {
  {
    w: vw,
    h: vh,
    layers: [
      {
        d,
        fill: if stroke > 0.0 { 0L } else { 0x000000FFL },
        stroke: if stroke > 0.0 { 0x000000FFL } else { 0L },
        width: stroke,
        even_odd: false,
        sx: 1.0,
        sy: 1.0,
        tx: 0.0,
        ty: 0.0,
      },
    ],
  }
}

///|
/// Several paths, each filled or stroked, as one picture.
fn vectors(vw : Double, vh : Double, paths : Array[(String, Double)]) -> @pixels.Vector {
  {
    w: vw,
    h: vh,
    layers: paths.map(fn(p) {
      let (d, stroke) = p
      {
        d,
        fill: if stroke > 0.0 { 0L } else { 0x000000FFL },
        stroke: if stroke > 0.0 { 0x000000FFL } else { 0L },
        width: stroke,
        even_odd: false,
        sx: 1.0,
        sy: 1.0,
        tx: 0.0,
        ty: 0.0,
      }
    }),
  }
}

///|
/// A glyph of the design's own (on a 16 grid, 1.5 wide lines; "play" filled), or one of the library's icons.
fn glyph_vector(name : String) -> @pixels.Vector? {
  match name {
    "play" =>
      Some(vector("M3 1.8v10.4a.6 .6 0 0 0 .9 .5l8.4-5.2a.6 .6 0 0 0 0-1L3.9 1.3a.6 .6 0 0 0-.9 .5z", 14.0, 14.0))
    "pause" => Some(vector("M3.5 2h2.5v10h-2.5zM8 2h2.5v10h-2.5z", 14.0, 14.0))
    // (clip mode's 撤销 and 重做: an arrow bent back, and forward)
    "undo" => Some(vectors(16.0, 16.0, [("M5.5 3.5 2.5 6.5l3 3M3 6.5h6.5a3.5 3.5 0 0 1 0 7H7", 1.5)]))
    "redo" => Some(vectors(16.0, 16.0, [("M10.5 3.5l3 3-3 3M13 6.5H6.5a3.5 3.5 0 0 0 0 7H9", 1.5)]))
    // (the marker's pin, as on the track (the reviewer's 48th, 2026-11-13): drawn round, its hole a ring)
    "bookmark" =>
      Some(
        vectors(16.0, 16.0, [
          ("M8 14.5C8 14.5 3 9.6 3 6.5a5 5 0 0 1 10 0c0 3.1-5 8-5 8z", 1.5),
          ("M6.4 6.5a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0-3.2 0z", 1.5),
        ]),
      )
    // (a marker where the playhead is: the pin filled, its hole cut through to what is under the key; the key a toggle)
    "bookmark-on" =>
      Some({
        w: 16.0,
        h: 16.0,
        layers: [
          {
            d: "M8 14.5C8 14.5 3 9.6 3 6.5a5 5 0 0 1 10 0c0 3.1-5 8-5 8zM6.1 6.5a1.9 1.9 0 1 0 3.8 0a1.9 1.9 0 1 0-3.8 0z",
            fill: 0x000000FFL,
            stroke: 0L,
            width: 0.0,
            even_odd: true,
            sx: 1.0,
            sy: 1.0,
            tx: 0.0,
            ty: 0.0,
          },
        ],
      })
    "full" => Some(vector("M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10", 16.0, 16.0, stroke=1.5))
    "unfull" => Some(vector("M6 2.5V6H2.5M13.5 6H10V2.5M10 13.5V10h3.5M2.5 10H6v3.5", 16.0, 16.0, stroke=1.5))
    // (scissors, which the library's icons have none of: two rings and two blades crossing)
    "scissors" =>
      Some(
        vectors(24.0, 24.0, [
          ("M3 6a3 3 0 1 0 6 0a3 3 0 1 0 -6 0Z", 2.25),
          ("M3 18a3 3 0 1 0 6 0a3 3 0 1 0 -6 0Z", 2.25),
          ("M20 4L8.12 15.88", 2.25),
          ("M14.47 14.48L20 20", 2.25),
          ("M8.12 8.12L12 12", 2.25),
        ]),
      )
    _ => None
  }
}

///|
/// A glyph `name` (as it changes) `size` across in `ink`: the design's own drawn as a picture, else the library's icon.
fn glyph(parent : @view.View, name : () -> String, size : Double, ink : () -> Int64) -> Unit {
  parent.box(fn(g) {
    g.width(Is(Some(size))).height(Is(Some(size))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    g.pick(fn() { glyph_vector(name()) is Some(_) }, fn(b, own) {
      if own {
        b
        .width(Is(Some(size)))
        .height(Is(Some(size)))
        .picture(By(fn() { glyph_vector(name()) }))
        .tint(By(ink))
        |> ignore
      } else {
        @sf.icon_node(b, "", size, By(ink), name_now=name) |> ignore
      }
    }, at_once=true)
  })
  |> ignore
}

///|
/// How a control answers the hand on node `v`: its pointed-at 0..1 coming over 100 ms, and how big it is drawn (97%
/// while pressed, over 100 ms). Read in a binding.
fn answer(v : @view.View) -> (@motion.NodeWay, @motion.NodeWay) {
  let hand = @motion.NodeWay::new(0.0)
  let held = @motion.NodeWay::new(1.0)
  v.reacts(fn() { v.pointed() || v.pressed() || v.focus_shown() }, fn(on) {
    hand.go_ms(v, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else { 100.0 })
  })
  v.reacts(fn() { v.pressed() }, fn(on) { held.go_ms(v, if on { 0.97 } else { 1.0 }, if motion_off() { 1.0 } else { 100.0 }) })
  v.scale(By(fn() { held.shown(v) })) |> ignore
  (hand, held)
}

///|
/// A button the hand presses in `parent`, named `label` (a screen reader's, and its tip), `press` done as it is
/// pressed. The node, its look the caller's. A press on it lets a selected region go (a control outside the picture),
/// unless `keeps_region`.
fn pressable(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  make : (@view.View) -> Unit,
  keeps_region? : Bool = false,
) -> @view.View {
  parent.box(fn(b) {
    b
    .presses(Is(true))
    .focusable(Is(true))
    .says(By(fn() { Some(@view.said(Button, label=label())) }))
    .on_press(fn() {
      if !keeps_region {
        region_let_go()
      }
      press()
    })
    .cursor(Is(Some(Arrow)))
    |> ignore
    make(b)
  })
}

///|
/// An icon button, 32 by 28, radius 6: bare, s3 under the pointer; its glyph muted, the text's colour under it. On
/// the saved clip's dark stage (`stage`) in the stage's own greys, whatever the theme. Its tip (still.fail's: faded in,
/// handed on between neighbours) says `label` (or `tip_words`) and the keys of action `shortcut` as caps, on `side`.
fn icon_button(
  parent : @view.View,
  name : () -> String,
  label : () -> String,
  press : () -> Unit,
  w? : Double = 32.0,
  h? : Double = 28.0,
  size? : Double = 16.0,
  stage? : Bool = false,
  shortcut? : String = "",
  side? : @view.Side = Top,
  tip_words? : () -> String,
) -> @view.View {
  let k = icon_button_bare(parent, name, label, press, w, h, size, stage)
  tip(k, match tip_words { Some(f) => f; None => label }, shortcut~, side~)
  k
}

///|
fn icon_button_bare(
  parent : @view.View,
  name : () -> String,
  label : () -> String,
  press : () -> Unit,
  w : Double,
  h : Double,
  size : Double,
  stage : Bool,
) -> @view.View {
  pressable(parent, label, press, fn(b) {
    let (hand, _) = answer(b)
    b
    .width(Is(Some(w)))
    .height(Is(Some(h)))
    .radius(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() {
      let on = if stage { stage_hover } else { c_s3() }
      mix(clear(on), on, hand.shown(b))
    }))
    |> ignore
    glyph(b, name, size, fn() {
      if stage {
        mix(stage_muted, stage_text, hand.shown(b))
      } else {
        mix(ui_muted(), ui_text(), hand.shown(b))
      }
    })
  })
}

///|
/// A button, 32 high, radius 8: `ghost` bare (its words grey, s3 under the pointer), else the secondary (a ground of
/// s3, s4 under the pointer); `danger` red (what cannot be undone: danger_ink); an icon before its words where it has
/// one.
fn text_button(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  icon? : String = "",
  ghost? : Bool = false,
  small? : Bool = false,
  danger? : Bool = false,
) -> @view.View {
  pressable(parent, label, press, fn(b) {
    let (hand, _) = answer(b)
    b
    .row(Is(true))
    .height(Is(Some(if small { 28.0 } else { 32.0 })))
    .padding(Is(if small { (9.0, 0.0, 10.0, 0.0) } else { (12.0, 0.0, 12.0, 0.0) }))
    .gap(Is(if small { 6.0 } else { 7.0 }))
    .radius(Is(if small { 6.0 } else { 8.0 }))
    .lines_up(Is(Some(Middle)))
    .ground(By(fn() {
      let h = hand.shown(b)
      if danger {
        danger_ground(h)
      } else if ghost {
        mix(clear(c_s3()), c_s3(), h)
      } else {
        mix(c_s3(), c_s4(), h)
      }
    }))
    |> ignore
    let ink = fn() {
      if danger {
        danger_ink()
      } else if ghost {
        mix(ui_muted(), ui_text(), hand.shown(b))
      } else {
        ui_text()
      }
    }
    if icon != "" {
      glyph(b, fn() { icon }, if small { 14.0 } else { 16.0 }, ink)
    }
    words(b, label, if small { 12.0 } else { 13.0 }, ink, weight=500) |> ignore
  })
}

///|
/// The primary button: the accent's ground, its words on it at 600; `small` after them, 12 at 62%.
fn solid_button(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  icon? : String = "",
  small? : () -> String,
) -> @view.View {
  pressable(parent, label, press, fn(b) {
    let (hand, _) = answer(b)
    b
    .row(Is(true))
    .height(Is(Some(32.0)))
    .padding(Is((12.0, 0.0, 12.0, 0.0)))
    .gap(Is(7.0))
    .radius(Is(8.0))
    .lines_up(Is(Some(Middle)))
    .ground(By(fn() { mix(ui_accent(), ui_accent_hover(), hand.shown(b)) }))
    |> ignore
    if icon != "" {
      glyph(b, fn() { icon }, 16.0, ui_on_accent)
    }
    words(b, label, 13.0, ui_on_accent, weight=600) |> ignore
    match small {
      Some(s) => words(b, s, 12.0, fn() { tone(0x1112149EL, 0xFFFFFF9EL) }) |> ignore
      None => ()
    }
  })
}

///|
/// A hairline across what holds it (1 high), in `ink`.
fn rule(parent : @view.View, ink : () -> Int64) -> Unit {
  parent.box(fn(r) { r.height(Is(Some(1.0))).fills_across(Is(true)).ground(By(ink)) |> ignore }) |> ignore
}

///|
/// Room that grows to take what is left along what holds it.
fn spring(parent : @view.View) -> Unit {
  parent.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
}

///|
/// The play key's glyph, a triangle and two bars one the other's shape (each bar half of the triangle, its corners
/// going to theirs), `k` of the way from play (0) to pause (1): on a 14 grid.
fn play_pause_picture(k : Double) -> @pixels.Vector {
  let lerp = fn(a : (Double, Double), b : (Double, Double)) { (a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k) }
  let quad = fn(play : Array[(Double, Double)], pause : Array[(Double, Double)]) {
    let p = play.mapi(fn(i, a) { lerp(a, pause[i]) })
    "M\{p[0].0} \{p[0].1}L\{p[1].0} \{p[1].1}L\{p[2].0} \{p[2].1}L\{p[3].0} \{p[3].1}Z"
  }
  // (the triangle cut down its middle: its left half and its right, the right's tip two corners at one point)
  let left = quad([(3.0, 1.8), (7.65, 4.4), (7.65, 9.6), (3.0, 12.2)], [(3.5, 2.0), (6.0, 2.0), (6.0, 12.0), (3.5, 12.0)])
  let right = quad([(7.65, 4.4), (12.3, 7.0), (12.3, 7.0), (7.65, 9.6)], [(8.0, 2.0), (10.5, 2.0), (10.5, 12.0), (8.0, 12.0)])
  vectors(14.0, 14.0, [(left, 0.0), (right, 0.0)])
}

///|
/// The play key: 36 by 32, radius 6, bare (s3 under the pointer); its glyph turning from play to pause and back over
/// 180 ms as it plays or stops (the replay's, or as `playing` says: a saved clip's, on its dark `stage`).
fn play_button(
  parent : @view.View,
  press : () -> Unit,
  playing? : () -> Bool = fn() { want_play.get() },
  stage? : Bool = false,
) -> Unit {
  let label = fn() { if playing() { t("暂停") } else { t("播放") } }
  let k = pressable(parent, label, press, fn(b) {
    let (hand, _) = answer(b)
    let morph = @motion.NodeWay::new(if @signals.untracked(playing) { 1.0 } else { 0.0 })
    b.reacts(playing, fn(on) { morph.go_ms(b, if on { 1.0 } else { 0.0 }, if motion_off() { 1.0 } else { 180.0 }) })
    b
    .width(Is(Some(36.0)))
    .height(Is(Some(32.0)))
    .radius(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() {
      let on = if stage { stage_hover } else { c_s3() }
      mix(clear(on), on, hand.shown(b))
    }))
    |> ignore
    b.box(fn(g) {
      g
      .width(Is(Some(20.0)))
      .height(Is(Some(20.0)))
      .picture(By(fn() { Some(play_pause_picture(morph.shown(g))) }))
      .tint(By(fn() { if stage { stage_text } else { ui_text() } }))
      |> ignore
    })
    |> ignore
  })
  tip(k, label, shortcut="play")
}

