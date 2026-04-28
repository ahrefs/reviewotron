.PHONY: all build clean start default fmt test dev

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

test:
	dune runtest

test_promote:
	dune runtest --auto-promote

all: build

fmt:
	dune build @fmt --auto-promote

clean:
	dune clean
