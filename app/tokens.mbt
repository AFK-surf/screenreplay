// ScreenReplay's look: the design reference the user approved on 2026-11-13 (screenreplay-design.html, its CSS the
// spec): dark its `.b` (the dark grey the user chose), light its `.l` (letter 21), as the settings say (following
// Windows by default: theme.mbt). Five grounds from the window's up and the well the picture sits in, two hairlines,
// three greys of text, four sizes of words (11, 12, 13, 15) in three weights; the one accent near-white in the dark,
// near-black in the light (the other on it), red only for the dot that says it records, amber only for warnings.
// Buttons 32 high, radius 8; icon buttons 32 by 28, radius 6; icons 16. What is drawn over the recorded picture stays
// as in the dark in both. Each is bound: read in a binding, it follows the theme as it turns.

///|
/// One colour in the dark and in the light.
fn tone(dark : Int64, light : Int64) -> Int64 {
  match (theme_way.val, the_root.val) {
    // (between the two over 160 ms as the theme turns, from the moment it turned)
    (Some(way), Some(root)) => mix(light, dark, way.shown(root))
    _ => if is_dark() { dark } else { light }
  }
}

///|
/// How dark the window is drawn (0 light, 1 dark), on its way as the theme turns.
let theme_way : Ref[@motion.NodeWay?] = Ref(None)

///|
/// `color` with no alpha: what a ground fades in from (its own colour, not black's).
fn clear(color : Int64) -> Int64 {
  color & 0xFFFFFF00L
}

///|
fn c_bg() -> Int64 {
  tone(0x1B1C1FFFL, 0xF2F3F5FFL)
}

///|
/// The well the picture sits in: darker than the window in the dark, a grey under the light.
fn well() -> Int64 {
  tone(0x0F1012FFL, 0xDCDFE4FFL)
}

///|
fn c_s1() -> Int64 {
  tone(0x222327FFL, 0xFFFFFFFFL)
}

///|
fn c_s2() -> Int64 {
  tone(0x2B2D32FFL, 0xE6E8ECFFL)
}

///|
fn c_s3() -> Int64 {
  tone(0x383A40FFL, 0xDADDE2FFL)
}

///|
fn c_s4() -> Int64 {
  tone(0x484A51FFL, 0xC9CDD4FFL)
}

///|
/// Hairlines: 10% white or 8% black; the stronger 17% or 15%.
fn hair() -> Int64 {
  tone(0xFFFFFF1AL, 0x00000014L)
}

///|
fn hair2() -> Int64 {
  tone(0xFFFFFF2BL, 0x00000026L)
}

///|
fn ui_text() -> Int64 {
  tone(0xEDEEF0FFL, 0x17181BFFL)
}

///|
fn ui_muted() -> Int64 {
  tone(0xB7BBC2FFL, 0x4A4E55FFL)
}

///|
fn ui_subtle() -> Int64 {
  tone(0x8C9199FFL, 0x6C7178FFL)
}

///|
fn ui_accent() -> Int64 {
  tone(0xEDEEF0FFL, 0x17181BFFL)
}

///|
fn ui_accent_hover() -> Int64 {
  tone(0xFFFFFFFFL, 0x000000FFL)
}

///|
/// What is drawn on the accent.
fn ui_on_accent() -> Int64 {
  tone(0x111214FFL, 0xFFFFFFFFL)
}

///|
/// The accent faint: a clip's range (9% white, 7% black).
fn ui_accent_faint() -> Int64 {
  tone(0xEDEEF017L, 0x17181B12L)
}

///|
/// Red: the dot that says it records (the icon's), and what cannot be undone (`danger`).
fn rec_red() -> Int64 {
  tone(0xFF4D4DFFL, 0xE5383BFFL)
}

///|
/// What cannot be undone (deleting recordings, a clip to the Recycle Bin; the user, 2026-11-15: 「对危险功能要改成红
/// 色」): its words red, on a faint red ground (14%, 22% under the pointer; light 10%, 17%).
fn danger_ink() -> Int64 {
  tone(0xFF6B6BFFL, 0xD92D2DFFL)
}

///|
fn danger_ground(hover : Double) -> Int64 {
  mix(tone(0xFF4D4D24L, 0xE5383B1AL), tone(0xFF4D4D38L, 0xE5383B2BL), hover)
}

///|
/// Amber: only warnings.
fn warn() -> Int64 {
  tone(0xE5A545FFL, 0xA85F00FFL)
}

///|
/// A dialog's scrim (62% dark, 38% light) and its shadow (55%, 28%).
fn scrim_ground() -> Int64 {
  tone(0x0607089EL, 0x06070861L)
}

///|
fn sheet_shadow() -> Int64 {
  tone(0x0000008CL, 0x00000047L)
}

///|
/// The ground under what is pressed or hovered on a bare control (a window button): 8% white, 6% black.
fn press_ground() -> Int64 {
  tone(0xFFFFFF14L, 0x0000000FL)
}

///|
/// The picture's dark ground, the same in both (it is the recording's).
let picture_ground : Int64 = 0x0F1012FFL

///|
/// The dark edge round what is drawn in white over the picture, so a white frame shows on a white screen.
let over_picture_edge : Int64 = 0x00000080L

///|
/// The stage a saved clip plays on is dark in both themes, as the replay's picture is: what is drawn on it its own
/// greys. Its words, muted and subtle; a bare control's ground under the pointer (10% white) and its track (18%).
let stage_text : Int64 = 0xEDEEF0FFL

///|
let stage_muted : Int64 = 0xA4A8B0FFL

///|
let stage_subtle : Int64 = 0x7A7F88FFL

///|
let stage_hover : Int64 = 0xFFFFFF1AL

///|
let stage_track : Int64 = 0xFFFFFF2EL

///|
/// The stage's ground over the clips page (96% of the picture's dark) and its cards' (the hover preview's).
let stage_ground : Int64 = 0x0B0C0EF5L

///|
let stage_card : Int64 = 0x1E1F23FFL
