# Decision: codex is paid for by a ChatGPT plan, not an API key

- Date: 2026-10-16
- Decided by: owner (Thebigtuna88)
- Status: accepted

## Context

Every PR's `code` lens (and by default every other lens) runs through `codex exec`. Codex can
sign in with a ChatGPT plan or run on an OpenAI API key (spec 7, "codex billing").

Checked 2026-10-16 on OpenAI's Codex pricing page (developers.openai.com/codex/pricing, which
redirects to learn.chatgpt.com/docs/pricing):

- Codex CLI is included in Plus ($20/month), Pro (from $100/month), Business and Enterprise/Edu.
  The page does not list CLI access for Free or Go.
- Plus caps local use per five-hour window (for example GPT-6.1 Sol 15–160 messages), and weekly
  limits may also apply.
- An API key is billed at API rates, has no stated cap of its own and excludes cloud features
  (GitHub code review, Slack). OpenAI's API price page refused automated fetches (403), so token
  prices were seen only on third-party trackers and are not recorded here as fact.

## Decision

Use a ChatGPT plan (Plus or higher). `codex login` is a browser sign-in, so no key is handled.

## Consequences

- Cost is flat and predictable. A runaway review loop hits the plan cap and pauses instead of
  running up a bill, which is the fail-closed outcome we want.
- When the cap is hit, reviews wait for the window to reset. The review runner (FRG-7) must
  report a usage-limit error as "lens unavailable", never as CLEAN.
- No API-key usage limit is needed for codex. Revisit if review volume outgrows Plus.
