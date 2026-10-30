;; Exception handling (try_table / throw / throw_ref / exnref) and tail calls
(module
  (tag $e (param i32))
  (tag $e2)
  (func $thrower (param i32) (throw $e (local.get 0)))
  (func $deep (param $n i32) (param $v i32)
    (if (i32.eqz (local.get $n)) (then (throw $e (local.get $v))))
    (call $deep (i32.sub (local.get $n) (i32.const 1)) (local.get $v)))

  (func (export "t_catch") (result i32)
    (i32.eq
      (block $h (result i32)
        (try_table (catch $e $h) (call $thrower (i32.const 42)))
        (i32.const 0))
      (i32.const 42)))

  (func (export "t_catch_all") (result i32)
    (block $h
      (try_table (catch_all $h) (throw $e2))
      (return (i32.const 0)))
    (i32.const 1))

  (func (export "t_nested_frames") (result i32)
    (i32.eq
      (block $h (result i32)
        (try_table (catch $e $h) (call $deep (i32.const 500) (i32.const 77)))
        (i32.const 0))
      (i32.const 77)))

  (func (export "t_rethrow_exnref") (result i32)
    (local $x exnref)
    (i32.eq
      (block $outer (result i32)
        (try_table (catch $e $outer)
          (block $inner (result i32 exnref)
            (try_table (catch_ref $e $inner) (call $thrower (i32.const 9)))
            (return (i32.const 0)))
          (local.set $x)
          (drop)
          (throw_ref (local.get $x)))
        (i32.const 0))
      (i32.const 9)))
  (func (export "t_no_throw") (result i32)
    (block $h
      (try_table (catch_all $h) (nop))
      (return (i32.const 1)))
    (i32.const 0))

  (func (export "x_uncaught") (result i32)
    (call $thrower (i32.const 1)) (i32.const 1))

  ;; tail calls
  (type $ft (func (param i64 i64) (result i64)))
  (table $t 1 funcref)
  (elem (table $t) (i32.const 0) func $sum_ind)
  (func $sum (param $n i64) (param $acc i64) (result i64)
    (if (result i64) (i64.eqz (local.get $n))
      (then (local.get $acc))
      (else (return_call $sum (i64.sub (local.get $n) (i64.const 1)) (i64.add (local.get $acc) (local.get $n))))))
  (func $sum_ind (param $n i64) (param $acc i64) (result i64)
    (if (result i64) (i64.eqz (local.get $n))
      (then (local.get $acc))
      (else (return_call_indirect (type $ft) (i64.sub (local.get $n) (i64.const 1)) (i64.add (local.get $acc) (local.get $n)) (i32.const 0)))))
  (func (export "t_tail_call") (result i32)
    (i64.eq (call $sum (i64.const 50000000) (i64.const 0)) (i64.const 1250000025000000)))
  (func (export "t_tail_call_indirect") (result i32)
    (i64.eq (call $sum_ind (i64.const 10000000) (i64.const 0)) (i64.const 50000005000000)))
)
