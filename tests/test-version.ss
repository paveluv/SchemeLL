;;; Exercise selection and refusal in fresh processes, and version-sensitive IR.
[import
 (chezscheme)
 (prefix (tests harness) t:)
 (prefix (llvm config) config:)
 (prefix (llvm ir) ir:)
 (prefix (llvm raw) LLVM)
 (prefix (sll) sll:)
 (prefix (llvm jit) jit:)
 (prefix (llvm jit-layout) layout:)]
(t:section "LLVM installation and capabilities")
[printf
 "  LLVM ~s; ~a; headers ~a\n"
 (config:version)
 config:shared-object
 config:header-directory]
[t:check
 "loaded release and C headers agree"
 (equal? (config:version) (config:validate-headers!))]
[t:check
 "selection is frozen after import"
 [let
  ((old (getenv "SCHEMELL_LLVM_VERSION")) (version (config:version)))
  [dynamic-wind
   (lambda () (putenv "SCHEMELL_LLVM_VERSION" "unsupported"))
   (lambda () (equal? version (config:version)))
   (lambda () (putenv "SCHEMELL_LLVM_VERSION" (or old "19")))]]]
[define
 (version-quote s)
 [string-append
  "'"
  [apply
   string-append
   (map (lambda (c) (if (char=? c #\') "'\\''" (string c))) (string->list s))]
  "'"]]
[define
 (version-contains? s part)
 [let
  loop
  ((i 0))
  [and
   (<= (+ i (string-length part)) (string-length s))
   [or
    (string=? part (substring s i (+ i (string-length part))))
    (loop (+ i 1))]]]]
[define
 (version-child version prefix mode expected)
 [let*
  [(path "tests/tmp/version-child.log")
   [status
    [system
     [format
      "SCHEMELL_LLVM_VERSION=~a SCHEMELL_LLVM_PREFIX=~a ~a --libdirs . --script tests/config-process.ss ~a ~a > ~a 2>&1"
      (version-quote version)
      (version-quote prefix)
      (version-quote (or (getenv "CHEZ") "scheme"))
      mode
      (version-quote config:shared-object)
      (version-quote path)]]]]
  [and
   (not (zero? status))
   (version-contains? (call-with-input-file path get-string-all) expected)]]]
(unless (file-exists? "tests/tmp") (mkdir "tests/tmp"))
[t:check
 "explicit Scheme selection takes precedence over invalid environment input"
 [let*
  [(path "tests/tmp/version-scheme-selection.log")
   [status
    [system
     [format
      "SCHEMELL_LLVM_VERSION=invalid SCHEMELL_LLVM_PREFIX=/invalid ~a --libdirs . --script tests/config-process.ss scheme-~a ignored > ~a 2>&1"
      (version-quote (or (getenv "CHEZ") "scheme"))
      config:major-version
      (version-quote path)]]]]
  [and
   (zero? status)
   [version-contains?
    (call-with-input-file path get-string-all)
    (format "~s" (config:version))]]]]
[t:check
 "unknown major is refused before library loading"
 [version-child
  "21"
  "/does-not-exist"
  "version"
  "unsupported SCHEMELL_LLVM_VERSION"]]
[t:check
 "preloaded LLVM is refused before loading another library"
 [version-child
  (number->string config:major-version)
  config:installation-directory
  "preload"
  "already loaded"]]
[define
 version-fixture
 (string-append (current-directory) "/tests/tmp/llvm-installation")]
[for-each
 [lambda
  (part)
  [let
   ((p (string-append version-fixture part)))
   (unless (file-exists? p) (mkdir p))]]
 '[""
   "/lib"
   "/include"
   "/include/llvm"
   "/include/llvm/Config"
   "/include/llvm-c"]]
[for-each
 [lambda
  (major)
  [let
   [[path
     [format
      "~a/lib/libLLVM-~a.~a"
      version-fixture
      major
      config:shared-object-suffix]]]
   (when (file-exists? path) (delete-file path))
   [unless
    [zero?
     [system
      [format
       "ln -s ~a ~a"
       (version-quote config:shared-object)
       (version-quote path)]]]
    (error 'version-test "cannot create installation fixture")]]]
 '(16 19 20)]
[t:check
 "a library under the wrong major name is refused by LLVMGetVersion"
 [version-child
  (if (= config:major-version 19) "20" "19")
  version-fixture
  "version"
  "mismatched installation"]]
[call-with-output-file
 (string-append version-fixture "/include/llvm/Config/llvm-config.h")
 [lambda
  (p)
  [display
   "#define LLVM_VERSION_MAJOR 99\n#define LLVM_VERSION_MINOR 0\n#define LLVM_VERSION_PATCH 0\n"
   p]]
 'replace]
[t:check
 "headers from another release are refused"
 [version-child
  (number->string config:major-version)
  version-fixture
  "headers"
  "headers do not match"]]

;; Detect removed C entries even when no current test happens to call them.
(define version-entries '())
[define
 (version-walk x)
 [cond
  ((pair? x) (version-walk (car x)) (version-walk (cdr x)))
  [[and
    (string? x)
    (> (string-length x) 4)
    (string=? (substring x 0 4) "LLVM")
    [for-all
     (lambda (c) (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))
     (string->list x)]]
   [unless
    (member x version-entries)
    (set! version-entries (cons x version-entries))]]]]
(define version-raw-source (call-with-input-file "llvm/raw.sls" read))
(version-walk version-raw-source)
;; the optional-entries table from the raw source: ((c-name . capability) ...)
[define
 version-optional
 [let
  find
  ((x version-raw-source))
  [cond
   [[and
     (pair? x)
     (eq? (car x) 'define)
     (pair? (cdr x))
     (eq? (cadr x) 'optional-entries)]
    (cadr (caddr x))]
   ((pair? x) (or (find (car x)) (find (cdr x))))
   (else #f)]]]
[t:check
 "the optional-entries table was found in the raw source"
 (and (list? version-optional) (> (length version-optional) 40))]
[t:check
 "every bound C entry exists, except optional ones whose capability is off"
 [for-all
  [lambda
   (name)
   [let
    ((opt (assoc name version-optional)))
    [if
     (and opt (not (config:capability? (cdr opt))))
     #t
     (foreign-entry? name)]]]
  version-entries]]
[t:check
 "optional entries are absent exactly when their capability is off"
 [for-all
  [lambda
   (entry)
   (eq? (config:capability? (cdr entry)) (foreign-entry? (car entry)))]
  version-optional]]
(define version-ctx (ir:make-context))
[t:check
 "MMX is available on 19 and explicitly refused on 20"
 [if
  (config:capability? 'x86-mmx)
  (eq? 'x86-mmx (ir:type-kind (ir:x86mmx-type version-ctx)))
  [guard
   (e ((and (who-condition? e) (eq? (condition-who e) 'llvm-config)) #t))
   (ir:x86mmx-type version-ctx)
   #f]]]
[unless
 (config:capability? 'atomic-usub)
 [t:check-exn
  "new atomic subtraction refuses LLVM 19 before calling its C builder"
  [sll:build
   version-ctx
   "unsupported"
   '[[define
      i64
      (@f (ptr %p))
      [label
       %entry
       (= %x (atomicrmw usub_sat (ptr %p) (i64 1) monotonic))
       (ret i64 %x)]]]]]]
(ir:context-dispose! version-ctx)

[when
 (config:capability? 'icmp-samesign-text)
 [let*
  [(ctx (ir:make-context))
   [m
    [ir:parse-ir
     ctx
     "same-sign"
     "define i1 @f(i64 %x, i64 %y) { %c = icmp samesign eq i64 %x, %y ret i1 %c }"]]
   [ordinary
    [ir:parse-ir
     ctx
     "quoted-name"
     "define i1 @g(i64 %x, i64 %y) { %\"a = icmp samesign false\" = icmp eq i64 %x, %y ret i1 %\"a = icmp samesign false\" }"]]]
  [t:check
   "unbuild refuses samesign instead of dropping its poison contract"
   [guard
    [e
     [(message-condition? e)
      (version-contains? (condition-message e) "icmp samesign")]]
    (sll:unbuild m)
    #f]]
  [t:check
   "a quoted SSA name cannot impersonate an instruction flag"
   (pair? (sll:unbuild ordinary))]
  (ir:module-dispose! ordinary)
  (ir:module-dispose! m)
  (ir:context-dispose! ctx)]]

(t:section "JIT non-integral layout admission")
(define version-jit (jit:make))
(define version-jc (jit:make-context))
(define version-layout (jit:data-layout version-jit '(1 3)))
(define version-restored '())
[define
 version-module
 [sll:build
  (jit:context-ir version-jc)
  "non-integral"
  `[(datalayout ,version-layout)
    (define i64 (@answer) (label %entry (ret i64 42)))]]]
[parameterize
 [[layout:restoration-observer
   (lambda (s) (set! version-restored (cons s version-restored)))]]
 (jit:add-module! version-jit version-jc version-module)
 [t:check
  "JIT runs a module with additional non-integral spaces"
  (= 42 ((jit:function version-jit "answer")))]]
[t:check
 "20 restores the exact GC layout immediately before code generation"
 [equal?
  version-restored
  (if (config:capability? 'jit-layout-bridge) (list version-layout) '())]]
(jit:dispose! version-jit)
(jit:context-dispose! version-jc)
[when
 (config:capability? 'jit-layout-bridge)
 [let*
  [(j (jit:make))
   (jc (jit:make-context))
   [m
    [sll:build
     (jit:context-ir jc)
     "wrong-layout"
     '[(datalayout "E-p:32:32")
       (define i64 (@wrong) (label %entry (ret i64 0)))]]]]
  [t:check
   "the bridge refuses physical layout differences without consuming the module"
   [and
    [guard
     [e
      [(message-condition? e)
       (version-contains? (condition-message e) "incompatible")]]
     (jit:add-module! j jc m)
     #f]
    (string? (ir:module->string m))]]
  (ir:module-dispose! m)
  (jit:dispose! j)
  (jit:context-dispose! jc)]
 [for-each
  [lambda
   (fail description)
   [let*
    [(j (jit:make))
     (jc (jit:make-context))
     [m
      [sll:build
       (jit:context-ir jc)
       "refuse"
       `[(datalayout ,(jit:data-layout j '(3)))
         (define i64 (@refuse) (label %entry (ret i64 9)))]]]]
    (jit:add-module! j jc m)
    [parameterize
     ((layout:restoration-observer (lambda (s) (fail))))
     [t:check
      description
      [guard
       [e
        [[and
          (condition? e)
          (who-condition? e)
          (eq? (condition-who e) 'jit:lookup-address)]
         #t]]
       (jit:function j "refuse")
       #f]]]
    (jit:dispose! j)
    (jit:context-dispose! jc)]]
  [list
   (lambda () (error 'test "restoration refused"))
   (lambda () (raise 'non-condition-restoration))]
  '["restoration failure returns through LLVM's lookup error"
    "a non-condition callback exception also returns through LLVM's lookup error"]]]

(t:section "typed pointers (LLVM 16) and bitcode output")
[define
 (version-bitcode-magic? bc)
 [and
  (> (bytevector-length bc) 4)
  (= (bytevector-u8-ref bc 0) #x42)
  (= (bytevector-u8-ref bc 1) #x43)
  (= (bytevector-u8-ref bc 2) #xC0)
  (= (bytevector-u8-ref bc 3) #xDE)]]
[let
 ((ctx (ir:make-context)))
 [if
  (config:capability? 'typed-pointers)
  [begin
   (ir:context-use-typed-pointers! ctx)
   [let
    [[m
      [ir:parse-ir
       ctx
       "typed"
       "define float @f(float addrspace(1)* %p) {\nentry:\n  %v = load float, float addrspace(1)* %p, align 4\n  ret float %v\n}"]]]
    [t:check
     "typed-pointer IR parses and prints with element types"
     (version-contains? (ir:module->string m) "float addrspace(1)*")]
    [t:check
     "typed-pointer-type builds an element-typed pointer"
     [version-contains?
      (ir:type->string (ir:typed-pointer-type (ir:float-type ctx) 1))
      "float addrspace(1)*"]]
    [t:check
     "a typed module's bitcode starts with the magic"
     (version-bitcode-magic? (ir:module->bitcode m))]
    (ir:module-dispose! m)]]
  [t:check
   "typed pointers are refused by capability name"
   [guard
    [e
     [(and (who-condition? e) (eq? (condition-who e) 'llvm-config))
      (and (memq 'typed-pointers (condition-irritants e)) #t)]]
    (ir:context-use-typed-pointers! ctx)
    #f]]]
 (ir:context-dispose! ctx)]
[let*
 [(ctx (ir:make-context))
  (m (ir:parse-ir ctx "bc" "define i32 @answer() {\nentry:\n  ret i32 42\n}"))
  (bc (ir:module->bitcode m))]
 (t:check "module->bitcode: BC C0 DE" (version-bitcode-magic? bc))
 [t:check
  "module->bitcode returns a fresh bytevector each time"
  [and
   (equal? bc (ir:module->bitcode m))
   (not (eq? bc (ir:module->bitcode m)))]]
 (ir:module-dispose! m)
 (ir:context-dispose! ctx)]
