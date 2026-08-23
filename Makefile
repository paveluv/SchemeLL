CHEZ ?= scheme
LIBDIRS = .

.PHONY: test repl build corpus format clean

test:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/run.ss

repl:
	$(CHEZ) --libdirs $(LIBDIRS)

# Level-3 coverage: round-trip LLVM's own test corpus through ll
# (needs reference/llvm-project, see project/RULES.md)
CORPUS_DIR = reference/llvm-project/llvm/test
corpus:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/corpus.ss $(CORPUS_DIR)

# Format all tracked Scheme sources in place (prints the files it changed)
format:
	~/.e/tools/scheme-format -i $$(git ls-files '*.sls' '*.ss')

# Compile libraries to Chez object files (llvm/*.so -- not ELF, gitignored)
build:
	echo '(compile-imported-libraries #t)(import (prefix (llscheme ll) ll:) (prefix (llvm target) target:))' | $(CHEZ) -q --libdirs $(LIBDIRS)

clean:
	find llvm llscheme tests -name '*.so' -delete 2>/dev/null; \
	find llvm llscheme tests -name '*.wpo' -delete 2>/dev/null; \
	rm -rf tests/tmp
