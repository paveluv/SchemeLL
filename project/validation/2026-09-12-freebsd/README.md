# FreeBSD amd64 qualification, 2026-09-12

Tested over `ssh freebsd01` in `~/git/SchemeLL`, starting from clean commit
`410717302dfb9bc4fc9e3cbe9eaa3ba13953d0af`. Source and compiled suites pass
on all three pinned LLVM releases. The example run exposed two Makefile
portability bugs, fixed and rechecked below. No LLVM binding changes were needed.

## Environment

- FreeBSD 15.0-RELEASE kernel and userland, amd64, build
  `releng/15.0-n280995-7aedc8de6446`, GENERIC.
- Reported CPU: AMD EPYC 9374F 32-Core Processor; 4 exposed CPUs and
  8,540,770,304 bytes of physical memory.
- Chez Scheme 10.4.0 (`chez-scheme`, `ta6fb`), package `chez-scheme-10.4.0`.
- System BSD make, `MAKE_VERSION=20250804`; no GNU make installed.
- LLVM packages: `llvm16-16.0.6_14`, `llvm19-19.1.7_4`, `llvm20-20.1.8_3`.
  The selected libraries report exactly 16.0.6, 19.1.7 and 20.1.8.
- Prefixes `/usr/local/llvm16`, `/usr/local/llvm19`, `/usr/local/llvm20`;
  libraries `lib/libLLVM-N.so`, C headers `include/llvm-c`. Header identity
  validation passes for each release.
- Triple `x86_64-portbld-freebsd15.0`, native target `X86`, object format ELF,
  LLVM host CPU `znver4` on every release.
- Initialized the pinned Schematter submodule at
  `317895e523ff333f4753075ed4c843198f4d1c64`.

Raw observations are retained in the adjacent `.txt` and `.sexp` files.

## Findings and fixes

1. BSD make stops the factorial recipe when `sllc --run` returns the expected
   exit status 120, before the following `test $? -eq 120` executes. Capture
   the status in an `||` branch, then explicitly require 120. The original
   failure is retained in `examples-before-llvm16.log`.
2. FreeBSD's `uname -m` returns `amd64`. The executable gate recognized only
   `x86_64`, so the ELF check was skipped after fixing the first problem.
   Accept both architecture spellings. `examples-before-amd64.log` retains
   that skipped result; every final example log contains an actual 194-byte
   executable build and its `Hello, SchemeLL!` output.
3. The retained Debian review probes hard-coded `/usr/lib/llvm-N/bin/llvm-dis`.
   They now use the selected LLVM installation's `bin/llvm-dis`, with shell
   quoting, so the same probes run on FreeBSD and Linux.

The final logs cover the starting commit plus those Makefile and probe edits.
The source suites ran before these tooling fixes; the compiled suites and
focused probes ran after the factorial and probe-path fixes. All example sets
were repeated after both Makefile fixes. The same example sets and probes also
pass on the Debian development machine; the final architecture-gate adjustment
was rechecked there with LLVM 16.

## Commands and outcomes

Commands ran from the checkout in fresh environments, using system `make`
and its automatic detection of `chez-scheme`:

```sh
env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C SCHEMELL_LLVM_VERSION=16 make test
env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C SCHEMELL_LLVM_VERSION=16 make examples
```

Repeat with 19 and 20. Existing compiled library objects were backed up to
`/tmp/schemell-freebsd-validation-20260912` and removed before the source runs.
The examples build the libraries; `make test` was then repeated using them.

| Check | LLVM 16 / 19 / 20 | Logs |
|---|---|---|
| Source suites | 332 / 362 / 372 passed; zero failed; 15 selection checks each | `test-source-llvm*.log` |
| Compiled-library suites | Same counts; all pass | `test-compiled-llvm*.log` |
| `make examples` | 38 scripts invoked per release; four explicit capability skips on 16 | `examples-llvm*.log` |
| CLI factorial and standalone ELF | Exit 120; 194-byte FreeBSD executable prints `Hello, SchemeLL!` on each release | `examples-llvm*.log` |
| `make test-version-cache` | Bindings compiled under 19; fresh 20/19/16/20 processes each return 42 | `version-cache.log` |
| Focused compatibility review | 9 / 8 / 8 passed; zero failed | `review-llvm*.log` |
| Pointer/metadata bitcode integration | 5 passed on each release; zero failed | `integration-llvm*.log` |
| `make check-format` | Pass | `check-format.log` |

The four LLVM 16 example skips are `sll/09-floats.ss`, `sll/11-casts.ss`,
`sll/20-unbuild.ss` and `aot/01-emit-object.ss`, reflecting documented missing
C API capabilities. The ELF executable check is not skipped.

The focused scripts are `../2026-09-12-linux-llvm16/review.ss` and
`../2026-09-12-linux-llvm16/rebase-integration.ss`. They verify typed pointer
bitcode with LLVM 16's `llvm-dis -opaque-pointers=0`, exact native and rendered
round trips, named function metadata and Max/Min module flags. LLVM 19 and 20
use opaque pointers.

[run.ss](run.ss) reproduces the remote stages (`matrix`, `review`, `corpus`)
with Chez. It expects the checkout at `~/git/SchemeLL` and retains output under
`/tmp/schemell-freebsd-validation-20260912`. For example:

```sh
ssh freebsd01 chez-scheme --script /home/paveluv/git/SchemeLL/project/validation/2026-09-12-freebsd/run.ss matrix
```

## Matching LLVM 16 corpus

Fetched the unmodified `llvmorg-16.0.6` corpus at
`7cbf1a2591520c2491aa35339f227775f4d3adf6` into `reference/llvm16`, using the
clone and sparse-checkout commands in `project/RULES.md`.

```sh
env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C SCHEMELL_LLVM_VERSION=16 make corpus CORPUS_DIR=reference/llvm16/llvm/test
```

The corpus command exits **0**, with zero unexplained failures, native-access
errors, canonical mismatches or rendering failures. Results match Debian:

| Classification | Files |
|---|---:|
| Strict C API round trips | 21,538 |
| Strict renderer round trips | 7,324 |
| Builder-folding fixed points | 2 |
| Rejected by LLVM's parser | 596 |
| Explicit not-modeled cases | 2,162 |
| Total | 31,622 |

`corpus16-final.log` contains the report, including expected diagnostics from
malformed debug fixtures. The failure ledger is empty; the bucket ledger
records all excluded paths. The runner's empty-file copier was corrected
while retaining that empty ledger; the corpus itself passed on its first run.
Trailing spaces and tabs were trimmed in retained text logs.

LLVM 19/20 full corpora and the Metal runtime were not exercised on this host.
