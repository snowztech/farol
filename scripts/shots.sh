#!/usr/bin/env bash
# Screenshots for the site, the same on any Mac. Run it without arguments for how.
# Farol Shots is a debug build with its own identity and FAROL_HOME, so it never sees your sessions, tasks, servers, theme or Ghostty config.
set -euo pipefail

usage="usage: scripts/shots.sh stage [sidebar|review]   build the shelf demo repo and open Farol Shots on it
       scripts/shots.sh shoot <name>              save the Farol Shots window as site/features/<name>.png
       scripts/shots.sh reset                     quit Farol Shots and forget the scene

make shots SCENE=review builds Farol Shots and stages a scene, and make shot NAME=review shoots it.
Shooting needs Screen Recording for your terminal app."

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Farol Shots.app"
id="dev.farol.Farol.shots"
# The resolved path, the one git reports, so folded projects match by it.
dir="$(cd "${TMPDIR%/}" && pwd -P)/farol-shots"
# 2540x1520 pixels on a Retina screen, the size of every image in site/features.
width=1270 height=760

quit() {
  pkill -f "$app/Contents/MacOS/Farol" 2>/dev/null || true
  while pgrep -f "$app/Contents/MacOS/Farol" >/dev/null; do sleep 0.2; done
}

repo() {
  rm -rf "$dir"
  mkdir -p "$dir/home" "$dir/zsh" "$dir/status" "$dir/run"
  local shelf="$dir/shelf"
  git init -q -b main "$shelf"
  cd "$shelf"
  git config user.name "Ada Lovelace"
  git config user.email "ada@example.com"
  mkdir -p src tests

  cat > README.md <<'EOF'
# shelf

Save links from the command line and read them later.

    shelf add https://example.com/article
    shelf list

## Sync

Links sync to your account as soon as you save them.
EOF
  cat > package.json <<'EOF'
{
  "name": "shelf",
  "version": "0.3.0",
  "type": "module",
  "bin": { "shelf": "src/cli.ts" },
  "scripts": { "test": "vitest run" }
}
EOF
  cat > src/store.ts <<'EOF'
export type Link = { url: string; title?: string; savedAt: number }

export class Store {
  private links: Link[] = []

  add(url: string, title?: string): Link {
    const link = { url, title, savedAt: Date.now() }
    this.links.push(link)
    return link
  }

  list(): Link[] {
    return [...this.links].sort((a, b) => a.savedAt - b.savedAt)
  }
}
EOF
  git add . && git commit -qm "feat: save and list links"

  cat > src/cli.ts <<'EOF'
import { Store } from "./store"

const store = new Store()
const [command, url] = process.argv.slice(2)

if (command === "add" && url) store.add(url)
for (const link of store.list()) console.log(link.url)
EOF
  git add . && git commit -qm "feat: add and list from the command line"

  cat > tests/store.test.ts <<'EOF'
import { expect, test } from "vitest"
import { Store } from "../src/store"

test("lists links in the order they were saved", () => {
  const store = new Store()
  store.add("https://a.example")
  store.add("https://b.example")
  expect(store.list().map((l) => l.url)).toEqual(["https://a.example", "https://b.example"])
})
EOF
  git add . && git commit -qm "docs: explain sync"

  git worktree add -q -b feat/search ../shelf-search
  git worktree add -q -b fix/flaky-tests ../shelf-flaky-tests
  git worktree add -q -b docs/api ../shelf-api

  git checkout -q -b feat/offline-sync
  cat > src/queue.ts <<'EOF'
import { api } from "./api"

type Change = { method: "post" | "delete"; path: string; body?: unknown }

/** Changes made while offline, sent in order once the network is back. */
export class Queue {
  private pending: Change[] = []

  push(change: Change) {
    this.pending.push(change)
  }

  get size() {
    return this.pending.length
  }

  async flush() {
    while (this.pending.length > 0) {
      const change = this.pending[0]
      if (change.method === "post") await api.post(change.path, change.body)
      else await api.delete(change.path)
      this.pending.shift()
    }
  }
}
EOF
  git add . && git commit -qm "feat: queue changes made offline"
  perl -pi -e 's/^Links sync to your account as soon as you save them\.$/Links sync to your account as soon as you save them. Offline, shelf keeps a\nqueue of your changes and sends them in order when you are back./' README.md

  cd ../shelf-flaky-tests
  perl -pi -e 's/const store = new Store\(\)/const store = new Store({ clock: fixedClock() })/' tests/store.test.ts
  cd ../shelf-api
  mkdir -p docs && printf '# API\n\n`Store.add(url, title?)` saves a link and returns it.\n' > docs/api.md
  git add . && git commit -qm "docs: describe the store"

  # A second project, so the sidebar groups sessions by project. It starts folded.
  git init -q -b main "$dir/harbor"
  cd "$dir/harbor"
  git config user.name "Ada Lovelace"
  git config user.email "ada@example.com"
  printf 'module example.com/harbor\n\ngo 1.24\n' > go.mod
  printf 'package main\n\nfunc main() {}\n' > main.go
  git add . && git commit -qm "feat: start the server"
  git worktree add -q -b feat/rate-limit ../harbor-rate-limit
  git worktree add -q -b chore/go-1.25 ../harbor-go
}

# A plain zsh, so the prompt is the same on every Mac.
# Each pane reports the status in status/<folder> and runs run/<folder>, which prints what the scene wants on screen.
shell() {
  cat > "$dir/zsh/.zshrc" <<'EOF'
export GIT_PAGER=cat PAGER=cat
# Set by the agent that started the stage, and Claude Code in the scene would inherit them.
for v in ${(k)parameters[(I)CLAUDE*]}; do unset $v; done
autoload -Uz vcs_info
zstyle ':vcs_info:git:*' formats ' %F{blue}git:(%F{red}%b%F{blue})%f'
precmd() { vcs_info }
setopt prompt_subst
PROMPT='%F{green}➜%f  %F{cyan}%1~%f${vcs_info_msg_0_} '
[[ -f $SHOTS/status/${PWD:t} ]] && eval "\"\$FAROL_CLI\" status $(<$SHOTS/status/${PWD:t})"
# Cleared first, so the login line and its date stay out of the shot.
[[ -f $SHOTS/run/${PWD:t} ]] && { print -n '\e[2J\e[H'; source $SHOTS/run/${PWD:t} }
EOF
  # The main session is a real Claude Code, so the shot shows a real conversation and its own status.
  # The scene's zsh doesn't load your PATH, so it gets claude's full path.
  local claude
  claude=$(command -v claude) || { echo "shots: claude isn't on your PATH" >&2; exit 1; }
  # A blank status line, so your own one, like plan usage, stays out of the shot.
  printf '%q --settings %q %q\n' "$claude" '{"statusLine":{"type":"command","command":"true"}}' "Review src/queue.ts. What goes wrong if the network drops halfway through a flush? Keep it short." > "$dir/run/shelf"
  echo 'working' > "$dir/status/shelf-search"
  echo 'waiting --asking "The fix is in. What should I do with it?"' > "$dir/status/shelf-flaky-tests"
  echo 'done' > "$dir/status/shelf-api"
  echo 'working' > "$dir/status/harbor-rate-limit"
  echo 'done' > "$dir/status/harbor-go"
}

# Sessions, the selected one, and the window's size, written where Farol restores them from.
scene() {
  local review=false
  [ "$1" = review ] && review=true
  local json
  json=$(python3 -I - "$dir" "$review" <<'EOF'
import json, sys
dir, review = sys.argv[1], sys.argv[2] == "true"
sessions = [("Offline sync", "shelf", review), ("Add fuzzy search", "shelf-search", False),
            ("Fix flaky CI tests", "shelf-flaky-tests", False), ("Document the API", "shelf-api", False),
            ("Rate limit the API", "harbor-rate-limit", False), ("Upgrade to Go 1.25", "harbor-go", False)]
print(json.dumps([{"name": name, "layout": {"terminal": {"directory": f"{dir}/{folder}"}},
                   "panels": {"files": False, "graph": False, "review": open_review}}
                  for name, folder, open_review in sessions]).encode().hex())
EOF
)
  local screen
  screen=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.frame; f.size.width + " " + f.size.height')
  defaults delete "$id" >/dev/null 2>&1 || true
  defaults write "$id" sessions.saved -data "$json"
  defaults write "$id" sessions.selected -int 0
  defaults write "$id" "NSWindow Frame FarolMain" "120 120 $width $height 0 0 $screen "
  # Wide enough for a task name next to its worktree tag.
  defaults write "$id" sidebar.width -float 268
  defaults write "$id" sidebar.groupByRepo -bool true
  defaults write "$id" sidebar.folded "$dir/harbor"
  defaults write "$id" review.width -float 560
}

stage() {
  local name="${1:-sidebar}"
  case "$name" in sidebar|review) ;; *) echo "shots: unknown scene $name (sidebar, review)" >&2; exit 64 ;; esac
  [ -d "$app" ] || { echo "shots: build it first with make shots" >&2; exit 1; }
  quit
  repo
  shell
  scene "$name"
  open -n --env FAROL_HOME="$dir/home" --env ZDOTDIR="$dir/zsh" --env SHOTS="$dir" "$app"
  echo "Farol Shots is open on the $name scene. Claude Code is reviewing the queue in Offline sync."
  echo "The first time, it asks to trust the demo folder: say yes in Farol Shots."
  local cli="$app/Contents/Resources/bin/farol" socket="$HOME/Library/Application Support/Farol/$id.sock"
  # wait returns at once while the agent is still starting, so this polls until it has worked and stopped.
  local status worked="" tries=0
  while [ $tries -lt 150 ]; do
    sleep 2; tries=$((tries + 1))
    status=$(FAROL_SOCKET="$socket" "$cli" sessions --json 2>/dev/null | python3 -I -c 'import json, sys
print(next((s["status"] for s in json.load(sys.stdin)["sessions"] if s["name"] == "Offline sync"), ""))' || true)
    [ "$status" = working ] && worked=1
    [ -n "$worked" ] && [ "$status" != working ] && break
  done
  [ -n "$worked" ] || echo "shots: Claude Code never started. Is it waiting on a prompt in Farol Shots?" >&2
  echo "Done. Set up anything else by hand, then: scripts/shots.sh shoot <name>"
}

shoot() {
  local name="${1:?usage: scripts/shots.sh shoot <name>}"
  local pid
  pid=$(pgrep -f "$app/Contents/MacOS/Farol" | head -1) || { echo "shots: Farol Shots isn't running. Run stage first." >&2; exit 1; }
  # The app's largest window on screen, by its process, so another Farol never gets in the shot.
  local window
  window=$(osascript -l JavaScript -e "
    ObjC.import('CoreGraphics');
    var list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)).js;
    var mine = list.map(function (w) { return w.js; }).filter(function (w) {
      return w.kCGWindowOwnerPID.js == $pid && w.kCGWindowLayer.js == 0; });
    mine.sort(function (a, b) {
      var x = a.kCGWindowBounds.js, y = b.kCGWindowBounds.js;
      return y.Width.js * y.Height.js - x.Width.js * x.Height.js; });
    mine.length ? mine[0].kCGWindowNumber.js : ''")
  [ -n "$window" ] || { echo "shots: no Farol Shots window on screen" >&2; exit 1; }
  # In front, so the window has its colored traffic lights.
  open -a "$app"; sleep 1
  local out="$root/site/features/$name.png"
  screencapture -x -o -l "$window" "$out"
  local size
  size=$(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/ { printf "%s%s", sep, $2; sep = "x" }')
  echo "saved site/features/$name.png ($size)"
  [ "$size" = "$((width * 2))x$((height * 2))" ] || echo "shots: expected $((width * 2))x$((height * 2)). Was the window resized, or the screen not Retina?" >&2
}

case "${1:-}" in
  stage) stage "${2:-}" ;;
  shoot) shoot "${2:-}" ;;
  reset) quit; defaults delete "$id" >/dev/null 2>&1 || true; rm -rf "$dir"; echo "Farol Shots reset" ;;
  *) echo "$usage"; exit 64 ;;
esac
