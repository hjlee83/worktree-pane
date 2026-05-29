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

## Installation

### Option A — Claude Code skill (recommended)

Clone into your user skills directory so it works in every project:

```bash
git clone https://github.com/hjlee83/worktree-pane.git ~/.claude/skills/worktree-pane
```

On first use Claude runs a short Q&A to save your preferences. You can skip it
and it still works with defaults.

### Option B — terminal installer (Q&A)

```bash
bash ~/.claude/skills/worktree-pane/install.sh
```

It detects your setup, asks 4 questions (each with a default — press Enter to
accept), writes `~/.config/worktree-pane/config.env`, and can add a `wt` alias.

### Option C — no install

```bash
bash ~/.claude/skills/worktree-pane/scripts/worktree-pane.sh FOO-1234
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
| `WORKTREE_PANE_MUX` | `auto` | `auto` / `tmux` / `cmux` / `none` |
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
| `--remove` `[--force]` | remove a worktree + close its pane (keeps the branch) |

Examples:

```bash
worktree-pane SELLERSYS-1234            # feature/SELLERSYS-1234 in .claude/worktrees/
worktree-pane FOO-12 --base develop     # branch off develop
worktree-pane sellersys-1234            # auto-uppercased
worktree-pane spike-cache --branch spike/cache   # non-ticket name + explicit branch
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

The whole tool is one self-contained shell script — `scripts/worktree-pane.sh`
— with no runtime dependency on personal dotfiles. `SKILL.md` is the Claude
Code entry point; `install.sh` is the terminal Q&A installer.

```bash
bash -n scripts/worktree-pane.sh        # syntax check
bash scripts/worktree-pane.sh --help    # usage
```

## License

[MIT](LICENSE)
