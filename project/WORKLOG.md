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

- Type syntax DECIDED: (array N TY) and (vector N TY) named heads (uniform
  with struct, nanopass-friendly), replacing the IR-positional
  (N x TY) / (< N x TY >) forms.

- Step 5 done: exception handling — the opcode axis is COMPLETE
  (65 + UserOp1/2 = 67/67). invoke/landingpad/resume (Itanium),
  catchswitch/catchpad/cleanuppad/catchret/cleanupret (funclets, `within
  none` via ConstNull of the token type), callbr with required inline-asm
  callee (minimal (asm ...) support, shared with call), (personality ...)
  clause on defines. Terminators that bind results (invoke, catchswitch,
  callbr) handled in the block-terminator check. Invoke's normal path
  proven through the JIT.

- Naming DECIDED (working code name): the future structured nanopass layer
  is "medl" — (llscheme medl), prefix medl:. MEDium Language, pronounced
  like "medal"; only known collision is an obscure academic MEDL (MaC
  runtime verification, ~2000). ll keeps its name (the .ll resonance).
  Rejected along the way: lol/mel (2026-08-22 discussion), M (MUMPS,
  Power Query), lowl/midl (MIDL = Microsoft IDL).

- Grammar migration DECIDED + done: the ll design principle is now
  formalized (prefix-only grammar; operands are names/literals/keyword
  operands/typed groups/nested forms; LLVM vocabulary and order; textual
  fidelity as tiebreaker; one name one symbol). All mid-form grammar words
  removed: casts lose `to`; call/invoke/callbr group callee with args
  (mirrors IR's @f(args)) and drop to/unwind; funclet EH drops
  within/from/unwind (`caller` is a keyword operand); (ptr addrspace N)
  -> (ptr N); global linkage moves after the kind head. Nanopass
  limitation verified empirically (reference/nanopass cloned): mid-pattern
  literals are rejected by define-language; the singleton-terminal
  workaround makes keywords fields that every pass must thread. Golden IR
  untouched.

- Address-space syntax revised after review: (ptr (addrspace N)), not
  (ptr N). The bare-number shape collides with typed operand groups —
  (ptr 1) in operand position naturally means "address 1 as a pointer
  value" (future inttoptr sugar / raw address injection), so that shape
  is reserved and rejected in type position with a pointed error.
  (addrspace N) is also the reusable attribute form for future
  address-spaced globals, parallel to (align N).

- Step 5.5 done (pre-corpus blockers): varargs (trailing `variadic`
  marker + (fn ...) call-site types; va_start/va_arg proven through the
  JIT), tail/musttail/notail as call flags (new tail-call-kind axis 4/4),
  alloca element counts, and non-phi forward references (freeze-of-undef
  placeholders in a scratch block, RAUW-patched and erased at end of
  function — LLVM's printer emits non-dominance block orders, so the
  corpus needs this). 145 checks.

- Step 6a done: ll:unbuild — the inverse of ll:build, named per review
  (LLVM parses, we unbuild). New library (llscheme ll unbuild),
  re-exported by (llscheme ll); ~95 read-only getter bindings added to
  (llvm raw) (layering note in RULES: raw getters are safe for read-only
  walks). Unnamed values get their LLVM printer slot numbers, so rebuilt
  modules print byte-identically. All 24 golden entries round-trip
  parse -> unbuild -> build -> identical print. Grammar additions en
  route: poison operands, half/bfloat/fp128/x86_fp80/ppc_fp128 types.
  Strict mode raises "not modeled" errors; the complete ledger (detected
  vs undetected) is project/not-modeled.md. 174 checks.

- Step 6b done (harness + 5 burn-down rounds): make corpus round-trips
  LLVM's regression suite (36488 files); pass rate 53.6% -> 76.0%.
  Grammar grown by corpus frequency: named/packed struct types
  ((type %name ...) items), scalable vectors, aggregate/string constants
  as operands, any-width integer constants, poison mask lanes,
  address-spaced globals, function linkage, anonymous all-digit %N names
  (build leaves them unnamed so LLVM reproduces the numbering).
  Normalizer (tests/normalize.sls) strips the not-modeled decorations
  from both sides; dso_local/comdat handled textually (no C API).
  unbuild gained detections: no-op casts, all-constant-operand
  instructions (C-API builder folds both), function alignment,
  alloca addrspace, externally_initialized, prefix/prologue data.

- MISMATCH bucket diagnosed and defeated (rounds 6-7): 2762 -> 25 files
  (0.07%). Tool: tests/probe-mismatch.ss re-runs failures and groups
  masked first-diff signatures. Causes found and fixed: blank-line
  separators from stripped sections; dllimport/dllexport (normalizer:
  SetDLLStorageClass); swifterror/inalloca alloca bits, named
  syncscopes, sanitizer metadata, global #N attribute refs + orphaned
  "attributes #N" lines (no C API -- textual canonicalization,
  centralized as n:comparable-ir); trunc nsw/nuw and uitofp nneg
  MODELED (getters/setters work despite header docs); explicit
  (align n) on atomicrmw/cmpxchg MODELED; packed-struct constants were
  built unpacked (real build bug); named-struct-typed constants via
  ConstNamedStruct; detections added: function alignment, function
  addrspace, digit-string explicit names, non-double NaN payloads.
  Corpus: 76.9% PASS, 176 suite checks green.

- Fixpoint tier added after design discussion: the parser (LLParser)
  builds via direct C++ instruction constructors and never folds; the C
  API's only construction path is IRBuilder with ConstantFolder
  hardwired (template-parameter policy, inexpressible in a C ABI), so
  strict text1==text2 is impossible for all-constant instructions.
  Second chance: (ll:unbuild m 'tolerate-builder-folds) + stability
  check over our own print. Corpus: 28024 strict + 1826 modulo-folding
  = 29850 verified (81.8%). Escape hatches ranked for the residue:
  textual ll->IR backend parsed by LLVM (zero-glue, exact; roadmapped),
  upstream C API patch, C shim (rejected: breaks zero-glue).

- (llscheme ll render): ll->textual-IR printer in pure Scheme (no LLVM
  calls). Purpose: constructing modules through LLVM's parser instead
  of the folding C-API builder, making the STRICT corpus comparison
  possible for all-constant/no-op-cast files -- 2254 files upgraded
  from fixpoint-verified to exactly verified (corpus: 30281 = 83.0%).
  Render round-trip self-test per golden entry (+25 checks, 203
  total; new wide-floats entry pins the fp hex forms). Renderer
  subtleties earned the hard way: fp constants must use per-type hex
  forms (0xK fp80 sign|exp15|explicit-bit+frac63; 0xL fp128 printed
  LOW 64-bit word first; 0xM ppc_fp128 = two doubles), unquoted names
  are ASCII-only and must not start with a digit (all-digit numeric
  IDs must stay UNQUOTED), scalable shuffle masks are splat constants
  (zeroinitializer/poison), musttail forwards `...` iff caller AND
  callee are varargs, declare params are bare types (can be pairs!).
  Not a production path: permanent bench in the corpus harness,
  aggregated over every PASS file: build 4.0s vs render+parse 14.8s
  (3.90x over 28023 modules); LLVM's parser is fast, but text can't
  beat direct calls. One render-unrepresentable PASS file (wasm
  funcref: callee in addrspace(20) needs the stripped datalayout).

- Round 9 (2026-08-22): every BUG bucket emptied and MISMATCH extinct
  (0 of 36488). Fixes, each a real defect: zero-length arrays [0 x T]
  rejected by resolve-type; array lengths are uint64, not fixnums
  ([2^64-1 x i32] exists); personality can be ANY ptr/int constant
  (null, undef, i8 7), not just @function; forward references to EH
  pad tokens -- freeze cannot take tokens, so the placeholder is a
  parentless cleanuppad in the scratch block (also fixed a latent type
  confusion: pad forward refs used ptr placeholders that RAUW would
  reject); zero-destination indirectbr is legal; blockaddress inside
  vector constants exposed an aggregate-vs-group disambiguation bug
  ((ptr X) is a type only as (ptr (addrspace N))), and resolve-constant
  now takes an element-resolver hook so instruction-position aggregates
  can hold blockaddress; LLVMStripModuleDebugInfo segfaults on
  malformed debug info (Verifier tests) -- guarded; ppc_fp128
  losesInfo under-reports -- exactness now verified by print
  comparison; digit-string GLOBAL names detected (locals already
  were); calls through null/undef pointer constants in non-zero
  address spaces detected (named callees carry their type and pass);
  align 4294967296 (LLVM's max; GetAlignment truncates to 0) detected
  textually by the harness; code_model and sanitize_memtag /
  sanitize_address_dyninit normalized textually; `; preds =` comments
  stripped from the comparison (use-list order is not modeled).
  New golden entry edge-shapes locks the round in (206 checks).
  Corpus: 28233 + 2263 renderer + 1 fixpoint = 30497 verified (83.6%).

- Round 10 (2026-08-22): constant expressions MODELED -- LLVM 19's
  surviving set (casts trunc/ptrtoint/inttoptr/bitcast/addrspacecast,
  binops add/sub/mul/xor with single wrap flags, gep with nowrap flags
  via LLVMConstGEPWithNoWrapFlags), spelled as the instruction forms
  nested in operand position (self-typed, no new grammar shapes).
  ConstantExpr::get folds symmetrically with the parser -- no fixpoint
  tier needed. Detections for the remainder: extract/insert/shuffle
  constexpr kinds (they fold away in practice), nuw+nsw binops (the C
  constructors set one flag each), inrange(lo,hi) gep annotations
  (NO C API accessor at all -- witnessed textually from the printed
  constant; 12 files, was 9 MISMATCHes). New constexprs golden entry
  pins all kinds through build/unbuild/render (209 checks). Corpus:
  29014 + 2495 renderer + 2 fixpoint = 31511 verified (86.4%),
  +1k files this round; constexpr bucket 1171 -> 239.

- Round 11 (2026-08-22): function alignment and global aliases
  MODELED. Alignment: (align N) after the signature, before
  (personality ...), on both define and declare; applied in the
  declare pass. Aliases: (= @a (alias linkage? value-type (ptr
  aliasee))), aliasee any ptr constant incl. constexprs; created in
  TWO phases -- all aliases first with a null placeholder aliasee
  (LLVM prints creation order, so program order must be creation
  order), then patched via LLVMAliasSetAliasee (alias-to-alias in any
  order). GlobalAlias recognized as an operand (IsAGlobalAlias);
  aliases normalized like globals; thread_local aliases detected
  textually (accessors unwrap GlobalVariable). Personalities
  generalized to ANY constant via resolve-constant (a corpus file has
  personality ptr inttoptr(i64 1 to ptr)). New aliases golden entry
  (212 checks). Corpus: 29432 + 2557 renderer + 2 fixpoint = 31991
  verified (87.7%); the fn-alignment (~337) and alias (~262) buckets
  are gone.

- Round 12 (2026-08-23): metadata-typed operands MODELED, the
  largest bucket (~1.7k files) eliminated. Two-part fix, per the
  semantic-tier analysis: (1) the bulk was normalizer debris -- 
  StripModuleDebugInfo removes dbg-intrinsic CALLS but leaves their
  dead declarations; the normalizer now deletes unused llvm.dbg.*
  declarations (~1.2k files). (2) The real semantics: metadata type +
  operand forms (md "string") / (md (element ...)) -- constrained-FP
  rounding/exception selectors, type.test typeids, read/write_register
  names. Metadata ids in retained lines are print artifacts:
  comparable-ir now renames !N (and raw <0x...> pointer forms) densely
  by first occurrence, so both sides match iff reference STRUCTURE
  matches -- which also catches identity collapse: LowerTypeTests
  `distinct !{}` typeids rebuilt uniqued would merge; unbuild now
  detects same-content-different-identity nodes (no C API for
  distinct). Also detected: value-as-metadata operands, cyclic scope
  lists. New normalized-golden entry kind (check-normalized-entry!)
  for constructs only expressible next to auto-attributed intrinsic
  declarations. MDString length was passed in characters, not bytes --
  fixed. Corpus: 31012 + 2659 renderer + 2 fixpoint = 33673 verified
  (92.3%), +1682 files, the largest single round since the harness
  was built. Zero bugs, zero mismatches.

### Next (coverage burn-down, by corpus statistics)
- Operand bundles (~334), token type kind (~293), residual constexpr
  kinds (~244), alloca addrspace (~199), unnamed identified structs
  (~121), all-constant folding residue (~102), NaN payloads (~93),
  module asm (~74), cross-function blockaddress (~66).
- Smaller leftovers: scalable vectors, raw value injection (the reserved
  (ptr N) shape), constant expressions on demand, address-spaced globals.

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
