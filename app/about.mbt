// Settings > About (letter 30): who it is (the icon, the name, what it does, its version and build), updates (signed
// ECDSA P-256 background updates for standalone Setup installs; Store updates for MSIX), links (the change log, the
// privacy policy, feedback), the diagnostics and a foot (© the year, recordings stay on this PC).

///|
let app_version : String = "0.1.19"

///|
extern "C" fn rp_install_kind() -> Int = "rp_install_kind"

///|
struct UpdateStatus {
  state : String
  version : String
  by_hand : Bool
  percent : Int
  error : String
}

///|
let update_rev : @signals.Signal[Int] = @signals.signal(0)

///|
fn read_update_status() -> UpdateStatus {
  match parse(read_text(root_dir() + "\\update.json")) {
    Some(Object(o)) => {
      let str = fn(k : String) {
        match o.get(k) {
          Some(String(v)) => v
          _ => ""
        }
      }
      let pct = match o.get("percent") {
        Some(Number(v, ..)) => v.to_int()
        _ => -1
      }
      {
        state: str("state"),
        version: str("version"),
        by_hand: o.get("byHand") is Some(True),
        percent: pct,
        error: str("error"),
      }
    }
    _ => { state: "unasked", version: "", by_hand: false, percent: -1, error: "" }
  }
}

///|
fn update_status() -> UpdateStatus {
  update_rev.get() |> ignore
  read_update_status()
}

///|
fn update_watch(root : @view.View) -> Unit {
  if @signals.untracked(fn() { settings_open.get() && settings_page.get() == 5 }) && rp_packaged() != 1 {
    update_rev.set(update_rev.untracked() + 1)
  }
  again(root, 400.0, fn() { update_watch(root) })
}

///|
fn update_note_words() -> String {
  if rp_packaged() == 1 {
    return t("通过 Microsoft Store 自动更新")
  }
  let st = update_status()
  match st.state {
    "checking" => t("正在检查更新…")
    "latest" => t("已是最新版本")
    "found" => tf("发现新版本 {0}", [st.version])
    "fetching" =>
      if st.percent >= 0 {
        tf("正在下载 {0}（{1}%）", [st.version, st.percent.to_string()])
      } else {
        tf("正在下载 {0}…", [st.version])
      }
    "ready" => tf("新版本 {0} 已下载，空闲时自动完成更新", [st.version])
    "installing" => t("正在重启并安装更新…")
    "failed" =>
      match st.error {
        "checksum" => t("安装包签名或校验失败")
        "install_failed" => t("未能启动更新安装程序")
        _ => t("检查或下载更新失败，请检查网络")
      }
    _ =>
      if rp_install_kind() == 1 {
        tf("当前版本 {0}", [app_version])
      } else {
        tf("当前版本 {0} · 便携/开发构建", [app_version])
      }
  }
}

///|
fn update_action_words() -> String {
  let st = update_status()
  match st.state {
    "checking" => t("检查中…")
    "found" => if st.by_hand { t("前往下载") } else { t("立即更新") }
    "fetching" => t("下载中…")
    "ready" => t("重启并更新")
    "installing" => t("正在更新…")
    _ => t("检查更新")
  }
}

///|
fn update_action_pressed() -> Unit {
  let st = read_update_status()
  match st.state {
    "checking" | "fetching" | "installing" => ()
    "found" =>
      if st.by_hand {
        rp_launch(cstr(site_url + (if is_english() { "?lang=en" } else { "" }))) |> ignore
      } else {
        rp_write(cstr(root_dir() + "\\update.request"), b"update") |> ignore
        update_rev.set(update_rev.untracked() + 1)
      }
    "ready" => {
      rp_write(cstr(root_dir() + "\\update.request"), b"update") |> ignore
      update_rev.set(update_rev.untracked() + 1)
    }
    _ => {
      rp_write(cstr(root_dir() + "\\update.request"), b"check") |> ignore
      update_rev.set(update_rev.untracked() + 1)
    }
  }
}

///|
// (the public site: the repository is private, its pages a 404 to everyone else)
let site_url : String = "https://screenreplay.pages.dev"

///|
#borrow(text)
extern "C" fn rp_copy_text(text : Bytes) -> Int = "rp_copy_text"

///|
extern "C" fn rp_windows_version() -> Bytes = "rp_windows_version"

///|
extern "C" fn rp_gpu() -> Bytes = "rp_gpu"

///|
/// Whether it runs from its package (the Store's): its build then is no development one.
extern "C" fn rp_packaged() -> Int = "rp_packaged"

///|
/// The build: the commit it was built from (build.txt beside the program, written by the build), "" unknown.
fn build_id() -> String {
  read_text(exe_dir() + "\\build.txt").trim().to_owned()
}

///|
let about_note : @signals.Signal[String] = @signals.signal("")

///|
/// What is copied as the diagnostics: the app, Windows, the graphics card, how it records. No window titles, apps,
/// paths or user names.
fn diagnostics_text() -> String {
  let info = recording_info()
  let codec = if info.codec == "" { "-" } else { info.codec }
  let why = match state_json() {
    Some({ "codecWhy": String(w), .. }) => w
    _ => ""
  }
  let lines = [
    "ScreenReplay \{app_version} (build \{build_id()})",
    "Windows \{@utf8.decode_lossy(rp_windows_version()[:])}",
    "GPU: \{@utf8.decode_lossy(rp_gpu()[:])}",
    "Encoder: \{codec}" + (if why != "" { " (\{why})" } else { "" }),
    "Recording: \{info.width}x\{info.height} @ \{settings.fps} fps, quality \{settings.quality}",
    "System audio: \{settings.system_audio}, microphone: \{settings.microphone}",
    "Sound mux trouble: " + (if info.audio_trouble == "" { "none" } else { info.audio_trouble }),
    "Store install: " + (if rp_packaged() == 1 { "yes" } else { "no" }),
    @signals.untracked(fn() {
      "Language: \{if is_english() { "en" } else { "zh" }}, theme: \{if is_dark() { "dark" } else { "light" }}"
    }),
  ]
  lines.join("\n")
}

///|
/// A row of a card that opens something: its icon, its words, a note, a mark at its right (an external link or an
/// arrow); a hairline over all but the first.
fn link_row(
  parent : @view.View,
  first : Bool,
  icon : String,
  label : () -> String,
  press : () -> Unit,
  note? : () -> String = fn() { "" },
  external? : Bool = false,
) -> Unit {
  if !first {
    rule(parent, hair)
  }
  pressable(parent, label, press, fn(b) {
    let (hand, _) = answer(b)
    b.scale(Is(1.0)) |> ignore
    b
    .row(Is(true))
    .height(Is(Some(44.0)))
    .padding(Is((14.0, 0.0, 14.0, 0.0)))
    .gap(Is(10.0))
    .lines_up(Is(Some(Middle)))
    .cursor(Is(Some(Arrow)))
    .edge(By(fn() { if b.focus_shown() { (1.5, focus_ring()) } else { (0.0, 0L) } }))
    .ground(By(fn() { mix(clear(c_s3()), c_s3(), hand.shown(b) * 0.5) }))
    |> ignore
    if icon == "x-logo" {
      // (X's mark, filled: none in the icon set)
      b.box(fn(g) {
        g
        .width(Is(Some(16.0)))
        .height(Is(Some(16.0)))
        .padding(Is((1.5, 1.5, 1.5, 1.5)))
        .picture(Is(Some({ w: 24.0, h: 24.0, layers: [layer(x_logo_d, 0xFFFFFFFFL)] })))
        .tint(By(ui_muted))
        |> ignore
      })
      |> ignore
    } else if icon == "envelope" {
      // (an envelope, lines as the icon set's: its "mail" is not among what icon_node draws)
      b.box(fn(g) {
        g
        .width(Is(Some(16.0)))
        .height(Is(Some(16.0)))
        .picture(Is(Some(vector("M3.2 3.6h9.6a1.6 1.6 0 0 1 1.6 1.6v5.6a1.6 1.6 0 0 1-1.6 1.6H3.2a1.6 1.6 0 0 1-1.6-1.6V5.2a1.6 1.6 0 0 1 1.6-1.6ZM2.2 4.6 7.2 8.5Q8 9.1 8.8 8.5L13.8 4.6", 16.0, 16.0, stroke=1.4))))
        .tint(By(ui_muted))
        |> ignore
      })
      |> ignore
    } else if icon == "coffee" {
      // (a cup, lines as the icon set's: it has none, and the row's place for it stood empty, the user, 2026-11-21)
      b.box(fn(g) {
        g
        .width(Is(Some(16.0)))
        .height(Is(Some(16.0)))
        .picture(Is(Some(vector("M2.6 6.4h8.4v3.4a3.2 3.2 0 0 1-3.2 3.2H5.8a3.2 3.2 0 0 1-3.2-3.2ZM11 7.3h0.8a1.6 1.6 0 0 1 0 3.2H11M5 2.2v2M7.4 2.2v2M9.8 2.2v2", 16.0, 16.0, stroke=1.4))))
        .tint(By(ui_muted))
        |> ignore
      })
      |> ignore
    } else {
      @sf.icon_node(b, icon, 16.0, By(ui_muted)) |> ignore
    }
    words(b, label, 13.0, ui_text) |> ignore
    words(b, note, 12.0, ui_subtle) |> ignore
    spring(b)
    @sf.icon_node(b, if external { "external" } else { "chevron-right" }, 14.0, By(ui_subtle)) |> ignore
  })
  |> ignore
}

///|
/// Where ScreenReplay is sponsored (free to use since 0.1.7).
let sponsor_url : String = site_url + "/support"

///|
/// X's mark (24 square).
let x_logo_d : String = "M18.901 1.153h3.68l-8.04 9.19L24 22.846h-7.406l-5.8-7.584-6.638 7.584H.474l8.6-9.83L0 1.154h7.594l5.243 6.932ZM17.61 20.644h2.039L6.486 3.24H4.298Z"

///|
/// The app's mark drawn as paths (assets/svg/icon-rec.svg: a graphite rounded square with a faint rim, two chevrons,
/// the red dot), sharp at any size and scale.
fn app_logo(parent : @view.View, size : Double) -> Unit {
  parent.box(fn(l) {
    l
    .width(Is(Some(size)))
    .height(Is(Some(size)))
    .picture(
      Is(
        Some({
          w: 256.0,
          h: 256.0,
          layers: [
            layer("M58 0H198A58 58 0 0 1 256 58V198A58 58 0 0 1 198 256H58A58 58 0 0 1 0 198V58A58 58 0 0 1 58 0Z", 0x2A2C32FFL),
            layer(
              "M58 1.5H198A56.5 56.5 0 0 1 254.5 58V198A56.5 56.5 0 0 1 198 254.5H58A56.5 56.5 0 0 1 1.5 198V58A56.5 56.5 0 0 1 58 1.5Z",
              0L,
              stroke=0xFFFFFF29L,
              width=3.0,
            ),
            layer("M82 88L46 128L82 168", 0L, stroke=0xFFFFFF80L, width=20.0),
            layer("M130 88L94 128L130 168", 0L, stroke=0xFFFFFFFFL, width=20.0),
            layer("M142 128A38 38 0 1 0 218 128A38 38 0 1 0 142 128Z", 0xFF4D4DFFL),
          ],
        }),
      ),
    )
    |> ignore
  })
  |> ignore
}

///|
fn about_page(p : @view.View) -> Unit {
  // who it is
  p.box(fn(who) {
    who.row(Is(true)).padding(Is((0.0, 4.0, 0.0, 8.0))).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
    app_logo(who, 56.0)
    who.box(fn(c) {
      c.grow(Is(1.0)).basis(Is(Some(0.0))).gap(Is(4.0)) |> ignore
      words(c, fn() { "ScreenReplay" }, 20.0, ui_text, weight=600) |> ignore
      c.box(fn(w) {
        w.words(By(fn() { t("一直在后台录屏，随时倒回去存下刚才那一段。") }), look={ ..@view.words_plain, size: 13.0, line: 18.0, wrap: true }).ink(By(ui_muted)) |> ignore
      })
      |> ignore
      c.box(fn(r) {
        r.row(Is(true)).gap(Is(10.0)) |> ignore
        words(r, fn() { tf("版本 {0}", [app_version]) }, 12.0, ui_muted, weight=500) |> ignore
        let b = build_id()
        if b != "" {
          words(r, fn() { tf("构建 {0}", [b]) }, 12.0, ui_subtle) |> ignore
        }
        if rp_install_kind() == 0 {
          words(r, fn() { t("开发构建") }, 12.0, ui_subtle) |> ignore
        } else if rp_packaged() == 1 {
          words(r, fn() { t("通过 Microsoft Store 自动更新") }, 12.0, ui_subtle) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  if rp_packaged() != 1 {
    p.box(fn(card) {
      card
      .radius(Is(10.0))
      .ground(By(fn() { tone(c_s2(), 0xF4F5F7FFL) }))
      .edge(By(fn() { if is_dark() { (0.0, 0L) } else { (1.0, 0x00000014L) } }))
      .clips(Is(true))
      |> ignore
      setting_row(card, true, fn() { t("版本更新") }, update_note_words, fn(c) {
        c.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))) |> ignore
        let busy = fn() {
          let s = update_status().state
          s == "checking" || s == "fetching" || s == "installing"
        }
        c.show(fn() {
          let s = update_status().state
          s == "found" || s == "fetching" || s == "ready"
        }, fn(n) {
          text_button(n, fn() { t("更新日志") }, fn() {
            rp_launch(cstr(site_url + "/changelog" + (if is_english() { "?lang=en" } else { "" }))) |> ignore
          }, ghost=true, small=true) |> ignore
        }) |> ignore
        let act_btn = text_button(c, update_action_words, update_action_pressed, small=true)
        act_btn.alpha(By(fn() { if busy() { 0.45 } else { 1.0 } })).presses(By(fn() { !busy() })) |> ignore
      })
      if rp_install_kind() == 1 {
        toggle_row(card, false, fn() { t("自动更新") }, fn() { t("每天检查一次，空闲时在后台静默下载并更新") }, fn() { sets().auto_update }, fn(v) {
          settings.auto_update = v
        })
      }
    })
    |> ignore
  }
  // (free, a sponsor's page for who wants to give: the user, 2026-11-19 「把这个项目直接免费提供。然后提供赞助链接」)
  // (a card of its own: sponsor_card.mbt, the user's 方案 B, 2026-11-21)
  sponsor_card(p)
  p.box(fn(card) {
    card
    .radius(Is(10.0))
    .ground(By(fn() { tone(c_s2(), 0xF4F5F7FFL) }))
    .edge(By(fn() { if is_dark() { (0.0, 0L) } else { (1.0, 0x00000014L) } }))
    .clips(Is(true))
    |> ignore
    link_row(card, true, "file-text", fn() { t("更新日志") }, fn() {
      rp_launch(cstr(site_url + "/changelog" + (if is_english() { "?lang=en" } else { "" }))) |> ignore
    }, external=true)
    link_row(card, false, "shield-check", fn() { t("隐私政策") }, fn() {
      rp_launch(cstr(site_url + "/privacy" + (if is_english() { "?lang=en" } else { "" }))) |> ignore
    }, external=true)
    // (the first run's sheet read again: its words alone, 知道了)
    link_row(card, false, "monitor", fn() { t("录制说明") }, consent_reread)
  })
  |> ignore
  // (who made it, to reach: the user, 2026-11-15 「about加上我的twitter pengx17和邮箱 pengxiao@outlook.com」)
  setting_group(p, fn() { t("联系作者") }, fn(g) {
    link_row(g, true, "x-logo", fn() { "X (Twitter)" }, note=fn() { "@pengx17" }, fn() {
      rp_launch(cstr("https://x.com/pengx17")) |> ignore
    }, external=true)
    link_row(g, false, "envelope", fn() { t("邮件") }, note=fn() { "pengxiao@outlook.com" }, fn() {
      rp_launch(cstr("mailto:pengxiao@outlook.com")) |> ignore
    }, external=true)
  })
  setting_group(p, fn() { t("诊断") }, fn(g) {
    link_row(g, true, "copy", fn() { t("复制诊断信息") }, note=fn() { t("版本、系统、显卡、当前编码器") }, fn() {
      about_note.set(if rp_copy_text(cstr(diagnostics_text())) == 1 { t("已复制诊断信息") } else { t("没能复制到剪贴板") })
    })
    link_row(g, false, "folder", fn() { t("打开日志文件夹") }, fn() { rp_launch(cstr(root_dir())) |> ignore })
    link_row(g, false, "file", fn() { t("开源许可") }, fn() {
      rp_launch(cstr(site_url + "/licenses.txt")) |> ignore
    }, external=true)
  })
  words(p, fn() { about_note.get() }, 12.0, ui_muted) |> ignore
  spring(p)
  p.box(fn(foot) {
    foot.row(Is(true)) |> ignore
    words(foot, fn() { "© 2026 pengx17" }, 11.0, ui_subtle) |> ignore
    spring(foot)
    words(foot, fn() { t("录像只存在这台电脑上，不会上传。") }, 11.0, ui_subtle) |> ignore
  })
  |> ignore
}
