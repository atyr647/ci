#!/usr/bin/env python3
"""Generates relaxed_ops.wat (one exported function per relaxed-simd opcode, constant inputs with only well-defined results, returning an i64 hash of the v128 result)
and main.c for the wasm2c build (prints 'name hash' for every export). usage: gen_test.py OUTDIR"""
import os, struct, sys
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
def f32x4(*v): return 'v128.const f32x4 ' + ' '.join(repr(float(x)) for x in v)
def f64x2(*v): return 'v128.const f64x2 ' + ' '.join(repr(float(x)) for x in v)
def i8x16(*v): return 'v128.const i8x16 ' + ' '.join(str(x) for x in v)
def i16x8(*v): return 'v128.const i16x8 ' + ' '.join(str(x) for x in v)
def i32x4(*v): return 'v128.const i32x4 ' + ' '.join(str(x) for x in v)
def i64x2(*v): return 'v128.const i64x2 ' + ' '.join(str(x) for x in v)
T = []   # (name, [operand constants], op)
T += [('madd_f32', [f32x4(1.5, 2, 3, -4), f32x4(2, 2, 2, 2), f32x4(0.5, 1, 1.5, 2)], 'f32x4.relaxed_madd')]
T += [('nmadd_f32', [f32x4(1.5, 2, 3, -4), f32x4(2, 2, 2, 2), f32x4(0.5, 1, 1.5, 2)], 'f32x4.relaxed_nmadd')]
T += [('madd_f64', [f64x2(1.5, -4), f64x2(2, 8), f64x2(0.25, 3)], 'f64x2.relaxed_madd')]
T += [('nmadd_f64', [f64x2(1.5, -4), f64x2(2, 8), f64x2(0.25, 3)], 'f64x2.relaxed_nmadd')]
T += [('lsel_i8', [i8x16(*range(16)), i8x16(*[100 + i for i in range(16)]), i8x16(*([-1, 0] * 8))], 'i8x16.relaxed_laneselect')]
T += [('lsel_i16', [i16x8(*range(8)), i16x8(*[1000 + i for i in range(8)]), i16x8(*([-1, 0] * 4))], 'i16x8.relaxed_laneselect')]
T += [('lsel_i32', [i32x4(1, 2, 3, 4), i32x4(10, 20, 30, 40), i32x4(-1, 0, 0, -1)], 'i32x4.relaxed_laneselect')]
T += [('lsel_i64', [i64x2(1, 2), i64x2(10, 20), i64x2(-1, 0)], 'i64x2.relaxed_laneselect')]
T += [('min_f32', [f32x4(1, -2, 3, 4), f32x4(2, -3, 3.5, 0.5)], 'f32x4.relaxed_min')]
T += [('max_f32', [f32x4(1, -2, 3, 4), f32x4(2, -3, 3.5, 0.5)], 'f32x4.relaxed_max')]
T += [('min_f64', [f64x2(1, -2), f64x2(2, -3)], 'f64x2.relaxed_min')]
T += [('max_f64', [f64x2(1, -2), f64x2(2, -3)], 'f64x2.relaxed_max')]
T += [('swizzle', [i8x16(*[10 * i for i in range(16)]), i8x16(*[15 - i for i in range(16)])], 'i8x16.relaxed_swizzle')]
T += [('q15mulr', [i16x8(1000, -2000, 30000, 5, 16384, -16384, 7, 0), i16x8(2000, 3000, 1000, -5, 16384, 16384, 9, 5)], 'i16x8.relaxed_q15mulr_s')]
T += [('dot_i16', [i8x16(*[(i * 7) % 100 - 50 for i in range(16)]), i8x16(*[(i * 5 + 3) % 128 for i in range(16)])], 'i16x8.relaxed_dot_i8x16_i7x16_s')]
T += [('dot_add_i32', [i8x16(*[(i * 7) % 100 - 50 for i in range(16)]), i8x16(*[(i * 5 + 3) % 128 for i in range(16)]), i32x4(1000, -1000, 5, 6)], 'i32x4.relaxed_dot_i8x16_i7x16_add_s')]
T += [('trunc_f32_s', [f32x4(1.9, -2.9, 100.5, 0)], 'i32x4.relaxed_trunc_f32x4_s')]
T += [('trunc_f32_u', [f32x4(1.9, 2.9, 100.5, 0)], 'i32x4.relaxed_trunc_f32x4_u')]
T += [('trunc_f64_s_zero', [f64x2(-1.9, 7.5)], 'i32x4.relaxed_trunc_f64x2_s_zero')]
T += [('trunc_f64_u_zero', [f64x2(1.9, 7.5)], 'i32x4.relaxed_trunc_f64x2_u_zero')]
w = ['(module', '  (func $h (param v128) (result i64) (i64.add (i64x2.extract_lane 0 (local.get 0)) (i64.mul (i64x2.extract_lane 1 (local.get 0)) (i64.const -7046029254386353131))))']
for n, ops, op in T:
    w.append(f'  (func (export "t_{n}") (result i64) (call $h ({" ) ( ".join(ops).join(["(", ")"]) if False else "".join("(" + o + ") " for o in ops) + "(" + op + ")"}))' if False else
             f'  (func (export "t_{n}") (result i64) {"".join("(" + o + ") " for o in ops)}{op} call $h)')
w.append(')')
open(f'{out}/relaxed_ops.wat', 'w').write('\n'.join(w) + '\n')
names = [n for n, _, _ in T]
open(f'{out}/names.txt', 'w').write('\n'.join('t_' + n for n in names) + '\n')
c = ['#include <stdio.h>', '#include <stdint.h>', '#include "rt.h"', 'void wasm_rt_init(void);', 'int main(void) { wasm_rt_init(); w2c_rt inst; wasm2c_rt_instantiate(&inst);']
for n in names: c.append(f'  printf("t_{n} %lld\\n", (long long)w2c_rt_t_{n}(&inst));')
c.append('  return 0; }')
open(f'{out}/main.c', 'w').write('\n'.join(c) + '\n')
print(len(T), 'tests')
