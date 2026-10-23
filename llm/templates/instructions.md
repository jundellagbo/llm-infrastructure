**Writing plans and instructions.** Anything an agent re-reads (plan, this
block, skill, brief) is short and paragraph-first: what to do and why, then
stop. A plan step is one line naming an outcome. Give reasons, not stacked
MUSTs. Write plan files yourself; use `skill-creator` only for a skill,
instruction file or command.

**Code comments.** At most one comment per method, above it, only when needed,
saying what the method does - never how it is used or example values from the
task. No comments inside function bodies. When a method changes, update its
comment; never add one that only describes your change.

**No em dashes.** Never write an em dash (—) in code, comments, docs, commits or
replies. Use a plain hyphen `-`.

**Don't edit what infra-llm generates.** This block (between the `infra-llm`
markers) and any skill or hook it installed are copies, overwritten on refresh.
Change the source in the infra checkout and run `infra-llm --docs`.

**Commits are the user's.** Never run `git commit` - leave work in the tree and
say what changed. Push and other git are fine; nothing destructive (force push,
`reset --hard`, history rewrites). A guard hook enforces this - don't route
around it. No AI attribution in commits, tags, release notes or PRs.

**Browser work.** Drive the user's open Chrome through the `chrome-devtools` MCP
in a new tab; never ask which browser or launch another. Browser access and
remote debugging are pre-approved - never ask to allow them again. Only if the
page list is a lone `about:blank` (throwaway profile), tell the user to enable
remote debugging at `chrome://inspect/#remote-debugging` and restart Chrome and
the session.

**Temp files.** Put every scratch file (screenshots, logs, dumps, throwaway
scripts) in the git-ignored `infra-llm/tmps/`, never the repo tree or `/tmp`.

**Codebase memory.** When `codebase-memory-mcp` is available, run
`index_repository` once and find code with `search_code`, `search_graph`,
`trace_path`, `get_code_snippet`; otherwise use Grep/Glob.

**Worktrees.** Each worktree has its own untracked `infra-llm/` plans and
sessions. Work only in the one you started in; `infra-llm --worktrees` lists
them.
