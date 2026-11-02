#!/bin/bash
# SpareRoom cleanup. Only removes things that rebuild themselves or hold no unsaved work,
# and never reads macOS-protected folders unless asked:
#   PROJECT_DIR=/path  folder with your git projects (macOS may ask once if it is on the Desktop)
#   MOLE=1             Mole deep clean, if Mole is installed (may ask for other apps' data)
# DRY=1 prints "@est <key> <KB>" per category. Otherwise CATS="a,b" picks categories
# and "@step <key>" marks progress. A category in use is skipped.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
DRY="${DRY:-0}"; CATS=",${CATS:-},"; MOLE="${MOLE:-0}"
H="$HOME"; PROJ="${PROJECT_DIR:-}"; PROJ=${PROJ%/}; CODE=0; [ -n "$PROJ" ] && [ -d "$PROJ" ] && CODE=1
SWEEP="$(cd "$(dirname "$0")" && pwd)/sweep-worktrees.sh"
WT_PATHS=""
busy() { pgrep -fq "$1"; }
sumkb() { awk '{s+=$1} END{print s+0}'; }
want() { [ "$DRY" = 1 ] || [[ "$CATS" == *",$1,"* ]]; }
est() { echo "@est $1 $2"; }
step() { echo "@step $1"; }
old_files() { find "$@" -type f -mtime +7 2>/dev/null; }   # untouched for a week

# 1. App caches older than a week. com.apple.* is skipped: macOS manages it and some of it is protected.
caches() {
  local dirs; dirs=$(find "$H/Library/Caches" -mindepth 1 -maxdepth 1 ! -name 'com.apple.*' ! -name Homebrew 2>/dev/null)
  if [ "$DRY" = 1 ]; then est caches "$(echo "$dirs" | tr '\n' '\0' | xargs -0 -I{} find {} -type f -mtime +7 -print0 2>/dev/null | xargs -0 du -k 2>/dev/null | sumkb)"
  else step caches; echo "$dirs" | while read -r d; do [ -n "$d" ] && old_files "$d" -delete; done; fi
}

# 2. Log files older than a week.
logs() {
  if [ "$DRY" = 1 ]; then est logs "$(old_files "$H/Library/Logs" -print0 | xargs -0 du -k 2>/dev/null | sumkb)"
  else step logs; old_files "$H/Library/Logs" ! -name SpareRoom.log -delete; fi
}

# 3. Download caches of developer tools (npm, npx, Homebrew, pnpm).
devcaches() {
  if [ "$DRY" = 1 ]; then
    local k=0; [ -d "$H/.npm" ] && k=$(du -sk "$H/.npm/_cacache" 2>/dev/null | sumkb)
    busy '\.npm/_npx' || k=$((k + $(du -sk "$H/.npm/_npx" 2>/dev/null | sumkb)))
    command -v brew >/dev/null && k=$((k + $(du -sk "$(brew --cache)" 2>/dev/null | sumkb)))
    [ "$k" -gt 0 ] && est devcaches "$k"; return
  fi
  step devcaches
  command -v npm >/dev/null && npm cache clean --force >/dev/null 2>&1
  busy '\.npm/_npx' || rm -rf "$H/.npm/_npx"
  command -v brew >/dev/null && brew cleanup --prune=all -s >/dev/null 2>&1
  command -v pnpm >/dev/null && pnpm store prune >/dev/null 2>&1
}

# 4. Xcode build files.
xcode() {
  local dd="$H/Library/Developer/Xcode/DerivedData"; [ -d "$dd" ] || return
  if busy xcodebuild || busy 'Xcode.app/Contents/MacOS/Xcode'; then [ "$DRY" = 1 ] && est xcode 0; return; fi
  if [ "$DRY" = 1 ]; then est xcode "$(du -sk "$dd" | sumkb)"; else step xcode; rm -rf "$dd"; fi
}

# 5. Apps and data inside iPhone simulators (the simulators stay).
simulators() {
  [ -d "$H/Library/Developer/CoreSimulator/Devices" ] && command -v xcrun >/dev/null || return
  if busy xcodebuild || busy Simulator.app || xcrun simctl list devices booted 2>/dev/null | grep -q Booted; then
    [ "$DRY" = 1 ] && est simulators 0; return; fi
  if [ "$DRY" = 1 ]; then est simulators "$(du -sk "$H"/Library/Developer/CoreSimulator/Devices/*/data 2>/dev/null | sumkb)"
  else step simulators; xcrun simctl delete unavailable; xcrun simctl erase all; fi
}

# 6. Web builds (.next folders): GitHub Actions runners in the home folder, plus your projects.
#    Skipped where a process is running inside the project (e.g. a dev server).
cwds() { lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; }
webbuild() {
  local list=""; busy Runner.Worker || list=$(find "$H"/actions-runner*/_work -maxdepth 5 -type d -name .next -prune 2>/dev/null)
  if [ "$CODE" = 1 ] && [ -d "$PROJ" ]; then
    local used; used=$(cwds)
    while read -r c; do
      echo "$used" | grep -qF "${c%/.next}" || list+=$'\n'"$c"
    done < <(find "$PROJ" -maxdepth 6 \( -name node_modules -o -name .git \) -prune -o -type d -name .next -print -prune 2>/dev/null)
  fi
  # Copies removed by the worktrees step are already counted there.
  [ -n "$WT_PATHS" ] && list=$(echo "$list" | grep -vF "$WT_PATHS")
  list=$(echo "$list" | grep .) || return
  if [ "$DRY" = 1 ]; then est webbuild "$(echo "$list" | tr '\n' '\0' | xargs -0 du -sk 2>/dev/null | sumkb)"
  else step webbuild; echo "$list" | tr '\n' '\0' | xargs -0 rm -rf; fi
}

# 6b. Installed packages (node_modules) in project copies that are kept but untouched for a week
#     and have nothing running inside. Reinstalled with npm/pnpm install when work resumes.
deps() {
  [ "$CODE" = 1 ] && [ -d "$PROJ" ] || return
  local used list="" cutoff=$(( $(date +%s) - 7 * 86400 )); used=$(cwds)
  for repo in "$PROJ"/*/; do
    [ -d "$repo/.git" ] || continue
    while read -r w; do
      [ -d "$w/node_modules" ] || continue
      [ -n "$WT_PATHS" ] && echo "$WT_PATHS" | grep -qxF "$w" && continue
      echo "$used" | grep -qF "$w" && continue
      local idx; idx=$(git -C "$w" rev-parse --path-format=absolute --git-path index 2>/dev/null)
      [ "$(stat -f %m "$idx" 2>/dev/null || echo 0)" -lt "$cutoff" ] && list+=$'\n'"$w/node_modules"
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)
  done
  list=$(echo "$list" | grep .) || return
  if [ "$DRY" = 1 ]; then est deps "$(echo "$list" | tr '\n' '\0' | xargs -0 du -sk 2>/dev/null | sumkb)"
  else step deps; echo "$list" | tr '\n' '\0' | xargs -0 rm -rf; fi
}

# 7. Old project copies (git worktrees): all work committed and pushed, nothing running
#    inside, no Claude Code conversation using it in the last 4 hours. See sweep-worktrees.sh.
worktrees() {
  [ "$CODE" = 1 ] && [ -f "$SWEEP" ] || return
  local out; out=$(ROOT="$PROJ" NO_FETCH=$DRY WINDOW_MIN=240 bash "$SWEEP" $([ "$DRY" = 1 ] || echo --apply))
  echo "$out" | grep -E '^(DEL|WOULD|FAIL)|summary'
  if [ "$DRY" = 1 ]; then
    local paths; paths=$(echo "$out" | sed -n 's/^WOULD DELETE  //p'); WT_PATHS=$paths
    est worktrees "$( [ -n "$paths" ] && echo "$paths" | tr '\n' '\0' | xargs -0 du -sk 2>/dev/null | sumkb || echo 0)"
  fi
}

# 8. Mole deep clean (optional).
mole() {
  [ "$MOLE" = 1 ] && command -v mo >/dev/null || return
  if [ "$DRY" = 1 ]; then
    est mole "$(mo clean --dry-run </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | awk '/Potential space:/{v=$3; n=v+0; u=v
      gsub(/[0-9.]/,"",u); m=(u=="GB")?1048576:(u=="MB")?1024:(u=="KB")?1:0; printf "%d", n*m}')"
  else step mole; mo clean </dev/null >/dev/null 2>&1; fi
}

echo "== SpareRoom $(date '+%F %T') $([ "$DRY" = 1 ] && echo PREVIEW || echo "CLEAN $CATS")"
ALL="caches logs devcaches xcode simulators worktrees webbuild deps mole"
RUN=""; for c in $ALL; do want $c && RUN="$RUN $c"; done
echo "@total $(echo $RUN | wc -w | tr -d ' ')"
for c in $RUN; do [ "$DRY" = 1 ] && echo "@check $c"; $c; [ "$DRY" = 1 ] || echo "@done $c"; done
echo "== done"
