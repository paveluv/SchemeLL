# What ll does not model

The complete ledger of LLVM IR constructs outside (llscheme ll)'s grammar,
as of 2026-08-22 (LLVM 19). Companion to `project/ll-design.md` (what IS
modeled) and `project/coverage-plan.md` (how coverage is verified).

**Detection column**: `ll:unbuild` is strict — *detected* means it raises a
`not modeled` error naming the construct; *undetected* means the walker
cannot see the construct and would silently lose it — for those, the
corpus harness's print comparison is the backstop that catches the loss.
Nothing on this list fails silently through both nets.

When a construct gets modeled, its row moves out of this file and (for
corpus purposes) out of the harness normalizer — same ledger discipline as
`coverage-exclusions.ss`: implemented ∪ documented-here = LLVM IR.

## Module level

| Construct | Detection |
|---|---|
| `target triple = "..."` | detected |
| `target datalayout = "..."` | detected |
| global aliases (`@a = alias ...`) | detected |
| ifuncs (`@i = ifunc ...`) | detected |
| named module metadata (`!llvm.module.flags`, `!llvm.ident`, ...) | detected; `(ll:unbuild m 'ignore-named-metadata)` opts out explicitly (the corpus harness does, stripping `!` lines from the comparison) |
| module-level inline asm (`module asm "..."`) | detected |
| comdat sections | undetected; the normalizer clears per-global comdats, declaration lines excluded textually |
| `source_filename` | ignored by design (module identity, not IR content) |

## Functions

| Construct | Detection |
|---|---|
| function / return / parameter attributes (`nounwind`, `noundef`, `sret(T)`, `#0` groups, ...) | detected |
| non-C calling conventions (`fastcc`, `tailcc`, `coldcc`, ...) | detected |
| sections (`section "..."`) | detected |
| visibility (`hidden` / `protected`) | detected |
| `dso_local` | undetected; the corpus harness normalizes it textually (no C API accessor in LLVM 19) |
| alignment on function definitions/declarations (`define ... align 8`) | detected |
| `unnamed_addr` / `local_unnamed_addr` | undetected |
| DLL storage class (`dllimport`/`dllexport`) | undetected; the corpus normalizer strips it |
| garbage-collector name (`gc "..."`) | undetected; the corpus normalizer strips it |
| prefix / prologue data | detected |
| functions in non-zero program address spaces | detected |
| intrinsic declarations acquiring auto-upgraded attributes | detected (via the attribute check) |

## Global variables

| Construct | Detection |
|---|---|
| `thread_local` | detected |
| sections | detected |
| visibility | detected |
| `externally_initialized` | detected |
| global variable attributes (`@g = global i32 7 #0`) | undetected (no C API); normalized textually |
| `unnamed_addr`, DLL storage, partitions | undetected; unnamed_addr is normalizer-stripped |

## Instructions

| Construct | Detection |
|---|---|
| attached metadata (`!dbg`, `!tbaa`, `!prof`, `!range`, ...) | detected |
| call-site attributes and call-site calling conventions | undetected |
| operand bundles (`[ "deopt"(...) ]`) | detected |
| `syncscope("singlethread")` on atomics | detected |
| named syncscopes (`syncscope("agent")`, ...) | undetected (no C API in LLVM 19); the harness normalizes them textually |
| `swifterror` / `inalloca` bits on alloca | undetected (no C API); normalized textually |
| sanitizer metadata on globals (`no_sanitize_address`, ...) | undetected (no C API); normalized textually |
| values explicitly named with digit strings (`%"0"`; inexpressible under the anonymity rule) | detected |
| multi-index extractvalue/insertvalue (chain single-index forms instead) | detected |
| instructions with all-constant operands (the C-API builder constant-folds them; no non-folding builder exists in the C API) | detected; `'tolerate-builder-folds` opts in, and the corpus fixpoint tier verifies such files modulo folding |
| alloca in a non-zero address space (datalayout-driven; the C-API builder cannot produce them) | detected |
| alignments of 2^32 or larger (LLVMGetAlignment truncates; the attribute is omitted) | undetected |
| no-op casts, e.g. `bitcast ptr %x to ptr` (the C-API builder folds them away even on non-constants) | detected; same `'tolerate-builder-folds` / fixpoint-tier treatment |
| metadata- and token-typed operands (`metadata !"..."` intrinsic arguments) | detected (as type kinds) |

## Types

| Construct | Detection |
|---|---|
| unnamed identified struct types (`%0 = type {...}`) | detected |
| `x86_mmx`, `x86_amx`, target extension types, `label`/`metadata`/`token` in type positions | detected |

## Constants

| Construct | Detection |
|---|---|
| constant expressions (`ptrtoint (ptr @g to i64)`, gep constexprs, ...) — opaque pointers made the common ones unnecessary; add on demand | detected (reports the constexpr opcode) |
| fp constants not exactly representable as a double (fp128/x86_fp80 values; half/bfloat constants that fit a double ARE modeled) | detected |
| blockaddress referencing another function | detected |
| non-ASCII byte arrays are modeled — unbuild falls back from `(c "...")` to per-element `(i8 N)` groups, which LLVM re-canonicalizes to the identical constant | n/a (modeled) |

## Inline asm

| Construct | Detection |
|---|---|
| Intel dialect (`asm inteldialect ...`) | detected |
| unwinding asm (`asm unwind ...`) | detected |

## Known-representable gaps (reserved syntax, not yet implemented)

- raw value injection: the reserved `(ptr N)` operand shape for inttoptr
  address constants (e.g. Scheme callback pointers).

(Modeled since the first corpus rounds, 2026-08-22: named/packed struct
types via `(type %name ...)` items, scalable vectors, function linkage,
integer constants of any width, aggregate constants as instruction
operands, poison shuffle-mask lanes, address-spaced globals, anonymous
all-digit `%N` names; later rounds: trunc nsw/nuw flags, explicit
alignment on atomicrmw/cmpxchg, named-struct-typed constants.)
