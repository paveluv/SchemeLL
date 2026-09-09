;;; sllc -- compile a .sll file (an sll program as plain data) using the LLVM C
;;; API directly: no external compiler, assembler, or linker.
;;;
;;;   scheme --libdirs . --script tools/sllc.ss prog.sll            -> prog.o
;;;   scheme --libdirs . --script tools/sllc.ss --asm prog.sll     -> prog.s
;;;   scheme --libdirs . --script tools/sllc.ss --render-llvm-ir prog.sll
;;;     (print the program as textual LLVM IR, via the pure-Scheme
;;;      renderer -- no LLVM machinery involved)
;;;   scheme --libdirs . --script tools/sllc.ss --print-canonical prog.sll
;;;     (print LLVM's own canonical form of the built module, with the
;;;      host target lines and any --opt passes applied)
;;;   scheme --libdirs . --script tools/sllc.ss --opt O2 prog.sll  (optimize)
;;;   scheme --libdirs . --script tools/sllc.ss --run prog.sll     (JIT @main,
;;;                                              exit with its return value)
;;;   scheme --libdirs . --script tools/sllc.ss --exe prog.sll     -> prog
;;;     A static executable, written by sllc itself (a minimal ELF64
;;;     emitter): works for self-contained programs -- an @_start, no
;;;     external symbols, no data relocations (hello-world class).
;;;   -o PATH   set the output path
[import
 (chezscheme)
 (prefix (sll) sll:)
 (prefix (sll render) render:)
 (prefix (llvm ir) ir:)
 (prefix (llvm jit) jit:)
 (prefix (llvm target) target:)]

;; ---- arguments -------------------------------------------------------------

(define args (cdr (command-line)))
(define mode #f)                ; #f = the default, object emission
(define opt-level #f)
(define out-path #f)
(define in-path #f)

[define
 (usage!)
 [printf
  "usage: sllc [--asm|--run|--exe|--render-llvm-ir|--print-canonical] [--opt LEVEL] [-o PATH] prog.sll~%"]
 (exit 2)]

[define
 (die msg . irritants)
 (printf "sllc: ~a~{ ~a~}~%" msg irritants)
 (usage!)]

[define
 (set-mode! m flag)
 (when (and mode (not (eq? mode m))) (die "conflicting modes" flag))
 (set! mode m)]

[define
 (option-value a flag)
 (when (null? (cdr a)) (die "missing value for" flag))
 (cadr a)]

[let
 loop
 ((a args))
 [unless
  (null? a)
  [let
   ((arg (car a)))
   [cond
    ((string=? arg "--asm") (set-mode! 'asm arg) (loop (cdr a)))
    ((string=? arg "--run") (set-mode! 'run arg) (loop (cdr a)))
    ((string=? arg "--exe") (set-mode! 'exe arg) (loop (cdr a)))
    ((string=? arg "--render-llvm-ir") (set-mode! 'render arg) (loop (cdr a)))
    [(string=? arg "--print-canonical")
     (set-mode! 'canonical arg)
     (loop (cdr a))]
    [(string=? arg "--opt")
     (when opt-level (die "duplicate option" arg))
     (set! opt-level (option-value a arg))
     (loop (cddr a))]
    [(string=? arg "-o")
     (when out-path (die "duplicate option" arg))
     (set! out-path (option-value a arg))
     (loop (cddr a))]
    [(and (> (string-length arg) 0) (char=? (string-ref arg 0) #\-))
     (die "unknown option" arg)]
    [else
     (when in-path (die "more than one input file" in-path arg))
     (set! in-path arg)
     (loop (cdr a))]]]]]

(unless in-path (usage!))
(unless mode (set! mode 'object))

[define
 (default-out ext)
 [or
  out-path
  [let*
   [(n (string-length in-path))
    [base
     [if
      (and (> n 4) (string=? (substring in-path (- n 4) n) ".sll"))
      (substring in-path 0 (- n 4))
      in-path]]]
   (string-append base ext)]]]

;; ---- read and build ---------------------------------------------------------

(define prog (sll:load-sll in-path))

(define ctx (ir:make-context))
(define m (sll:build ctx (path-last in-path) prog))
(ir:verify-module m)

;; a (triple "...") item in the program selects the target; without one, the
;; host is the target. The declared triple is honored (cross object/assembly
;; emission), never clobbered by the host's.
[define
 declared-triple
 (let ((item (assq 'triple prog))) (and item (cadr item)))]

[define
 (triple->backend t)
 [let*
  [[arch
    [let
     loop
     ((i 0))
     [cond
      ((= i (string-length t)) t)
      ((char=? (string-ref t i) #\-) (substring t 0 i))
      (else (loop (+ i 1)))]]]]
  [cond
   ((member arch '("x86_64" "i386" "i686")) "X86")
   ((member arch '("aarch64" "arm64")) "AArch64")
   ((member arch '("arm" "armv7" "thumbv7")) "ARM")
   ((member arch '("riscv32" "riscv64")) "RISCV")
   ((member arch '("wasm32" "wasm64")) "WebAssembly")
   (else #f)]]]

;; target setup and optimization run lazily: only the modes that codegen need a
;; backend, so e.g. --render-llvm-ir works for programs declaring triples this
;; libLLVM cannot even target
[define
 get-tm
 [let
  ((tm #f))
  [lambda
   ()
   [unless
    tm
    [set!
     tm
     [if
      declared-triple
      [let
       ((backend (triple->backend declared-triple)))
       [unless
        (and backend (target:initialize-target! backend))
        [error
         'sllc
         "no backend available for the declared triple"
         declared-triple]]
       (target:make-machine declared-triple "generic" "" 'default)]
      (begin (target:initialize-native!) (target:make-machine))]]
    (target:configure-module! m tm)
    [when
     opt-level
     (ir:run-module-passes! m (string-append "default<" opt-level ">"))]]
   tm]]]

;; an output path may never coincide with the input (finding: --exe on an
;; extensionless input silently replaced the source with the binary)
[define
 (checked-out ext)
 [let
  ((path (default-out ext)))
  [when
   (string=? path in-path)
   (die "output path equals the input; pass -o" path)]
  path]]

;; ---- the minimal ELF64 executable emitter ----------------------------------
;; Takes the relocatable object LLVM produced, extracts .text, finds @_start,
;; and lays out a one-segment static executable. Refuses programs that need what
;; a real linker provides (relocations, external symbols, data sections).

(define (bv-u16 bv i) (bytevector-u16-ref bv i (endianness little)))
(define (bv-u32 bv i) (bytevector-u32-ref bv i (endianness little)))
(define (bv-u64 bv i) (bytevector-u64-ref bv i (endianness little)))

[define
 (cstr bv off)
 [let
  loop
  ((i off) (acc '()))
  [let
   ((b (bytevector-u8-ref bv i)))
   [if
    (zero? b)
    (list->string (reverse acc))
    (loop (+ i 1) (cons (integer->char b) acc))]]]]

[define
 (sections obj)
 [let*
  [(shoff (bv-u64 obj #x28))
   (shentsize (bv-u16 obj #x3A))
   (shnum (bv-u16 obj #x3C))
   (shstrndx (bv-u16 obj #x3E))
   (sh (lambda (i field) (+ shoff (* i shentsize) field)))
   (strtab-off (bv-u64 obj (sh shstrndx #x18)))]
  [let
   loop
   ((i 0) (acc '()))
   [if
    (= i shnum)
    (reverse acc)
    [loop
     (+ i 1)
     [cons
      [list
       (cstr obj (+ strtab-off (bv-u32 obj (sh i 0))))
       (bv-u32 obj (sh i 4))    ; type
       (bv-u64 obj (sh i 8))    ; flags
       (bv-u64 obj (sh i #x18)) ; offset
       (bv-u64 obj (sh i #x20)) ; size
       (bv-u32 obj (sh i #x28)) ; link
       (bv-u64 obj (sh i #x30))] ; addralign
      acc]]]]]]

(define (s-name s) (list-ref s 0))
(define (s-type s) (list-ref s 1))
(define (s-flags s) (list-ref s 2))
(define (s-off s) (list-ref s 3))
(define (s-size s) (list-ref s 4))
(define (s-link s) (list-ref s 5))
(define (s-align s) (list-ref s 6))

[define
 (section-named secs name)
 (find (lambda (s) (string=? (s-name s) name)) secs)]

;; --exe writes exactly one binary format: ELF64, little-endian, x86-64, Linux
;; process ABI. Refuse anything else -- both hosts that cannot run such a binary
;; and objects that are not in that format.
[define
 exe-osabi                      ; e_ident[EI_OSABI] for the host, #f =
                                ; unsupported
 [case
  (machine-type)
  ((a6le ta6le) 0)              ; Linux accepts SYSV branding
  ((a6fb ta6fb) 9)              ; FreeBSD requires ELFOSABI_FREEBSD
  (else #f)]]

[define
 host-os
 [case
  (machine-type)
  ((a6le ta6le) "linux")
  ((a6fb ta6fb) "freebsd")
  (else #f)]]

[define
 (check-exe-supported! obj)
 [unless
  exe-osabi
  [error
   'sllc
   "--exe produces x86-64 ELF executables (Linux or FreeBSD); this host cannot run them -- use --run, or emit a .o for the system toolchain"
   (machine-type)]]
 ;; a declared cross-OS triple would yield a binary branded for THIS host but
 ;; built against another kernel's ABI
 [when
  (and declared-triple host-os)
  [let
   ((n (string-length declared-triple)) (m (string-length host-os)))
   [unless
    [let
     loop
     ((i 0))
     [cond
      ((> (+ i m) n) #f)
      ((string=? (substring declared-triple i (+ i m)) host-os) #t)
      (else (loop (+ i 1)))]]
    [error
     'sllc
     "--exe runs on this host's kernel; the program declares another OS -- emit a .o instead"
     declared-triple
     host-os]]]]
 [unless
  [and
   (>= (bytevector-length obj) #x40)
   (= (bytevector-u8-ref obj 0) #x7F)
   (= (bytevector-u8-ref obj 1) (char->integer #\E))
   (= (bytevector-u8-ref obj 2) (char->integer #\L))
   (= (bytevector-u8-ref obj 3) (char->integer #\F))
   (= (bytevector-u8-ref obj 4) 2)  ; ELFCLASS64
   (= (bytevector-u8-ref obj 5) 1)] ; little-endian
  [error
   'sllc
   "--exe expects an ELF64 little-endian object; the module targets something else"]]
 [unless
  (= (bv-u16 obj #x12) 62)      ; EM_X86_64
  [error
   'sllc
   "--exe supports only x86-64 objects (e_machine 62); this object's e_machine differs"
   (bv-u16 obj #x12)]]]

[define
 (emit-executable obj path)
 (check-exe-supported! obj)
 [let*
  [(secs (sections obj))
   [text
    [or
     (section-named secs ".text")
     (error 'sllc "no .text section in the object")]]]
  [when
   (section-named secs ".rela.text")
   [error
    'sllc
    "--exe handles only self-contained code (no relocations); use --run, or link the .o with a system linker"]]
  ;; any loadable data (ALLOC + PROGBITS/NOBITS, size > 0) other than .text
  ;; would be silently absent from the executable; refuse by FLAGS, which also
  ;; covers .rodata.cst8-style suffixed names and .bss (NOBITS). .eh_frame
  ;; (X86_64_UNWIND) is droppable: nothing unwinds in a freestanding binary.
  [for-each
   [lambda
    (s)
    [when
     [and
      (not (eq? s text))
      (memv (s-type s) '(1 8))  ; PROGBITS, NOBITS
      (positive? (bitwise-and (s-flags s) 2))               ; SHF_ALLOC
      (> (s-size s) 0)]
     [error
      'sllc
      "--exe handles only code; found a loadable data section"
      (s-name s)]]]
   secs]
  ;; find _start's offset inside .text via the symbol table
  [let*
   [[symtab
     [or
      (find (lambda (s) (= (s-type s) 2)) secs)             ; SYMTAB
      (error 'sllc "no symbol table in the object")]]
    (strtab (list-ref secs (s-link symtab)))
    [text-index
     [let
      loop
      ((ss secs) (i 0))
      (if (eq? (car ss) text) i (loop (cdr ss) (+ i 1)))]]
    [start-off
     [let
      loop
      ((off (s-off symtab)))
      [if
       (>= off (+ (s-off symtab) (s-size symtab)))
       (error 'sllc "--exe requires a @_start function")
       [let
        [(nm (cstr obj (+ (s-off strtab) (bv-u32 obj off))))
         (shndx (bv-u16 obj (+ off 6)))]
        [if
         (and (string=? nm "_start") (= shndx text-index))
         (bv-u64 obj (+ off 8))
         (loop (+ off 24))]]]]]
    [text-bytes
     [let
      ((b (make-bytevector (s-size text))))
      (bytevector-copy! obj (s-off text) b 0 (s-size text))
      b]]
    (base #x400000)
    ;; place .text honoring its alignment requirement (the assembler laid it out
    ;; against a 2^n-aligned base; 0x78 alone is 8 mod 16 and misaligns aligned
    ;; constants/jump tables inside the section)
    (text-align (max 1 (s-align text)))
    [text-off
     [let
      ((h #x78))                ; ehdr (64) + one phdr (56)
      (* (div (+ h text-align -1) text-align) text-align)]]
    (entry (+ base text-off start-off))
    (total (+ text-off (bytevector-length text-bytes)))
    (exe (make-bytevector total 0))]
   ;; ELF header
   (bytevector-copy! (bytevector #x7F 69 76 70) 0 exe 0 4)  ; \x7F E L F
   (bytevector-u8-set! exe 1 (char->integer #\E))
   (bytevector-u8-set! exe 2 (char->integer #\L))
   (bytevector-u8-set! exe 3 (char->integer #\F))
   (bytevector-u8-set! exe 4 2) ; 64-bit
   (bytevector-u8-set! exe 5 1) ; little-endian
   (bytevector-u8-set! exe 6 1) ; version
   (bytevector-u8-set! exe 7 exe-osabi)                     ; OS branding
   (bytevector-u16-set! exe #x10 2 (endianness little))     ; ET_EXEC
   (bytevector-u16-set! exe #x12 62 (endianness little))    ; EM_X86_64
   (bytevector-u32-set! exe #x14 1 (endianness little))
   (bytevector-u64-set! exe #x18 entry (endianness little))
   (bytevector-u64-set! exe #x20 #x40 (endianness little))  ; phoff
   (bytevector-u16-set! exe #x34 64 (endianness little))    ; ehsize
   (bytevector-u16-set! exe #x36 56 (endianness little))    ; phentsize
   (bytevector-u16-set! exe #x38 1 (endianness little))     ; phnum
   ;; program header: one RX PT_LOAD covering the whole file
   (bytevector-u32-set! exe #x40 1 (endianness little))     ; PT_LOAD
   (bytevector-u32-set! exe #x44 5 (endianness little))     ; R+X
   (bytevector-u64-set! exe #x48 0 (endianness little))     ; offset
   (bytevector-u64-set! exe #x50 base (endianness little))  ; vaddr
   (bytevector-u64-set! exe #x58 base (endianness little))  ; paddr
   (bytevector-u64-set! exe #x60 total (endianness little)) ; filesz
   (bytevector-u64-set! exe #x68 total (endianness little)) ; memsz
   (bytevector-u64-set! exe #x70 #x1000 (endianness little)) ; align
   (bytevector-copy! text-bytes 0 exe text-off (bytevector-length text-bytes))
   (when (file-exists? path) (delete-file path))
   [call-with-port
    (open-file-output-port path)
    (lambda (p) (put-bytevector p exe))]
   (chmod path #o755)
   (printf "wrote executable ~a (~a bytes, entry #x~x)~%" path total entry)]]]

;; ---- modes
;; -------------------------------------------------------------------

;; text output goes to -o when given, stdout otherwise
[define
 (emit-text text)
 [if
  out-path
  [begin
   [when
    (string=? out-path in-path)
    (die "output path equals the input" out-path)]
   (when (file-exists? out-path) (delete-file out-path))
   (call-with-output-file out-path (lambda (p) (put-string p text)))
   (printf "wrote ~a~%" out-path)]
  (display text)]]

[case
 mode
 [(render)
  ;; sll -> ll in pure Scheme; sll:build above has already validated and
  ;; verified the program. --opt has nothing to act on here.
  [when
   opt-level
   [die
    "--opt has no effect with --render-llvm-ir (it prints the program as written)"]]
  (emit-text (render:sll->ll prog))]
 [(canonical)
  (get-tm)                      ; configure the module (and apply --opt) before
                                ; printing
  (emit-text (ir:module->string m))]
 [(object)
  [let
   ((path (checked-out ".o")))
   (target:emit-object-file (get-tm) m path)
   (printf "wrote ~a~%" path)]]
 [(asm)
  [let
   ((path (checked-out ".s")))
   (target:emit-assembly-file (get-tm) m path)
   (printf "wrote ~a~%" path)]]
 [(run)
  ;; --run executes @main (hosted semantics: exit with its return value; the
  ;; classic (i32 @main (i32 %argc) (ptr %argv)) form is called with argc 0,
  ;; argv NULL) or, when there is none, @_start (freestanding semantics: the
  ;; program exits ITSELF, usually via a raw exit syscall that ends this process
  ;; on the spot -- flush first).
  (when out-path (die "-o has no effect with --run"))
  [let*
   [[fn-params
     [lambda
      (name)
      [exists
       [lambda
        (item)
        [and
         (pair? item)
         (eq? (car item) 'define)
         (exists (lambda (x) (and (pair? x) (eq? (car x) name) (cdr x))) item)]]
       prog]]]
    (main-params (fn-params '@main))
    (start-params (fn-params '@_start))]
   [unless
    (or main-params start-params)
    (die "--run executes @main (or @_start), and this program defines neither")]
   [let*
    [(jc (jit:make-context))
     (m2 (sll:build (jit:context-ir jc) "main" prog))
     (j (jit:make))]
    ;; --opt applies to what actually RUNS
    [when
     opt-level
     (target:initialize-native!)
     (ir:run-module-passes! m2 (string-append "default<" opt-level ">"))]
    (jit:add-module! j jc m2)
    (jit:context-dispose! jc)
    [cond
     [main-params
      [let
       ((main (jit:function j "main")))
       [case
        (length main-params)
        ((0) (exit (main)))
        ((2) (exit (main 0 0))) ; argc 0, argv NULL
        [else
         (die "--run supports @main with no parameters or (argc, argv)")]]]]
     [else
      [let
       ((start (jit:function j "_start")))
       (flush-output-port (current-output-port))
       (start)                  ; normally never returns
       (exit 0)]]]]]]
 [(exe)
  [emit-executable
   (target:emit-object-bytevector (get-tm) m)
   (checked-out "")]]]
