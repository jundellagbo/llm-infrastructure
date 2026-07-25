---
description: Prepare a release - gather tags/commits via git, pick the version, draft the notes, hand the tag/push to the user. Never duplicates an existing tag.
---

<!-- infra-llm:generated -->
# Prepare a release

Read the real state yourself first (read-only git is fine):
- `git tag --sort=-v:refname | head` for existing tags; the top one is the previous release;
- `git log --oneline <last-tag>..HEAD` and `git diff --stat <last-tag>..HEAD` for what changed since it;
- if a requested version already tags something, STOP — never duplicate or move a tag.

Pick a version if none was given and bump it everywhere the project declares it:
`vMAJOR.MINOR.PATCH` — `vX.Y.(Z+1)` bug fix, `vX.(Y+1).0` feature, `v(X+1).0.0`
breaking (one breaking change makes it major). Notes come from the commits since
the last tag, not the task. Run `infra-llm verify` — flag a red tree. Call out
security fixes and dependency updates with severity, or say there were none.

Git is the user's decision, so DON'T commit, tag, push or create the release
yourself. Prepare the version bump and notes, then hand over the exact commands
(`git commit`, `gh release create vX.Y.Z …` which tags and pushes). No AI/LLM
attribution in the tag, notes or commits.

Release notes by user impact, not commit order: **Security** (fixes/deps, or
"none"), **Highlights**, **Bug fixes**, **Breaking changes** ("none" explicitly),
**Migration notes**, **Deployment checklist**.
