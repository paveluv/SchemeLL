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
| named module metadata (`!llvm.module.flags`, `!llvm.ident`, ...) | detected |
| module-level inline asm (`module asm "..."`) | detected |
| comdat sections | undetected |
| `source_filename` | ignored by design (module identity, not IR content) |

## Functions

| Construct | Detection |
|---|---|
| function / return / parameter attributes (`nounwind`, `noundef`, `sret(T)`, `#0` groups, ...) | detected |
| non-C calling conventions (`fastcc`, `tailcc`, `coldcc`, ...) | detected |
| sections (`section "..."`) | detected |
| visibility (`hidden` / `protected`) | detected |
| `dso_local` | undetected |
| `unnamed_addr` / `local_unnamed_addr` | undetected |
| DLL storage class (`dllimport`/`dllexport`) | undetected |
| garbage-collector name (`gc "..."`) | undetected |
| prefix / prologue data | undetected |
| functions in non-zero program address spaces | undetected |
| intrinsic declarations acquiring auto-upgraded attributes | detected (via the attribute check) |

## Global variables

| Construct | Detection |
|---|---|
| `thread_local` | detected |
| sections | detected |
| visibility | detected |
| non-zero address spaces (`@g = addrspace(1) global ...`) | detected |
| `unnamed_addr`, `externally_initialized`, DLL storage, partitions | undetected |

## Instructions

| Construct | Detection |
|---|---|
| attached metadata (`!dbg`, `!tbaa`, `!prof`, `!range`, ...) | detected |
| call-site attributes and call-site calling conventions | undetected |
| operand bundles (`[ "deopt"(...) ]`) | detected |
| `syncscope("singlethread")` (and named syncscopes) on atomics | detected |
| non-default alignment on atomicrmw/cmpxchg (ll rebuilds with the ABI default) | undetected |
| poison shuffle-mask lanes (`<4 x i32> <i32 0, i32 poison, ...>`) | detected |
| multi-index extractvalue/insertvalue (chain single-index forms instead) | detected |

## Types

| Construct | Detection |
|---|---|
| named struct types (`%struct.foo = type {...}`) | detected |
| packed structs (`<{ ... }>`) | detected |
| scalable vectors (`<vscale x 4 x i32>`) | detected |
| `x86_mmx`, `x86_amx`, target extension types, `label`/`metadata`/`token` in type positions | detected |

## Constants

| Construct | Detection |
|---|---|
| constant expressions (`ptrtoint (ptr @g to i64)`, gep constexprs, ...) — opaque pointers made the common ones unnecessary; add on demand | detected (reports the constexpr opcode) |
| integer constants wider than 64 bits | detected |
| fp constants not exactly representable as a double (fp128/x86_fp80 values; half/bfloat constants that fit a double ARE modeled) | detected |
| aggregate constants in instruction-operand positions (only global initializers and landingpad clauses accept them) | detected |
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
- address-spaced globals via the `(addrspace N)` attribute form.
