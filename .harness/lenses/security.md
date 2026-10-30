## Lens: security

Context: a defensive review of our own guardrail software. FORGE's hooks and tools stop an AI
agent (Claude Code) from doing what only the owner may do. The agent wrote this change, so assume
it could be wrong in its own favour.

Check, adversarially:
- Secrets: anything that could put a secret in git, a log, a PR, the chat or a file others read.
- Injection: shell (word splitting, globbing, option injection, eval), SQL, HTML, JSON or
  Markdown built from untrusted text; paths from untrusted input.
- Access: can the change let the agent do an owner-only action, change an owner-only path, merge,
  push to main, deploy or spend without the owner? Can it switch a gate off, make it fail open or
  route around it (rule 9)?
- Evidence the agent writes: can a file the agent controls make a check pass that should fail?
  Known limit L12 (the agent shares a macOS user with the runner and its files) stays open until
  FRG-27; report anything that claims to close it or makes it worse.
- Unsafe defaults, missing input validation, trusting the environment, PATH, the current folder,
  config files or links.
- Dependencies and downloaded tools: source, pinning, checksum, what happens on a mismatch.
- Overstated protection anywhere in code comments or docs.
