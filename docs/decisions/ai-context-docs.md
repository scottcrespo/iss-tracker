# Decision: AI Context Document Standard

## Decision

Adopt a structured set of AI context documents following Anthropic's Claude Code
guidelines as the minimum baseline. The context layer consists of:

- `CLAUDE.md` — project-level rulebook loaded automatically by Claude Code at
  the start of every session
- `docs/context/` — domain-specific context documents (AWS, Terraform,
  Kubernetes, security, CI/CD) imported by CLAUDE.md and loaded when relevant

## Rationale

### Explicit context over informal assumptions

Without structured context documents, an AI assistant rebuilds project
understanding from scratch each session through conversation and code exploration.
This produces inconsistent behavior — the assistant may suggest patterns that
contradict established decisions, miss project-specific constraints, or require
repeated correction on the same points.

Structured context documents establish explicit, durable rules that survive
session boundaries. Hard constraints (no secrets in Git, no GitHub Actions cluster
access) are enforced from the first message rather than rediscovered through
mistakes.

### Portfolio signal

Context documents demonstrate engineering maturity in an emerging area: working
effectively with AI tooling at a production level. The approach signals:

- Awareness of how AI assistants consume context and where informal assumptions
  break down
- Ability to codify project standards in a reusable, maintainable format
- Discipline around documentation as a first-class engineering artifact

The documents are reusable across projects as they mature — AWS IAM governance
rules, Terraform conventions, and security principles apply broadly.

### Anthropic guidelines as a completeness baseline

Using Anthropic's published Claude Code guidelines as a minimum standard provides
an authoritative reference to measure the documents against. This prevents the
context layer from being incomplete in ways that are hard to detect — if the
guidelines recommend covering build commands, repo navigation, and coding
standards, those sections exist.

## Structure Decisions

**CLAUDE.md is the always-loaded rulebook, not the full context.** Keeping
CLAUDE.md under 200 lines (per Anthropic guidelines) ensures it is read reliably.
Domain depth lives in `docs/context/` files imported via `@path` syntax, which
are loaded when relevant rather than always consuming context tokens.

**Domain docs are organized by tooling layer, not by concern.** AWS, Terraform,
Kubernetes, security, and CI/CD each have their own file. A developer working on
an IAM policy knows to look in `docs/context/aws.md`; one working on a Helm chart
looks in `docs/context/kubernetes.md`. This matches how the work is actually done.

**Update triggers are documented inside each file.** Each context document begins
with an explicit list of project events that should prompt an update. This makes
maintenance a pull rather than a push — the trigger is visible at the point of
use rather than relying on institutional memory.

## Tradeoffs Accepted

**Maintenance overhead.** Context documents can become stale. Mitigation: update
triggers are documented in each file, and the development methodology in CLAUDE.md
requires documentation to be current before merging.

**Not a hard enforcement mechanism.** CLAUDE.md is loaded as context, not
enforced configuration. An AI assistant can still deviate from documented rules.
Mitigation: hard constraints are written imperatively and placed prominently;
the most critical rules are repeated in domain docs where they apply.

## Alternatives Considered

**No context documents — rely on conversation.** Rejected. Inconsistent session
behavior and repeated correction overhead outweigh the setup cost.

**Single monolithic context file.** Rejected. Files over 200 lines are followed
less reliably per Anthropic guidelines. Domain separation also makes maintenance
easier — a Kubernetes change does not require editing an AWS document.