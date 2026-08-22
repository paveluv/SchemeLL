CHEZ ?= scheme
LIBDIRS = .

.PHONY: test repl build clean

test:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/run.ss

repl:
	$(CHEZ) --libdirs $(LIBDIRS)

# Compile libraries to Chez object files (llvm/*.so -- not ELF, gitignored)
build:
	echo '(compile-imported-libraries #t)(import (llvm jit) (llvm target) (llvm ir))' | $(CHEZ) -q --libdirs $(LIBDIRS)

clean:
	find llvm llscheme tests -name '*.so' -delete 2>/dev/null; \
	find llvm llscheme tests -name '*.wpo' -delete 2>/dev/null; \
	rm -rf tests/tmp
