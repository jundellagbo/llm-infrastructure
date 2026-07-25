---
name: infra-llm-code
description: >-
  Review and tighten code you write or change on this machine - cut duplication,
  nesting and dead code, keep naming and structure consistent with what's there,
  and check for security, performance and correctness holes before finishing.
  Use whenever writing a non-trivial function, refactoring, or reviewing a change
  for quality and safety.
---

# infra-llm-code

`infra-llm-code` is the code-quality gate for work on this machine. "It runs" is
not done: before finishing a non-trivial change, make these three passes and
report what each found.

**Cleanliness.** Prefer short functions, early returns, shallow nesting, small
interfaces and composition; name for intent and match the surrounding
conventions. Cut duplicated logic, dead code, magic numbers and needless
complexity, and don't touch unrelated files. Refactor only when the code
genuinely needs it — behaviour-preserving and inside the change — never because
it "looks nicer".

**Security.** Trace untrusted input to its sinks and check for injection (SQL,
command, path traversal, SSRF, XSS), missing or bypassed authn/authz, leaked
secrets, unsafe deserialization, over-broad permissions and race conditions.
Validate input on both frontend and backend, encode output, apply least
privilege, guard middleware, and never log sensitive data.

**Performance & correctness.** Watch for inefficient or duplicated calls,
blocking operations, unbounded memory, and missing database indexes or caching.
When you change code, inspect its callers, tests, interfaces and configuration so
nothing downstream breaks. For anything with a UI, verify it in the real browser
through the chrome-devtools MCP.
