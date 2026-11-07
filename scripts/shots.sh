#!/usr/bin/env bash
# Screenshots for the site, the same on any Mac. Run it without arguments for how.
# Farol Shots is a debug build with its own identity and FAROL_HOME, so it never sees your sessions, tasks, servers, theme or Ghostty config.
set -euo pipefail

usage="usage: scripts/shots.sh stage [sidebar|review|new-task]   build the shelf demo repo and open Farol Shots on it
       scripts/shots.sh shoot <name>              save the Farol Shots window as site/features/<name>.png
       scripts/shots.sh library                   stage once and shoot every feature into assets/screenshots
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

  # A local origin, so New Task starts from origin/main as it does on a real repo, with no network.
  git init -q --bare "$dir/origin/shelf.git" && git remote add origin "$dir/origin/shelf.git" && git push -q -u origin main
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
  cat > main.go <<'EOF'
package main

import "net/http"

func main() {
	http.ListenAndServe(":8080", routes())
}
EOF
  git add . && git commit -qm "feat: start the server"
  git init -q --bare "$dir/origin/harbor.git" && git remote add origin "$dir/origin/harbor.git" && git push -q -u origin main
  git worktree add -q -b feat/rate-limit ../harbor-rate-limit
  git worktree add -q -b chore/go-1.25 ../harbor-go
  # Both sides change the line that starts the server, so merging main stops on a conflict.
  perl -pi -e 's/^\thttp\.ListenAndServe.*/\thttp.ListenAndServe(":8080", limit(routes()))/' main.go
  git commit -qam "feat: rate limit every route"
  cd ../harbor-go
  perl -pi -e 's/^go 1\.24$/go 1.25/; ' go.mod
  perl -pi -e 's/^\thttp\.ListenAndServe.*/\tlog.Fatal(http.ListenAndServe(addr(), routes()))/; s/^import "net\/http"$/import (\n\t"log"\n\t"net\/http"\n)/' main.go
  git commit -qam "chore: move to Go 1.25 and read the port from the environment"
  git merge -q main >/dev/null 2>&1 || true
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
# Cleared, so the login line and its date stay out of the shot.
print -n '\e[2J\e[H'
# Once per folder, so a pane split in the same folder gets a plain prompt instead of a second agent.
if [[ -f $SHOTS/run/${PWD:t} && ! -e $SHOTS/run/${PWD:t}.ran ]]; then
  touch $SHOTS/run/${PWD:t}.ran; source $SHOTS/run/${PWD:t}
fi
EOF
  # The main session is a real Claude Code, so the shot shows a real conversation and its own status.
  # The scene's zsh doesn't load your PATH, so it gets claude's full path.
  local claude
  claude=$(command -v claude) || { echo "shots: claude isn't on your PATH" >&2; exit 1; }
  # A blank status line, so your own one, like plan usage, stays out of the shot.
  # In the repo rather than a flag, so the conversation Farol resumes after a relaunch keeps it too.
  mkdir -p "$dir/shelf/.claude"
  echo '{"statusLine":{"type":"command","command":"true"}}' > "$dir/shelf/.claude/settings.local.json"
  echo '.claude/' >> "$dir/shelf/.git/info/exclude"
  printf '%q %q\n' "$claude" "Review src/queue.ts. What goes wrong if the network drops halfway through a flush? Keep it short." > "$dir/run/shelf"
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
  tasks
  case "$1" in review|library) notes ;; esac
  return 0
}

# Tasks for later, so the sidebar's Tasks pane shows. Their times are days away, so none comes due while a scene is open.
tasks() {
  mkdir -p "$dir/home/schedules"
  local once
  once=$(date -v+5d '+%Y-%m-%d')
  cat > "$dir/home/schedules/triage-issues.md" <<EOF
---
name: Triage new issues
when: weekdays 9:00
repos: $dir/shelf
branch: triage
agent: claude
---
Read the issues opened since yesterday, label them, and draft a reply for each bug report.
EOF
  cat > "$dir/home/schedules/bump-dependencies.md" <<EOF
---
name: Bump dependencies
when: mon 8:30
repos: $dir/harbor
branch: bump-deps
agent: codex
---
Update the Go modules, run the tests, and open a pull request if they pass.
EOF
  cat > "$dir/home/schedules/release-notes.md" <<EOF
---
name: Write the release notes
when: once $once 17:00
repos: $dir/shelf
branch: release-notes
agent: claude
---
Write the release notes for 0.4 from the merged pull requests.
EOF
  # Farol's own record of each task: allowed, as if you had written it in New Task, and with a few past runs.
  local states
  states=$(python3 -I - <<'EOF'
import json, time
ref = 978307200  # Foundation dates count seconds from 2001.
now = time.time() - ref
day = 86400
# Since now, so Farol counts no run as missed and starts none. The past runs are only history to show.
state = lambda runs: {"paused": False, "since": now, "lastDue": now, "allowed": True,
                      "runs": [{"started": now - d * day, "branch": b} for d, b in runs]}
print(json.dumps({
    "triage-issues": state([(1, "triage-2026-11-06"), (2, "triage-2026-11-05")]),
    "bump-dependencies": state([(5, "bump-deps-2026-11-02")]),
    "release-notes": state([]),
}).encode().hex())
EOF
)
  defaults write "$id" schedules.state -data "$states"
}

# Two notes for the agent under lines of the change, waiting to be sent.
notes() {
  local json
  json=$(python3 -I - "$dir/shelf" <<'EOF'
import json, sys, uuid
root = sys.argv[1]
note = lambda path, line, end, text: {
    "id": str(uuid.uuid4()).upper(), "path": path, "line": line, "end": end, "old": False, "lost": False,
    "quote": open(f"{root}/{path}").read().splitlines()[line - 1:end], "text": text}
print(json.dumps({root: [
    note("src/queue.ts", 20, 21, "Keep the change when this throws, so the next flush retries it instead of losing it."),
    note("README.md", 10, 11, "Say what happens to changes made while shelf is closed."),
]}).encode().hex())
EOF
)
  defaults write "$id" review.notes -data "$json"
}

stage() {
  local name="${1:-sidebar}"
  case "$name" in sidebar|review|new-task|library) ;; *) echo "shots: unknown scene $name (sidebar, review, new-task, library)" >&2; exit 64 ;; esac
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
  # Opened the way you would, so the sheet shows what it does today. Typing needs Accessibility for your terminal app.
  if [ "$name" = new-task ]; then
    open -a "$app"; sleep 1
    osascript -e 'tell application "System Events" to keystroke "n" using {shift down, command down}' \
      -e 'delay 1' -e 'tell application "System Events" to keystroke "Add tags to saved links, with a --tag filter on shelf list"' \
      || echo "shots: couldn't type into Farol Shots. Give your terminal app Accessibility, or press ⇧⌘N yourself." >&2
  fi
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
  case "$name" in */*) out="$root/$name.png" ;; esac
  screencapture -x -o -l "$window" "$out"
  local size
  size=$(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/ { printf "%s%s", sep, $2; sep = "x" }')
  echo "saved ${out#"$root"/} ($size)"
  [ "$size" = "$((width * 2))x$((height * 2))" ] || echo "shots: expected $((width * 2))x$((height * 2)). Was the window resized, or the screen not Retina?" >&2
}

# Keys go to the app in front, which shoot keeps Farol Shots. Needs Accessibility for your terminal app.
press() { osascript -e "tell application \"System Events\" to keystroke \"$1\" using {${2}}"; sleep "${3:-1.5}"; }
typed() { osascript -e "tell application \"System Events\" to keystroke \"$1\""; sleep 1; }
escape() { osascript -e 'tell application "System Events" to key code 53'; sleep 1; }
enter() { osascript -e 'tell application "System Events" to key code 36'; sleep "${1:-2}"; }

# Quits and reopens Farol Shots from the layout saved after staging, with the main session's panels and the selected session set.
# Each shot starts the same, with no pane or file left from the one before. Farol resumes the Claude Code conversation on its own.
relaunch() {
  local panels="$1" selected="${2:-0}"
  quit
  python3 -I - "$dir/base.plist" "$dir/defaults.plist" "$panels" "$selected" <<'EOF'
import json, plistlib, sys
base, path, panels, selected = sys.argv[1], sys.argv[2], sys.argv[3].split(","), int(sys.argv[4])
with open(base, "rb") as f: d = plistlib.load(f)
sessions = json.loads(d["sessions.saved"])
sessions[0]["panels"] = {name: name in panels for name in ("files", "graph", "review")}
d["sessions.saved"] = json.dumps(sessions).encode()
d["sessions.selected"] = selected
with open(path, "wb") as f: plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
EOF
  defaults import "$id" "$dir/defaults.plist"
  open -n --env FAROL_HOME="$dir/home" --env ZDOTDIR="$dir/zsh" --env SHOTS="$dir" "$app"
  sleep 6
}

# A shot of each feature, from one stage, into assets/screenshots.
library() {
  stage library
  local out="assets/screenshots"
  # Saved once the agent is done, so it holds the conversation to resume.
  quit; defaults export "$id" "$dir/base.plist"
  relaunch none; shoot "$out/sidebar"
  relaunch review; shoot "$out/review-notes"
  relaunch graph; shoot "$out/git-graph"
  # Each one is a moment from real use: the reviewed file open beside the agent, a search followed to its line, a commit after the diff.
  relaunch files; press p "command down"; typed "queue.ts"; enter 3; shoot "$out/files"
  relaunch none; press f "shift down, command down" 3; typed "pending"; enter 3; shoot "$out/find-in-files"
  relaunch none; press p "command down"; typed "test"; shoot "$out/palette"
  relaunch review; press c "option down, command down" 2; typed "docs: say what the offline queue does"; shoot "$out/commit"
  relaunch none; press n "shift down, command down"; typed "Add tags to saved links, with a --tag filter on shelf list"; shoot "$out/new-task"
  relaunch none; press "," "command down" 2; shoot "$out/settings"
  relaunch none; press d "command down" 2; typed "git log --oneline"; enter; shoot "$out/split"
  # The sixth session is harbor's Go upgrade, stopped on a merge conflict.
  relaunch none 5; press m "option down, command down" 3; shoot "$out/conflicts"
  echo "Library shot into $out. Farol Shots stays open for anything else."
}

case "${1:-}" in
  stage) stage "${2:-}" ;;
  shoot) shoot "${2:-}" ;;
  library) library ;;
  reset) quit; defaults delete "$id" >/dev/null 2>&1 || true; rm -rf "$dir"; echo "Farol Shots reset" ;;
  *) echo "$usage"; exit 64 ;;
esac
