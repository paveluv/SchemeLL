# Plan: verifiable 100% IR coverage for (llscheme ll)

Status: Levels 1+2 IMPLEMENTED (2026-08-22): `tests/test-coverage.ss` +
`tests/oracle.sls` (enum extraction from installed headers) +
`project/coverage-exclusions.ss` (the ledger). Score at implementation:
opcodes 42 implemented + 25 excluded = 67/67; icmp 10/10; fcmp 16/16.
Levels 3 (corpus round-trip via ll:disassemble) still to do. "100% coverage" is meaningless without a
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

Implement `ll:disassemble`: walk any LLVM module (e.g. one parsed from
disk) via the C API and emit ll data. Then for `.ll` files from LLVM's own
regression corpus (`reference/llvm-project/llvm/test/`, clone command in
RULES.md):

    A = print(parse(file))                        ; LLVM's canonical form
    B = print(build(disassemble(parse(file))))    ; through our layer
    assert A == B  (or the file matches an exclusion pattern)

The corpus pass-rate is an *external* coverage metric over thousands of
real-world IR files — it catches grammar gaps we didn't imagine, not just
missing opcodes. 100% = every corpus file either round-trips byte-identically
or matches a documented exclusion (debug metadata, inline asm, ...).
Disassembly also gives IR→ll transliteration for free (paste clang output,
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
6. `ll:disassemble` + corpus harness (`make coverage`).

Separate axis, same method: (llvm raw) completeness vs the 1267 exported
C symbols — eventually via the header-driven binding generator; tracked by
the same implemented/excluded ledger discipline.
