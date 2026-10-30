;; A hand-written component that exercises the canonical ABI both ways: strings, lists, records, results (returned through memory), a host import taking a string, and a trap.
(component
  (import "log" (func $log (param "s" string)))

  (core module $mm (memory (export "mem") 2))
  (core module $impl
    (import "m" "mem" (memory 2))
    (import "env" "log" (func $log (param i32 i32)))
    (global $bump (mut i32) (i32.const 4096))
    (data (i32.const 2048) "division by zero")
    (data (i32.const 3000) "hello, ")

    (func $realloc (export "realloc") (param $old i32) (param $osz i32) (param $align i32) (param $nsz i32) (result i32)
      (local $p i32)
      (local.set $p (i32.and (i32.add (global.get $bump) (i32.sub (local.get $align) (i32.const 1))) (i32.xor (i32.sub (local.get $align) (i32.const 1)) (i32.const -1))))
      (global.set $bump (i32.add (local.get $p) (local.get $nsz)))
      (local.get $p))

    ;; upper(s: string) -> string   (result is returned through a pointer to {ptr,len})
    (func (export "upper") (param $p i32) (param $n i32) (result i32)
      (local $i i32) (local $out i32) (local $c i32) (local $r i32)
      (local.set $out (call $realloc (i32.const 0) (i32.const 0) (i32.const 1) (local.get $n)))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $c (i32.load8_u (i32.add (local.get $p) (local.get $i))))
        (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122))) (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))
        (i32.store8 (i32.add (local.get $out) (local.get $i)) (local.get $c))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (local.set $r (call $realloc (i32.const 0) (i32.const 0) (i32.const 4) (i32.const 8)))
      (i32.store (local.get $r) (local.get $out))
      (i32.store offset=4 (local.get $r) (local.get $n))
      (local.get $r))

    ;; sum(xs: list<u32>) -> u64
    (func (export "sum") (param $p i32) (param $n i32) (result i64)
      (local $i i32) (local $s i64)
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $s (i64.add (local.get $s) (i64.extend_i32_u (i32.load (i32.add (local.get $p) (i32.shl (local.get $i) (i32.const 2)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (local.get $s))

    ;; div(a: s32, b: s32) -> result<s32, string>   (returned through memory: u8 case, payload at +4)
    (func (export "div") (param $a i32) (param $b i32) (result i32)
      (local $r i32)
      (local.set $r (call $realloc (i32.const 0) (i32.const 0) (i32.const 4) (i32.const 12)))
      (if (i32.eqz (local.get $b))
        (then
          (i32.store8 (local.get $r) (i32.const 1))
          (i32.store offset=4 (local.get $r) (i32.const 2048))
          (i32.store offset=8 (local.get $r) (i32.const 16)))
        (else
          (i32.store8 (local.get $r) (i32.const 0))
          (i32.store offset=4 (local.get $r) (i32.div_s (local.get $a) (local.get $b)))))
      (local.get $r))

    ;; area(r: record { w: u32, h: u32 }) -> u32
    (func (export "area") (param $w i32) (param $h i32) (result i32) (i32.mul (local.get $w) (local.get $h)))

    ;; greet(name: string): calls the host's log("hello, " + name)
    (func (export "greet") (param $p i32) (param $n i32)
      (local $out i32)
      (local.set $out (call $realloc (i32.const 0) (i32.const 0) (i32.const 1) (i32.add (local.get $n) (i32.const 7))))
      (memory.copy (local.get $out) (i32.const 3000) (i32.const 7))
      (memory.copy (i32.add (local.get $out) (i32.const 7)) (local.get $p) (local.get $n))
      (call $log (local.get $out) (i32.add (local.get $n) (i32.const 7))))

    (func (export "boom") (unreachable))
  )

  (core instance $memi (instantiate $mm))
  (alias core export $memi "mem" (core memory $mem))
  (core func $logl (canon lower (func $log) (memory $mem)))
  (core instance $env (export "log" (func $logl)))
  (core instance $i (instantiate $impl (with "m" (instance $memi)) (with "env" (instance $env))))
  (alias core export $i "realloc" (core func $realloc))
  (alias core export $i "upper" (core func $upper))
  (alias core export $i "sum" (core func $sum))
  (alias core export $i "div" (core func $div))
  (alias core export $i "area" (core func $area))
  (alias core export $i "greet" (core func $greet))
  (alias core export $i "boom" (core func $boom))

  (func (export "upper") (param "s" string) (result string) (canon lift (core func $upper) (memory $mem) (realloc (core func $realloc))))
  (func (export "sum") (param "xs" (list u32)) (result u64) (canon lift (core func $sum) (memory $mem) (realloc (core func $realloc))))
  (func (export "div") (param "a" s32) (param "b" s32) (result (result s32 (error string))) (canon lift (core func $div) (memory $mem) (realloc (core func $realloc))))
  (type $dim (record (field "w" u32) (field "h" u32)))
  (func (export "area") (param "d" $dim) (result u32) (canon lift (core func $area)))
  (func (export "greet") (param "name" string) (canon lift (core func $greet) (memory $mem) (realloc (core func $realloc))))
  (func (export "boom") (canon lift (core func $boom)))
)
