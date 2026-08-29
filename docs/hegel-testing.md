# Running the Hegel property tests

The unit and adapter suites run in the Nix dev shell:

```sh
nix develop -c dune runtest
```

The Hegel property tests do not. Hegel loads a native `libhegel` chosen by the
architecture reported at runtime, and it is only published for `darwin-arm64` on
macOS, so it needs a native arm64 OCaml switch and a native process:

```sh
opam switch create ade-arm64 ocaml-base-compiler.5.4.0
eval $(opam env --switch=ade-arm64 --set-switch)
opam pin add -y hegel "git+https://github.com/hegeldev/hegel-ocaml.git#56eec3788594afd39e8ffff05635d84a88643c1e"
opam pin add -y ppx_hegel_test "git+https://github.com/hegeldev/hegel-ocaml.git#56eec3788594afd39e8ffff05635d84a88643c1e"
opam install -y hegel ppx_hegel_test alcotest otoml bos rresult digestif cmdliner yojson

dune build test/test_workbench_name.exe
arch -arm64 ./_build/default/test/test_workbench_name.exe
```

`arch -arm64` matters. Under Rosetta the process reports `x86_64`, Hegel then
looks for a `darwin-amd64` artifact that upstream does not publish, and the run
fails with:

```
hegel: no baked-in libhegel checksum for platform darwin-amd64
```

An x86_64 opam switch cannot run these tests at all: linking `ctypes-foreign`
against an arm64 Homebrew `libffi` fails.
