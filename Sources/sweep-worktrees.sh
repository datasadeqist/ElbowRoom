#!/bin/bash
# Finds git worktrees under ROOT that hold nothing worth keeping, and removes them with --apply.
# A worktree is kept when ANY of these is true:
#   - it is locked by a process that is still running
#   - a process is running inside it (a terminal, an editor, a dev server)
#   - a Claude Code conversation used it in the last WINDOW_MIN minutes
#   - it changed in the last WINDOW_MIN minutes
#   - it has uncommitted changes (untracked caches like .DS_Store are ignored)
#   - its current commit is not on any remote branch
# Branches are never deleted, only the extra working folder.
# Env: ROOT (required), WINDOW_MIN (default 240), NO_FETCH=1 skips `git fetch` (used for previews).
set -u
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
ROOT="${ROOT:?set ROOT to the folder that holds your git projects}"; ROOT=${ROOT%/}
WINDOW_MIN="${WINDOW_MIN:-240}"
TRANSCRIPTS="${CLAUDE_TRANSCRIPTS:-$HOME/.claude/projects}"
G="/usr/bin/git --no-optional-locks"   # no index refresh, so the activity check stays honest
CACHE='^\?\? (.*/)?(\.playwright-mcp/|\.vitest/|\.DS_Store|[^/]*\.tsbuildinfo|\.package\.resolved)'
now=$(date +%s); cutoff=$((now - WINDOW_MIN * 60))
cwds=$(/usr/sbin/lsof -a -d cwd -Fn 2>/dev/null | grep '^n' | cut -c2-)
# Folders a Claude Code conversation worked in (cwd, commands, edited files) recently.
# ponytail: one grep over recent transcripts; paths written as ~ or ../ are not seen.
root_re=$(printf '%s' "$ROOT" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
convo=$(find "$TRANSCRIPTS" -name '*.jsonl' -mmin -"$WINDOW_MIN" -print0 2>/dev/null \
  | xargs -0 grep -ohE '"(cwd|command|file_path|path)":"([^"\\]|\\.)*"' 2>/dev/null \
  | grep -oE "($root_re|$HOME/\.claude/jobs)/[A-Za-z0-9._/-]+" | sort -u)
rm_n=0; keep_n=0
under() { printf '%s\n' "$2" | awk -v w="$1" '$0 == w || index($0, w "/") == 1 {f=1; exit} END {exit !f}'; }

for repo in "$ROOT"/*/; do
  repo=${repo%/}; [ -d "$repo/.git" ] || continue
  [ "$($G -C "$repo" worktree list | wc -l)" -gt 1 ] || continue
  [ "${NO_FETCH:-0}" = 1 ] || GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 GIT_TERMINAL_PROMPT=0 \
    $G -C "$repo" fetch --all --prune -q 2>/dev/null || echo "  (fetch failed: ${repo##*/}, using local remote refs)"
  while read -r w; do
    [ -d "$w" ] || continue
    gd=$($G -C "$w" rev-parse --absolute-git-dir 2>/dev/null) || { echo "KEEP  $w  (not readable)"; keep_n=$((keep_n+1)); continue; }
    reason=""; stale=0
    if [ -f "$gd/locked" ]; then   # a lock from a process that has exited does not protect it
      lpid=$(grep -oE 'pid [0-9]+' "$gd/locked" | grep -oE '[0-9]+')
      if [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; then stale=1; else reason="locked"; fi
    fi
    [ -z "$reason" ] && under "$w" "$cwds" && reason="in use"
    [ -z "$reason" ] && under "$w" "$convo" && reason="Claude Code conversation in the last ${WINDOW_MIN}m"
    if [ -z "$reason" ]; then
      last=$(stat -f %m "$gd/index" 2>/dev/null || echo 0)
      ct=$($G -C "$w" log -1 --format=%ct 2>/dev/null || echo 0); [ "$ct" -gt "$last" ] && last=$ct
      [ "$last" -gt "$cutoff" ] && reason="changed in the last ${WINDOW_MIN}m"
    fi
    if [ -z "$reason" ]; then
      dirty=$($G -C "$w" status --porcelain | grep -Ev "$CACHE" | wc -l | tr -d ' ')
      [ "$dirty" -gt 0 ] && reason="$dirty uncommitted file(s)"
    fi
    if [ -z "$reason" ]; then
      [ "$($G -C "$w" for-each-ref --contains HEAD refs/remotes --count=1 --format=x | wc -l)" -eq 0 ] && reason="commits not on any remote"
    fi
    if [ -n "$reason" ]; then echo "KEEP  $w  ($reason)"; keep_n=$((keep_n+1)); continue; fi
    if [ $APPLY = 1 ]; then
      [ $stale = 1 ] && $G -C "$w" worktree unlock "$w" 2>/dev/null
      if $G -C "$w" worktree remove --force "$w" 2>/dev/null; then echo "DEL   $w"; rm_n=$((rm_n+1))
      else echo "FAIL  $w"; keep_n=$((keep_n+1)); fi
    else echo "WOULD DELETE  $w"; rm_n=$((rm_n+1)); fi
  done < <($G -C "$repo" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' | tail -n +2)
  [ $APPLY = 1 ] && $G -C "$repo" worktree prune
done
echo "summary: $([ $APPLY = 1 ] && echo removed || echo 'would remove') $rm_n, kept $keep_n"
