#!/usr/bin/env bash
# worktree-pane — create a git worktree for a ticket/branch and open it in a
# new terminal pane. Portable across tmux and cmux. Zero-config by default;
# every default is overridable via config file or env vars / flags.
#
# Config (sourced if present): ~/.config/worktree-pane/config.env
#   WORKTREE_PANE_MUX=auto|tmux|cmux|none
#   WORKTREE_PANE_ROOT=.claude/worktrees      # repo-relative or absolute
#   WORKTREE_PANE_BRANCH_PREFIX=feature/      # set empty for no prefix
#   WORKTREE_PANE_BASE=                       # default base branch override
#
# Usage:
#   worktree-pane <ticket-or-name> [--base <branch>] [--branch <branch>]
#                 [--root <dir>] [--mux auto|tmux|cmux|none]
#   worktree-pane /abs/path/to/worktree       # bare-path mode
#
# Examples:
#   worktree-pane SELLERSYS-1234              # -> .claude/worktrees/SELLERSYS-1234, branch feature/SELLERSYS-1234
#   worktree-pane FOO-12 --base develop       # base override
#   worktree-pane sellersys-1234              # auto-uppercased to SELLERSYS-1234
set -eu

CONFIG_FILE="${WORKTREE_PANE_CONFIG:-$HOME/.config/worktree-pane/config.env}"
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

mux="${WORKTREE_PANE_MUX:-auto}"
wt_root="${WORKTREE_PANE_ROOT:-.claude/worktrees}"
branch_prefix="${WORKTREE_PANE_BRANCH_PREFIX-feature/}"   # '-' keeps an explicit empty value
base="${WORKTREE_PANE_BASE:-}"
name=""
branch=""
create_new=0   # set by -y/--create-new to allow creating a brand-new branch non-interactively
list_mode=0    # set by --list
all=0          # set by --all (include temporary/agent worktrees in --list)
remove_mode=0  # set by --remove/--rm
force=0        # set by --force (remove a dirty worktree without asking)
agent="${WORKTREE_PANE_AGENT:-auto}"   # what to launch in the new pane: auto|none|<command>

usage() {
  cat <<'EOF'
worktree-pane — create a git worktree and open it in a new terminal pane (tmux/cmux).

Usage:
  worktree-pane <ticket-or-name> [--base <branch>] [--branch <branch>]
                [--root <dir>] [--mux auto|tmux|cmux|none]
                [--agent auto|none|<command>] [-y|--create-new]
  worktree-pane /abs/path/to/worktree       # bare-path mode
  worktree-pane --list [--all]              # list worktrees (TAB: path<TAB>branch)
  worktree-pane --remove <ticket-or-path> [--force]   # remove a worktree + close its pane

--remove (alias --rm) deletes the worktree directory and closes its pane,
keeping the branch. If the worktree has uncommitted changes it stops
(interactively it prompts; non-interactively it prints "WORKTREE_PANE_NEEDS_FORCE
..." and exits 3) unless --force is given. --close is NOT an alias for this: it
is non-destructive and refuses (close a pane via your multiplexer instead).

--agent decides what runs in the pane: 'auto' (default) launches the agent that
invoked this script (detected via $AI_AGENT / $CLAUDECODE), 'none' just opens a
shell, any other value is run verbatim. When focusing an already-open pane whose
agent has exited, it is relaunched.

--list prints existing worktrees one per line as "path<TAB>branch", skipping
the main checkout and (unless --all) temporary worktrees whose branch starts
with "worktree-". Meant to feed a picker.

Creating a brand-new branch requires confirmation: interactively it prompts,
non-interactively it prints "WORKTREE_PANE_NEEDS_CONFIRM ..." and exits 3
(pass -y/--create-new to proceed). Existing local/remote branches are reused
without asking.

Config (optional): ~/.config/worktree-pane/config.env
  WORKTREE_PANE_MUX=auto|tmux|cmux|none
  WORKTREE_PANE_ROOT=.claude/worktrees
  WORKTREE_PANE_BRANCH_PREFIX=feature/
  WORKTREE_PANE_BASE=
  WORKTREE_PANE_AGENT=auto|none|<command>
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base)   base="$2";   shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --root)   wt_root="$2"; shift 2 ;;
    --mux)    mux="$2";    shift 2 ;;
    --agent)  agent="$2";  shift 2 ;;
    -y|--create-new) create_new=1; shift ;;
    --list|--ls) list_mode=1; shift ;;
    --remove|--rm) remove_mode=1; shift ;;
    --close)
      # 'close' is non-destructive elsewhere (close a pane / drop attention), so
      # it must NOT delete a worktree. Refuse and point to the right action.
      echo "worktree-pane: --close does not delete anything." >&2
      echo "  To close a pane, use your multiplexer (cmux: close-surface, tmux: Ctrl-b x)." >&2
      echo "  To delete the worktree directory, use --remove (keeps the branch)." >&2
      exit 2 ;;
    --force) force=1; shift ;;
    --all) all=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "worktree-pane: unknown flag: $1" >&2; exit 1 ;;
    *) name="$1"; shift ;;
  esac
done

# ---------- list mode ----------
do_list() {
  local repo
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "worktree-pane: not a git repo" >&2; exit 1; }
  git -C "$repo" worktree list --porcelain | awk -v all="$all" '
    function out() {
      if (path == "" || cnt == 1) return                       # skip blanks + main checkout
      if (all == "1") { print path "\t" (branch=="" ? "(detached)" : branch); return }
      if (branch != "" && branch !~ /^worktree-/) print path "\t" branch
    }
    /^worktree / { out(); cnt++; path=substr($0,10); branch="" }
    /^branch /   { branch=$0; sub(/^branch refs\/heads\//,"",branch) }
    END { out() }
  '
}

if [ "$list_mode" -eq 1 ]; then do_list; exit 0; fi

[ -n "$name" ] || { usage; exit 1; }

# --- normalize ticket-style names (PREFIX-123, optionally with a -suffix) ---
# Matches SELLERSYS-8451 and SELLERSYS-8451-distributed-lock-core alike. Only the
# PREFIX-NUM head is uppercased; any suffix is kept verbatim. ticket_id holds the
# head so we can later find existing branches for the same ticket (anti-fork).
is_ticket=0
ticket_id=""
if printf '%s' "$name" | grep -Eq '^[A-Za-z]+-[0-9]+([-_].*)?$'; then
  is_ticket=1
  head=$(printf '%s' "$name" | grep -Eo '^[A-Za-z]+-[0-9]+')
  rest=${name#"$head"}
  ticket_id=$(printf '%s' "$head" | tr '[:lower:]' '[:upper:]')
  name="${ticket_id}${rest}"
fi

# --- resolve worktree path + label ---
# A bare path is only assumed when the input is *clearly* a path: it starts with
# /, ~, ./ or ../, OR it contains a slash AND already exists on disk. Otherwise
# the input is a NAME — which may itself contain slashes (a branch name like
# `feature/SELLERSYS-7652`). The directory is named after the branch's basename.
repo_root=""
is_path=0
case "$name" in
  /*|\~*|./*|../*) is_path=1 ;;
  */*)             [ -e "$name" ] && is_path=1 ;;
esac
if [ "$is_path" -eq 1 ]; then
  wt="${name/#\~/$HOME}"
  label=$(basename "$wt")
  repo_root=$(git -C "$(dirname "$wt")" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || true)
else
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "worktree-pane: not inside a git repo — pass a full path instead" >&2; exit 1; }
  label=$(basename "$name")            # branch may contain slashes; dir = basename
  case "$wt_root" in
    /*) wt="$wt_root/$label" ;;
    *)  wt="$repo_root/$wt_root/$label" ;;
  esac
fi
gitdir="${repo_root:-$PWD}"

# --- decide branch name (name mode only; bare-path mode targets an existing wt) ---
if [ -z "$branch" ] && [ "$is_path" -ne 1 ]; then
  if [ "$is_ticket" -eq 1 ]; then
    branch="${branch_prefix}${name}"
  else
    branch="$name"                     # full branch name as given (may contain '/')
  fi
fi

# --- detect multiplexer (must be INSIDE a session, not merely installed) ---
# $TMUX is set only inside a tmux session; CMUX_SURFACE_ID only inside a cmux
# surface. Gating on these (not `command -v`) avoids picking cmux when it's just
# on PATH but the call came from a plain terminal — there's no pane to open, so
# 'none' is the right answer (a normal mux-out mode, not a failure).
if [ "$mux" = "auto" ]; then
  if [ -n "${TMUX:-}" ]; then mux="tmux"
  elif [ -n "${CMUX_SURFACE_ID:-}" ] && command -v cmux >/dev/null 2>&1; then mux="cmux"
  else mux="none"; fi
fi

# ---------- agent autostart ----------
# What to launch inside the pane. 'auto' detects the agent that invoked this
# script from the environment (cmux sets AI_AGENT; Claude Code sets CLAUDECODE).
# 'none' disables it. Any other value is run verbatim as the command.
resolve_agent_cmd() {
  case "$agent" in
    none|"") return 0 ;;
    auto)
      local a="${AI_AGENT:-}" cmd=""
      case "$a" in
        *claude*) cmd=claude ;;
        *kiro*)   cmd=kiro ;;
        *codex*)  cmd=codex ;;
        *cursor*) cmd=cursor-agent ;;
        *gemini*) cmd=gemini ;;
        *)
          if   [ -n "${CLAUDECODE:-}" ]; then cmd=claude
          elif [ -n "${CODEX_HOME:-}${CODEX_SANDBOX:-}" ]; then cmd=codex
          fi ;;
      esac
      [ -n "$cmd" ] && command -v "$cmd" >/dev/null 2>&1 && printf '%s' "$cmd"
      ;;
    *) printf '%s' "$agent" ;;
  esac
}
agent_cmd=$(resolve_agent_cmd)
# Process names that mean "an agent is already running" in a pane (heuristic —
# Claude/others run under node, so node counts as on).
agent_proc_re='^(node|claude|kiro|codex|cursor-agent|gemini)$'

agent_running_on_tty() {   # 0 if an agent process is on this tty (cmux)
  local tty="${1#/dev/}"
  [ -n "$tty" ] || return 1
  ps -t "$tty" -o comm= 2>/dev/null | sed 's@.*/@@' | grep -qiE "$agent_proc_re"
}
tmux_agent_running() {     # 0 if the window's active pane is running an agent
  local cmd
  cmd=$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)
  printf '%s\n' "$cmd" | grep -qiE "$agent_proc_re"
}

# ---------- pane helpers ----------
cmux_find() {  # echoes "window workspace pane surface tty" if a surface titled $label exists
  command -v python3 >/dev/null 2>&1 || return 1
  cmux tree --all 2>/dev/null | python3 -c '
import re, sys
target = sys.argv[1]
window = workspace = pane = None
for line in sys.stdin:
    if "surface " in line:
        m = re.search(r"surface (surface:\d+) \[\w+\] \"([^\"]*)\"", line)
        if m and m.group(2) == target:
            t = re.search(r"tty=(\S+)", line)
            print("|".join([window or "", workspace or "", pane or "", m.group(1), (t.group(1) if t else "")]))
            sys.exit(0)
        continue
    if "pane " in line:
        m = re.search(r"pane (pane:\d+)", line)
        if m: pane = m.group(1)
    elif "workspace " in line:
        m = re.search(r"workspace (workspace:\d+)", line)
        if m: workspace = m.group(1)
    elif "window " in line:
        m = re.search(r"window (window:\d+)", line)
        if m: window = m.group(1)
' "$label" 2>/dev/null
}

cmux_run() {  # send a command line + Enter to a surface
  cmux send --surface "$1" "$2" >/dev/null
  cmux send-key --surface "$1" Enter >/dev/null
}

open_cmux() {
  local match w ws p s tty out sfc
  match=$(cmux_find || true)
  if [ -n "$match" ]; then
    local oldifs="$IFS"
    IFS='|'   # non-whitespace delimiter so empty fields are preserved
    read -r w ws p s tty <<EOF
$match
EOF
    IFS="$oldifs"
    [ -n "$w" ]  && cmux focus-window --window "$w" >/dev/null 2>&1 || true
    [ -n "$ws" ] && cmux select-workspace --workspace "$ws" ${w:+--window "$w"} >/dev/null 2>&1 || true
    [ -n "$p" ]  && cmux focus-pane --pane "$p" ${ws:+--workspace "$ws"} >/dev/null 2>&1 || true
    # Restart the agent if the pane fell back to a bare shell.
    if [ -n "$agent_cmd" ] && [ -n "$s" ] && ! agent_running_on_tty "$tty"; then
      cmux_run "$s" "$agent_cmd"
      echo "worktree-pane: already open → focused $s ($label) + relaunched '$agent_cmd'"
    else
      echo "worktree-pane: already open → focused $s ($label)"
    fi
    return 0
  fi
  out=$(cmux new-pane --direction right --focus true)
  sfc=$(printf '%s\n' "$out" | grep -oE 'surface:[0-9]+' | head -1)
  [ -n "$sfc" ] || { echo "worktree-pane: failed to parse cmux surface" >&2; return 1; }
  cmux_run "$sfc" "cd $wt"
  cmux rename-tab --surface "$sfc" "$label" >/dev/null
  if [ -n "$agent_cmd" ]; then
    cmux_run "$sfc" "$agent_cmd"
    echo "worktree-pane: opened $sfc → $label ($wt) + launched '$agent_cmd'"
  else
    echo "worktree-pane: opened $sfc → $label ($wt)"
  fi
}

open_tmux() {
  # Identity is the window name (= worktree label). Detection spans every
  # session/window, not just the attached one. Fall back to matching a pane's
  # current path in case the window was renamed.
  local sess win
  win=$(tmux list-windows -a -F '#{window_name}	#{session_name}:#{window_index}' 2>/dev/null \
          | awk -F'	' -v n="$label" '$1==n {print $2; exit}')
  if [ -z "$win" ]; then
    win=$(tmux list-panes -a -F '#{pane_current_path}	#{session_name}:#{window_index}' 2>/dev/null \
            | awk -F'	' -v p="$wt" '$1==p {print $2; exit}')
  fi
  if [ -n "$win" ]; then
    sess="${win%%:*}"
    tmux switch-client -t "$sess" >/dev/null 2>&1 || true
    tmux select-window -t "$win" >/dev/null 2>&1 || true
    # Restart the agent if the window's active pane fell back to a bare shell.
    if [ -n "$agent_cmd" ] && ! tmux_agent_running "$win"; then
      tmux send-keys -t "$win" "$agent_cmd" Enter
      echo "worktree-pane: already open → focused $win ($label) + relaunched '$agent_cmd'"
    else
      echo "worktree-pane: already open → focused $win ($label)"
    fi
    return 0
  fi
  # New split pane; name the window it lives in after the worktree.
  tmux split-window -h -c "$wt"
  tmux rename-window "$label" >/dev/null 2>&1 || true
  if [ -n "$agent_cmd" ]; then
    tmux send-keys "$agent_cmd" Enter   # active pane is the new split
    echo "worktree-pane: opened tmux pane → window '$label' ($wt) + launched '$agent_cmd'"
  else
    echo "worktree-pane: opened tmux pane → window '$label' ($wt)"
  fi
}

# ---------- close pane (used by remove) ----------
close_pane() {
  case "$mux" in
    cmux)
      local match s oldifs
      match=$(cmux_find || true)
      [ -n "$match" ] || return 0
      oldifs="$IFS"; IFS='|'; read -r _ _ _ s _ <<EOF
$match
EOF
      IFS="$oldifs"
      [ -n "$s" ] && cmux close-surface --surface "$s" >/dev/null 2>&1 \
        && echo "worktree-pane: closed cmux pane $s"
      ;;
    tmux)
      tmux list-panes -a -F '#{pane_current_path}	#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null \
        | awk -F'	' -v p="$wt" '$1==p {print $2}' \
        | while IFS= read -r pn; do
            tmux kill-pane -t "$pn" 2>/dev/null && echo "worktree-pane: closed tmux pane $pn"
          done
      ;;
  esac
}

# True only when $1 is the ROOT of its own git worktree. Guards against the
# silent fallback where `git -C <dir>` on an orphan/stray directory walks up to
# an ancestor repo (e.g. the main checkout) and operates on THAT instead — so a
# `git -C "$wt" status` could read the main repo's state by mistake.
is_worktree_root() {
  local d top
  d=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$top" = "$d" ]
}

# Canonicalize a path even if it doesn't exist (parent must exist).
canon_path() {
  if [ -d "$1" ]; then (cd "$1" 2>/dev/null && pwd -P); return; fi
  local d; d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "$d" "$(basename "$1")"
}
path_under() { case "$2" in "$1"/*) return 0 ;; *) return 1 ;; esac; }   # path_under <parent> <child>

# Report an orphan and exit. $1=kind (prunable|stray-dir), $2=path. Interactive:
# print the safe cleanup command. Non-interactive: machine marker for the caller.
orphan_report() {
  if [ -t 0 ]; then
    case "$1" in
      prunable)  echo "worktree-pane: '$2' is registered but its directory is gone (orphan)." >&2
                 echo "  Safe to clean the stale entry: git -C \"$gitdir\" worktree prune" >&2 ;;
      stray-dir) echo "worktree-pane: '$2' is a stray directory (no .git, not a registered worktree)." >&2
                 echo "  git can't remove it; if you're sure it's junk: rm -rf \"$2\"" >&2 ;;
    esac
  else
    echo "WORKTREE_PANE_ORPHAN kind='$1' worktree='$2'"
  fi
  exit 1
}

# ---------- remove mode ----------
do_remove() {
  local canon registered=0 wt_root_abs
  canon=$(canon_path "$wt")
  if [ -n "$canon" ] && git -C "$gitdir" worktree list --porcelain 2>/dev/null \
       | grep -Fxq "worktree $canon"; then registered=1; fi
  case "$wt_root" in /*) wt_root_abs="$wt_root" ;; *) wt_root_abs="$gitdir/$wt_root" ;; esac
  wt_root_abs=$(cd "$wt_root_abs" 2>/dev/null && pwd -P) || wt_root_abs=""

  if [ ! -d "$wt" ]; then
    [ "$registered" -eq 1 ] && orphan_report prunable "$wt"   # registered but dir gone
    echo "worktree-pane: no worktree at $wt" >&2; exit 1
  fi
  if ! is_worktree_root "$wt"; then
    # Dir exists but isn't its own worktree root. Only propose `rm -rf` when it's
    # a stray dir DIRECTLY under the worktree root (never for arbitrary paths —
    # e.g. a real source dir of the main repo). Otherwise refuse without a
    # destructive suggestion.
    if [ "$registered" -ne 1 ] && [ -n "$wt_root_abs" ] && [ -n "$canon" ] \
       && path_under "$wt_root_abs" "$canon" && [ ! -e "$wt/.git" ]; then
      orphan_report stray-dir "$wt"
    fi
    echo "worktree-pane: '$wt' is not a worktree root (resolves to '$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)')." >&2
    echo "  Refusing to operate so the main repo isn't touched by fallback. Inspect and remove manually if intended." >&2
    exit 1
  fi
  if [ "$force" -ne 1 ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    if [ -t 0 ]; then
      printf "worktree-pane: '%s' has uncommitted changes. Remove anyway? [y/N] " "$label" >&2
      read -r reply </dev/tty || reply=""
      case "$reply" in y|Y|yes|YES) force=1 ;; *) echo "worktree-pane: aborted (nothing removed)."; exit 0 ;; esac
    else
      echo "WORKTREE_PANE_NEEDS_FORCE worktree='$wt' label='$label' reason='uncommitted changes'"
      exit 3
    fi
  fi
  close_pane   # while the dir still exists, so pane-by-path matching works
  if [ "$force" -eq 1 ]; then
    git -C "$gitdir" worktree remove --force "$wt"
  else
    git -C "$gitdir" worktree remove "$wt"
  fi
  echo "worktree-pane: removed worktree '$label' ($wt) — branch kept"
}

if [ "$remove_mode" -eq 1 ]; then do_remove; exit 0; fi

# ---------- base candidates (for a brand-new branch) ----------
# Emit a deduped, ordered list of plausible base refs so the caller can let the
# user choose: repo default (origin/HEAD → master → main), then develop if it
# exists, then branches of live worktrees (epics / other active work — M2b).
# The new branch being created is excluded. Prefer origin/<x> when that
# remote-tracking ref resolves, else the bare name.
base_candidates() {
  local seen=" " out="" x ref
  add() {
    x="$1"
    [ -n "$x" ] || return 0
    [ "$x" = "$branch" ] && return 0                 # never offer the new branch itself
    case "$seen" in *" $x "*) return 0 ;; esac       # dedup by branch name
    seen="$seen$x "
    if git -C "$gitdir" rev-parse --verify --quiet "refs/remotes/origin/$x" >/dev/null; then
      ref="origin/$x"
    else
      ref="$x"
    fi
    out="${out:+$out|}$ref"
  }
  # 1) repo default
  add "$(git -C "$gitdir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  for b in master main; do
    git -C "$gitdir" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null && add "$b"
  done
  # 2) develop (common integration branch), if present local or remote
  if git -C "$gitdir" rev-parse --verify --quiet refs/remotes/origin/develop >/dev/null \
     || git -C "$gitdir" rev-parse --verify --quiet refs/heads/develop >/dev/null; then
    add develop
  fi
  # 3) branches of live worktrees (epics / other active work)
  while IFS=$'\t' read -r _ wb; do add "$wb"; done <<EOF
$(do_list)
EOF
  printf '%s' "$out"
}

# ---------- create worktree if missing ----------
if [ ! -d "$wt" ]; then
  if git -C "$gitdir" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    echo "worktree-pane: checking out existing local branch '$branch'"
    git -C "$gitdir" worktree add "$wt" "$branch"
  elif git -C "$gitdir" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null \
       || [ -n "$(git -C "$gitdir" ls-remote --heads origin "$branch" 2>/dev/null)" ]; then
    # Remote branch exists — locally tracked, OR present on the remote but not
    # fetched yet (e.g. someone just pushed it). Fetch so origin/<branch>
    # resolves, then create a tracking worktree to continue that work.
    echo "worktree-pane: tracking remote 'origin/$branch'"
    git -C "$gitdir" fetch -q origin "$branch" 2>/dev/null || true
    git -C "$gitdir" worktree add "$wt" -b "$branch" "origin/$branch"
  else
    # (B) Anti-fork: no exact branch, but maybe one already exists for this
    # ticket under a different prefix/suffix (e.g. typed SELLERSYS-8451, remote
    # has feature/SELLERSYS-8451-distributed-lock-core). Find local+remote
    # branches containing the ticket id and defer the choice — re-invoking with
    # the chosen full branch name resolves cleanly via the exact-match paths
    # above. --create-new skips this and forces a new branch.
    if [ "$create_new" -ne 1 ] && [ -n "$ticket_id" ]; then
      matches=$(
        { git -C "$gitdir" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null
          git -C "$gitdir" ls-remote --heads origin 2>/dev/null | sed 's@.*refs/heads/@@'
        } | grep -E "${ticket_id}([^0-9]|\$)" | grep -vxF "$branch" | sort -u | paste -sd'|' -
      )
      if [ -n "$matches" ]; then
        if [ -t 0 ]; then
          echo "worktree-pane: no exact branch '$branch', but found existing branch(es) for $ticket_id:" >&2
          i=0; IFS='|'; set -- $matches; unset IFS
          for m in "$@"; do i=$((i+1)); printf "  %d) %s\n" "$i" "$m" >&2; done
          echo "  To use one:  worktree-pane <that-branch-name>" >&2
          echo "  To create new '$branch' anyway:  re-run with --create-new" >&2
          exit 3
        else
          echo "WORKTREE_PANE_TICKET_MATCHES branch='$branch' ticket='$ticket_id' matches='$matches' worktree='$wt'"
          exit 3
        fi
      fi
    fi
    # Gather base candidates unless the user pinned one with --base.
    cands=""
    if [ -z "$base" ]; then
      cands=$(base_candidates)
      base=$(git -C "$gitdir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)
      if [ -z "$base" ]; then
        for b in master main; do
          if git -C "$gitdir" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null; then base="$b"; break; fi
        done
      fi
      [ -n "$base" ] || { echo "worktree-pane: cannot detect default branch; pass --base" >&2; exit 1; }
    fi
    if git -C "$gitdir" rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null; then
      base_ref="origin/$base"
    else
      base_ref="$base"
    fi
    # Creating a brand-new branch must be confirmed; offer the base candidates.
    if [ "$create_new" -ne 1 ]; then
      if [ -t 0 ]; then
        if [ -n "$cands" ]; then
          echo "worktree-pane: no branch for '$name' yet — choose a base for new '$branch':" >&2
          i=0; IFS='|'; set -- $cands; unset IFS
          for c in "$@"; do i=$((i+1)); printf "  %d) %s%s\n" "$i" "$c" \
            "$([ "$c" = "$base_ref" ] && printf ' (default)')" >&2; done
          printf "  select [1-%d, Enter=default '%s', n=cancel]: " "$i" "$base_ref" >&2
          read -r reply </dev/tty || reply=""
          case "$reply" in
            ""|y|Y|yes|YES) ;;                                   # keep base_ref
            n|N|no|NO) echo "worktree-pane: aborted (no branch created)."; exit 0 ;;
            *[!0-9]*) echo "worktree-pane: invalid selection; aborted." >&2; exit 1 ;;
            *) base_ref=$(printf '%s' "$cands" | cut -d'|' -f"$reply")
               [ -n "$base_ref" ] || { echo "worktree-pane: selection out of range; aborted." >&2; exit 1; } ;;
          esac
        else
          printf "worktree-pane: no branch for '%s' yet. Create '%s' from '%s'? [y/N] " "$name" "$branch" "$base_ref" >&2
          read -r reply </dev/tty || reply=""
          case "$reply" in y|Y|yes|YES) ;; *) echo "worktree-pane: aborted (no branch created)."; exit 0 ;; esac
        fi
      else
        # Non-interactive (e.g. driven by an agent): defer the decision, and
        # hand back the candidate list so the caller can present a choice.
        echo "WORKTREE_PANE_NEEDS_CONFIRM branch='$branch' base='$base_ref' worktree='$wt'"
        [ -n "$cands" ] && echo "WORKTREE_PANE_BASE_CANDIDATES $cands"
        exit 3
      fi
    fi
    echo "worktree-pane: creating '$branch' from '$base_ref'"
    # --no-track: a brand-new feature branch must not inherit the base as its
    # upstream (else `git pull` would merge e.g. master into it, and merge-state
    # detection misreads it). The user sets the real upstream later via
    # `git push -u origin <branch>`.
    git -C "$gitdir" worktree add "$wt" --no-track -b "$branch" "$base_ref"
  fi
else
  # The dir name is the branch's basename, so two branches with the same
  # basename (e.g. feature/X and hotfix/X) would map to the same dir. If it
  # already holds a *different* branch, refuse rather than open the wrong one.
  if [ "$is_path" -ne 1 ] && [ -n "$branch" ] && is_worktree_root "$wt"; then
    cur=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$cur" ] && [ "$cur" != "$branch" ]; then
      echo "worktree-pane: '$wt' already holds branch '$cur', not '$branch' (basename collision)." >&2
      echo "  Use --branch <name> to disambiguate, or --root <dir> for a separate location." >&2
      exit 1
    fi
  fi
  echo "worktree-pane: worktree already exists at $wt"
fi

# ---------- open the pane ----------
case "$mux" in
  tmux) open_tmux ;;
  cmux) open_cmux ;;
  none) echo "worktree-pane: no tmux/cmux detected — worktree ready at $wt"; echo "  cd $wt" ;;
  *) echo "worktree-pane: unknown mux '$mux'" >&2; exit 1 ;;
esac
