.PHONY: all build clean start default fmt test dev install cli-smoke install-smoke release gh-release

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
BINARY ?= $(BINDIR)/reviewotron

# Build directory. Defaults to dune's own default (_build). Override to build in
# an isolated tree that does not share dune's build lock with other tooling —
# useful when this repo is vendored inside a larger workspace where an editor
# LSP or an indexer (ocamllsp / `dune build @ocaml-index`) holds the shared
# _build lock and would otherwise make this build block:
#     make install DUNE_BUILD_DIR=/tmp/reviewotron-build
# dune reads DUNE_BUILD_DIR from the environment natively; we only export it when
# non-empty (dune treats an empty value as the invalid build dir ".").
DUNE_BUILD_DIR ?=
ifneq ($(strip $(DUNE_BUILD_DIR)),)
export DUNE_BUILD_DIR
endif

default: build

ARGS ?=
dev:
	watchexec -i _build -i _opam -w lib -w src -e ml,mli -r -c "dune build && dune exec reviewotron -- $(ARGS)"


start:
	dune exec -- ./src/reviewotron.exe

build:
	dune build src/reviewotron.exe

watch:
	dune build -w src/reviewotron.exe

release:
	dune build --profile=release src/reviewotron.exe

# Publish a GitHub release: build, package the binary as a tarball, and upload it
# with its checksum. The version and tag both come from the (version X.Y.Z) field
# in dune-project — bump it there before running this.
gh-release:
	./scripts/release.sh

# Resolve the built exe path robustly whether we build standalone or from inside
# a larger dune workspace (e.g. vendored as a subrepo). dune always builds from
# the workspace root and places artifacts at
# <root>/<build-dir>/default/<dir-relative-to-root>/src/reviewotron.exe.
# The dune workspace root is the git root here (monorepo or standalone); we fall
# back to $PWD for a non-git checkout. <build-dir> is DUNE_BUILD_DIR when set
# (absolute as-is, relative resolved under root), else _build. No path is
# hardcoded.
install:
	dune build --profile=release src/reviewotron.exe
	@root=$$(git -C "$$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$$PWD"); \
	rel=$${PWD#$$root/}; \
	[ "$$rel" = "$$PWD" ] && rel=. || :; \
	bd=$${DUNE_BUILD_DIR:-$$root/_build}; \
	case "$$bd" in /*) ;; *) bd="$$root/$$bd" ;; esac; \
	exe="$$bd/default/$$rel/src/reviewotron.exe"; \
	echo "install -m 755 $$exe -> $(BINARY)"; \
	mkdir -p "$(BINDIR)"; \
	install -m 755 "$$exe" "$(BINARY)"

test:
	dune runtest
	$(MAKE) cli-smoke
	$(MAKE) test-replay

cli-smoke:
	sh test/cli_smoke.sh

# No-network invariant checks for the replay eval harness (needs no eval.jsonl).
test-replay:
	python3 tools/replay/test_replay.py

install-smoke:
	prefix=$$(mktemp -d); trap 'rm -rf "$$prefix"' EXIT; $(MAKE) install PREFIX="$$prefix"; PATH="$$prefix/bin:$$PATH" reviewotron --help >/dev/null

test_promote:
	dune runtest --auto-promote

all: build

fmt:
	dune build @fmt --auto-promote

clean:
	dune clean
