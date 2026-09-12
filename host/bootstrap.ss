;;; Optional hosted command input: --llvm N, --llvm-prefix DIR and --chez PATH
;;; on the command line. Explicit Scheme selection takes precedence; with
;;; neither, (llvm config) resolves the release from what is installed.
(import (prefix (llvm host-command-line) llvm-host:))
(llvm-host:install!)
