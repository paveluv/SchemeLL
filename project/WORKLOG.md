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

- Switched ll to grouped block form (DECIDED, replaces flat labels):
  `(label %name insn ... terminator)`, first group = entry block, no `_`
  shorthand (one-name-one-symbol ruling). New structural errors:
  instruction outside a block, empty block, missing terminator, nested
  blocks. Migrated interpreter, tests, corpus, examples, README, design doc.

- Step 2 done: instruction flags. Peeled from IR position, validated per
  opcode (wrap ops, exact ops, or/disjoint, zext/nneg, load-store/volatile),
  applied via C API setters; fast-math flags gated by
  LLVMCanValueUseFastMathFlags; gep takes its no-wrap mask at construction
  (inbounds implies nusw, as in the IR parser). Two new coverage axes from
  bitmask enums (LLVMFastMath* 7/7, LLVMGEPFlag* 3/3). tail/musttail/notail
  still rejected.

- Step 3 done: 14 opcodes off the ledger (56+11=67/67). switch, indirectbr
  + blockaddress, unreachable, freeze, va_arg, addrspacecast, vector ops
  (+ (< N x TY >) type and (mask ...) groups), aggregate ops (+ array/struct
  types), full atomics (fence, all 17 atomicrmw ops, cmpxchg weak, atomic
  load/store with orderings), undef operands, (ptr addrspace N). Two new
  axes: atomic orderings 6+1=7/7, atomicrmw ops 17/17. Remaining ledger:
  9 exception-handling opcodes + UserOp1/2.

- Step 4 done: module-level globals as (= @name (linkage? global|constant
  ty init? attrs)) items — IR word order preserved; initializers: literals,
  undef/zeroinitializer/null, cross-references to globals/functions,
  c/cz strings, per-element-typed aggregates. New linkage axis
  11 + 6 obsolete = 17/17. Constant expressions deferred with rationale
  (opaque pointers obsoleted the common ones); add on demand.

### Next (coverage plan order)
- Step 5: exception handling (the last 9 ledger opcodes).
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
