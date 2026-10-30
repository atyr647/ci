;; relaxed SIMD (only cases whose result does not depend on the CPU)
(module
  (func $all_f32_eq (param v128 v128) (result i32) (i32x4.all_true (f32x4.eq (local.get 0) (local.get 1))))
  (func (export "t_madd") (result i32)
    (call $all_f32_eq
      (f32x4.relaxed_madd (v128.const f32x4 1 2 3 4) (v128.const f32x4 2 2 2 2) (v128.const f32x4 1 1 1 1))
      (v128.const f32x4 3 5 7 9)))
  (func (export "t_nmadd") (result i32)
    (call $all_f32_eq
      (f32x4.relaxed_nmadd (v128.const f32x4 1 2 3 4) (v128.const f32x4 2 2 2 2) (v128.const f32x4 10 10 10 10))
      (v128.const f32x4 8 6 4 2)))
  (func (export "t_trunc") (result i32)
    (i32x4.all_true (i32x4.eq (i32x4.relaxed_trunc_f32x4_s (v128.const f32x4 1.5 -2.5 3.0 100.0)) (v128.const i32x4 1 -2 3 100))))
  (func (export "t_swizzle") (result i32)
    (i8x16.all_true (i8x16.eq
      (i8x16.relaxed_swizzle (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15) (v128.const i8x16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0))
      (v128.const i8x16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0))))
  (func (export "t_laneselect") (result i32)
    (i32x4.all_true (i32x4.eq
      (i32x4.relaxed_laneselect (v128.const i32x4 1 2 3 4) (v128.const i32x4 10 20 30 40) (v128.const i32x4 -1 0 -1 0))
      (v128.const i32x4 1 20 3 40))))
  (func (export "t_minmax") (result i32)
    (i32.and
      (call $all_f32_eq (f32x4.relaxed_min (v128.const f32x4 1 5 -3 8) (v128.const f32x4 2 4 -4 9)) (v128.const f32x4 1 4 -4 8))
      (call $all_f32_eq (f32x4.relaxed_max (v128.const f32x4 1 5 -3 8) (v128.const f32x4 2 4 -4 9)) (v128.const f32x4 2 5 -3 9))))
  (func (export "t_q15mulr") (result i32)
    (i16x8.all_true (i16x8.eq
      (i16x8.relaxed_q15mulr_s (v128.const i16x8 16384 16384 -16384 8192 0 100 200 300) (v128.const i16x8 16384 -16384 16384 8192 5 0 0 0))
      (v128.const i16x8 8192 -8192 -8192 2048 0 0 0 0))))
  (func (export "t_dot") (result i32)
    (i32.and
      (i16x8.all_true (i16x8.eq
        (i16x8.relaxed_dot_i8x16_i7x16_s (v128.const i8x16 1 2 3 4 5 6 7 8 1 1 1 1 1 1 1 1) (v128.const i8x16 1 1 1 1 2 2 2 2 3 3 3 3 4 4 4 4))
        (v128.const i16x8 3 7 22 30 6 6 8 8)))
      (i32x4.all_true (i32x4.eq
        (i32x4.relaxed_dot_i8x16_i7x16_add_s (v128.const i8x16 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1) (v128.const i8x16 1 1 1 1 2 2 2 2 3 3 3 3 4 4 4 4) (v128.const i32x4 100 100 100 100))
        (v128.const i32x4 104 108 112 116)))))
  (func (export "t_regular_simd_still_works") (result i32)
    (i32x4.all_true (i32x4.eq (i32x4.add (v128.const i32x4 1 2 3 4) (v128.const i32x4 10 20 30 40)) (v128.const i32x4 11 22 33 44))))
)
