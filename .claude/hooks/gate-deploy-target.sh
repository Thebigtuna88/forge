#!/bin/bash -p
# gate-deploy-target (spec 5.3, rule 8, FRG-5). Production deploys, App Store and TestFlight
# uploads are the owner's scripts, never the agent's commands. A deploy tool's command (the tools
# in .harness/deploy-targets.json, on top of the runtime's floor) must already be one plain command
# that starts with the tool itself (hr_require_simple); then a production pattern is refused, a
# preview pattern is allowed, and a command matching neither is refused (fail closed). Disguised
# spellings are known limit L13.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init gate-deploy-target
hr_guarded || hr_allow
hr_require_simple

rc=0
hr_deploy_class || rc=$?
class="$(head -n 1 "$HR_TMP/deploy.out")"
[[ $rc == 0 ]] || hr_deny "can't read .harness/deploy-targets.json ($class), so deploy commands can't be judged"
case "$class" in
  other | preview) hr_allow ;;
  production) hr_deny "this command matches a production pattern in .harness/deploy-targets.json; production deploys and store uploads are the owner's scripts (rule 8), so write an owner handoff" ;;
esac
hr_deny "this deploy-tool command is neither a preview nor a production pattern in .harness/deploy-targets.json, so it is refused (fail closed)"
