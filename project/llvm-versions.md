# Selecting and qualifying LLVM

The qualified releases are 16.0.6, 19.1.7 and 20.1.8. Which one a process
uses is decided once, before the bindings load, by `(llvm selection)`, a
pure library: no environment, no filesystem, no FFI. Three ways to decide,
in order of precedence:

1. **Pin a release**: `select!` with an explicit `major-version`.
2. **State requirements**: `require!` names capabilities the program needs
   (`typed-pointers`, `operand-bundles`, ...); the release is the first
   installed one, in preference order, that has them all.
3. **Nothing**: the first installed release in preference order, which is
   19, then 20, then 16 (16 exists for typed-pointer bitcode).

`prefer!` is the soft form of `require!`: candidates that have the preferred
capabilities come first, but none is excluded, so a program can lean toward
a release (SchemeGPU prefers `typed-pointers` on a Mac with a GPU) and still
run when it is not installed.

Installation is the one fact the selection library cannot know. When
`(llvm config)` loads it calls `resolve!` with a probe of the host, and
that seals the selection for the process, compiled Chez libraries
included. Use fresh processes to compare releases.

```scheme
(import (prefix (llvm selection) llvm:))
(llvm:require! 'typed-pointers)          ; or: (llvm:select! (llvm:make-selection '((major-version . 20))))
(import (prefix (llvm config) config:))
(config:version)                         ; => (16 0 6)
```

Execute these as separate top-level forms, so the decision precedes the
import that loads the bindings. `make-selection` accepts a strict alist;
unknown and duplicate keys, unsupported majors, and invalid path values are
errors. The record and its strings cannot be mutated through this API.
`selected?` and `sealed?` expose the states; `selection-ref` reads a value;
`requirements` and `candidates` show what was asked for and which majors
could satisfy it. Reinstalling an equal selection is harmless; replacing a
sealed installation is refused, and so is a pin or a later requirement the
sealed release cannot satisfy. An unsatisfiable set fails with the
requirements, the candidates and the releases found on the host.

| Key | Default | Meaning |
| --- | --- | --- |
| `major-version` | `#f` (resolve) | a qualified major: 16, 19 or 20 |
| `prefix` | `#f` | optional installation directory |
| `shared-object` | `#f` | optional exact library path/name (needs an explicit major) |
| `header-directory` | `#f` | optional directory containing `Core.h` |
| `version-header` | `#f` | optional exact `llvm-config.h` path |

Path overrides accept `#f` or a nonempty string. Explicit `shared-object`
selection skips installation-directory discovery; `(llvm config)` still
supplies the hosted loader and checks library identity.

**Hosted commands** (`make test`, the tools and the examples) take the
release on their command line, which `(llvm host-command-line)` parses
when a script installs it (`host/bootstrap.ss`, the first form of every
hosted script): `--llvm N`, `--llvm-prefix DIR`, and `--chez PATH` for
scripts that spawn child processes. An explicit Scheme selection wins over
the command line. Nothing in either library reads the environment; a
release is visible in the source that required it or in the command that
ran.

```sh
make test                       # the first installed of 19, 20, 16
make test-llvm20                # LLVMFLAGS="--llvm 20"
make test LLVMFLAGS="--llvm-prefix /opt/llvm-20 --llvm 20"
make test-version-cache
```

The optional `prefix` points to an installation with `lib/`
and `include/`. Otherwise SchemeLL looks in `/usr/lib/llvm-N` and
`/usr/local/llvmN` (Debian packages, manual builds), then in Homebrew's
keg-only `/opt/homebrew/opt/llvm@N` (Apple Silicon) and
`/usr/local/opt/llvm@N` (Intel Mac), then MacPorts' `/opt/local/libexec/llvm-N`;
a release counts as installed when one of those directories holds its
library (`config:installed-releases` lists them). The library suffix follows
the host: `.so` on ELF systems, `.dylib` on macOS, `.dll` on Windows
(`config:shared-object-suffix`). Within a directory it prefers
`libLLVM-N.<suffix>`, with `libLLVM.<suffix>` as a fallback; under an
explicit prefix only the versioned name identifies a release. It calls
`LLVMGetVersion` before binding the rest of the C API and refuses a different
major or patch release. It also refuses LLVM loaded outside SchemeLL, because
Chez resolves foreign entries across the process. A failed load requires a
fresh process; it cannot be retried against a different library.

`(llvm config)` exposes `version`, `major-version`, `installed-releases`,
`installation-directory`, `shared-object`, `header-directory`,
`validate-headers!`, `capability?`, and `require-capability!`. Headers are
needed by the coverage oracle, which checks their version against the
loaded library; deployment does not require headers. Capabilities describe
C API/IR differences, not Woof's runtime protocols; their table lives in
`(llvm selection)` (`capability-of`) so requirements resolve before loading.

## Capabilities

`config:capability?` names what the selected release's C API and IR can do;
the raw bindings, the IR layer, unbuild and the tests consult these names,
never version numbers, and `selection:require!` resolves a release from them. `config:require-capability!` raises
`feature unavailable in selected LLVM version` with the name and the major.

| Capability | 16 | 19 | 20 | Meaning |
| --- | --- | --- | --- | --- |
| `typed-pointers` | yes | – | – | `ir:context-use-typed-pointers!` switches a fresh context to typed pointers (`LLVMContextSetOpaquePointers`); its bitcode is readable by consumers that predate opaque pointers |
| `array-length-64` | – | yes | yes | `LLVMArrayType2` and friends; 16 reads full lengths from the printer and refuses native construction above 2^32−1 |
| `target-ext-types` | – | yes | yes | target extension type inspection; construction exists on 16 |
| `atomic-uinc-wrap` | – | yes | yes | C API for atomicrmw `uinc_wrap`/`udec_wrap`; 16 can parse and print them, and SchemeLL reads their opcodes safely |
| `value-as-metadata-inspection` | – | yes | yes | `LLVMIsAValueAsMetadata`; 16 uses `LLVMGetMetadataKind` on the wrapped metadata |
| `flag-accessors` | – | yes | yes | nsw/nuw/exact/nneg/disjoint and fast-math setters and getters; before 18 sll refuses these flags when building and reads them back from the printer |
| `tail-call-kinds` | – | yes | yes | `musttail`/`notail`; 16 has only the `tail` boolean and reads the others from the printer |
| `operand-bundles` | – | yes | yes | building and reading operand bundles; 16 refuses calls that carry them |
| `inline-asm-inspection` | – | yes | yes | reading inline-asm callees back (unbuild); building them works everywhere |
| `prefix-data-inspection` | – | yes | yes | `LLVMHasPrefixData`; 16 reads the printed header |
| `sized-string-constants` | – | yes | yes | `LLVMConstStringInContext2`; 16 uses the unsigned predecessor |
| `overloaded-va-intrinsics` | – | yes | yes | `llvm.va_start.p0` spelling; 16 knows `llvm.va_start` |
| `callbr` | – | yes | yes | `LLVMBuildCallBr` |
| `fence-ordering-accessor` | – | yes | yes | correct `LLVMGetOrdering` for fences; 16 reads the ordering before metadata in the printed instruction |
| `gep-no-wrap-flags` | – | yes | yes | `getelementptr nusw`/`nuw`; `inbounds` builds everywhere |
| `blockaddress-inspection` | – | yes | yes | reading `blockaddress` constants back |
| `fence-ordering-accessor` | – | yes | yes | `LLVMGetOrdering` reads fences; 16 misreads them (probed) and reads the printer instead |
| `x86-mmx` | yes | yes | – | the MMX type |
| `atomic-usub` | – | – | yes | atomicrmw `usub_cond`/`usub_sat` |
| `jit-layout-bridge` | – | – | yes | LLJIT non-integral layout admission |
| `icmp-samesign-text` | – | – | yes | `icmp samesign` detection in unbuild |

Every optional C entry is listed with its capability in `llvm/raw.sls`
(`optional-entries`); `make test` checks that each is present in the loaded
library exactly when its capability is on.

## LLVM 16 differences

- Typed pointers are available (see `typed-pointers`); contexts default to
  opaque pointers as on 19 and 20. sll spells a typed pointer as
  `(ptr T (addrspace N))`: it builds everywhere (opaque contexts ignore
  `T`), unbuild returns it from typed contexts, and `(sll render)` prints
  `T addrspace(N)*` only under `render:typed-pointers?`.
- Module-level metadata is built through `ir:add-named-metadata!` with
  `ir:md-node`, `ir:md-string` and `ir:value-as-metadata`; module flags are
  the named metadata `llvm.module.flags` (the C API's own flag adder cannot
  express the Max/Min behaviors that Metal AIR uses).
- The 18/19 C API listed above is absent. sll builds `inbounds`, `tail`
  and `volatile` as before; other instruction flags, `musttail`/`notail`,
  operand bundles and `callbr` are refused by capability name rather than
  silently dropped. unbuild reads flags and tail kinds from LLVM's printer
  (`(llvm text-flags)`), and refuses inline-asm callees, blockaddress
  constants and bundles it cannot inspect as not-modeled.
- The coverage corpus is one text for all releases: entries whose golden IR
  needs a missing capability are skipped by name, and the exclusions ledger
  carries `(unless CAP)` entries (callbr) so level 1 still balances.
- Fallback text inspection tokenizes LLVM syntax, including quoted names,
  attribute comments and metadata. It detects prefix/prologue data and
  attributed operand bundles without silently dropping them. Both old and new
  `inrange` GEP annotations are explicitly refused as not modeled.
- LLVM 16's array-length getter truncates lengths above 2^32−1. SchemeLL reads
  the complete length from the type's printed form and refuses oversized
  native array construction by capability name. The text renderer preserves
  such arrays and can be used with `ir:parse-ir`.
- Scalable splats render as equivalent `insertelement`/`shufflevector`
  constant expressions, accepted by all three releases. LLVM 16 predates the
  short `splat (type value)` spelling.
- `llvm.va_start`/`llvm.va_end` are not overloaded (`overloaded-va-intrinsics`).
- The `memory(...)` function attribute exists in 16 but its bitcode encoding
  differs from later releases; producers targeting older bitcode readers
  (Metal AIR) must not emit it.

## LLVM 20 differences

- The MMX type was removed. `ir:x86mmx-type` and the raw entry refuse it on
  20; LLVM 19 behavior is unchanged. Enum slot 15 stays reserved on 20.
- Atomic `usub_cond` and `usub_sat` are available on 20 and refused on 19.
  Coverage uses the selected version's headers as its oracle.
- Fast-math flags on floating-point casts survive unbuilding and rebuilding.
  The C API decides whether each instruction supports these flags.
- `icmp samesign` has no C API getter/setter on 20. The strict walker detects
  its printed opcode prefix and raises a named error. A quoted SSA name cannot
  impersonate a flag. This is an explicit limit, not loss of a poison contract.
- Alias rendering carries address space on the aliasee pointer, as required
  by LLVM syntax. It no longer emits an invalid address-space modifier before
  the `alias` keyword. This repair also applies to 19.

## LLJIT and non-integral pointer layouts

LLVM 20 includes non-integral pointer properties in data-layout equality.
LLJIT checks the incoming layout against its own, but its C API exposes no
layout setter. An otherwise matching module adding `ni:1` therefore fails
admission. LLVM 19's equality did not compare that property.

`(llvm jit-layout)` uses LLJIT's documented IR transform hook to preserve the
layout. Before admission, it verifies that only extra non-integral spaces
differ, records the exact layout in a reserved module flag, and temporarily
uses LLJIT's layout. Its callback restores the original immediately before
the IR compile layer. The flag survives ORC context cloning. No optimization
or code generation may run with the temporary admission layout. The optional
`restoration-observer` receives the restored string for verification; if it
raises, materialization fails with an LLVM error.

The callbacks return errors through `LLVMErrorRef`, never unwind through C++.
Exception formatting is guarded too; a non-condition Scheme exception gets
a constant fallback message and follows the same LLVM error path.
They stay locked until the owning JIT is disposed, including when a module
was added without ever being materialized. This adapter uses the default
LLJIT execution setup; it adds no concurrent-compilation API.

The ordinary target-machine object-emission C API overwrites a module's
layout in both releases. It is therefore not an alternative for preserving
non-integral properties through JIT code generation. Woof's existing AOT path
still uses that C API after its GC passes; its code-generation behavior remains
a validation boundary. See Woof's [runtime qualification](../../project/llvm-versions.md).

## Reproducible qualification

`make test` audits all bound C entry names, exercises removal and refusal
cases, checks header identity, and verifies layout restoration and its error
path. `make test` also checks the pure selection API without loading LLVM.
`make test-version-cache` compiles selection/config/raw once under 19 in an
isolated test directory, then runs them under 20/19/16/20 without rebuilding.

The [Debian LLVM 16 qualification](validation/2026-09-12-linux-llvm16/README.md)
includes 25 compatibility regression checks and all 31,622 files in the
unmodified LLVM 16.0.6 corpus. Its gate passes with zero unexplained failures:
21,538 strict C API round trips, 7,324 strict text-renderer round trips and
2 builder-folding fixed points; 596 parser rejections and 2,162 documented
not-modeled cases remain explicit. For missing construction APIs, the harness
uses the text-renderer tier only when the original canonical IR matches
exactly; a renderer failure is still a failed gate.

Run `make corpus CORPUS_DIR=...` against each release's unmodified `llvm/test`
directory in a separate process with that release selected. Corpus comparisons
are within a version. Missing/empty inputs, unexplained mismatches, and failed
rendering are failed gates. Every run replaces its failure/bucket ledgers,
including a successful run with no failures. Use `make corpus-case
CORPUS_FILE=...` to retain a single case's before/after/rendered IR under
`tests/tmp/corpus-case/`.

The 20.1.8 source can be reproduced with:

```sh
git clone --depth 1 --branch llvmorg-20.1.8 https://github.com/llvm/llvm-project.git LLVM20
```

The primary signature references are the matching installed `llvm-c` headers.
The data-layout comparison and layer ordering were checked in each release's
`llvm/lib/IR/DataLayout.cpp`, `llvm/lib/ExecutionEngine/Orc/LLJIT.cpp`,
`IRTransformLayer.cpp`, `CompileUtils.cpp`, and `llvm/lib/Target/TargetMachineC.cpp`.
