# Reviewotron — Implementation Plans

## Overview

Reviewotron is an agentic code review bot that listens to GitHub webhooks and runs AI-powered reviews using the Claude API. It follows monorobot's architecture (functor-based API abstraction, ATDgen types, golden file testing).

## Phases

| Phase | Focus | Est. Time | Status |
|-------|-------|-----------|--------|
| [Phase 1](phase-1-skeleton.md) | Skeleton + Webhook Parsing | ~1 day | Not started |
| [Phase 2](phase-2-github-api.md) | GitHub API + Diff Parser | ~1 day | Not started |
| [Phase 3](phase-3-claude-engine.md) | Claude Review Engine | ~2 days | Not started |
| [Phase 4](phase-4-slack-state-push.md) | Slack + State + Push Reviews | ~1 day | Not started |
| [Phase 5](phase-5-testing-polish.md) | Testing Polish | ~0.5 day | Not started |
| [Phase 6](phase-6-deployment.md) | Production Deployment | ~1 day | Not started |

## Execution Protocol

Each phase is executed by a subagent that:

1. **Reads** `.cursor/rules/backend-developer.mdc` for code style guidance
2. **Uses context7 MCP** for library documentation (cmdliner, ATDgen, Anthropic API)
3. **Uses serena MCP** for semantic code navigation (monorobot patterns, one_llm library)
4. **Implements** all tasks in the phase plan

### QA Steps (after each phase)

After each phase completes:

1. **Code Review**: Spawn a subagent with `/review` to review the implementation against the phase plan, coding standards and defined code style
2. **Simplify**: Run `/simplify` to check for reuse opportunities, code quality, and efficiency improvements
3. **Fix Issues**: Address any findings from review and simplify before proceeding to the next phase
4. **Final quality gates**: make that `make clean build test fmt` exits cleanly. Otherwise fix until it does. Don't cheat to make the build pass, address the root problems. Leave the codebase better than you've found it.

### Implementation Principles

- **Lean on Devkit**: Use `Web.http_request_lwt` for HTTP requests, `Stre` for strings, `Exn` for errors, `Files` for I/O. Don't reinvent what Devkit provides.
- **Follow monorobot's patterns closely**: The `subrepo/monorobot/lib/` code is the primary reference for how to structure API calls, error handling, and HTTP requests. Study `api_remote.ml` and `util.ml` before writing new networking code.
- **Use context7 MCP**: Always check library documentation before implementing. Verify function signatures and usage patterns against docs.
- **Use serena MCP**: Navigate the monorepo codebase to find existing patterns and utilities before writing new ones.

### Key References

| Resource | Purpose |
|----------|---------|
| `.cursor/rules/backend-developer.mdc` | OCaml code style and best practices |
| `subrepo/monorobot/lib/api_remote.ml` | HTTP request patterns, auth handling, GitHub API calls |
| `subrepo/monorobot/lib/util.ml` | `http_request` wrapper, `fmt_error`, URL helpers |
| `subrepo/monorobot/` | Architecture reference (functors, ATD, testing) |
| `backend/one_llm/lib/anthropic.ml` | Claude API integration to reuse |
| `backend/one_llm/lib/anthropic.atd` | Anthropic request/response types |
| `backend/admin/cluster.ml` | Deployment config (Phase 6) |
| `backend/gen_ci/ci_apps.ml` | CI registration (Phase 6) |
