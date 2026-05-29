---
name: worktree-pane
description: >-
  Create a git worktree for a ticket or branch and open it in a new terminal
  pane (tmux or cmux). Use when the user asks to make/open a worktree — e.g.
  "SELLERSYS-1234 워크트리 만들어줘", "open a worktree for FOO-12",
  "<ticket> 워크트리를 새 pane 에 띄워줘". Portable and zero-config: every
  default is auto-detected and overridable.
---

# worktree-pane

Creates a git worktree for the requested ticket/branch and opens it in a new
split pane of whatever terminal multiplexer is running (tmux or cmux). All the
real logic lives in the bundled script — your job is to map the user's request
onto it and report the result.

The script is at `scripts/worktree-pane.sh` **relative to this skill file**.
Resolve the absolute path before running (the skill may be installed at user
scope `~/.claude/skills/worktree-pane/` or project scope).

## First run — interactive setup (Q&A)

If the config file `~/.config/worktree-pane/config.env` does **not** exist,
the user is new. Offer a quick Q&A setup before the first worktree:

1. Detect the environment yourself: multiplexer (`$TMUX` → tmux, else `cmux`
   on PATH → cmux, else none) and the repo's default base branch
   (`git symbolic-ref --short refs/remotes/origin/HEAD`).
2. Use **AskUserQuestion** to confirm, presenting detected values as the first
   (recommended) option:
   - Multiplexer: `auto` (recommended) / tmux / cmux / none
   - Worktree directory: `.claude/worktrees` (recommended) / custom
   - Branch prefix: `feature/` (recommended) / none / custom
   - Default base: `auto-detect` (recommended) / a specific branch
3. Write the answers to `~/.config/worktree-pane/config.env` in this format:
   ```
   WORKTREE_PANE_MUX=auto
   WORKTREE_PANE_ROOT=.claude/worktrees
   WORKTREE_PANE_BRANCH_PREFIX=feature/
   WORKTREE_PANE_BASE=
   ```

Terminal-only users (no Claude) can instead run `bash install.sh`, which does
the same Q&A with `read` prompts. The skill works **without** any config too —
the script falls back to the same auto-detected defaults — so if the user just
wants it done now, skip setup and run the script directly.

## Normal invocation

Run the bundled script with the ticket/name the user gave:

```bash
bash "<skill-dir>/scripts/worktree-pane.sh" <TICKET-OR-NAME>
```

- Pass the name **exactly as spoken**; the script uppercases ticket-style
  names (`foo-12` → `FOO-12`) and prepends the branch prefix on its own.
- Honor explicit overrides from the user as flags:
  `--base <branch>`, `--branch <branch>`, `--root <dir>`, `--mux tmux|cmux|none`.
- The script is idempotent: if the worktree already exists it reuses it, and
  if a pane for it is already open **anywhere** (any cmux workspace, any tmux
  session/window) it just focuses that pane instead of making a new one.
- The pane carries the worktree name: cmux renames the tab, tmux renames the
  window the new split pane lives in.

### Branch resolution (handled by the script — don't pre-empt it)

1. Local branch `<prefix><TICKET>` exists → check it out (no questions).
2. Else remote `origin/<prefix><TICKET>` exists → create a tracking worktree
   to continue existing work — important so the same ticket doesn't fork
   (no questions).
3. Else a brand-new branch is needed → **must be confirmed** (see below).

### Confirming a new branch

When no local or remote branch exists, the script will **not** create one on
its own. Run it normally first; if it prints a line starting with
`WORKTREE_PANE_NEEDS_CONFIRM` and exits with code 3, that means a new branch
would be created. Parse the proposed `branch='...'` and `base='...'`, then use
**AskUserQuestion** to confirm with the user:

- whether to create the branch at all, and
- which **base** to branch from (offer the proposed base as the recommended
  option; also offer `develop`/`main`/`master` if they exist, plus "other").

The branch **name** is derived from the ticket — don't ask about it unless the
user volunteers one. Once confirmed, re-invoke with the chosen base and the
confirm flag:

```bash
bash "<skill-dir>/scripts/worktree-pane.sh" <TICKET> --base <chosen> --create-new
```

If the user declines, stop — create nothing.

## After running

Report concisely: the worktree path, the branch, which of the three modes
fired (new / local checkout / remote tracking), and that the pane opened (or
was already open). If `mux` resolved to `none`, tell the user to `cd` into the
printed path.
