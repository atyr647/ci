;; threads proposal: atomic instructions on a normal memory
(module
  (memory 1)
  (func (export "t_atomic_rmw") (result i32)
    (i32.atomic.store (i32.const 0) (i32.const 5))
    (drop (i32.atomic.rmw.add (i32.const 0) (i32.const 3)))
    (i32.eq (i32.atomic.load (i32.const 0)) (i32.const 8)))
  (func (export "t_atomic_cmpxchg") (result i32)
    (i64.atomic.store (i32.const 8) (i64.const 100))
    (drop (i64.atomic.rmw.cmpxchg (i32.const 8) (i64.const 100) (i64.const 200)))
    (i64.eq (i64.atomic.load (i32.const 8)) (i64.const 200)))
  (func (export "t_notify_no_waiters") (result i32)
    (i32.eq (memory.atomic.notify (i32.const 16) (i32.const 1)) (i32.const 0)))
)
