# Work log

Newest entries first. Format: date, Done / Decided / Next.

## 2026-08-21 — project start

### Done
- Repo skeleton, git init, project rules (`project/RULES.md`).
- Vertical slice implemented: `(llvm config)`, `(llvm raw)`, `(llvm base)`,
  `(llvm ir)`, `(llvm target)`, `(llvm jit)` + test suite.
- Verified environment facts: Chez 10.0 `ta6le`, LLVM 19.1.7 single `libLLVM-19.so`
  exporting 1267 `LLVM*` C symbols; C headers installed at
  `/usr/include/llvm-c-19/llvm-c/`.
- Verified the three FFI mechanisms the design depends on:
  computed-string entry, raw-address entry via `eval` (the JIT→`foreign-procedure`
  trick), `size_t`/`unsigned-64` arg types.

### Decided
- Library prefixes: `(llvm ...)` for bindings, `(llscheme ...)` reserved for the DSL.
- Layer-0 names = exact C names; opaque refs = raw integer addresses; only owning
  handles get records (see RULES.md ownership section).
- Pin LLVM 19; isolate version knowledge in `config.sls`/`raw.sls`.
- JIT'd procedures keep their jit record reachable by closing over it; guardian
  disposes unreachable jits lazily.
- Namespacing: `(llvm jit)` names are un-prefixed at definition (`make`,
  `function`, `add-module!`, ...) and the library is documented as
  prefix-imported (`jit:`); it imports `(llvm ir)` as `ir:` internally to
  avoid clashes. Other libraries keep self-describing names; prefixing them
  is the importer's choice.

### Next
- Expose Scheme procedures to JIT'd code as absolute symbols
  (`LLVMOrcAbsoluteSymbols` + `foreign-callable` + `lock-object`) — enables two-way
  calls.
- Optimization passes via `LLVMRunPasses` (new pass manager) — raw bindings exist,
  need a layer-1 wrapper + test.
- ResourceTracker support for per-module unloading / redefinition.
- GDB JIT-interface listener for debuggability.
- Grow `(llvm ir)` coverage (structs, globals, vararg calls, switch, more casts).
- Eventually: binding generator from `clang -ast-dump=json` for full API coverage.
