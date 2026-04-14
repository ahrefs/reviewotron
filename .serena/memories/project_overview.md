# Reviewotron

## Purpose
OCaml-based automated code review tool that integrates with GitHub PRs. Currently being extended with a multi-agent security analysis pipeline.

## Tech Stack
- OCaml with Lwt for async
- melange-json-native for JSON serialization (migrating from ATD)
- ppx_deriving_jsonschema for JSON Schema generation
- Yojson for JSON parsing
- Re2 for regex
- Routes for HTTP routing
- OUnit2 for testing

## Key Commands
- `make build` — build the project
- `make test` — run tests
- `make fmt` — format code (auto-promote)
- `make clean` — clean build artifacts
- `make clean build test fmt` — full quality gate

## Structure
- `lib/` — main library code
- `src/` — executables
- `test/` — tests
- `docs/plans/` — PRD and planning documents
- `dune-project` — project configuration
