---
description: Ship a release - gather tags/commits via git, pick the version, draft the notes, then commit, tag and publish directly. Never duplicates an existing tag.
---

<!-- infra-llm:generated -->
# Ship a release

Read the real state yourself first:
- `git tag --sort=-v:refname | head` for existing tags; the top one is the previous release;
- `git log --oneline <last-tag>..HEAD | head -40` and `git diff --shortstat <last-tag>..HEAD` for what changed since it — the commits carry the notes, so reach for the full log or a per-file `--stat` only when 40 subjects don't cover the release;
- if a requested version already tags something, STOP — never duplicate or move a tag.

Pick a version if none was given and bump it everywhere the project declares it:
`vMAJOR.MINOR.PATCH` — `vX.Y.(Z+1)` bug fix, `vX.(Y+1).0` feature, `v(X+1).0.0`
breaking (one breaking change makes it major). Notes come from the commits since
the last tag, not the task.

This command publishes for real, so clear every blocker first: `infra-llm verify`
must pass — a red tree is a blocker to fix or report, never something to release
over. Call out security fixes and dependency updates with severity, or say there
were none.

Then ship it yourself — the guard window is what makes the push allowed:
1. `infra-llm git-window release`
2. commit the version bump; `git push`
3. `gh release create vX.Y.Z --title "..." --notes-file infra-llm/tmps/release-notes.md` (tags and pushes the tag)
4. `infra-llm git-window --close`, then report the release URL.

All scratch for this run — the notes draft, anything temporary — goes in `infra-llm/tmps/` (git-ignored), never in `/tmp` or the project tree. No AI/LLM attribution in the tag, notes or commits.

Release notes by user impact, not commit order: **Security** (fixes/deps, or "none"), **Highlights**, **Bug fixes**, **Breaking changes** ("none" explicitly), **Migration notes**, **Deployment checklist**.
