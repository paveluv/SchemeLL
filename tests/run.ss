;;; Test entry point: scheme --libdirs . --script tests/run.ss
(import (chezscheme) (prefix (tests harness) t:))

(load "tests/test-ir.ss")
(load "tests/test-jit.ss")
(load "tests/test-object.ss")
(load "tests/test-ll.ss")

(t:summary-and-exit)
