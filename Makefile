.PHONY: all build clean start default fmt test dev install cli-smoke install-smoke

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
BINARY ?= $(BINDIR)/reviewotron

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

install:
	dune build --profile=release src/reviewotron.exe
	mkdir -p "$(BINDIR)"
	install -m 755 _build/default/src/reviewotron.exe "$(BINARY)"

test:
	dune runtest
	$(MAKE) cli-smoke

cli-smoke:
	sh test/cli_smoke.sh

install-smoke:
	prefix=$$(mktemp -d); trap 'rm -rf "$$prefix"' EXIT; $(MAKE) install PREFIX="$$prefix"; PATH="$$prefix/bin:$$PATH" reviewotron --help >/dev/null

test_promote:
	dune runtest --auto-promote

all: build

fmt:
	dune build @fmt --auto-promote

clean:
	dune clean
