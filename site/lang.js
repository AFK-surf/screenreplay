// Language & theme controller for ScreenReplay official site (zh-CN / en + dark / light)
(function () {
  var params = new URLSearchParams(location.search);
  var qLang = params.get("lang");
  var savedLang = null;
  var savedTheme = null;
  try {
    savedLang = localStorage.getItem("sr_lang");
    savedTheme = localStorage.getItem("sr_theme");
  } catch (e) {}

  var lang = qLang || savedLang || (((navigator.language || "").toLowerCase().indexOf("zh") === 0) ? "zh" : "en");
  var theme = savedTheme || "dark";
  var origTitle = document.title;

  function applyTheme(t) {
    theme = t === "light" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", theme);
    var tb = document.getElementById("theme-toggle");
    if (tb) {
      tb.setAttribute("aria-label", theme === "dark" ? "Switch to light mode" : "Switch to dark mode");
      tb.innerHTML = theme === "dark"
        ? '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="3.2"/><path d="M8 1.5v1.8M8 12.7v1.8M1.5 8h1.8M12.7 8h1.8M3.4 3.4l1.3 1.3M11.3 11.3l1.3 1.3M12.6 3.4l-1.3 1.3M4.7 11.3l-1.3 1.3" stroke-linecap="round"/></svg>'
        : '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M13.2 9.8A5.6 5.6 0 0 1 6.2 2.8a5.6 5.6 0 1 0 7 7Z" stroke-linejoin="round"/></svg>';
    }
  }

  var GLOBE_SVG = '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.35"><circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2a9.8 9.8 0 0 1 2.4 6A9.8 9.8 0 0 1 8 14a9.8 9.8 0 0 1-2.4-6A9.8 9.8 0 0 1 8 2Z"/></svg>';

  function applyLang(l) {
    lang = l === "zh" ? "zh" : "en";
    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
    document.querySelectorAll("[data-zh]").forEach(function (el) {
      var val = el.getAttribute(lang === "zh" ? "data-zh" : "data-en");
      if (val == null) return;
      if (el.hasAttribute("data-html")) el.innerHTML = val;
      else el.textContent = val;
    });
    document.querySelectorAll("[data-title-zh]").forEach(function (el) {
      var tv = el.getAttribute(lang === "zh" ? "data-title-zh" : "data-title-en");
      if (tv != null) el.setAttribute("title", tv);
    });
    document.querySelectorAll("[data-only]").forEach(function (el) {
      el.hidden = el.getAttribute("data-only") !== lang;
    });
    if (origTitle.indexOf("|") !== -1) {
      var parts = origTitle.split("|");
      document.title = lang === "zh" ? parts[0].trim() : ("ScreenReplay — " + parts[1].trim());
    }
    var lb = document.querySelector(".lang-btn");
    if (lb) {
      lb.style.display = "inline-flex";
      lb.style.alignItems = "center";
      lb.style.gap = "5px";
      lb.innerHTML = GLOBE_SVG + '<span>' + (lang === "zh" ? "EN" : "ZH") + '</span>';
      lb.setAttribute("title", lang === "zh" ? "Switch to English" : "Switch to Chinese");
      lb.setAttribute("aria-label", lang === "zh" ? "Switch to English" : "Switch to Chinese");
    }
    window.dispatchEvent(new CustomEvent("sr-lang", { detail: lang }));
  }

  applyTheme(theme);
  applyLang(lang);

  var lb = document.querySelector(".lang-btn");
  if (lb) {
    lb.addEventListener("click", function () {
      var next = lang === "zh" ? "en" : "zh";
      try { localStorage.setItem("sr_lang", next); } catch (e) {}
      applyLang(next);
    });
  }

  var tb = document.getElementById("theme-toggle");
  if (tb) {
    tb.addEventListener("click", function () {
      var next = theme === "dark" ? "light" : "dark";
      try { localStorage.setItem("sr_theme", next); } catch (e) {}
      applyTheme(next);
    });
  }
})();
