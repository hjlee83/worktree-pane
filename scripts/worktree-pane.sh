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
remove_mode=0  # set by --remove/--close
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

--remove deletes the worktree directory and closes its pane, keeping the branch.
If the worktree has uncommitted changes it stops (interactively it prompts;
non-interactively it prints "WORKTREE_PANE_NEEDS_FORCE ..." and exits 3) unless
--force is given.

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
    --remove|--close|--rm) remove_mode=1; shift ;;
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

# --- normalize ticket-style names (PREFIX-123) to uppercase ---
is_ticket=0
if printf '%s' "$name" | grep -Eq '^[A-Za-z]+-[0-9]+$'; then
  name=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  is_ticket=1
fi

# --- resolve worktree path + label ---
repo_root=""
case "$name" in
  /*|\~*|*/*)
    wt="${name/#\~/$HOME}"
    label=$(basename "$wt")
    repo_root=$(git -C "$(dirname "$wt")" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || true)
    ;;
  *)
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
      echo "worktree-pane: not inside a git repo — pass a full path instead" >&2; exit 1; }
    case "$wt_root" in
      /*) wt="$wt_root/$name" ;;
      *)  wt="$repo_root/$wt_root/$name" ;;
    esac
    label="$name"
    ;;
esac
gitdir="${repo_root:-$PWD}"

# --- decide branch name ---
if [ -z "$branch" ]; then
  if [ "$is_ticket" -eq 1 ]; then
    branch="${branch_prefix}${name}"
  else
    branch="$name"
  fi
fi

# --- detect multiplexer ---
if [ "$mux" = "auto" ]; then
  if [ -n "${TMUX:-}" ]; then mux="tmux"
  elif command -v cmux >/dev/null 2>&1; then mux="cmux"
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

# ---------- remove mode ----------
do_remove() {
  [ -d "$wt" ] || { echo "worktree-pane: no worktree at $wt" >&2; exit 1; }
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

# ---------- create worktree if missing ----------
if [ ! -d "$wt" ]; then
  if git -C "$gitdir" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    echo "worktree-pane: checking out existing local branch '$branch'"
    git -C "$gitdir" worktree add "$wt" "$branch"
  elif git -C "$gitdir" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
    echo "worktree-pane: tracking remote 'origin/$branch'"
    git -C "$gitdir" worktree add "$wt" -b "$branch" "origin/$branch"
  else
    if [ -z "$base" ]; then
      base=$(git -C "$gitdir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)
      if [ -z "$base" ]; then
        for b in master main; do
          if git -C "$gitdir" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null; then base="$b"; break; fi
        done
      fi
      [ -n "$base" ] || { echo "worktree-pane: cannot detect default branch; pass --base" >&2; exit 1; }
      echo "worktree-pane: base auto-detected = '$base'"
    fi
    if git -C "$gitdir" rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null; then
      base_ref="origin/$base"
    else
      base_ref="$base"
    fi
    # Creating a brand-new branch must be confirmed.
    if [ "$create_new" -ne 1 ]; then
      if [ -t 0 ]; then
        printf "worktree-pane: no branch for '%s' yet. Create '%s' from '%s'? [y/N] " "$name" "$branch" "$base_ref" >&2
        read -r reply </dev/tty || reply=""
        case "$reply" in
          y|Y|yes|YES) ;;
          *) echo "worktree-pane: aborted (no branch created)."; exit 0 ;;
        esac
      else
        # Non-interactive (e.g. driven by an agent): defer the decision.
        echo "WORKTREE_PANE_NEEDS_CONFIRM branch='$branch' base='$base_ref' worktree='$wt'"
        exit 3
      fi
    fi
    echo "worktree-pane: creating '$branch' from '$base_ref'"
    git -C "$gitdir" worktree add "$wt" -b "$branch" "$base_ref"
  fi
else
  echo "worktree-pane: worktree already exists at $wt"
fi

# ---------- open the pane ----------
case "$mux" in
  tmux) open_tmux ;;
  cmux) open_cmux ;;
  none) echo "worktree-pane: no tmux/cmux detected — worktree ready at $wt"; echo "  cd $wt" ;;
  *) echo "worktree-pane: unknown mux '$mux'" >&2; exit 1 ;;
esac
