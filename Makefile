CHEZ ?= scheme
LIBDIRS = .

.PHONY: test repl build format clean

test:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/run.ss

repl:
	$(CHEZ) --libdirs $(LIBDIRS)

# Format all tracked Scheme sources in place (prints the files it changed)
format:
	~/.e/tools/scheme-format -i $$(git ls-files '*.sls' '*.ss')

# Compile libraries to Chez object files (llvm/*.so -- not ELF, gitignored)
build:
	echo '(compile-imported-libraries #t)(import (prefix (llvm jit) jit:) (prefix (llvm target) target:) (prefix (llvm ir) ir:))' | $(CHEZ) -q --libdirs $(LIBDIRS)

clean:
	find llvm llscheme tests -name '*.so' -delete 2>/dev/null; \
	find llvm llscheme tests -name '*.wpo' -delete 2>/dev/null; \
	rm -rf tests/tmp
