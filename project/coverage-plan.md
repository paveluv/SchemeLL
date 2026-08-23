# Plan: verifiable 100% IR coverage for (llscheme ll)

Status: Levels 1+2 IMPLEMENTED (2026-08-22): `tests/test-coverage.ss` +
`tests/oracle.sls` (enum extraction from installed headers) +
`project/coverage-exclusions.ss` (the ledger). Score at implementation:
opcodes 42 implemented + 25 excluded = 67/67; icmp 10/10; fcmp 16/16.
Step 2 (instruction flags) done 2026-08-22: fast-math flags 7/7 and gep
no-wrap flags 3/3 as new bitmask-enum axes; nsw/nuw/exact/disjoint/nneg/
volatile proven by golden round-trips. Step 3 done 2026-08-22: opcodes
56+11=67/67 (only exception handling and UserOp1/2 remain excluded);
atomic orderings 6+1=7/7 and atomicrmw ops 17/17 as new enum axes.
Step 4 done 2026-08-22: module-level globals; linkage axis 11 + 6
obsolete = 17/17; constant expressions deferred (opaque pointers made
the common ones unnecessary). Step 5 done 2026-08-22: exception
handling — the opcode axis is COMPLETE at 65 implemented + UserOp1/2
permanently excluded = 67/67. Step 5.5 done 2026-08-22 (pre-corpus
blockers): varargs, tail markers (tail-call-kind axis 4/4), alloca
counts, non-phi forward references. Step 6a done 2026-08-22:
ll:unbuild implemented and self-tested — all 24 golden entries
round-trip parse -> unbuild -> build -> byte-identical print; strict
`not modeled` errors per project/not-modeled.md, with six
strictness tests. Step 6b harness DONE
2026-08-22 (make corpus over LLVM's regression suite, 36488 .ll files);
burn-down rounds took the pass rate 53.6% -> 63.3% -> 65.9% -> 70.9%
-> 76.0% (27744 PASS), growing the grammar by corpus frequency along
the way (named/packed struct types, scalable vectors, aggregate
constants as operands, any-width integers, poison mask lanes,
address-spaced globals, function linkage, anonymous %N names). Largest
remaining buckets: instructions with all-constant operands (C-API
builder folds them, ~2.3k), metadata-typed operands (~1.7k), constant
expressions (~1.2k), MISMATCH to be diagnosed (~1.5k), operand bundles,
global aliases. The burn-down continues by these statistics. "100% coverage" is meaningless without a
machine-checkable oracle and an explicit scope. This plan defines both, and
three verification levels that turn coverage from a claim into a test that
fails.

## Scope definition

Target: **all LLVM IR expressible through the LLVM-C API**, minus a
*versioned exclusion list* (a checked-in file with one reason per entry).
Anything not implemented must be excluded explicitly; the tests enforce that
implemented ∪ excluded = oracle, with no overlap. Nothing is ever silently
missing.

## The oracles (all machine-readable, all in installed headers)

| Axis | Oracle |
|---|---|
| Instructions | `LLVMOpcode` enum, llvm-c-19/Core.h (~68 opcodes) |
| Types | `LLVMTypeKind` enum |
| icmp/fcmp predicates | `LLVMIntPredicate` / `LLVMRealPredicate` enums |
| Instruction flags | C API setters: `LLVMSetNSW`/`NUW`/`Exact`/`IsInBounds`/`FastMathFlags` |
| Linkage, visibility, callconv, atomic orderings | enums in Core.h |
| Module-level items | C API function inventory (globals, aliases, ...) |
| Semantics | LLVM's own parser: `LLVMParseIRInContext` (IRReader.h) |
| (llvm raw) completeness | exported `LLVM*` symbols in libLLVM-19.so (1267) |

Enums are trivially extractable from the header text with Scheme string
processing — no C parser needed — so the extraction can live inside the test
suite and run on every `make test`.

## Level 1 — enumeration tests (the ledger)

A coverage test extracts each enum from the installed headers at test time
and checks it against ll's tables plus the exclusion file:

- fails if an oracle entry is neither implemented nor excluded (we missed
  something, or a new LLVM version added an instruction);
- fails if an entry is both (stale exclusion);
- reports the score: implemented / total per axis.

## Level 2 — observed-opcode + round-trip tests (the proof)

Two mechanisms make "implemented" mean "actually works":

1. **Opcode observation.** After building every ll test program, walk all
   instructions with `LLVMGetInstructionOpcode` and collect the set of
   opcodes actually emitted. Assert: observed = implemented. A handler with
   no test exercising it fails the suite — coverage is measured on emitted
   IR, not trusted from a table. Same for type kinds and predicates.
2. **Round-trip goldens.** Bind IRReader. Each construct gets a golden pair
   (ll snippet, expected textual IR); assert
   `print(build(ll)) == print(parse(expected))`. Both sides pass through
   LLVM's canonical printer, so the string comparison is exact and
   formatting-proof. This checks the transliteration table in both
   directions using LLVM itself as the referee.

## Level 3 — corpus round-trip (the endgame)

Implement `ll:unbuild` (named for what it is: the inverse of ll:build;
LLVM parses, we unbuild): walk any LLVM module (e.g. one parsed from
disk) via the C API and emit ll data. Then for `.ll` files from LLVM's own
regression corpus (`reference/llvm-project/llvm/test/`, clone command in
RULES.md):

    A = print(parse(file))                        ; LLVM's canonical form
    B = print(build(unbuild(parse(file))))    ; through our layer
    assert A == B  (or the file matches an exclusion pattern)

The corpus pass-rate is an *external* coverage metric over thousands of
real-world IR files — it catches grammar gaps we didn't imagine, not just
missing opcodes. 100% = every corpus file either round-trips byte-identically
or matches a documented exclusion (debug metadata, inline asm, ...).
Unbuilding also gives IR→ll transliteration for free (paste clang output,
get ll back).

## Gap-closing order (current known gaps)

1. IRReader + instruction-walking bindings (raw/ir), Level 1+2 harness.
2. Instruction flags via post-hoc setters: nsw/nuw/exact/inbounds/fast-math
   — unblocks `(add nsw ...)` which currently errors.
3. Missing easy instructions: switch, unreachable, indirectbr, freeze,
   extractvalue/insertvalue, insert/extractelement, shufflevector, va_arg,
   addrspacecast, atomicrmw/cmpxchg/fence + atomic load/store orderings.
4. Module-level: globals, constant expressions, aggregate/vector types in
   the type grammar, aliases.
5. Exception handling (invoke/landingpad/resume/catch*/cleanup*) — likely
   the initial exclusion list, implemented last.
6. `ll:unbuild` + corpus harness (`make coverage`).

Separate axis, same method: (llvm raw) completeness vs the 1267 exported
C symbols — eventually via the header-driven binding generator; tracked by
the same implemented/excluded ledger discipline.
