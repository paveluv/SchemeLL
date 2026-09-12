# Chez's binary is `scheme` on most systems, `chez` from Homebrew on
# macOS, `chez-scheme` on FreeBSD (and some Linux distros); override
# with `make CHEZ=...`. Detection runs in the recipe shell: neither
# `!=` (GNU make >= 4.0, BSD make) nor `$(shell)` (GNU make only) exists
# in every make, and macOS ships GNU make 3.81, which has neither.
CHEZ ?= $$(for c in scheme chez; do command -v $$c >/dev/null 2>&1 && echo $$c && exit 0; done; echo chez-scheme)
LIBDIRS = .
SCHEME_SOURCES = '*.sls' '*.ss' '*.scm' '*.sps' '*.sll'

# Which LLVM release: nothing selects the first installed of 19, 20, 16;
# LLVMFLAGS="--llvm 20" (or --llvm-prefix DIR) names one for a run. Scripts
# read these from their command line, never from the environment; --chez
# tells scripts that spawn child processes which binary to use.
LLVMFLAGS =
HOSTFLAGS = --chez $(CHEZ) $(LLVMFLAGS)

.PHONY: test test-llvm16 test-llvm19 test-llvm20 test-version-cache repl build corpus corpus-case format check-format clean examples examples-llvm16 examples-llvm19 examples-llvm20 reference

test:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/selection.ss
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/run.ss $(HOSTFLAGS)

test-llvm16:
	@$(MAKE) test LLVMFLAGS="--llvm 16"
test-llvm19:
	@$(MAKE) test LLVMFLAGS="--llvm 19"
test-llvm20:
	@$(MAKE) test LLVMFLAGS="--llvm 20"

repl:
	$(CHEZ) --libdirs $(LIBDIRS)

# Level-3 coverage: round-trip LLVM's own test corpus through sll
# (needs reference/llvm-project, see project/RULES.md)
CORPUS_DIR = reference/llvm-project/llvm/test
corpus:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/corpus.ss $(HOSTFLAGS) $(CORPUS_DIR)

CORPUS_FILE =
corpus-case:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/corpus-case.ss $(HOSTFLAGS) "$(CORPUS_FILE)"

# compile config/raw once, run them under every installed release
test-version-cache:
	$(CHEZ) --script tests/version-cache.ss --chez $(CHEZ)

# Populate reference/ with what the tests need: LLVM's regression
# corpus (for `make corpus`), pinned to the LLVM version the bindings
# target. Idempotent. See project/RULES.md ("The reference/ directory")
# for the full catalogue, including optional extras like llvm/docs.
LLVM_TAG = llvmorg-19.1.7
reference:
	@test -d reference/llvm-project || \
	  git clone --depth 1 --branch $(LLVM_TAG) --filter=blob:none \
	    --sparse https://github.com/llvm/llvm-project.git \
	    reference/llvm-project
	@cd reference/llvm-project && git sparse-checkout add llvm/test
	@echo "reference ready: $$(find reference/llvm-project/llvm/test \
	  -name '*.ll' | wc -l) .ll files"

# depends on build: each example is its own Chez process, and without
# compiled library objects every one of the 37 re-compiles the whole
# stack in memory (~35s total); with them the run takes ~5s.
examples: build
	@for f in examples/sll/*.ss examples/llvm/*.ss examples/aot/*.ss; do \
	  echo "== $$f"; $(CHEZ) --libdirs $(LIBDIRS) --script $$f $(HOSTFLAGS) >/dev/null || exit 1; \
	done
	@sll_exit=0; \
	  $(CHEZ) --libdirs $(LIBDIRS) --script tools/sllc.ss $(HOSTFLAGS) --run examples/aot/fact.sll || sll_exit=$$?; \
	  test $$sll_exit -eq 120 || exit 1
	@if { [ "$$(uname -m)" = x86_64 ] || [ "$$(uname -m)" = amd64 ]; } && \
	  { [ "$$(uname -s)" = Linux ] || [ "$$(uname -s)" = FreeBSD ]; }; then \
	  $(CHEZ) --libdirs $(LIBDIRS) --script tools/sllc.ss $(HOSTFLAGS) --opt O2 --exe examples/aot/hello-metaprog.sll && \
	  ./examples/aot/hello-metaprog && rm -f examples/aot/hello-metaprog; \
	else \
	  echo "== --exe skipped: sllc writes x86-64 ELF executables, which this host cannot run"; \
	fi
	@echo "examples ok"

examples-llvm16:
	@$(MAKE) examples LLVMFLAGS="--llvm 16"
examples-llvm19:
	@$(MAKE) examples LLVMFLAGS="--llvm 19"
examples-llvm20:
	@$(MAKE) examples LLVMFLAGS="--llvm 20"

schematter/schematter.sps:
	@echo "Schematter is missing; run: git submodule update --init --recursive" >&2
	@exit 1

# Format all tracked Scheme sources, including .sll (prints changed paths).
format: schematter/schematter.sps
	git ls-files -z -- $(SCHEME_SOURCES) | \
	  xargs -0 $(CHEZ) --script schematter/schematter.sps -i --

check-format: schematter/schematter.sps
	git ls-files -z -- $(SCHEME_SOURCES) | \
	  xargs -0 $(CHEZ) --script schematter/schematter.sps --check --

# Compile every library to Chez object files (*.so -- Chez objects,
# not ELF; gitignored). Any later run with --libdirs reuses them; the
# ./sllc wrapper also compiles on demand.
build:
	echo '(compile-imported-libraries #t)(import (prefix (sll) sll:) (prefix (sll render) render:) (prefix (sll asm) asm:) (prefix (llvm target) target:) (prefix (tests normalize) n:))' | $(CHEZ) -q --libdirs $(LIBDIRS)

clean:
	find llvm sll tests -name '*.so' -delete 2>/dev/null; \
	find llvm sll tests -name '*.wpo' -delete 2>/dev/null; \
	rm -rf tests/tmp
