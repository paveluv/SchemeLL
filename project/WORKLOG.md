# Work log

Newest entries first. Format: date, Done / Decided / Next.

## 2026-08-22 — coverage plan + harness (levels 1+2)

### Done
- `project/coverage-plan.md`: verifiable-coverage strategy (oracles from
  installed headers, exclusion ledger, observed-opcode enforcement, golden
  round-trips via LLVM's parser, corpus round-trip as the endgame).
- Implemented levels 1+2: `tests/oracle.sls` extracts enums from Core.h at
  test time; `tests/test-coverage.ss` builds a 7-entry golden corpus, walks
  the emitted IR with LLVMGetInstructionOpcode, and enforces
  observed + excluded = oracle (no gaps, no overlap, no stale exclusions).
  Verified the harness fails when an exclusion is removed.
- Bindings added: LLVMParseIRInContext + memory buffers (ir:parse-ir),
  block/instruction iteration, opcode/predicate getters.
- Score: opcodes 42+25=67/67, icmp 10/10, fcmp 16/16.

### Next (coverage plan order)
- Step 2: instruction flags via setters (nsw/nuw/exact/inbounds/fast-math).
- Step 3: switch, unreachable, indirectbr, freeze, va_arg, addrspacecast,
  vector/aggregate ops, atomics — shrink the exclusion ledger.
- Step 4: globals, constant expressions, aggregate types in type grammar.
- Step 6: ll:disassemble + LLVM test-corpus round-trip (level 3).

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
- Namespacing (project-wide, see RULES.md "Naming and namespaces"): definitions
  never carry module prefixes, no export renames, and ALL project imports are
  prefixed (`config:` `base:` `ir:` `target:` `jit:` `t:`). `(llvm raw)` drops
  the leading `LLVM` at definition and is imported as `(prefix (llvm raw) LLVM)`
  so call sites read as exact C names. `base:error` is the project error raiser
  (shadows R6RS error inside base).

- Formatting: all Scheme sources go through `~/.e/tools/scheme-format`;
  enforced by `project/hooks/pre-commit` (`git config core.hooksPath
  project/hooks`, once per clone). `make format` formats everything.

- Wrote the design proposal for the first DSL layer: `project/ll-design.md`
  ((llscheme ll), LLVM IR as s-expressions). Key calls: mechanical
  transliteration from textual IR, flat control flow with `(label %x)`
  instructions, data-interpreter core + thin quasiquoting macro (not
  per-opcode macros). Awaiting review before implementation.

- Implemented `(llscheme ll)` per the design doc: data interpreter with
  module/function two-pass build (forward calls, forward labels), phi fixups,
  align attributes, `build`/`jit`/`dump` entry points. @fact runs live.
  Added `LLVMSetAlignment`/`LLVMSetValueName2`/`LLVMBuildFRem` down-stack.
  MVP limits (rejected loudly): instruction flags, aggregates, globals,
  alloca counts, non-phi forward value refs.

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
