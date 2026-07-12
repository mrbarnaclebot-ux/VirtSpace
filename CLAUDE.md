# VirtSpace — Project Conventions

## Agent routing (MANDATORY — every session)

- The main assistant (**Fable**) is the **ORCHESTRATOR**: architecture, design, task breakdown, spec upkeep, code review, QA verification, git/commit curation, and deploy operations. It does **not** write application code directly.
- **All implementation** (Swift/iOS, backend, web viewer, scripts), **token-hungry work** (computer-use/browser automation, bulk codebase analysis, large refactors), and research sweeps are **delegated to Opus subagents** via the Agent tool with `model: "opus"`. Subagents report results back to the orchestrator.
- The orchestrator MAY directly edit: markdown docs, `.gitignore`/config one-liners, and CI/config files where delegation is wasteful. Everything else goes through subagents.
- **QA loop:** after a subagent reports, the orchestrator independently verifies (Xcode build via MCP/`xcodebuild`, backend tests, run the affected flow) **before** committing. Failed verification goes back to a subagent with the failure output.

## Source of truth

- `spec-doc.md` — product & technical spec. Read **§11 build phases** and **§10 open-items ledger** before starting any work. Update the spec when decisions change; the spec leads, code follows.

## Repo layout (monorepo)

- `VirtSpace/` — iOS app (SwiftUI, Xcode project; path kept stable so the open Xcode project doesn't break)
- `backend/` — Railway API + worker (Phase 1+)
- `tools/spike/` — Phase 0 spike scripts + Spark viewer fixture
- `video-example.mp4` — reference app walkthrough the product replicates

## Git & CLI conventions

- **Conventional Commits** with scope: `feat(ios-capture): …`, `fix(worker): …`, `chore:`, `docs:`, `refactor:`, `test:`. Imperative mood, ≤72-char subject, body explains *why* when non-obvious.
- Small, atomic commits — one logical change each. No mixed-concern commits, no "WIP" on `main`.
- Push to `origin main` after each verified, coherent batch.
- **Never commit secrets**: `.env` is gitignored; the World Labs key lives in local `.env` (dev scripts) and Railway env vars (production) only. Never in the app bundle or repo.
- CLIs available & authenticated: `git`, `gh` (mrbarnaclebot-ux), `railway` (project deploys), `xcodebuild`.

## Agent isolation (added after production data pollution)

- Implementation/QA agents must NEVER run app builds against the production backend. Simulator runs use the DEBUG `VIRTSPACE_API_BASE_URL` override pointing at a local mock — no exceptions, including "read-only" launches (launch-time resume/recovery kicks create real state: a sim verification run uploaded 28 test frames into the owner's production library).
- Before any simulator app launch, clear pending capture sessions from prior runs or use a fresh simulator.
- Agent sim runs previously also exhausted the owner's daily scan quota. Treat the production backend as the owner's data, always.

## Cost guardrails (real money)

- World Labs credits are billed per generation (~7k credits ≈ $5.60 on the account). Development defaults to `marble-1.0-draft` (150 credits); use the backend **mock-provider mode** for app development. **Never call `worlds:generate` in a loop or retry it blind** — persist `provider_operation_id` first (spec §14).
