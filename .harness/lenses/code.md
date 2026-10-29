## Lens: code

Check correctness and robustness, adversarially:
- Correctness and edge cases: empty, missing, huge, unusual or hostile input; paths with spaces,
  links or odd characters; races between a check and a use; behaviour on a failing command.
- Error handling: does every failure stop the operation (fail closed), with a message that says
  what to do? Can anything report success without having done the work?
- Tests: does each test fail without the change it claims to prove (spec 10.4)? Can a test pass
  for the wrong reason (a check that can't fail, a fixture that hides the case, text matched in a
  comment)? Is a claimed behaviour left untested?
- Dead, duplicated or contradictory code; a rule implemented twice that could drift apart.
- Scope: the change does what its ticket and approved plan say, no more and no less. Behaviour
  changes that aren't stated are findings.
- Consistency between code, tests, the spec, the plan, CLAUDE.md and comments. Text that claims
  more than the code does is a finding.
- macOS /bin/bash 3.2 and Apple's tools (BSD sed, md5, stat); shellcheck clean.
