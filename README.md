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

## Installation instructions

SchemeLL needs Chez Scheme 10 and one qualified LLVM release, 19.1.7 (the
default), 20.1.8, or 16.0.6, installed as a shared library with the C API.
Nothing else: no C compiler, no Python. The library is located automatically
in the layouts below; anything else is pointed at explicitly. LLVM 16 is the
release to pick when the bitcode must be read by a consumer that predates
opaque pointers (Apple's Metal compiler): it is the last one that can write
typed pointers. Everything else works alike on all three; the C API that
arrived after 16 is refused by capability name there
(see [capabilities](project/llvm-versions.md)).

**Debian / Ubuntu**

```
apt install chezscheme llvm-19-dev      # or llvm-20-dev, or both
```

`llvm-N-dev` installs `/usr/lib/llvm-N/lib/libLLVM-N.so` plus the headers the
coverage oracle checks, and `/usr/lib/llvm-N` is searched first. Debian's
Chez binary is `scheme` (`chez-scheme` on some releases; the Makefile tries
both). `llvm-16-dev` comes from [apt.llvm.org](https://apt.llvm.org) on
current releases.

**macOS (Homebrew)**

```
brew install chezscheme llvm@19         # or llvm@20 / llvm@16, or all three
```

Apple's own toolchain (Xcode, Command Line Tools) ships no LLVM C API
library, so Homebrew's keg-only `llvm@N` is the source of LLVM. Its
`/opt/homebrew/opt/llvm@N/lib/libLLVM-N.dylib` (Apple Silicon;
`/usr/local/opt/llvm@N` on Intel) is found without any configuration: no
`PATH`, `LDFLAGS` or `DYLD_*` changes. Homebrew's Chez binary is `chez`, which
the Makefile finds. MacPorts' `/opt/local/libexec/llvm-N` is searched too.

**FreeBSD**

```
pkg install chez-scheme llvm19          # or llvm20
```

The port installs under `/usr/local/llvm19`, which is searched. The Chez
binary is `chez-scheme`.

**Any other layout**

Point SchemeLL at the installation explicitly, either from Scheme before
importing the bindings, through the pure
[selection API](project/llvm-versions.md):

```scheme
(import (prefix (llvm selection) llvm:))
[llvm:select!
 [llvm:make-selection
  '[(major-version . 20            )
    (prefix        . "/opt/llvm-20")]]]
```

or, for the hosted commands (`make test`, the tools and the examples), through
`SCHEMELL_LLVM_VERSION=20` and `SCHEMELL_LLVM_PREFIX=/opt/llvm-20`; an explicit
Scheme selection takes precedence over the environment. A prefix holds
`lib/libLLVM-N.<so|dylib|dll>` (or `lib/libLLVM.<suffix>`) and, for the
coverage tests, `include/`; a `shared-object` entry names the library file
directly. SchemeLL reads the loaded library's version with `LLVMGetVersion`
and refuses any other release.

**Submodules.** Schematter, the formatter, is pinned as a submodule: run
`git submodule update --init --recursive`, or clone with
`--recurse-submodules`. `make CHEZ=...` overrides the Chez binary.

## Getting started

```
$ make build       # compile the libraries to .so (later runs start ~5x faster)
$ make test        # selected-version suite (LLVM 19)
$ SCHEMELL_LLVM_VERSION=20 make test
$ SCHEMELL_LLVM_VERSION=16 make test
$ make test-version-cache  # needs all three releases installed
$ make examples    # smoke-runs 38 Scheme scripts and the CLI checks
$ make reference   # (optional) fetch LLVM's test corpus for `make corpus`
$ scheme --libdirs . --script examples/sll/01-add.ss
2 + 40 = 42
```

`make format` formats all tracked Scheme sources with Schematter, including
`.sll`, and `make check-format` checks them. Enable the pre-commit formatting
hook with
`git config core.hooksPath project/hooks`. The hook also formats Scheme
code blocks in staged Markdown files.

Then read **`examples/README.md`** — 38 standalone Scheme scripts in three
buckets: sll scripting (21), the binding layers (10), and AOT objects &
executables (7), plus the AOT `.sll` input files.

Design documents live in `project/`: the sll grammar and its
rationale (`sll-design.md`, built nanopass-friendly: prefix-only
forms, no mid-form keywords), the coverage methodology and final
standing (`coverage-plan.md`), and the exclusions ledger
(`not-modeled.md`).

## Tested platforms

Dated rows record SchemeLL test runs; add a row when you verify another
environment. The Linux row was rerun at `c7ed835` and links to its exact
commands, environment records and logs. The *inferred* FreeBSD row retains
earlier status notes and is not a newly recorded run; replace it when the
suite is run there again. Counts in historical rows retain their reported
scope.

| Date | OS | CPU | Chez | LLVM | Result |
|---|---|---|---|---|---|
| 2026-09-12 | macOS 15.7.9 (Darwin 24.6), arm64 | Apple M3 Pro | 10.4.1 (Homebrew, `chez`) | 16.0.6, 19.1.7, 20.1.8 (Homebrew `llvm@16`, `llvm@19`, `llvm@20`) | 301/301 checks on 16, 332/332 on 19, 342/342 on 20; 37 examples on each (`--exe` skipped; four skip on 16 by capability); version cache 20/19/16/20 |
| [2026-09-12](project/validation/2026-09-12-linux/README.md) | Debian GNU/Linux 13.6 (trixie), Linux `6.12.101+deb13-amd64`, x86_64 | AMD Ryzen Threadripper PRO 9965WX 24-Cores | 10.0.0 (`scheme`, `ta6le`; Debian `10.0.0+dfsg-5`) | 19.1.7, 20.1.8 (`/usr/lib/llvm-19`, `/usr/lib/llvm-20`) | 324/324 checks on 19, 334/334 on 20, plus 14 selection checks each; repeated with compiled libraries; 38 Scheme examples and both CLI checks on each release, including executing the 194-byte `--exe`; version cache 20/19/20 |
| inferred | FreeBSD, x86_64 | ? | ? (`chez-scheme`) | 19.1.7 | suite and `--exe` executables (ELFOSABI_FREEBSD branding) |

Notes:

- `--exe` writes x86-64 ELF executables for the Linux and FreeBSD process
  ABIs only; `make examples` skips that step on other hosts. Objects,
  assembly and the JIT are exercised by the recorded Linux and macOS runs;
  this table does not qualify untested hosts.
- The Linux run used GNU Make 4.4.1, native target `X86`, object format
  `elf`, and LLVM triple `x86_64-pc-linux-gnu`. Both selected libraries and
  their C headers reported the exact releases above. Full Debian package
  versions, library paths and raw results are in the linked validation record.
  This run did not repeat the LLVM regression-corpus campaign.
- On Apple Silicon `LLVMGetHostCPUFeatures` returns an empty string (the CPU
  name carries the features), Mach-O section names are spelled
  `segment,section`, the stack-map section is
  `__LLVM_STACKMAPS,__llvm_stackmaps`, and the JIT's stack-map keeper needs
  LLVM's `\01` no-mangle spelling of `__LLVM_StackMaps`. The library and its
  tests handle all of these; see `project/HANDOFF.md`.
- The recorded macOS environment uses GNU Make 3.81, which lacks `!=`
  assignment but supports `$(shell ...)`. The latter is GNU-specific, so
  the Makefile detects Chez in the recipe shell to also accommodate BSD make.
