# SchemeLL

**LLVM for Chez Scheme** — and LLVM IR as s-expressions.

SchemeLL gives Scheme the whole LLVM toolchain with no glue code: full
FFI bindings over stock `libLLVM.so`, an in-memory ORC JIT that hands
back ordinary Scheme procedures, ahead-of-time object emission, and
**sll** ("Scheme's Low Level") — a complete s-expression dialect of
LLVM IR. Programs are plain data, so `quasiquote` is the macro layer
and Scheme is the metaprogramming language.

SchemeLL is built to be a **lowering target**: if you're writing a
compiler in Scheme, sll is the data structure you lower to — then JIT
it, optimize it, or emit native objects, all from the same
representation.

```scheme
(import (chezscheme) (prefix (sll) sll:))

(define fact
  (sll:procedure
    '((define i64 (@fact (i64 %n))
        (label %entry
          (= %base (icmp slt i64 %n 2))
          (br i1 %base (label %one) (label %rec)))
        (label %one (ret i64 1))
        (label %rec
          (= %n1 (sub i64 %n 1))
          (= %f (call i64 (@fact (i64 %n1))))
          (= %r (mul i64 %n %f))
          (ret i64 %r))))
    "fact"))

(fact 20)   ; => 2432902008176640000, running as native code
```

That's the whole program: one import, and IR-as-data becomes a
callable native procedure (in about 20 ms, ORC JIT included). The
syntax is textual LLVM IR transliterated — commas dropped, parens
added — so anything you know about IR carries over directly.

## Programs are data

Because an sll program is a list, generating code is just building
lists. Here is a fully unrolled `x^n`, specialized at run time:

```scheme
(define (power-prog n)
  `((define i64 (@pow (i64 %x))
      (label %entry
        ,@(let loop ([i 1] [prev '%x] [acc '()])
            (if (>= i n)
                (reverse (cons `(ret i64 ,prev) acc))
                (let ([next (string->symbol (format "%p~a" i))])
                  (loop (+ i 1) next
                        (cons `(= ,next (mul i64 ,prev %x)) acc)))))))))

((sll:procedure (power-prog 11) "pow") 2)   ; => 2048
```

The same trick scales to real problems: platform-specific code becomes
a Scheme function returning the platform-specific forms
(`examples/aot/hello-portable.ss` cross-compiles one source into both
x86-64 and AArch64 Linux objects this way).

## A 186-byte executable, no toolchain

`tools/sllc.ss` compiles `.sll` files — whole programs as pure data —
using the LLVM C API alone. For self-contained programs it even writes
the final static executable itself (a built-in minimal ELF64 emitter;
no compiler, assembler, or linker anywhere):

```
$ scheme --libdirs . --script tools/sllc.ss --opt O2 --exe examples/aot/hello-linux-x86.sll
wrote executable examples/aot/hello-linux-x86 (186 bytes, entry #x400078)
$ ./examples/aot/hello-linux-x86
Hello, SchemeLL!
```

**186 bytes**, talking to the kernel directly. `sllc` also emits
relocatable objects and assembly (including cross-target: an x86 host
emits genuine AArch64 objects), JIT-runs `@main` with `--run`, and
prints your program as textual LLVM IR with `--render-llvm-ir` —
using SchemeLL's own pure-Scheme renderer, no LLVM in the path.

## Verified against LLVM itself

sll is not a toy subset. Its coverage was driven by round-tripping
**LLVM's own regression corpus** — all 36,488 `.ll` files — through
`parse → sll:unbuild → sll:build → print` and demanding byte-identical
canonical output:

- **98.9%** of every file LLVM's parser accepts round-trips exactly
  (35,324 of 35,709; the remainder sit in named, documented buckets,
  every one a C-API limitation — the campaign's definition of 100%
  was *utilizing the C API to full potential*, and it got there).
- **Zero unexplained failures**: no mismatches, no crashes, across
  the entire corpus.
- IR construction runs at roughly **150 µs per module** (the corpus
  harness builds ~28,000 modules in ~4 seconds, benchmarked on every
  run).
- The exclusions ledger (`project/not-modeled.md`) maintains the
  invariant *implemented ∪ documented = LLVM IR* — checked by tests
  that parse the LLVM C headers as the oracle.

Everything that can appear in IR is expressible: all 67 opcodes, EH
funclets, atomics with syncscopes, operand bundles, statepoints,
inline asm (all dialects), constant expressions, metadata operands,
scalable vectors, ifuncs, aliases, unnamed struct types,
cross-function blockaddress, bit-exact NaN payloads, module asm,
datalayout/triple, and more.

## The stack

| layer | what it is |
|---|---|
| `(llvm raw)` | the C API verbatim — `(prefix (llvm raw) LLVM)` reconstructs exact C names |
| `(llvm ir)` | safe construction: contexts/modules/builders as records with **ownership tracking** — use-after-free raises a Scheme condition instead of segfaulting |
| `(llvm jit)` | ORC LLJIT: foreign signatures derived from LLVM types automatically; JIT'd code resolves process symbols (call `@cos` or `@puts` by declaring them); refuses modules targeting a foreign platform |
| `(llvm target)` | objects and assembly, to disk or bytevector; any backend in your libLLVM (X86, AArch64, ARM, RISCV, WebAssembly on stock Debian) |
| `(sll)` | the s-expression dialect: `build`, `jit`, `procedure`, `dump`, and `unbuild` (modules **back** into sll data) |
| `(sll render)` | `sll->ll`: textual LLVM IR from sll data in pure Scheme |
| `tools/sllc.ss` | the `.sll` compiler: `.o` / `.s` / `--run` / `--exe` / IR printing |

The whole stack is about **5,800 lines of Scheme**. There is no C to
compile: everything talks to stock `libLLVM` through Chez's FFI.

## Getting started

Requirements: Chez Scheme 10, LLVM 19 (`libLLVM-19.so`; the Debian
`llvm-19` packages work as-is). Only LLVM 19 is supported at the
moment; newer versions are planned.

```
$ make test        # 224 checks
$ make examples    # smoke-runs all 35 examples end to end
$ scheme --libdirs . --script examples/sll/01-add.ss
2 + 40 = 42
```

Then read **`examples/README.md`** — 35 examples in three buckets:
sll scripting (20), the binding layers (10), and AOT objects &
executables (10, including the `.sll` files).

Design documents live in `project/`: the sll grammar and its
rationale (`sll-design.md`, built nanopass-friendly: prefix-only
forms, no mid-form keywords), the coverage methodology and final
standing (`coverage-plan.md`), and the exclusions ledger
(`not-modeled.md`).
