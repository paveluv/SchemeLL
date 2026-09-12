# Selecting and qualifying LLVM

`(llvm selection)` selects `16`, `19` (the default) or `20` before importing
the LLVM bindings. The qualified release pins are 16.0.6, 19.1.7 and 20.1.8.
Selection is fixed for the process, including when importing compiled Chez
libraries. Use fresh processes to compare versions.

```scheme
(import (chezscheme) (prefix (llvm selection) llvm:))
(llvm:select! (llvm:make-selection '((major-version . 20))))
(import (prefix (llvm config) config:))
(config:version)
```

Execute these as separate top-level forms, so selection happens before
the bindings load. `make-selection` accepts a strict alist; unknown and
duplicate keys, unsupported majors, and invalid path values are errors.
The record and its strings cannot be mutated through this API. The first
consumer's `setting` seals the selection. `selected?` and `sealed?` expose
those states; `selection-ref` reads a value. Reinstalling an equal selection
is harmless; replacing a sealed installation is refused.

| Key | Default | Meaning |
| --- | --- | --- |
| `major-version` | `19` | qualified major: 16, 19 or 20 |
| `prefix` | `#f` | optional installation directory |
| `shared-object` | `#f` | optional exact library path/name |
| `header-directory` | `#f` | optional directory containing `Core.h` |
| `version-header` | `#f` | optional exact `llvm-config.h` path |

Path overrides accept `#f` or a nonempty string. The selection library does
no I/O, host detection, environment reading, or native loading. Explicit
`shared-object` selection skips conventional installation-directory discovery;
`(llvm config)` still supplies the hosted loader and checks library identity.

Hosted test/tool entry points explicitly install `(llvm host-environment)`.
Its `install!` translates `SCHEMELL_LLVM_VERSION` and `SCHEMELL_LLVM_PREFIX`
only if no Scheme selection exists. Importing the adapter alone reads nothing.
An explicit selection wins over inherited environment input. Direct library
clients must select in Scheme or explicitly install this compatibility
adapter before importing the bindings. Existing hosted commands remain:

```sh
SCHEMELL_LLVM_VERSION=19 make test
SCHEMELL_LLVM_VERSION=20 make test
make test-version-cache
```

The optional Scheme `prefix` (or hosted `SCHEMELL_LLVM_PREFIX`) points to an installation with `lib/`
and `include/`. Otherwise SchemeLL looks in `/usr/lib/llvm-N` and
`/usr/local/llvmN` (Debian packages, manual builds), then in Homebrew's
keg-only `/opt/homebrew/opt/llvm@N` (Apple Silicon) and
`/usr/local/opt/llvm@N` (Intel Mac), then MacPorts' `/opt/local/libexec/llvm-N`;
with no directory found it uses the versioned system library name. The
library suffix follows the host: `.so` on ELF systems, `.dylib` on macOS,
`.dll` on Windows (`config:shared-object-suffix`). Within a prefix it prefers
`libLLVM-N.<suffix>`, with `libLLVM.<suffix>` as a fallback. It calls
`LLVMGetVersion` before binding the rest of the C API and refuses a different
major or patch release. It also refuses LLVM loaded outside SchemeLL, because
Chez resolves foreign entries across the process. A failed load requires a
fresh process; it cannot be retried against a different library.

`(llvm config)` exposes `version`, `major-version`, `installation-directory`,
`shared-object`, `header-directory`, `validate-headers!`, `capability?`, and
`require-capability!`. Headers are needed by the coverage oracle, which checks
their version against the loaded library; deployment does not require headers.
Capabilities describe C API/IR differences, not Woof's runtime protocols.

## Capabilities

`config:capability?` names what the selected release's C API and IR can do;
the raw bindings, the IR layer, unbuild and the tests consult these names,
never version numbers. `config:require-capability!` raises
`feature unavailable in selected LLVM version` with the name and the major.

| Capability | 16 | 19 | 20 | Meaning |
| --- | --- | --- | --- | --- |
| `typed-pointers` | yes | – | – | `ir:context-use-typed-pointers!` switches a fresh context to typed pointers (`LLVMContextSetOpaquePointers`); its bitcode is readable by consumers that predate opaque pointers |
| `array-length-64` | – | yes | yes | `LLVMArrayType2` and friends; 16 uses the unsigned predecessors |
| `target-ext-types` | – | yes | yes | target extension type accessors |
| `atomic-uinc-wrap` | – | yes | yes | atomicrmw `uinc_wrap`/`udec_wrap` |
| `value-as-metadata-inspection` | – | yes | yes | `LLVMIsAValueAsMetadata`; 16 infers it from the type |
| `flag-accessors` | – | yes | yes | nsw/nuw/exact/nneg/disjoint and fast-math setters and getters; before 18 sll refuses these flags when building and reads them back from the printer |
| `tail-call-kinds` | – | yes | yes | `musttail`/`notail`; 16 has only the `tail` boolean and reads the others from the printer |
| `operand-bundles` | – | yes | yes | building and reading operand bundles; 16 refuses calls that carry them |
| `inline-asm-inspection` | – | yes | yes | reading inline-asm callees back (unbuild); building them works everywhere |
| `prefix-data-inspection` | – | yes | yes | `LLVMHasPrefixData`; 16 reads the printed header |
| `sized-string-constants` | – | yes | yes | `LLVMConstStringInContext2`; 16 uses the unsigned predecessor |
| `overloaded-va-intrinsics` | – | yes | yes | `llvm.va_start.p0` spelling; 16 knows `llvm.va_start` |
| `callbr` | – | yes | yes | `LLVMBuildCallBr` |
| `gep-no-wrap-flags` | – | yes | yes | `getelementptr nusw`/`nuw`; `inbounds` builds everywhere |
| `blockaddress-inspection` | – | yes | yes | reading `blockaddress` constants back |
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
isolated test directory, then runs them under 20/19/20 without rebuilding.

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
