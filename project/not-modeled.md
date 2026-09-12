# What sll does not model

The complete ledger of LLVM IR constructs outside (sll)'s grammar,
initially recorded 2026-08-22, updated for LLVM 16/19/20. Companion to `project/sll-design.md` (what IS
modeled) and `project/coverage-plan.md` (how coverage is verified).

**Detection column**: `sll:unbuild` is strict — *detected* means it raises a
`not modeled` error naming the construct; *undetected* means the walker
cannot see the construct and would silently lose it — for those, the
corpus harness's print comparison is the backstop that catches the loss.
Nothing on this list fails silently through both nets.

When a construct gets modeled, its row moves out of this file and (for
corpus purposes) out of the harness normalizer — same ledger discipline as
`coverage-exclusions.ss`: implemented ∪ documented-here = LLVM IR.

## Release-specific limits

On LLVM 16, unbuild explicitly refuses inline-asm callees, blockaddress
constants, operand bundles and target extension type inspection because their
C accessors are absent. These are capability restrictions on that release;
the grammar can represent them on newer releases.

Instruction flags, tail kinds beyond `tail`, wrapping atomic operations and
arrays larger than 2^32−1 can be read and rendered on 16, but their native
construction APIs are unavailable and raise a named capability error. The
corpus's strict text-renderer tier verifies their canonical round trips.
See [the capability table](llvm-versions.md) for exact per-release behavior.

## Module level

| Construct | Detection |
|---|---|
| `thread_local` aliases (the thread-local accessors unwrap GlobalVariable) | detected (textually, from the printed alias) |
| named module metadata (`!llvm.module.flags`, `!llvm.ident`, ...) | detected; `(sll:unbuild m 'ignore-named-metadata)` opts out explicitly (the corpus harness does, stripping `!` lines from the comparison) |
| comdat sections | undetected; the normalizer clears per-global comdats, declaration lines excluded textually |
| `source_filename` | ignored by design (module identity, not IR content) |

## Functions

| Construct | Detection |
|---|---|
| return / parameter attributes (`noundef`, `sret(T)`, ...) | detected |
| valued enum function attributes (`memory(...)`, `uwtable(sync)`, `alignstack(N)`, `allocsize(N)`, ...) and type attributes at function position | detected |
| sections (`section "..."`) | detected |

Function-position VALUELESS enum attributes (`nounwind`, `noinline`,
...; the table in `sll/attributes.sls`) and string attributes
(`"gc-leaf-function"`, `"frame-pointer"="all"`) ARE modeled
(2026-08-24). Deviation from the usual ledger rule: the corpus
normalizer still strips ALL attributes, so the corpus does not yet
test the modeled subset -- attribute fidelity across all positions
and kinds is a future corpus campaign; until it runs, the golden
entry `function-attributes` is the pin.
| visibility (`hidden` / `protected`) | detected |
| `dso_local` | undetected; the corpus harness normalizes it textually (no C API accessor in LLVM 19) |
| `unnamed_addr` / `local_unnamed_addr` | undetected |
| DLL storage class (`dllimport`/`dllexport`) | undetected; the corpus normalizer strips it |
| prefix / prologue data | detected |
| intrinsic declarations acquiring auto-upgraded attributes | detected (their groups carry `memory(...)`, a valued attribute) |

## Global variables

| Construct | Detection |
|---|---|
| `thread_local` | detected |
| sections | detected |
| visibility | detected |
| global variable attributes (`@g = global i32 7 #0`) | undetected (no C API); normalized textually |
| `code_model "small"/"large"` on globals | undetected (no C API in LLVM 19); normalized textually |
| `sanitize_address_dyninit` / `sanitize_memtag` global sanitizer bits | undetected (no C API); normalized textually |
| `unnamed_addr`, DLL storage | undetected; unnamed_addr is normalizer-stripped |
| `partition "..."` on globals and functions | undetected (no C API); normalized textually |

## Instructions

| Construct | Detection |
|---|---|
| attached metadata (`!dbg`, `!tbaa`, `!prof`, `!range`, ...) | detected |
| LLVM 20 `icmp samesign` (no C API accessor or setter) | detected from the printed instruction's opcode prefix; quoted SSA names are skipped; never silently dropped |
| call-site attributes at return/parameter positions | undetected |
| operand bundles on callbr | detected (call and invoke bundles are modeled) |
| calls through null/undef pointer constants in non-zero address spaces (the untyped callee slot cannot carry the addrspace) | detected |
| named syncscopes (`syncscope("agent")`, ...) | undetected (no C API in LLVM 19); the harness normalizes them textually |
| `swifterror` / `inalloca` bits on alloca | undetected (no C API); normalized textually |
| sanitizer metadata on globals (`no_sanitize_address`, ...) | undetected (no C API); normalized textually |
| values explicitly named with digit strings (`%"0"`, `@"0"`; inexpressible under the anonymity rule) | detected (locals and globals) |
| multi-index extractvalue/insertvalue (no C-API builder; chain single-index forms, or let the corpus render tier verify via the parser) | detected in strict mode; emitted under `'tolerate-builder-folds` |
| instructions with all-constant operands (the C-API builder constant-folds them; no non-folding builder exists in the C API) | detected; `'tolerate-builder-folds` opts in, and the corpus render tier verifies such files strictly through `(sll render)` + LLVM's non-folding parser |
| alloca outside the datalayout's alloca address space (the C-API builder always uses the `A` default; allocas IN it are modeled) | detected (A sniffed from the datalayout string) |
| functions outside the datalayout's program address space (same story with `P`) | detected |
| alignments of 2^32, LLVM's maximum (LLVMGetAlignment truncates to 0; the attribute is omitted) | detected textually by the corpus harness (the C API cannot see it) |
| no-op casts, e.g. `bitcast ptr %x to ptr` (the C-API builder folds them away even on non-constants) | detected; same `'tolerate-builder-folds` / render-tier treatment |
| value-as-metadata operands (`metadata i64 %x`; nearly always debug intrinsics, which the harness strips) | detected |
| cyclic metadata node operands (`distinct !{!0, ...}` self-references, e.g. noalias scope lists) | detected |
| distinct metadata operand nodes (no C API to create distinct nodes; rebuilding uniqued would collapse identities, e.g. LowerTypeTests typeids `distinct !{}`) | detected (same content arriving under a second identity) |

## Types

| Construct | Detection |
|---|---|
| `label` in first-class type positions | detected (x86_amx, target-ext, metadata, and token are modeled; x86_mmx is available on LLVM 19 and explicitly refused on 20, which removed the type) |

## Constants

| Construct | Detection |
|---|---|
| `dso_local_equivalent` / `no_cfi` constants (no C-API constructors) | detected (as "constant kind"; the irritant carries the printed constant) |
| non-splat extractelement/insertelement/shufflevector constexprs (splats ARE modeled; the C API cannot read a constexpr shuffle mask) | detected (reports the constexpr opcode) |
| constexpr binops carrying BOTH nuw and nsw (the C API constructors set one flag each) | detected |
| old `inrange` index markers and newer `inrange(lo, hi)` annotations on gep constexprs (vtable splitting; no C API accessor exists) | detected by LLVM tokens in the printed constant; quoted names are ignored |
| ppc_fp128 constants not exactly representable as a double (every other float type travels bit-exactly as a folded bitcast constexpr) | detected |
| blockaddress referencing another function | detected |
| `; preds = ...` block comments reflect LLVM use-list order, which is not modeled | n/a (comments; stripped from the comparison) |
| non-ASCII byte arrays are modeled — unbuild falls back from `(c "...")` to per-element `(i8 N)` groups, which LLVM re-canonicalizes to the identical constant | n/a (modeled) |

## Inline asm

| Construct | Detection |
|---|---|

## Known-representable gaps (reserved syntax, not yet implemented)

- raw value injection: the reserved `(ptr N)` operand shape for inttoptr
  address constants (e.g. Scheme callback pointers).

(Modeled since the first corpus rounds, 2026-08-22: named/packed struct
types via `(type %name ...)` items, scalable vectors, function linkage,
integer constants of any width, aggregate constants as instruction
operands, poison shuffle-mask lanes, address-spaced globals, anonymous
all-digit `%N` names; later rounds: trunc nsw/nuw flags, explicit
alignment on atomicrmw/cmpxchg, named-struct-typed constants.)
