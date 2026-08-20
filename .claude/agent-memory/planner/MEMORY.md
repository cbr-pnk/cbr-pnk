# Planner memory — architectural decisions

Record durable architectural decisions and their rationale here, one entry
each. Settled decisions are not re-litigated in future plans. Correct entries
that become wrong; never leave stale decisions beside their replacements.

Format: `YYYY-MM-DD — Decision. Rationale. (Supersedes: … if any)`

## Decisions

- 2026-08-20 — This repo uses a supervisor + subagent architecture for Claude
  Code (scout/planner/implementer/reviewer, defined in `.claude/agents/`).
  Rationale: keeps the supervisor's context clean and puts memory only where
  accumulated knowledge pays off.
