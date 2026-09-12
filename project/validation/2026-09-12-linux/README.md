# Debian x86-64 validation, 2026-09-12

Tested SchemeLL `c7ed835` after a fast-forward pull from `3e4ed49` on
`main`. No rebase was needed. Subsequent changes are documentation and this
evidence record; no binding, lowering or test behavior changed locally.
Schematter remains pinned to `317895e523ff333f4753075ed4c843198f4d1c64`.

## Environment

- Debian GNU/Linux 13.6 (trixie), x86_64.
- Kernel `6.12.101+deb13-amd64`, Debian build `6.12.101-1` (2026-08-05),
  SMP PREEMPT_DYNAMIC.
- AMD Ryzen Threadripper PRO 9965WX 24-Cores.
- Chez Scheme 10.0.0, machine type `ta6le`, executable
  `/usr/bin/chezscheme` via `scheme`; Debian package `10.0.0+dfsg-5`.
- GNU Make 4.4.1.
- LLVM 19.1.7: `/usr/lib/llvm-19/lib/libLLVM-19.so`, C headers under
  `/usr/lib/llvm-19/include/llvm-c`.
- LLVM 20.1.8: `/usr/lib/llvm-20/lib/libLLVM-20.so`, C headers under
  `/usr/lib/llvm-20/include/llvm-c`.
- Both LLVM releases report `x86_64-pc-linux-gnu`, native target `X86`,
  ELF object format and LLVM CPU name `znver5`. Header validation passes.

The adjacent `os-release.txt`, `kernel.txt`, `cpu.txt`, `packages.txt`,
`chez-executable.txt`, `make-version.txt` and `llvm{19,20}.sexp` retain the
observed values, including the complete Debian package version strings.
`facts.ss` reproduces the Scheme/LLVM records, selecting the version before
importing consumers:

```sh
scheme --libdirs . --script project/validation/2026-09-12-linux/facts.ss 19
scheme --libdirs . --script project/validation/2026-09-12-linux/facts.ss 20
```

## Commands and outcomes

Run from the SchemeLL root, serially. Each command used a fresh host
environment with `PATH=/usr/local/bin:/usr/bin:/bin` and `LC_ALL=C`;
no installation-prefix override was needed.

| Command | Log | Result |
|---|---|---|
| `SCHEMELL_LLVM_VERSION=19 make test` | `test-llvm19.log` | 14 selection checks; 324 passed, 0 failed |
| `SCHEMELL_LLVM_VERSION=20 make test` | `test-llvm20.log` | 14 selection checks; 334 passed, 0 failed |
| `SCHEMELL_LLVM_VERSION=19 make examples` | `examples-llvm19.log` | 38 standalone Scheme scripts and both CLI checks pass |
| `SCHEMELL_LLVM_VERSION=20 make examples` | `examples-llvm20.log` | Same coverage; all pass |
| `make test-version-cache` | `version-cache.log` | Compile selection/config/raw under 19, reuse under 20/19/20; answer 42 each time |
| `SCHEMELL_LLVM_VERSION=19 make test` after building libraries | `test-compiled-llvm19.log` | 14 selection checks; 324 passed, 0 failed |
| `SCHEMELL_LLVM_VERSION=20 make test` after building libraries | `test-compiled-llvm20.log` | 14 selection checks; 334 passed, 0 failed |
| `make check-format` | `check-format.log` | Passes |

For example, the full first invocation was:

```sh
env -i PATH=/usr/local/bin:/usr/bin:/bin LC_ALL=C SCHEMELL_LLVM_VERSION=19 make test
```

No root library objects existed before the first two suite runs.
`make examples` builds them; the final two suite runs exercise their reuse
with each selected LLVM release. Version-cache objects live separately
under `tests/tmp/version-cache`.

Each example log contains 38 `== examples/...` entries: 21 sll scripts,
10 binding scripts and 7 AOT scripts. The additional CLI checks are
`fact.sll --run` (expected exit 120) and building/executing
`hello-metaprog.sll --exe` (194-byte x86-64 ELF, output `Hello, SchemeLL!`).
The executable step was run on this Linux host, not skipped.

The normal suites cover JIT, object/assembly emission, stack-map lookup,
ownership/refusal paths and the selected C-header oracle. This run does not
claim a new full LLVM-corpus campaign or new FreeBSD/macOS validation.

The GNU Make wording correction is documentation-only: the installed GNU
Make `NEWS` describes `$(shell ...)` in the 3.81 release and introduces
`!=` in 4.0. Recipe behavior is unchanged.

Trailing space/tab padding is trimmed in the retained text logs. Test
outcomes and observations are otherwise preserved.
