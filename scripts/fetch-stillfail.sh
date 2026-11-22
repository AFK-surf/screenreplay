#!/bin/bash
# monoid's (still.fail's) mbui runtime (libs/mbui) and component library (libs/sf-ui, @sf), at the commit
# stillfail.lock names, into deps/stillfail: only those two public directories, only that commit.
# Nothing is fetched when it is there already. STILLFAIL_REPO: another place to fetch from (a local clone).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="$(tr -d ' \r\n' < "$ROOT/stillfail.lock")"
DIR="$ROOT/deps/stillfail"
REPO="${STILLFAIL_REPO:-https://github.com/AFK-surf/monoid.git}"
apply_mac_patches() {
  if [ "$(uname -s)" = "Darwin" ] && [ -f "$ROOT/scripts/apple-stream.patch" ]; then
    if git -C "$DIR" apply --check "$ROOT/scripts/apple-stream.patch" >/dev/null 2>&1; then
      git -C "$DIR" apply "$ROOT/scripts/apple-stream.patch"
      echo "fetch-stillfail.sh: applied apple-stream.patch"
    fi
  fi
}

if [ -d "$DIR/.git" ] && [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" = "$COMMIT" ] && [ -f "$DIR/libs/sf-ui/moon.mod" ]; then
  apply_mac_patches
  exit 0
fi
mkdir -p "$DIR"
if [ ! -d "$DIR/.git" ]; then
  git -C "$DIR" init -q
  git -C "$DIR" remote add origin "$REPO"
fi
git -C "$DIR" sparse-checkout set --no-cone libs/mbui/ libs/sf-ui/
git -C "$DIR" remote set-url origin "$REPO"
git -C "$DIR" fetch -q --depth 1 --filter=blob:none origin "$COMMIT"
git -C "$DIR" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
apply_mac_patches
echo "fetch-stillfail.sh: monoid $COMMIT"
