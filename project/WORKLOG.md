# Work log

Newest entries first. Format: date, Done / Decided / Next.

## 2026-09-09 — Record model attribution and Scheme-only tooling

### Done

- Added AGENTS.md with the user's exact-model Co-Authored-By requirement
  and the Scheme-only tooling rule, including temporary probes and scripts.
- Replaced conflicting older co-author guidance in RULES and HANDOFF.
- Checked Markdown formatting and whitespace; implementation is unchanged.

### Next

- Apply these rules to future work in this repository.

## 2026-09-09 — Use Schematter's pre-commit helpers

### Done
- Updated `schematter/` to `d220dcf`, including `(schematter hook)` and the
  renamed `schematter.sps` CLI.
- Added `project/hooks/pre-commit.sps`, using `format-staged` to select,
  format, and report staged Scheme sources (including `.sll`) and Scheme
  blocks in `.md` and `.markdown` files.
- Reduced the shell hook to submodule initialization guidance and Chez
  selection, preserving the `CHEZ` override and `chez-scheme` fallback.
- Updated the Makefile's CLI path and documented the hook's Markdown support.
- All 109 upstream CLI tests passed. Local Git fixtures verified commit
  rejection and retry, all seven extensions, filenames with spaces, Markdown
  prose preservation, unstaged files, malformed input, missing-submodule
  guidance, the `CHEZ` override, and a simulated `chez-scheme` fallback.
- Verified `make check-format`, formatting of the new Scheme entry point and
  edited Markdown files, shell syntax, and `git diff --check`.
- Rebased onto `origin/main` at `4e83cf8` and formatted the incoming
  function-section changes in `sll.sls`, `sll/unbuild.sls`, and
  `tests/test-sll.ss`. The combined tree passes `make build`, `make test`
  (303 passed, 0 failed), and the formatting checks.

### Decided
- Keep Chez executable selection in the shell launcher and use `--script`
  for the Scheme entry point so its library path is set before imports.

### Next
- (unchanged below)

## 2026-09-08 — Reapply Schematter with original form separation

### Done
- Updated `schematter/` to `5ed2579`, which preserves existing blank
  separators without adding them between adjacent top-level forms.
- Reformatted all 73 Scheme sources from `93e3c9a`, the commit before the
  Schematter migration. Removed 362 blank separator lines across 41 files;
  the source diff contains no other changes.
- Reprocessed the three original README samples while preserving the
  current prose and formatter setup notes; the README output is unchanged.
- Verified datum equivalence against the committed sources,
  `make check-format`, the native README formatting check, `make test`
  (300 passed, 0 failed), and `git diff --check`.

### Decided
- Use the original source spacing as input so separators inserted by the
  previous formatter do not become permanent.
- Keep this update in a separate commit after `5ff52e8`.

### Next
- (unchanged below)

## 2026-09-08 — Schematter submodule and formatting

### Done
- Added `https://github.com/paveluv/Schematter.git` as the `schematter/`
  submodule, now pinned at `d7943eb43e4e0008718f375019741b850bdba45d`.
- Reformatted all 73 tracked Scheme sources, including the `.sll` examples.
- Switched `make format` and the pre-commit hook to Schematter; added
  `make check-format`. All three cover `.sls`, `.ss`, `.scm`, `.sps`, and
  `.sll`, with filenames passed using NUL delimiters.
- Documented submodule initialization and the formatting workflow in the
  README, rules, and handoff notes.
- Formatted all three Scheme code samples in `README.md` with Schematter,
  verified that a second pass leaves them unchanged, and added an explicit
  note about the canonical form before the first sample.
- Pulled Schematter's native Markdown support and ran its CLI directly on
  `README.md` with `-i` and `--check`. The README stayed byte-identical;
  all 12 upstream Markdown tests and `make check-format` passed.
- Verified `make check-format`, `make test` (300 passed, 0 failed),
  `make examples`, and `git diff --check`. Integration smoke checks covered
  all five extensions, filenames with spaces, missing-submodule guidance,
  and the hook's reformat/re-add workflow.

### Decided
- Keep the formatter pinned with the project and use its canonical defaults.

### Next
- (unchanged below)

## 2026-09-07 — byte-string constants from a bytevector

### Done
- `(c BYTES)` / `(cz BYTES)` accept a bytevector beside a string, on both
  paths: the builder through a second raw binding of
  `LLVMConstStringInContext2` over `u8*` (`ConstStringInContext2/bytes`,
  `ir:const-string` dispatches), the renderer through `quoted-bytes` taking
  the bytes as they are. A string's utf8 cannot spell a byte above 127;
  Woof's base64 global initializer (its P30) hands sll the decoded
  bytevector for MeikScheme's byte-encoded quote stream (M13/S5).
- Suite 300/0 unchanged.

### Decided
- A bytevector in a constant means its bytes exactly; a string still
  means its utf8. No third spelling.

### Next
- (unchanged below)

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

- Switched sll to grouped block form (DECIDED, replaces flat labels):
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
  is "medl" — (SchemeLL medl), prefix medl:. MEDium Language, pronounced
  like "medal"; only known collision is an obscure academic MEDL (MaC
  runtime verification, ~2000). sll keeps its name (the .ll resonance).
  Rejected along the way: lol/mel (2026-08-22 discussion), M (MUMPS,
  Power Query), lowl/midl (MIDL = Microsoft IDL).

- Grammar migration DECIDED + done: the sll design principle is now
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

- Step 6a done: sll:unbuild — the inverse of sll:build, named per review
  (LLVM parses, we unbuild). New library (sll unbuild),
  re-exported by (sll); ~95 read-only getter bindings added to
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
  Second chance: (sll:unbuild m 'tolerate-builder-folds) + stability
  check over our own print. Corpus: 28024 strict + 1826 modulo-folding
  = 29850 verified (81.8%). Escape hatches ranked for the residue:
  textual sll->ll backend parsed by LLVM (zero-glue, exact; roadmapped),
  upstream C API patch, C shim (rejected: breaks zero-glue).

- (sll render): sll->ll printer (textual IR) in pure Scheme (no LLVM
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

- Round 13 (2026-08-23), motivated by the GC-in-medl goal: operand
  bundles, token type, gc attribute, and target datalayout/triple all
  MODELED -- the full statepoint chain (gc.statepoint + "deopt"/
  "gc-live" bundles + gc.relocate/gc.result + tokens + gc
  "statepoint-example" + ni:1 datalayout) round-trips through build,
  unbuild, AND render (statepoints golden). Grammar: (bundle "tag"
  (ty arg)...) after the application on call/invoke; (gc "name")
  after (align N); (datalayout "...")/(triple "...") module items --
  which the parser demands BEFORE any other entity (found the hard
  way: 811 render failures). Un-stripping the datalayout surfaced the
  A/G default address spaces: LLVMAddGlobal uses the G default, so
  globals now always pass an explicit space; AS0 allocas under a
  non-zero A default are inexpressible (builder always uses A) and
  detected by sniffing the datalayout string. Modeling datalayout
  also fixed the one permanently render-unrepresentable file (wasm
  funcref). Corpus: 31595 + 2705 renderer + 2 fixpoint = 34302
  verified (94.0% of all, 96.2% of parseable); bundle (~334) and
  token (~293) buckets gone. 219 checks.

- Round 14 (2026-08-23): seven features. Address spaces: allocas in
  the datalayout's A space and functions in its P space round-trip
  (both the parser and the builder apply those defaults -- verified
  empirically; detections relaxed to "outside the default", A/P
  sniffed from the DL string); allocas carry an (addrspace N)
  annotation; calls through pointers outside the program space get an
  (addrspace N) marker rendered as IR's `call addrspace(N)`.
  syncscope("singlethread") modeled as a `singlethread` flag
  (SetAtomicSingleThread). externally_initialized modeled.
  fp constants a double cannot carry (NaN payloads, fp80/fp128
  values) travel as folded bitcast constexprs -- bitcast folds
  bit-exactly IN BOTH DIRECTIONS for every float type except
  ppc_fp128, so unbuild extracts bits via fp->int folding and emits
  (bitcast i16 31745 half); killed the NaN (93) and most of the
  fp-inexact bucket. ifuncs modeled ((= @i (ifunc fn-type (ptr
  @resolver))), two-phase like aliases). module asm modeled
  ((module-asm "...") item; render re-splits lines). partition "..."
  normalized textually (no C API). round14 golden covers all seven
  (223 checks). Corpus: 31888 + 2720 renderer + 2 fixpoint = 34610
  verified (94.9% of all, 97.0% of parseable).

- Round 15 (2026-08-23): coverage goal REDEFINED with the user: 100%
  means utilizing the C API to full potential; C-API gaps are valid
  exclusions (like UserOp1/2). Modeled: unnamed identified struct
  types ((type %0 ...) -- all-digit type names are anonymous like
  values; StructCreateNamed(ctx, "") creates them, and the printer
  numbers types by FIRST USE on both sides, so numbering matches by
  construction; build keeps an anon-types table since GetTypeByName2
  cannot see unnamed types). Cross-function blockaddress: build gained
  a prepare-blocks! pass creating every define's blocks BEFORE any
  emission (registry parameter function-blocks), so blockaddress
  resolves across functions and from global initializers; unbuild
  names other functions' blocks via an on-demand function-names walk.
  Multi-index extractvalue/insertvalue: no C-API builder (valid
  exclusion for the build path) but emitted under the tolerance flag
  and verified strictly by the render tier. Fixed a real bug the
  round surfaced: struct constants for ANONYMOUS identified types
  were built as literal structs (the named-vs-literal test used the
  name; now IsLiteralStruct). The comparison drops type-definition
  lines whose name is unreferenced in retained text (to a fixpoint):
  LLVM's TypeFinder also walks named metadata, which the harness
  ignores. constant kind bucket diagnosed: mostly
  dso_local_equivalent/no_cfi (no C constructors -- valid exclusion);
  irritants now carry the printed constant. Corpus: 32061 + 2803
  renderer + 2 fixpoint = 34866 verified (95.6% of all, 97.6% of
  parseable).

- Round 16 (2026-08-23): splat constants, Intel/unwinding asm, and
  the exotic types. `splat (i32 7)` is LLVM 19's spelling of scalable
  splats (shufflevector-of-insertelement constexprs; fixed-vector ones
  fold to plain vectors) -- modeled as (splat (ty elem)); since the C
  API cannot read a constexpr shuffle's mask, unbuild verifies the
  shape by reconstructing the splat and POINTER-comparing (constexprs
  are uniqued). Killed most of the constexpr bucket (247 -> 15).
  Inline asm's dialect and can-throw are just LLVMGetInlineAsm
  parameters: (asm "T" "C" sideeffect? alignstack? inteldialect?
  unwind?) fully modeled. x86_mmx / x86_amx type symbols and
  target-ext types ((target-ext "spirv.Image" void 0 1) -- type
  params then int params, as in IR) modeled with the full 19 C API
  reader/constructor set. Corpus: 32438 + 2843 renderer + 2 fixpoint
  = 35283 verified (96.7% of all, 98.8% of parseable). The remaining
  426 bucket files are nearly all C-API gaps (alloca outside DL-A 157,
  folding 45+6, dso_local_equivalent/no_cfi 44, cyclic/distinct md 27,
  fn outside DL-P 21, inrange 21, ppc_fp128 10, prefix/prologue 13,
  max-align 7, thread_local aliases 6, value-as-md 6) or grammar
  choices (digit-string names 32); a handful of stragglers (alias AS
  4, callbr bundles 1, splat residue 15) are modelable followups.

- Round 16 (2026-08-23): splat constants ((splat (ty elem)); shape
  verified by reconstructing and pointer-comparing, constexprs being
  uniqued -- the C API cannot read a constexpr shuffle mask);
  inteldialect/unwind asm flags (always just LLVMGetInlineAsm
  parameters); x86_mmx / x86_amx / target-ext types with the full 19
  reader set. 247-file constexpr bucket -> 15; 142 exotic-type files
  unblocked.
- Round 17, the scraps round (2026-08-23): alias address spaces,
  operand bundles on callbr, call-site (addrspace n) markers typing
  constant callees at build (call addrspace(1) void null() rebuilds
  exactly), extractelement/insertelement constexprs. The harness
  writes every bucketed file's path to tests/tmp/corpus-buckets.txt.
  A lost-patch regression (call/callbr edits silently unapplied)
  surfaced as 2 MISMATCHes and was re-applied.

### Coverage campaign: COMPLETE (2026-08-23)

Final: 32452 strict + 2868 renderer + 4 fixpoint = 35324 verified,
96.8% of all 36488 files, 98.9% of the 35709 parseable. Zero
MISMATCH / BUG / RENDER-FAIL. 17 rounds, 53.6% -> 98.9%. Declared
complete per the agreed definition: 100% = full C-API potential; the
385 remaining files sit in 17 named ledger buckets, every one a
documented C-API gap or recorded grammar choice.

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
- Library prefixes: `(llvm ...)` for bindings, `(SchemeLL ...)` reserved for the DSL.
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

- Wrote the design proposal for the first DSL layer: `project/sll-design.md`
  ((sll), LLVM IR as s-expressions). Key calls: mechanical
  transliteration from textual IR, flat control flow with `(label %x)`
  instructions, data-interpreter core + thin quasiquoting macro (not
  per-opcode macros). Awaiting review before implementation.

- Implemented `(sll)` per the design doc: data interpreter with
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
