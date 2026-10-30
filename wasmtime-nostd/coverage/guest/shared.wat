;; threads proposal: a shared memory
(module
  (memory 1 1 shared)
  (func (export "t_shared_atomic") (result i32)
    (i32.atomic.store (i32.const 0) (i32.const 41))
    (drop (i32.atomic.rmw.add (i32.const 0) (i32.const 1)))
    (i32.eq (i32.atomic.load (i32.const 0)) (i32.const 42)))
)
