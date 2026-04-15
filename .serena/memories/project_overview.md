# Reviewotron

## Purpose
OCaml-based automated PR code reviewer for GitHub. Uses Claude AI to review pull requests and post inline comments.

## Tech Stack
- OCaml with Lwt for async, Dream/Routes for web, Yojson for JSON
- melange-json-native for type-safe JSON serialization (`[@@deriving json]`)
- ppx_deriving_jsonschema for JSON Schema generation (`[@@deriving jsonschema]`)
- ocaml-ai-sdk for AI agent execution
- OUnit2 for testing

## Structure
- `lib/` — core library (types, plugins, agents, API abstractions)
- `src/` — entrypoints
- `test/` — tests with mock API responses in `test/mock_api_responses/`
- `docs/plans/` — PRDs and implementation plans

## Commands
- `make clean` — clean build artifacts
- `make build` — build the project
- `make test` — run tests
- `make fmt` — format code with ocamlformat
- Full check: `make clean build test fmt`

## Key Patterns
- Functor-based API abstraction for testability (Api.Github, Api_local)
- Golden-file testing with mock implementations
- Plugin-based review pipeline (general + security plugins)
- No `else if` — use pattern matching
- `[@@deriving json]` for all JSON, no manual JSON manipulation
- Abstract `type t` with .mli files
