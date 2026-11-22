// Platform helpers shared by Windows (`replay_win.c`) and macOS (`replay_mac`): path joining/basename and platform
// predicates so `app/` keeps one cross-platform UI tree with zero Windows regressions.

///|
extern "C" fn rp_is_mac() -> Int = "rp_is_mac"

///|
fn is_mac() -> Bool {
  rp_is_mac() != 0
}

///|
fn path_sep() -> String {
  if is_mac() {
    "/"
  } else {
    "\\"
  }
}

///|
/// Joins `dir` and `name` with `path_sep()` without doubling trailing or leading slashes.
fn pjoin(dir : String, name : String) -> String {
  if dir == "" {
    return name
  }
  if name == "" {
    return dir
  }
  let base = dir.trim_end(chars="/\\").to_owned()
  let tail = name.trim_start(chars="/\\").to_owned()
  if base == "" && (dir.has_prefix("/") || dir.has_prefix("\\")) {
    path_sep() + tail
  } else {
    base + path_sep() + tail
  }
}

///|
/// The file or folder name after the last `/` or `\`.
fn pbase(path : String) -> String {
  let slash = path.rev_find("/")
  let bslash = path.rev_find("\\")
  let idx = match (slash, bslash) {
    (Some(a), Some(b)) => Some(@cmp.maximum(a, b))
    (Some(a), None) => Some(a)
    (None, Some(b)) => Some(b)
    (None, None) => None
  }
  match idx {
    Some(i) => path[i + 1:].to_owned()
    None => path
  }
}
