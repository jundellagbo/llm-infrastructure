---
name: infra-llm-designer
description: >-
  Validate UI work instead of eyeballing it - audit with impeccable, review
  motion with the emilkowalski design skills, then see it running in the user's
  own browser through the chrome-devtools MCP. Use this whenever a task builds,
  changes, polishes or reviews anything visual: a page, component, layout,
  styling, animation, responsive or accessibility pass, or "make this look
  better / less like AI slop".
---

# infra-llm-designer

`infra-llm-designer` is the design gate for UI work on this machine, installed as
a global skill by `infra-llm --global`. "It renders" is not done: when a change
touches UI, styling, layout or motion, run these three passes and report what
you deliberately left alone.

**Audit — impeccable.** Run the `impeccable` skill (or `npx impeccable detect
<path>`) over the changed UI for typography, colour, spacing, layout and motion
anti-patterns. It judges markup and CSS, not backend logic, and server-rendered
templates must be told which extensions to scan.

**Motion — emilkowalski/skills.** For anything animated or interactive, review
easing, duration, physicality, interruptibility, performance and accessibility
with those skills rather than inventing curves.

**Live — chrome-devtools MCP.** Screenshot the running UI, inspect computed
styles, spacing and contrast on the real elements, and check the console/network
for new errors, iterating until the page matches the audit. Drive the user's own
browser — the instruction block's "Browser work" note already covers how the
server attaches and how to spot a throwaway profile.

Done means: no unaddressed anti-patterns, motion reviewed, and the change seen
working in the user's own browser with no new console or network errors.
