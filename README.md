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

Clients that prepare modules themselves can query `(llvm jit)`'s
`target-triple` and `data-layout`, or `(llvm target)`'s `machine-triple` and
`machine-data-layout`, before building instructions. Supply these as sll
`triple` and `datalayout` headers so builder alignments and optimization see
the target from the start. Both layout queries accept an optional list of
non-integral address spaces to add to the target's policy. `sll:build`
releases partial modules and builders on failure; a successful module still
belongs to its caller. Woof clients normally use Woof's owned execution API.

The project's Scheme code, including the samples below, uses
[Schematter](https://github.com/paveluv/Schematter) canonical form:
`(...)` for single-line lists and `[...]` for multiline lists.

```scheme
(import (chezscheme) (prefix (sll) sll:))

[define
 fact
 [sll:procedure
  '[[define
     i64
     (@fact (i64 %n))
     [label
      %entry
      (= %base (icmp slt i64 %n 2))
      (br i1 %base (label %one) (label %rec))]
     (label %one (ret i64 1))
     [label
      %rec
      (= %n1 (sub i64 %n 1))
      (= %f (call i64 (@fact (i64 %n1))))
      (= %r (mul i64 %n %f))
      (ret i64 %r)]]]
  "fact"]]

(fact 20)                       ; => 2432902008176640000, running as native code
```

That's the whole program: one import, and IR-as-data becomes a
callable native procedure (in about 20 ms, ORC JIT included). The
syntax is textual LLVM IR transliterated — commas dropped, parens
added — so anything you know about IR carries over directly.

## Programs are data

Because an sll program is a list, generating code is just building
lists. Here is a fully unrolled `x^n`, specialized at run time:

```scheme
[define
 (power-prog n)
 `[[define
    i64
    (@pow (i64 %x))
    [label
     %entry
     ,@[let
        loop
        ((i 1) (prev '%x) (acc '()))
        [if
         (>= i n)
         (reverse (cons `(ret i64 ,prev) acc))
         [let
          ((next (sll:name '%p i)))
          (loop (+ i 1) next (cons `(= ,next (mul i64 ,prev %x)) acc))]]]]]]]

((sll:procedure (power-prog 11) "pow") 2) ; => 2048
```

(`sll:name` assembles `%`/`@` names from symbol, string, and integer
pieces — the generator's replacement for `string->symbol`+`format`.)

The same trick scales to real problems: platform-specific code becomes
a Scheme function returning the platform-specific forms
(`examples/aot/hello-portable.ss` cross-compiles one source into both
x86-64 and AArch64 Linux objects this way).

## A 194-byte executable, no toolchain

`tools/sllc.ss` compiles `.sll` files using the LLVM C API alone, and
for self-contained programs it even writes the final static executable
itself (a built-in minimal ELF64 emitter; no compiler, assembler, or
linker anywhere).

A `.sll` file is the **inverted format**: its top level is sll data,
and Scheme is escaped *into* it. The whole file is one quasiquote
body — `,expr` and `,@expr` evaluate at compile time, top-level
`(scheme ...)` forms hold the definitions and imports they use, and
plain data is the degenerate case. This is
`examples/aot/hello-metaprog.sll`, a self-contained file that picks
the host's kernel ABI and builds its inline asm structurally, at
compile time:

```scheme
[scheme
 (import (prefix (sll asm) asm:))
 [define-values
  (instr nr-reg ret-reg arg-regs clobbers sys-write sys-exit)
  [case
   (machine-type)
   ((a6le ta6le) (values "syscall" 'rax 'rax '(rdi rsi rdx) '(rcx r11) 1 231))
   ((arm64le tarm64le) (values "svc #0" 'x8 'x0 '(x0 x1 x2) '() 64 94))]]
 (define (syscall nr . args) ...)] ; a few lines of generator

[define
 void
 (@_start)
 [label
  %entry
  ...                           ; plain sll, verbatim
  ,@(syscall sys-write '(i64 1) '(ptr %buf) '(i64 17))
  ,@(syscall sys-exit)
  (unreachable)]]
```

```
$ scheme --libdirs . --script tools/sllc.ss --opt O2 --exe examples/aot/hello-metaprog.sll
wrote executable examples/aot/hello-metaprog (194 bytes, entry #x400080)
$ ./examples/aot/hello-metaprog
Hello, SchemeLL!
```

**194 bytes**, talking to the kernel directly, from constraint strings
no human spelled. `sllc` also emits
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
| `(llvm datalayout)` | the datalayout string as structured data: `parse`/`unparse`, byte-identical round-trips (validated against every layout in LLVM's test corpus), unknown components pass through verbatim |
| `(sll)` | the s-expression dialect: `build`, `jit`, `procedure`, `dump`, and `unbuild` (modules **back** into sll data) |
| `(sll render)` | `sll->ll`: textual LLVM IR from sll data in pure Scheme |
| `(sll asm)` | structured inline asm: named operands, computed `$N` numbering, assembled constraint strings |
| — | the freestanding kernel ABI (`(abi ...)`) moved to the Woof repo (2026-08-27): SchemeLL is a pure LLVM wrapper; machine and kernel knowledge live with the systems language |
| `tools/sllc.ss` | the `.sll` compiler: `.o` / `.s` / `--run` / `--exe` / IR printing |

The whole stack is about **5,800 lines of Scheme**. There is no C to
compile: everything talks to stock `libLLVM` through Chez's FFI.

## Getting started

Requirements: Chez Scheme 10, LLVM 19 (`libLLVM-19.so`; the Debian
`llvm-19` packages work as-is).

**Status: work in progress.** SchemeLL has so far been tested only on
x86-64 Linux and x86-64 FreeBSD (including the freestanding `--exe`
executables on both), always with LLVM 19 — the only supported LLVM
version at the moment. Newer LLVM versions and more platforms are
planned.

```
$ make build       # compile the libraries to .so (later runs start ~5x faster)
$ make test        # 313 checks
$ make examples    # smoke-runs all 37 examples end to end
$ make reference   # (optional) fetch LLVM's test corpus for `make corpus`
$ scheme --libdirs . --script examples/sll/01-add.ss
2 + 40 = 42
```

Schematter is pinned as a submodule. Initialize it with
`git submodule update --init --recursive`
(or clone with `--recurse-submodules`), then use `make format` to format all
tracked Scheme sources, including `.sll`, and `make check-format` to check
them. Enable the pre-commit formatting hook with
`git config core.hooksPath project/hooks`. The hook also formats Scheme
code blocks in staged Markdown files.

Then read **`examples/README.md`** — 37 examples in three buckets:
sll scripting (21), the binding layers (10), and AOT objects &
executables (10, including the `.sll` files).

Design documents live in `project/`: the sll grammar and its
rationale (`sll-design.md`, built nanopass-friendly: prefix-only
forms, no mid-form keywords), the coverage methodology and final
standing (`coverage-plan.md`), and the exclusions ledger
(`not-modeled.md`).
