# How we build — PM-led, agent-built

The product manager (the user) owns **what** and **why**. The eng lead (the main Claude Code
session) owns **how**, and runs specialist agents to do the work. The PM never has to read a
diff to make a decision.

## The loop (`/pm feature <idea>`)

1. **Brief.** Idea → `briefs/NNN-slug.md` (from `briefs/TEMPLATE.md`): problem, who it's for,
   success, acceptance criteria, scope cuts, open product questions with a recommendation. The
   PM approves it. No code before approval.
2. **Build.** One writing agent in a feature worktree; other agents only read, test or review.
3. **Gate.** The project's check passes, a tester maps every acceptance criterion, a
   fresh-context reviewer finds nothing blocking. Max two fix rounds, then escalate.
4. **PR.** Top section written for the PM. **The PM merges.** Deploys and anything spending
   real money happen only on the PM's explicit go.

**Fast lane:** a one-sentence change touching no money/safety/data-loss path skips the brief.

## What comes to the PM vs. what doesn't

| Comes to the PM (product calls) | Decided by the lead (logged in the brief) |
|---|---|
| Prices, fees, anything a user sees about money | Code structure, libraries, data models |
| Who can do what; defaults users see | Test strategy, refactors inside scope |
| Safety / privacy policy | Error handling, retries, performance |
| UX flow and copy tone | Internal naming, file layout |
| Scope cuts and sequencing | Which agent does what |
| Anything that spends money, deploys, or is hard to reverse | Bugs found along the way inside scope |

## Files

- `DECISIONS.md` — the product decision log (append-only).
- `briefs/` — one file per feature. Status: `draft → approved → building → in review (PR #n) → shipped | dropped`.
