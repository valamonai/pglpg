# Agent Instructions

**pglpg** is a Ruby library that provides APIs for working with labeled property graphs (LPG) stored in plain PostgreSQL tables. It follows the ISO GQL property graph model and PG-Schema / PG-Keys. It is a library only: no application, no server, no second database.

This project uses **knowen.md** (knowen.md) as its knowledge base and issue tracker.
Read [pglpg.md](https://knowen.md/nodes/36325) before any work.
Use the knowen.md MCP server to work with knowen.md.

## Documentation

All project knowledge lives in the [pglpg.md](https://knowen.md/nodes/36325) subgraph:

| Document | Answers |
| -------- | ------- |
| [VISION.md](https://knowen.md/nodes/36327) | Why does the library exist, and what is out of scope? |
| [DOMAIN.md](https://knowen.md/nodes/36328) | What do the property graph terms and concepts mean? |
| [STANDARDS.md](https://knowen.md/nodes/36336) | Which LPG standards do we follow (GQL, PG-Schema, PG-Keys), and how far? |
| [API.md](https://knowen.md/nodes/36329) | What is the public Ruby API, and what does it promise? |
| [ARCHITECTURE.md](https://knowen.md/nodes/36330) | How is it built internally? |
| [DEVELOPMENT.md](https://knowen.md/nodes/36331) | How to set up, run and test the codebase? |
| [RELEASING.md](https://knowen.md/nodes/36332) | How is it versioned and released? |
| [KANBAN.md](https://knowen.md/nodes/36333) | Kanban board for tracking project tasks |
| [AGENT-WORKFLOW.md](https://knowen.md/nodes/36334) | How should AI agents work with this project? |
| [ADRS.md](https://knowen.md/nodes/36335) | Why were key decisions made? |

Keep this file short. Durable knowledge belongs in the subgraph above, not here: when something here grows beyond a few lines, move it to the matching node and link to it.

## Commands

The commands for setup, tests, lint and docs live in [DEVELOPMENT.md](https://knowen.md/nodes/36331). Run every check listed there before you push, and fix any failure first. *(To be filled in when the gem skeleton exists.)*

## Rules for library code

- **The public API is a contract.** Anything not documented in [API.md](https://knowen.md/nodes/36329) is internal. Changing the public API needs an ADR, or a Kanban task that says so, plus a changelog entry.
- **Follow the standards.** Model changes must match [STANDARDS.md](https://knowen.md/nodes/36336). Record every deliberate deviation there.
- **Every query applies the visibility policy to every node and edge, on every hop.** Never add a code path that skips it.
- **No raw SQL fragments from callers.** Conditions are structured, all values are bound as parameters, and path lengths always have an upper bound.
- **Plain PostgreSQL only.** No extensions beyond those that common managed PostgreSQL services offer, and no second datastore.

## Protected Trees

If a knowen.md write returns `403 master_protected`, `agent_published_tree` or `agent_read_only_tree`, don't retry it and don't ask for the tree to be unprotected. Instead, propose the change on a graph branch and open a pull request for a human to merge.

A response with `meta.reason: "grant_level"` means the refusal comes from your grant's level, not from the tree's protection. Every grant is `read` (View only), `propose` (Propose changes, the default) or `write` (Write directly), and only a `write` grant can write master (ADR-008 §7.5). Don't ask for a higher level; propose the change instead.

Follow "Protected Trees: Propose, Don't Write (ADR-008)" in [AGENT-WORKFLOW.md](https://knowen.md/nodes/31743) of knowen.md.

## Syncing git PRs and graph PRs (ADR-010)

A task often has two pull requests: a **git PR** on GitHub ([valamonai/pglpg](https://github.com/valamonai/pglpg)) for the code, and a **graph PR** on knowen.md (`https://knowen.md/trees/36325/pulls/<n>`) for the documentation. Link them, so the graph PR merges when the git PR does:

- **Link both ways.** Put a line `Knowen-PR: <graph PR URL>` in the git PR's description; knowen.md reads it when the PR is opened or edited. Put the git PR's URL in the graph PR's description. Linking grants no permissions.
- **Only a human arms.** A tree writer reviews the graph PR and clicks **Merge when GitHub PR merges**. When the git PR merges into `master`, the graph PR then merges as that person. Agents can't arm and can't merge, and must not ask for that step to be skipped.
- **Finish the graph PR before review.** Any write to the graph branch after it is armed makes the arming stale, and the automatic merge is then refused. If review asks for changes, make them in a new round (`start_round`) and say so in the PR, so the reviewer can arm it again.
- **Check the status.** The `knowen.md/graph-pr` status on the git PR shows whether the graph PR is armed and up to date.
- **Prerequisite:** the tree owner connects the pglpg.md tree to the GitHub repository (tree collaborators page → **GitHub** → **Connect a repository**). Until then, link the PRs by hand and a human merges both.

## Git Worktrees (`bin/wt`)

Use `bin/wt` to create and manage git worktrees under `.worktrees/` (gitignored), instead of switching branches in the main checkout.

**When to use it**

- A task needs its own branch while the main checkout stays on `master`.
- Several tasks or agents run in parallel, each in its own worktree.
- Risky or long-running work that must not disturb the main checkout.

Skip it for small edits on the branch you already have checked out.

**How to use it**

| Command | Purpose |
| ------- | ------- |
| `bin/wt <name> [base-ref]` | Create or switch to worktree `.worktrees/<name>` (default base: `origin/master`) |
| `bin/wt list` | List worktrees with their branch and clean/dirty status |
| `bin/wt rm <name> [--force]` | Remove a worktree (refuses if dirty; `--force` overrides; never removes the current one) |
| `bin/wt help` | Full help, including the optional zsh wrapper for interactive `wt` use |

- `<name>` becomes both the directory name and the branch name. It must not contain `/` or `..` and must not start with `-`; use dashes (for example `add-edge-uniqueness`). If the worktree or branch already exists, `wt` switches to it instead of creating a new one.
- Creating a worktree also sets it up, and it is safe to run again. It only acts on what the main checkout has:
  - symlinks `.env` and the shared `vendor/bundle`;
  - copies `.bundle/config`;
  - runs `bundle install` once a `Gemfile` exists (skip with `--no-bundle`).
- **Test database:** if the specs use a PostgreSQL database, give each worktree its own database name (see [DEVELOPMENT.md](https://knowen.md/nodes/36331)), so parallel runs don't overwrite each other's data.
- **Agents:** `bin/wt` prints `cd '<path>'` to stdout. If the caller's PATH lacks the rbenv or Homebrew directories that tools like `bundle` and `gh` need, it adds `&& export PATH="..."`. Eval the output to apply both, for example `eval "$(./bin/wt <name>)"`, or set the working directory to `.worktrees/<name>`.
- After the branch is merged, clean up with `bin/wt rm <name>`. Remove only worktrees you created, and check `bin/wt list` first.

## Session completion

Work is not complete until your branch is pushed and its pull requests are open:

1. Track any remaining work as tasks under the [KANBAN.md](https://knowen.md/nodes/36333) Backlog column.
2. Run the checks listed in [DEVELOPMENT.md](https://knowen.md/nodes/36331).
3. Push your branch (`git push -u origin HEAD`). Never commit to or push `master`.
4. Open the git PR against `master` (`gh pr create`) with what changed, why, how it was tested, and a link to the Kanban task. If you changed documentation through a graph branch, seal its round, open the graph PR, and link the two PRs. Move the Kanban card to Review.
5. Never merge your own pull request, git or graph: a human reviews and merges.
