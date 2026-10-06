;; json2dir: create the directory tree a JSON document describes, in the current directory.
;; Implements RFC J2D-1. Hand-written WebAssembly text: strict UTF-8 check, JSON parser,
;; tree validation and the file-system walk, all through WASI preview1 (fd 3 = preopened ".").
;; The only non-WASI import is host.make_executable (WASI has no chmod).
(module
  (import "wasi_snapshot_preview1" "args_sizes_get" (func $args_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read" (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_close" (func $fd_close (param i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_create_directory" (func $path_create_directory (param i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_symlink" (func $path_symlink (param i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_unlink_file" (func $path_unlink_file (param i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_filestat_get" (func $path_filestat_get (param i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (import "host" "make_executable" (func $make_executable (param i32 i32) (result i32)))

  (memory (export "memory") 2)

  ;; Memory layout:
  ;;   0  iovec (ptr, len)      8  nread / nwritten     12  fd out
  ;;  16  argc                 20  argv buffer size     64  filestat (64 bytes)
  ;; 256  messages, slot k at 256 + 64*k, NUL-terminated
  ;; 4096 input, then the heap (decoded strings, nodes, path buffer)
  (global $IN i32 (i32.const 4096))
  (global $inlen (mut i32) (i32.const 0))
  (global $heap (mut i32) (i32.const 0))
  (global $pos (mut i32) (i32.const 0))
  (global $end (mut i32) (i32.const 0))
  (global $slen (mut i32) (i32.const 0))
  (global $pb (mut i32) (i32.const 0))

  (data (i32.const 256)  "usage: json2dir < document.json")
  (data (i32.const 320)  "input is not valid UTF-8")
  (data (i32.const 384)  "input is not valid JSON")
  (data (i32.const 448)  "the root of the document must be an object")
  (data (i32.const 512)  "numbers, true, false and null are not allowed")
  (data (i32.const 576)  "an array must be [\"link\", target] or [\"script\", content]")
  (data (i32.const 640)  "unknown array kind")
  (data (i32.const 704)  "invalid name")
  (data (i32.const 768)  "string contains an unpaired surrogate")
  (data (i32.const 832)  "duplicate name")
  (data (i32.const 896)  "a link target cannot contain NUL")
  (data (i32.const 960)  "nesting too deep")
  (data (i32.const 1024) "a directory is in the way")
  (data (i32.const 1088) "cannot read input")
  (data (i32.const 1152) "cannot inspect entry")
  (data (i32.const 1216) "cannot remove entry")
  (data (i32.const 1280) "cannot create directory")
  (data (i32.const 1344) "cannot create file")
  (data (i32.const 1408) "cannot write file")
  (data (i32.const 1472) "cannot create symbolic link")
  (data (i32.const 1536) "cannot make file executable")
  (data (i32.const 1600) "out of memory")
  (data (i32.const 1664) "json2dir: ")
  (data (i32.const 1680) ": ")
  (data (i32.const 1684) "\n")

  ;; ---------------------------------------------------------------- output / errors

  (func $write_all (param $fd i32) (param $p i32) (param $n i32)
    (block $done
      (loop $more
        (br_if $done (i32.le_s (local.get $n) (i32.const 0)))
        (i32.store (i32.const 0) (local.get $p))
        (i32.store (i32.const 4) (local.get $n))
        (br_if $done (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8)))
        (local.set $p (i32.add (local.get $p) (i32.load (i32.const 8))))
        (local.set $n (i32.sub (local.get $n) (i32.load (i32.const 8))))
        (br $more))))

  (func $cstrlen (param $p i32) (result i32)
    (local $n i32)
    (block $done
      (loop $l
        (br_if $done (i32.eqz (i32.load8_u (i32.add (local.get $p) (local.get $n)))))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (br $l)))
    (local.get $n))

  (func $msg (param $k i32) (result i32)
    (i32.add (i32.const 256) (i32.mul (local.get $k) (i32.const 64))))

  ;; "json2dir: <message>\n", exit 1
  (func $fail (param $k i32)
    (call $write_all (i32.const 2) (i32.const 1664) (i32.const 10))
    (call $write_all (i32.const 2) (call $msg (local.get $k)) (call $cstrlen (call $msg (local.get $k))))
    (call $write_all (i32.const 2) (i32.const 1684) (i32.const 1))
    (call $proc_exit (i32.const 1))
    unreachable)

  ;; "json2dir: <path>: <message>\n", exit 1
  (func $fail_at (param $k i32) (param $plen i32)
    (call $write_all (i32.const 2) (i32.const 1664) (i32.const 10))
    (call $write_all (i32.const 2) (i32.add (global.get $pb) (i32.const 2)) (i32.sub (local.get $plen) (i32.const 2)))
    (call $write_all (i32.const 2) (i32.const 1680) (i32.const 2))
    (call $write_all (i32.const 2) (call $msg (local.get $k)) (call $cstrlen (call $msg (local.get $k))))
    (call $write_all (i32.const 2) (i32.const 1684) (i32.const 1))
    (call $proc_exit (i32.const 1))
    unreachable)

  ;; ---------------------------------------------------------------- memory

  ;; make sure [0, limit) is addressable
  (func $ensure (param $limit i32)
    (local $have i32)
    (local.set $have (i32.mul (memory.size) (i32.const 65536)))
    (if (i32.gt_u (local.get $limit) (local.get $have))
      (then
        (if (i32.eq
              (memory.grow (i32.add (i32.shr_u (i32.sub (local.get $limit) (local.get $have)) (i32.const 16))
                                    (i32.const 1)))
              (i32.const -1))
          (then (call $fail (i32.const 21)))))))

  (func $alloc (param $n i32) (result i32)
    (local $p i32)
    (local.set $p (global.get $heap))
    (global.set $heap (i32.and (i32.add (i32.add (local.get $p) (local.get $n)) (i32.const 3)) (i32.const -4)))
    (call $ensure (global.get $heap))
    (local.get $p))

  (func $memeq (param $a i32) (param $b i32) (param $n i32) (result i32)
    (local $i i32)
    (block $no
      (loop $l
        (if (i32.ge_u (local.get $i) (local.get $n)) (then (return (i32.const 1))))
        (br_if $no (i32.ne (i32.load8_u (i32.add (local.get $a) (local.get $i)))
                           (i32.load8_u (i32.add (local.get $b) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (i32.const 0))

  ;; ---------------------------------------------------------------- input

  (func $read_input
    (local $n i32)
    (block $eof
      (loop $more
        (call $ensure (i32.add (i32.add (global.get $IN) (global.get $inlen)) (i32.const 65536)))
        (i32.store (i32.const 0) (i32.add (global.get $IN) (global.get $inlen)))
        (i32.store (i32.const 4) (i32.const 65536))
        (if (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 8))
          (then (call $fail (i32.const 13))))
        (local.set $n (i32.load (i32.const 8)))
        (br_if $eof (i32.eqz (local.get $n)))
        (global.set $inlen (i32.add (global.get $inlen) (local.get $n)))
        (br $more))))

  ;; strict UTF-8 (RFC 3629): no overlongs, no surrogates, nothing above U+10FFFF
  (func $check_utf8 (param $p i32) (param $end i32)
    (local $b i32) (local $lo i32) (local $hi i32) (local $n i32) (local $i i32)
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $p) (local.get $end)))
        (local.set $b (i32.load8_u (local.get $p)))
        (local.set $lo (i32.const 0x80))
        (local.set $hi (i32.const 0xBF))
        (if (i32.lt_u (local.get $b) (i32.const 0x80))
          (then (local.set $n (i32.const 0)))
          (else (if (i32.and (i32.ge_u (local.get $b) (i32.const 0xC2)) (i32.le_u (local.get $b) (i32.const 0xDF)))
            (then (local.set $n (i32.const 1)))
            (else (if (i32.and (i32.ge_u (local.get $b) (i32.const 0xE0)) (i32.le_u (local.get $b) (i32.const 0xEF)))
              (then
                (local.set $n (i32.const 2))
                (if (i32.eq (local.get $b) (i32.const 0xE0)) (then (local.set $lo (i32.const 0xA0))))
                (if (i32.eq (local.get $b) (i32.const 0xED)) (then (local.set $hi (i32.const 0x9F)))))
              (else (if (i32.and (i32.ge_u (local.get $b) (i32.const 0xF0)) (i32.le_u (local.get $b) (i32.const 0xF4)))
                (then
                  (local.set $n (i32.const 3))
                  (if (i32.eq (local.get $b) (i32.const 0xF0)) (then (local.set $lo (i32.const 0x90))))
                  (if (i32.eq (local.get $b) (i32.const 0xF4)) (then (local.set $hi (i32.const 0x8F)))))
                (else (call $fail (i32.const 1))))))))))
        (if (i32.gt_u (i32.add (local.get $p) (local.get $n)) (i32.sub (local.get $end) (i32.const 1)))
          (then (if (local.get $n) (then (call $fail (i32.const 1))))))
        (local.set $p (i32.add (local.get $p) (i32.const 1)))
        (local.set $i (i32.const 0))
        (block $conts
          (loop $c
            (br_if $conts (i32.ge_u (local.get $i) (local.get $n)))
            (local.set $b (i32.load8_u (local.get $p)))
            (if (i32.or (i32.lt_u (local.get $b) (local.get $lo)) (i32.gt_u (local.get $b) (local.get $hi)))
              (then (call $fail (i32.const 1))))
            (local.set $lo (i32.const 0x80))
            (local.set $hi (i32.const 0xBF))
            (local.set $p (i32.add (local.get $p) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $c)))
        (br $next))))

  ;; ---------------------------------------------------------------- JSON parser
  ;; Only objects, strings and two-string arrays mean something; every other value makes
  ;; the document invalid, so the parser rejects it on sight.
  ;; Nodes (12 bytes): type, a, b.  1 = string (ptr, len), 2 = object (first member),
  ;; 3 = link (ptr, len), 4 = script (ptr, len).
  ;; Members (16 bytes): name ptr, name len, value node, next member.

  (func $peek (result i32)
    (if (result i32) (i32.ge_u (global.get $pos) (global.get $end))
      (then (i32.const -1))
      (else (i32.load8_u (global.get $pos)))))

  (func $ws
    (local $c i32)
    (block $done
      (loop $l
        (local.set $c (call $peek))
        (br_if $done (i32.eqz (i32.or (i32.or (i32.eq (local.get $c) (i32.const 0x20)) (i32.eq (local.get $c) (i32.const 0x09)))
                                      (i32.or (i32.eq (local.get $c) (i32.const 0x0A)) (i32.eq (local.get $c) (i32.const 0x0D))))))
        (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
        (br $l))))

  (func $expect (param $c i32)
    (if (i32.ne (call $peek) (local.get $c)) (then (call $fail (i32.const 2))))
    (global.set $pos (i32.add (global.get $pos) (i32.const 1))))

  (func $hex4 (result i32)
    (local $v i32) (local $i i32) (local $c i32)
    (if (i32.gt_u (i32.add (global.get $pos) (i32.const 4)) (global.get $end)) (then (call $fail (i32.const 2))))
    (loop $l
      (local.set $c (i32.load8_u (global.get $pos)))
      (if (i32.and (i32.ge_u (local.get $c) (i32.const 0x30)) (i32.le_u (local.get $c) (i32.const 0x39)))
        (then (local.set $c (i32.sub (local.get $c) (i32.const 0x30))))
        (else (if (i32.and (i32.ge_u (local.get $c) (i32.const 0x61)) (i32.le_u (local.get $c) (i32.const 0x66)))
          (then (local.set $c (i32.sub (local.get $c) (i32.const 87))))
          (else (if (i32.and (i32.ge_u (local.get $c) (i32.const 0x41)) (i32.le_u (local.get $c) (i32.const 0x46)))
            (then (local.set $c (i32.sub (local.get $c) (i32.const 55))))
            (else (call $fail (i32.const 2))))))))
      (local.set $v (i32.or (i32.shl (local.get $v) (i32.const 4)) (local.get $c)))
      (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (i32.const 4))))
    (local.get $v))

  ;; parse a string at $pos (which is at '"'); the decoded bytes go to the heap.
  ;; Returns the pointer, sets $slen. Decoded output is never longer than the input left.
  (func $parse_string (result i32)
    (local $out i32) (local $o i32) (local $c i32) (local $cp i32) (local $lo i32)
    (call $expect (i32.const 0x22))
    (local.set $out (global.get $heap))
    (call $ensure (i32.add (local.get $out) (i32.sub (global.get $end) (global.get $pos))))
    (local.set $o (local.get $out))
    (block $closed
      (loop $l
        (local.set $c (call $peek))
        (if (i32.lt_s (local.get $c) (i32.const 0x20)) (then (call $fail (i32.const 2))))
        (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
        (br_if $closed (i32.eq (local.get $c) (i32.const 0x22)))
        (if (i32.ne (local.get $c) (i32.const 0x5C))
          (then
            (i32.store8 (local.get $o) (local.get $c))
            (local.set $o (i32.add (local.get $o) (i32.const 1)))
            (br $l)))
        ;; escape
        (local.set $c (call $peek))
        (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
        (local.set $cp (i32.const -1))
        (if (i32.eq (local.get $c) (i32.const 0x22)) (then (local.set $cp (i32.const 0x22))))
        (if (i32.eq (local.get $c) (i32.const 0x5C)) (then (local.set $cp (i32.const 0x5C))))
        (if (i32.eq (local.get $c) (i32.const 0x2F)) (then (local.set $cp (i32.const 0x2F))))
        (if (i32.eq (local.get $c) (i32.const 0x62)) (then (local.set $cp (i32.const 0x08))))
        (if (i32.eq (local.get $c) (i32.const 0x66)) (then (local.set $cp (i32.const 0x0C))))
        (if (i32.eq (local.get $c) (i32.const 0x6E)) (then (local.set $cp (i32.const 0x0A))))
        (if (i32.eq (local.get $c) (i32.const 0x72)) (then (local.set $cp (i32.const 0x0D))))
        (if (i32.eq (local.get $c) (i32.const 0x74)) (then (local.set $cp (i32.const 0x09))))
        (if (i32.eq (local.get $c) (i32.const 0x75))
          (then
            (local.set $cp (call $hex4))
            (if (i32.eq (i32.and (local.get $cp) (i32.const 0xFC00)) (i32.const 0xDC00))
              (then (call $fail (i32.const 8))))
            (if (i32.eq (i32.and (local.get $cp) (i32.const 0xFC00)) (i32.const 0xD800))
              (then
                (if (i32.ne (call $peek) (i32.const 0x5C)) (then (call $fail (i32.const 8))))
                (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
                (if (i32.ne (call $peek) (i32.const 0x75)) (then (call $fail (i32.const 8))))
                (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
                (local.set $lo (call $hex4))
                (if (i32.ne (i32.and (local.get $lo) (i32.const 0xFC00)) (i32.const 0xDC00))
                  (then (call $fail (i32.const 8))))
                (local.set $cp (i32.add (i32.const 0x10000)
                  (i32.or (i32.shl (i32.sub (local.get $cp) (i32.const 0xD800)) (i32.const 10))
                          (i32.sub (local.get $lo) (i32.const 0xDC00)))))))))
        (if (i32.lt_s (local.get $cp) (i32.const 0)) (then (call $fail (i32.const 2))))
        ;; UTF-8 encode $cp
        (if (i32.lt_u (local.get $cp) (i32.const 0x80))
          (then
            (i32.store8 (local.get $o) (local.get $cp))
            (local.set $o (i32.add (local.get $o) (i32.const 1))))
          (else (if (i32.lt_u (local.get $cp) (i32.const 0x800))
            (then
              (i32.store8 (local.get $o) (i32.or (i32.const 0xC0) (i32.shr_u (local.get $cp) (i32.const 6))))
              (i32.store8 offset=1 (local.get $o) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
              (local.set $o (i32.add (local.get $o) (i32.const 2))))
            (else (if (i32.lt_u (local.get $cp) (i32.const 0x10000))
              (then
                (i32.store8 (local.get $o) (i32.or (i32.const 0xE0) (i32.shr_u (local.get $cp) (i32.const 12))))
                (i32.store8 offset=1 (local.get $o) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
                (i32.store8 offset=2 (local.get $o) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
                (local.set $o (i32.add (local.get $o) (i32.const 3))))
              (else
                (i32.store8 (local.get $o) (i32.or (i32.const 0xF0) (i32.shr_u (local.get $cp) (i32.const 18))))
                (i32.store8 offset=1 (local.get $o) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 0x3F))))
                (i32.store8 offset=2 (local.get $o) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
                (i32.store8 offset=3 (local.get $o) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
                (local.set $o (i32.add (local.get $o) (i32.const 4)))))))))
        (br $l)))
    (global.set $slen (i32.sub (local.get $o) (local.get $out)))
    (drop (call $alloc (global.get $slen)))
    (local.get $out))

  (func $new_node (param $type i32) (param $a i32) (param $b i32) (result i32)
    (local $n i32)
    (local.set $n (call $alloc (i32.const 12)))
    (i32.store (local.get $n) (local.get $type))
    (i32.store offset=4 (local.get $n) (local.get $a))
    (i32.store offset=8 (local.get $n) (local.get $b))
    (local.get $n))

  ;; RFC 4.2.1: a simple name is non-empty, not "." or "..", without "/" and NUL
  (func $check_name (param $p i32) (param $n i32)
    (local $i i32) (local $c i32)
    (if (i32.eqz (local.get $n)) (then (call $fail (i32.const 7))))
    (if (i32.and (i32.eq (local.get $n) (i32.const 1)) (i32.eq (i32.load8_u (local.get $p)) (i32.const 0x2E)))
      (then (call $fail (i32.const 7))))
    (if (i32.and (i32.eq (local.get $n) (i32.const 2))
                 (i32.eq (i32.load16_u (local.get $p)) (i32.const 0x2E2E)))
      (then (call $fail (i32.const 7))))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $c (i32.load8_u (i32.add (local.get $p) (local.get $i))))
        (if (i32.or (i32.eqz (local.get $c)) (i32.eq (local.get $c) (i32.const 0x2F)))
          (then (call $fail (i32.const 7))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l))))

  (func $parse_array (result i32)
    (local $kp i32) (local $kn i32) (local $pp i32) (local $pn i32) (local $type i32) (local $i i32)
    (call $expect (i32.const 0x5B))
    (call $ws)
    (if (i32.ne (call $peek) (i32.const 0x22)) (then (call $fail (i32.const 5))))
    (local.set $kp (call $parse_string))
    (local.set $kn (global.get $slen))
    (call $ws)
    (if (i32.ne (call $peek) (i32.const 0x2C)) (then (call $fail (i32.const 5))))
    (call $expect (i32.const 0x2C))
    (call $ws)
    (if (i32.ne (call $peek) (i32.const 0x22)) (then (call $fail (i32.const 5))))
    (local.set $pp (call $parse_string))
    (local.set $pn (global.get $slen))
    (call $ws)
    (if (i32.ne (call $peek) (i32.const 0x5D)) (then (call $fail (i32.const 5))))
    (call $expect (i32.const 0x5D))
    ;; kind: "link" or "script", case-sensitive
    (if (i32.and (i32.eq (local.get $kn) (i32.const 4)) (i32.eq (i32.load (local.get $kp)) (i32.const 0x6B6E696C)))
      (then (local.set $type (i32.const 3))))
    (if (i32.and (i32.eq (local.get $kn) (i32.const 6))
                 (i32.and (i32.eq (i32.load (local.get $kp)) (i32.const 0x69726373))
                          (i32.eq (i32.load16_u offset=4 (local.get $kp)) (i32.const 0x7470))))
      (then (local.set $type (i32.const 4))))
    (if (i32.eqz (local.get $type)) (then (call $fail (i32.const 6))))
    ;; a link target with NUL cannot be created
    (if (i32.eq (local.get $type) (i32.const 3))
      (then
        (block $done
          (loop $l
            (br_if $done (i32.ge_u (local.get $i) (local.get $pn)))
            (if (i32.eqz (i32.load8_u (i32.add (local.get $pp) (local.get $i)))) (then (call $fail (i32.const 10))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $l)))))
    (call $new_node (local.get $type) (local.get $pp) (local.get $pn)))

  (func $parse_object (param $depth i32) (result i32)
    (local $first i32) (local $last i32) (local $m i32) (local $np i32) (local $nn i32) (local $v i32) (local $o i32)
    (if (i32.gt_u (local.get $depth) (i32.const 1000)) (then (call $fail (i32.const 11))))
    (call $expect (i32.const 0x7B))
    (call $ws)
    (if (i32.eq (call $peek) (i32.const 0x7D))
      (then
        (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
        (return (call $new_node (i32.const 2) (i32.const 0) (i32.const 0)))))
    (loop $member
      (call $ws)
      (local.set $np (call $parse_string))
      (local.set $nn (global.get $slen))
      (call $check_name (local.get $np) (local.get $nn))
      ;; duplicates are rejected (RFC 4.2 allows that)
      (local.set $o (local.get $first))
      (block $nodup
        (loop $scan
          (br_if $nodup (i32.eqz (local.get $o)))
          (if (i32.eq (i32.load offset=4 (local.get $o)) (local.get $nn))
            (then (if (call $memeq (i32.load (local.get $o)) (local.get $np) (local.get $nn))
              (then (call $fail (i32.const 9))))))
          (local.set $o (i32.load offset=12 (local.get $o)))
          (br $scan)))
      (call $ws)
      (call $expect (i32.const 0x3A))
      (call $ws)
      (local.set $v (call $parse_value (local.get $depth)))
      (local.set $m (call $alloc (i32.const 16)))
      (i32.store (local.get $m) (local.get $np))
      (i32.store offset=4 (local.get $m) (local.get $nn))
      (i32.store offset=8 (local.get $m) (local.get $v))
      (i32.store offset=12 (local.get $m) (i32.const 0))
      (if (local.get $last)
        (then (i32.store offset=12 (local.get $last) (local.get $m)))
        (else (local.set $first (local.get $m))))
      (local.set $last (local.get $m))
      (call $ws)
      (if (i32.eq (call $peek) (i32.const 0x2C))
        (then
          (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
          (br $member))))
    (call $expect (i32.const 0x7D))
    (call $new_node (i32.const 2) (local.get $first) (i32.const 0)))

  (func $parse_value (param $depth i32) (result i32)
    (local $c i32) (local $p i32)
    (local.set $c (call $peek))
    (if (i32.eq (local.get $c) (i32.const 0x7B))
      (then (return (call $parse_object (i32.add (local.get $depth) (i32.const 1))))))
    (if (i32.eq (local.get $c) (i32.const 0x5B))
      (then (return (call $parse_array))))
    (if (i32.eq (local.get $c) (i32.const 0x22))
      (then
        (local.set $p (call $parse_string))
        (return (call $new_node (i32.const 1) (local.get $p) (global.get $slen)))))
    (if (i32.or (i32.or (i32.eq (local.get $c) (i32.const 0x2D))
                        (i32.and (i32.ge_u (local.get $c) (i32.const 0x30)) (i32.le_u (local.get $c) (i32.const 0x39))))
                (i32.or (i32.or (i32.eq (local.get $c) (i32.const 0x74)) (i32.eq (local.get $c) (i32.const 0x66)))
                        (i32.eq (local.get $c) (i32.const 0x6E))))
      (then (call $fail (i32.const 4))))
    (call $fail (i32.const 2))
    unreachable)

  ;; ---------------------------------------------------------------- file system
  ;; $pb holds the current path relative to fd 3, e.g. "./a/b/name".

  ;; filetype of the entry at $pb[0..plen) without following symlinks; -1 if missing
  (func $lstat_type (param $plen i32) (result i32)
    (local $e i32)
    (local.set $e (call $path_filestat_get (i32.const 3) (i32.const 0) (global.get $pb) (local.get $plen) (i32.const 64)))
    (if (i32.eq (local.get $e) (i32.const 44)) (then (return (i32.const -1))))  ;; ENOENT
    (if (local.get $e) (then (call $fail_at (i32.const 14) (local.get $plen))))
    (i32.load8_u (i32.const 80)))

  ;; RFC 5.2-5.4: remove a non-directory in the way (a symlink itself), fail on a directory
  (func $clear (param $plen i32)
    (local $t i32)
    (local.set $t (call $lstat_type (local.get $plen)))
    (if (i32.eq (local.get $t) (i32.const -1)) (then (return)))
    (if (i32.eq (local.get $t) (i32.const 3)) (then (call $fail_at (i32.const 12) (local.get $plen))))
    (if (call $path_unlink_file (i32.const 3) (global.get $pb) (local.get $plen))
      (then (call $fail_at (i32.const 15) (local.get $plen)))))

  (func $write_file (param $plen i32) (param $p i32) (param $n i32) (param $exec i32)
    (local $fd i32)
    ;; O_CREAT | O_EXCL, no SYMLINK_FOLLOW, rights: fd_write
    (if (call $path_open (i32.const 3) (i32.const 0) (global.get $pb) (local.get $plen)
              (i32.const 5) (i64.const 0x40) (i64.const 0) (i32.const 0) (i32.const 12))
      (then (call $fail_at (i32.const 17) (local.get $plen))))
    (local.set $fd (i32.load (i32.const 12)))
    (block $done
      (loop $more
        (br_if $done (i32.le_s (local.get $n) (i32.const 0)))
        (i32.store (i32.const 0) (local.get $p))
        (i32.store (i32.const 4) (local.get $n))
        (if (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8))
          (then (call $fail_at (i32.const 18) (local.get $plen))))
        (local.set $p (i32.add (local.get $p) (i32.load (i32.const 8))))
        (local.set $n (i32.sub (local.get $n) (i32.load (i32.const 8))))
        (br $more)))
    (drop (call $fd_close (local.get $fd)))
    (if (local.get $exec)
      (then (if (call $make_executable (global.get $pb) (local.get $plen))
        (then (call $fail_at (i32.const 20) (local.get $plen)))))))

  (func $apply (param $obj i32) (param $dirlen i32)
    (local $m i32) (local $v i32) (local $nn i32) (local $plen i32) (local $type i32) (local $t i32)
    (local.set $m (i32.load offset=4 (local.get $obj)))
    (block $done
      (loop $next
        (br_if $done (i32.eqz (local.get $m)))
        (local.set $nn (i32.load offset=4 (local.get $m)))
        (local.set $v (i32.load offset=8 (local.get $m)))
        (memory.copy (i32.add (global.get $pb) (local.get $dirlen)) (i32.load (local.get $m)) (local.get $nn))
        (local.set $plen (i32.add (local.get $dirlen) (local.get $nn)))
        (local.set $type (i32.load (local.get $v)))
        (if (i32.eq (local.get $type) (i32.const 2))
          (then
            ;; RFC 5.1: reuse an existing directory; anything else (even a symlink to one) is replaced
            (local.set $t (call $lstat_type (local.get $plen)))
            (if (i32.ne (local.get $t) (i32.const 3))
              (then
                (if (i32.ne (local.get $t) (i32.const -1))
                  (then (if (call $path_unlink_file (i32.const 3) (global.get $pb) (local.get $plen))
                    (then (call $fail_at (i32.const 15) (local.get $plen))))))
                (if (call $path_create_directory (i32.const 3) (global.get $pb) (local.get $plen))
                  (then (call $fail_at (i32.const 16) (local.get $plen))))))
            (i32.store8 (i32.add (global.get $pb) (local.get $plen)) (i32.const 0x2F))
            (call $apply (local.get $v) (i32.add (local.get $plen) (i32.const 1)))))
        (if (i32.eq (local.get $type) (i32.const 1))
          (then
            (call $clear (local.get $plen))
            (call $write_file (local.get $plen) (i32.load offset=4 (local.get $v)) (i32.load offset=8 (local.get $v)) (i32.const 0))))
        (if (i32.eq (local.get $type) (i32.const 4))
          (then
            (call $clear (local.get $plen))
            (call $write_file (local.get $plen) (i32.load offset=4 (local.get $v)) (i32.load offset=8 (local.get $v)) (i32.const 1))))
        (if (i32.eq (local.get $type) (i32.const 3))
          (then
            (call $clear (local.get $plen))
            (if (call $path_symlink (i32.load offset=4 (local.get $v)) (i32.load offset=8 (local.get $v))
                                    (i32.const 3) (global.get $pb) (local.get $plen))
              (then (call $fail_at (i32.const 19) (local.get $plen))))))
        (local.set $m (i32.load offset=12 (local.get $m)))
        (br $next))))

  ;; ---------------------------------------------------------------- main

  (func (export "_start")
    (local $root i32)
    ;; no arguments allowed (argv[0] is the program)
    (drop (call $args_sizes_get (i32.const 16) (i32.const 20)))
    (if (i32.gt_u (i32.load (i32.const 16)) (i32.const 1))
      (then
        (call $write_all (i32.const 2) (i32.const 256) (call $cstrlen (i32.const 256)))
        (call $write_all (i32.const 2) (i32.const 1684) (i32.const 1))
        (call $proc_exit (i32.const 2))
        unreachable))
    (call $read_input)
    (global.set $pos (global.get $IN))
    (global.set $end (i32.add (global.get $IN) (global.get $inlen)))
    (global.set $heap (i32.and (i32.add (global.get $end) (i32.const 7)) (i32.const -8)))
    (call $ensure (global.get $heap))
    (call $check_utf8 (global.get $pos) (global.get $end))
    ;; a leading byte order mark is ignored (RFC 3)
    (if (i32.ge_u (global.get $inlen) (i32.const 3))
      (then (if (i32.and (i32.eq (i32.load16_u (global.get $pos)) (i32.const 0xBBEF))
                         (i32.eq (i32.load8_u offset=2 (global.get $pos)) (i32.const 0xBF)))
        (then (global.set $pos (i32.add (global.get $pos) (i32.const 3)))))))
    ;; parse and validate the whole document before touching the file system
    (call $ws)
    (if (i32.eq (call $peek) (i32.const -1)) (then (call $fail (i32.const 2))))
    (if (i32.ne (call $peek) (i32.const 0x7B))
      (then
        (if (i32.or (i32.eq (call $peek) (i32.const 0x5B)) (i32.eq (call $peek) (i32.const 0x22)))
          (then (call $fail (i32.const 3))))
        (drop (call $parse_value (i32.const 0)))
        (call $fail (i32.const 3))))
    (local.set $root (call $parse_value (i32.const 0)))
    (call $ws)
    (if (i32.ne (global.get $pos) (global.get $end)) (then (call $fail (i32.const 2))))
    ;; path buffer: a path is never longer than the input
    ;; Every path starts with "./" so a name such as "\a" stays a plain relative path.
    (global.set $pb (call $alloc (i32.add (global.get $inlen) (i32.const 64))))
    (i32.store16 (global.get $pb) (i32.const 0x2F2E))
    (call $apply (local.get $root) (i32.const 2))
    (call $proc_exit (i32.const 0)))
)
