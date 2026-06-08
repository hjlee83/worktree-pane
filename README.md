# worktree-pane

![License](https://img.shields.io/github/license/hjlee83/worktree-pane)
![Stars](https://img.shields.io/github/stars/hjlee83/worktree-pane)

Create a git worktree for a ticket or branch and open it in a **new terminal
pane** — works in both **tmux** and **cmux**, across every workspace/session.
Built to run with as little setup as possible: use it as a Claude Code skill
(just ask in natural language) or as a plain shell command.

## Demo

```text
$ worktree-pane SELLERSYS-1234
worktree-pane: tracking remote 'origin/feature/SELLERSYS-1234'
worktree-pane: opened surface:7 → SELLERSYS-1234 (~/proj/.claude/worktrees/SELLERSYS-1234)
# → a new pane opens, already cd'd into the worktree, tab named "SELLERSYS-1234"

$ worktree-pane SELLERSYS-1234        # run again
worktree-pane: already open → focused surface:7 (SELLERSYS-1234)
# → no duplicate; it just jumps to the existing pane
```

Inside Claude Code you don't type the command — just say:

> SELLERSYS-1234 워크트리 만들어줘
> open a worktree for FOO-12

Claude then asks **where** to open it — a **new pane** (recommended) or a
**fresh session in the current pane** (no pane: the worktree is prepared and
you get the exact steps to start a clean `claude` there, plus how to resume
the previous session later). State the location up front ("새 pane 에 열어줘",
"open it in a new pane") to skip the question. To avoid surprises, ambiguous
words like "종료"/"close" make Claude confirm whether you mean *closing the
pane* or *deleting the worktree* — only explicit deletion words (삭제 /
remove / delete) go straight to removal.

## Installation

### Option A — Claude Code plugin (recommended, for teams)

This repo is a Claude Code **plugin marketplace**. In Claude Code:

```text
/plugin marketplace add hjlee83/worktree-pane
/plugin install worktree-pane@hjlee-tools
```

Update later with `/plugin marketplace update hjlee-tools` (or it auto-updates
at session start). Since the plugin pins no version, every pushed commit is the
latest. Share just those two lines with your team.

### Option B — clone into your skills dir (single machine)

A clone placed at `~/.claude/skills/<name>/` auto-loads next session as a
plugin (`worktree-pane@skills-dir`):

```bash
git clone https://github.com/hjlee83/worktree-pane.git ~/.claude/skills/worktree-pane
```

Update it with `git -C ~/.claude/skills/worktree-pane pull`.

### Optional — config Q&A / shell alias

```bash
bash ~/.claude/skills/worktree-pane/install.sh
```

It detects your setup, asks 4 questions (each with a default — press Enter to
accept), writes `~/.config/worktree-pane/config.env`, and can add a `wt` alias.
The skill works without it (sensible defaults).

### No install — run the script directly

```bash
bash <plugin-or-clone-dir>/skills/worktree-pane/scripts/worktree-pane.sh FOO-1234
```

### Requirements

- `git` with worktree support (2.5+)
- `bash` (works on macOS' bundled bash 3.2)
- a multiplexer to open the pane: `tmux` or `cmux` (without one it still
  creates the worktree and prints the `cd` path)
- `python3` — only used to detect already-open cmux panes (optional)

## How it works

Given a ticket like `FOO-1234`:

1. Resolve the worktree path (default `<repo>/.claude/worktrees/FOO-1234`).
2. Pick the branch — see the table below.
3. Open it in a **new pane** named after the worktree (cmux: tab title; tmux:
   the window the pane lives in).
4. If a pane for that worktree is already open **anywhere** — any cmux
   workspace, any tmux session/window — just focus it instead of duplicating.
5. **Launch the agent in the pane.** With `WORKTREE_PANE_AGENT=auto` (default)
   the pane starts the same agent that invoked the skill — Claude opens a new
   pane already running `claude`, Kiro runs `kiro`, etc. (detected via
   `$AI_AGENT` / `$CLAUDECODE`). When you jump to an already-open pane whose
   agent has since exited, it is relaunched. Set `none` for a plain shell.

### Branch resolution

| Situation | Action | Asks? |
|-----------|--------|-------|
| Local branch exists | check it out | no |
| Remote `origin/<prefix><TICKET>` exists | create a tracking worktree (continue existing work, non-destructive) | no |
| Neither exists | create a new branch | **yes** — confirm + choose base |

Creating a brand-new branch always requires confirmation. Interactively it
prompts; non-interactively (agent-driven) it prints
`WORKTREE_PANE_NEEDS_CONFIRM ...` and exits `3` so the agent can ask, then
re-runs with `--create-new`.

## Configuration

Optional. Lives at `~/.config/worktree-pane/config.env` (or set
`WORKTREE_PANE_CONFIG`). Env vars and flags override the file.

| Key | Default | Meaning |
|-----|---------|---------|
| `WORKTREE_PANE_MUX` | `auto` | `auto` / `tmux` / `cmux` / `none`. `auto` picks a multiplexer only when run **inside** one (`$TMUX` / `$CMUX_SURFACE_ID`); from a plain terminal it resolves to `none` (prepares the worktree, prints the `cd` path). Force with `--mux`. |
| `WORKTREE_PANE_ROOT` | `.claude/worktrees` | worktree dir, repo-relative or absolute |
| `WORKTREE_PANE_BRANCH_PREFIX` | `feature/` | prefix for ticket branches; blank = none |
| `WORKTREE_PANE_BASE` | *(empty)* | default base branch; blank = auto-detect |
| `WORKTREE_PANE_AGENT` | `auto` | what to run in the pane: `auto` (the invoking agent) / `none` (shell) / a command |

## Commands

```bash
worktree-pane <ticket-or-name> [--base <branch>] [--branch <branch>] \
              [--root <dir>] [--mux auto|tmux|cmux|none] \
              [--agent auto|none|<command>] [-y|--create-new]
worktree-pane /abs/path/to/worktree         # bare-path mode
worktree-pane --list [--all]                # list worktrees (path<TAB>branch)
worktree-pane --remove <ticket-or-path> [--force]   # remove worktree + close pane
```

| Flag | Meaning |
|------|---------|
| `--base <branch>` | base branch for a brand-new branch |
| `--branch <branch>` | override the derived branch name |
| `--root <dir>` | worktree directory (repo-relative or absolute) |
| `--mux <m>` | force `auto` / `tmux` / `cmux` / `none` |
| `--agent <a>` | what to run in the pane: `auto` / `none` / a command |
| `-y`, `--create-new` | allow creating a new branch without prompting |
| `--list` `[--all]` | print worktrees (skips temp ones unless `--all`) |
| `--stale` `[--base <b>]` | classify worktrees `completed`/`active`/`gray` (read-only) for cleanup; delete chosen ones with `--remove` |
| `--remove` / `--rm` `[--force]` | remove a worktree + close its pane (keeps the branch) |
| `--close` | **not** a remove alias — refuses (non-destructive); close panes via your multiplexer |

Examples:

```bash
worktree-pane SELLERSYS-1234            # feature/SELLERSYS-1234 in .claude/worktrees/
worktree-pane hotfix/SELLERSYS-1234     # full branch name kept as-is; dir = SELLERSYS-1234
worktree-pane FOO-12 --base develop     # branch off develop
worktree-pane sellersys-1234            # auto-uppercased
worktree-pane spike-cache --branch spike/cache   # non-ticket name + explicit branch
```

### Cleaning up finished worktrees

`--stale` classifies worktrees so you can see which are safe to delete. It only
reads — nothing is removed until you call `--remove`. Run `git fetch --prune`
first so merge/upstream state is accurate:

```bash
git fetch --prune
worktree-pane --stale
# completed   …/SELLERSYS-8116   feature/SELLERSYS-8116                  2 weeks ago   clean
# gray        …/SPIKE-cache      spike/cache                             6 weeks ago   clean
# active      …/SELLERSYS-9001   feature/SELLERSYS-9001                  2 days ago    dirty
```

- **completed** — merged into an integration branch, or its upstream is gone
  (covers squash/rebase teams). Safe to delete.
- **active** — recent, unmerged. Keep it.
- **gray** — unmerged but older than `WORKTREE_PANE_STALE_DAYS` (default 14).
  Could be on hold or abandoned — your call; never auto-deleted.

Then delete the ones you chose (keeps the branch; `--force` if it's dirty):

```bash
worktree-pane --remove SELLERSYS-8116
```

## Troubleshooting

<details>
<summary>The tmux pane name isn't showing</summary>

The worktree name is set as the **window** name. If you don't see it, your
status bar may hide window names — check `set -g window-status-format` in your
`~/.tmux.conf`. The detection still works regardless of what's displayed.
</details>

<details>
<summary>"cannot detect default branch; pass --base"</summary>

The repo has no `origin/HEAD` and neither `master` nor `main` exists on the
remote. Pass an explicit base: `worktree-pane FOO-1 --base <branch>`.
</details>

<details>
<summary>It created a new branch from the wrong base</summary>

New-branch creation asks for the base first (interactively, or via the agent).
If you scripted it with `--create-new`, also pass `--base <branch>` — otherwise
it falls back to the repo's auto-detected default branch.
</details>

<details>
<summary>Already-open detection isn't finding my pane (cmux)</summary>

Detection of open cmux panes uses `python3`. If it's not on `PATH`, the script
still works but will open a new pane instead of focusing the existing one.
</details>

## Development

The whole tool is one self-contained shell script —
`skills/worktree-pane/scripts/worktree-pane.sh` — with no runtime dependency on
personal dotfiles. `skills/worktree-pane/SKILL.md` is the Claude Code entry
point; `.claude-plugin/{plugin,marketplace}.json` make the repo an installable
plugin marketplace; `install.sh` is the optional config Q&A. Design notes live
in `docs/purpose-and-use-cases.md`.

```bash
S=skills/worktree-pane/scripts/worktree-pane.sh
bash -n "$S"            # syntax check
bash "$S" --help        # usage
claude plugin validate . --strict   # validate manifests
```

## License

[MIT](LICENSE)
