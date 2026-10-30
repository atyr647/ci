#!/usr/bin/env python3
"""Adds the relaxed-SIMD instructions to wasm2c (wabt). Upstream wasm2c translates fixed-width SIMD128 through SIMDe but stops with
"error: wasm2c does not support the f32x4.relaxed_madd instruction" for every relaxed-simd opcode. This script edits a wabt checkout in place:
  src/template/wasm2c_simd.declarations.c : helper functions (GNU vector extensions, so gcc/clang map them to SSE/AVX/FMA/NEON)
  src/c-writer.cc                         : the 20 relaxed opcodes of the unary / binary / ternary writers
  src/prebuilt/wasm2c_simd_source_declarations.cc : regenerated from the template with wabt's own script
usage: patch_wabt.py WABT_DIR     (fails loudly when an anchor is missing)"""
import os, re, subprocess, sys
W = sys.argv[1]
def rd(p): return open(os.path.join(W, p)).read()
def wr(p, s): open(os.path.join(W, p), 'w').write(s)

HELPERS = r'''
/* ---- relaxed-simd (added by the wasm-perf patch). Fused multiply-add is used when the target has it (relaxed semantics allow fused or unfused);
 * otherwise a separate multiply and add. All of these are plain GNU vector expressions, so gcc/clang vectorise them for the target ISA. */
typedef float w2c_vf32x4 __attribute__((vector_size(16)));
typedef double w2c_vf64x2 __attribute__((vector_size(16)));
#define W2C_V128_TO(T, name, v) T name; wasm_rt_memcpy(&name, &(v), 16)
#define W2C_V128_FROM(T, x) ({ v128 w2c_r; T w2c_t = (x); wasm_rt_memcpy(&w2c_r, &w2c_t, 16); w2c_r; })
static inline v128 w2c_f32x4_relaxed_madd(v128 a, v128 b, v128 c) { W2C_V128_TO(w2c_vf32x4, x, a); W2C_V128_TO(w2c_vf32x4, y, b); W2C_V128_TO(w2c_vf32x4, z, c); return W2C_V128_FROM(w2c_vf32x4, x * y + z); }
static inline v128 w2c_f32x4_relaxed_nmadd(v128 a, v128 b, v128 c) { W2C_V128_TO(w2c_vf32x4, x, a); W2C_V128_TO(w2c_vf32x4, y, b); W2C_V128_TO(w2c_vf32x4, z, c); return W2C_V128_FROM(w2c_vf32x4, z - x * y); }
static inline v128 w2c_f64x2_relaxed_madd(v128 a, v128 b, v128 c) { W2C_V128_TO(w2c_vf64x2, x, a); W2C_V128_TO(w2c_vf64x2, y, b); W2C_V128_TO(w2c_vf64x2, z, c); return W2C_V128_FROM(w2c_vf64x2, x * y + z); }
static inline v128 w2c_f64x2_relaxed_nmadd(v128 a, v128 b, v128 c) { W2C_V128_TO(w2c_vf64x2, x, a); W2C_V128_TO(w2c_vf64x2, y, b); W2C_V128_TO(w2c_vf64x2, z, c); return W2C_V128_FROM(w2c_vf64x2, z - x * y); }
static inline v128 w2c_i16x8_relaxed_dot_i8x16_i7x16_s(v128 a, v128 b) {
  int8_t x[16], y[16]; int16_t r[8]; wasm_rt_memcpy(x, &a, 16); wasm_rt_memcpy(y, &b, 16);
  for (int i = 0; i < 8; i++) r[i] = (int16_t)(x[2 * i] * y[2 * i] + x[2 * i + 1] * y[2 * i + 1]);
  v128 out; wasm_rt_memcpy(&out, r, 16); return out;
}
static inline v128 w2c_i32x4_relaxed_dot_i8x16_i7x16_add_s(v128 a, v128 b, v128 c) {
  int8_t x[16], y[16]; int32_t acc[4], r[4]; wasm_rt_memcpy(x, &a, 16); wasm_rt_memcpy(y, &b, 16); wasm_rt_memcpy(acc, &c, 16);
  for (int i = 0; i < 4; i++) r[i] = x[4 * i] * y[4 * i] + x[4 * i + 1] * y[4 * i + 1] + x[4 * i + 2] * y[4 * i + 2] + x[4 * i + 3] * y[4 * i + 3] + acc[i];
  v128 out; wasm_rt_memcpy(&out, r, 16); return out;
}
'''
p = 'src/template/wasm2c_simd.declarations.c'
t = rd(p)
if 'w2c_f32x4_relaxed_madd' not in t: wr(p, t.rstrip('\n') + '\n' + HELPERS)

p = 'src/c-writer.cc'; c = rd(p)
if 'F32X4RelaxedMadd' in c: print('already patched'); sys.exit(0)

def need(anchor):
    if c.count(anchor) != 1: sys.exit(f'ANCHOR NOT FOUND (or ambiguous: {c.count(anchor)}): {anchor[:70]!r}')
# unary
a = '    case Opcode::I32X4TruncSatF32X4S:\n      WriteSimpleUnaryExpr(expr.opcode, "simde_wasm_i32x4_trunc_sat_f32x4");'
need(a)
c = c.replace(a, '''    case Opcode::I32X4RelaxedTruncF32X4S:
      WriteSimpleUnaryExpr(expr.opcode, "simde_wasm_i32x4_trunc_sat_f32x4");
      break;
    case Opcode::I32X4RelaxedTruncF32X4U:
      WriteSimpleUnaryExpr(expr.opcode, "simde_wasm_u32x4_trunc_sat_f32x4");
      break;
    case Opcode::I32X4RelaxedTruncF64X2SZero:
      WriteSimpleUnaryExpr(expr.opcode, "v128_i32x4_trunc_sat_f64x2_zero");
      break;
    case Opcode::I32X4RelaxedTruncF64X2UZero:
      WriteSimpleUnaryExpr(expr.opcode, "v128_u32x4_trunc_sat_f64x2_zero");
      break;

''' + a)
# binary
a = '    case Opcode::I16X8Q15mulrSatS:\n      WritePrefixBinaryExpr(expr.opcode, "simde_wasm_i16x8_q15mulr_sat");'
need(a)
c = c.replace(a, '''    case Opcode::I8X16RelaxedSwizzle:
      WritePrefixBinaryExpr(expr.opcode, "v128_i8x16_swizzle");
      break;
    case Opcode::F32X4RelaxedMin:
      WritePrefixBinaryExpr(expr.opcode, "simde_wasm_f32x4_min");
      break;
    case Opcode::F32X4RelaxedMax:
      WritePrefixBinaryExpr(expr.opcode, "simde_wasm_f32x4_max");
      break;
    case Opcode::F64X2RelaxedMin:
      WritePrefixBinaryExpr(expr.opcode, "simde_wasm_f64x2_min");
      break;
    case Opcode::F64X2RelaxedMax:
      WritePrefixBinaryExpr(expr.opcode, "simde_wasm_f64x2_max");
      break;
    case Opcode::I16X8RelaxedQ15mulrS:
      WritePrefixBinaryExpr(expr.opcode, "simde_wasm_i16x8_q15mulr_sat");
      break;
    case Opcode::I16X8DotI8X16I7X16S:
      WritePrefixBinaryExpr(expr.opcode, "w2c_i16x8_relaxed_dot_i8x16_i7x16_s");
      break;

''' + a)
# ternary
a = '''    default:
      WABT_FATAL("error: wasm2c does not support the %s instruction\\n",
                 expr.opcode.GetName());
  }
}

void CWriter::Write(const QuaternaryExpr& expr) {'''
need(a)
def tern(op, fn):
    return f'''    case Opcode::{op}: {{
      Type result_type = expr.opcode.GetResultType();
      Write(StackVar(2, result_type), " = ", "{fn}", "(", StackVar(2), ", ",
            StackVar(1), ", ", StackVar(0), ");", Newline());
      DropTypes(3);
      PushType(result_type);
      break;
    }}
'''
new = ''.join(tern(o, f) for o, f in (
    ('F32X4RelaxedMadd', 'w2c_f32x4_relaxed_madd'), ('F32X4RelaxedNmadd', 'w2c_f32x4_relaxed_nmadd'),
    ('F64X2RelaxedMadd', 'w2c_f64x2_relaxed_madd'), ('F64X2RelaxedNmadd', 'w2c_f64x2_relaxed_nmadd'),
    ('I8X16RelaxedLaneSelect', 'simde_wasm_v128_bitselect'), ('I16X8RelaxedLaneSelect', 'simde_wasm_v128_bitselect'),
    ('I32X4RelaxedLaneSelect', 'simde_wasm_v128_bitselect'), ('I64X2RelaxedLaneSelect', 'simde_wasm_v128_bitselect'),
    ('I32X4DotI8X16I7X16AddS', 'w2c_i32x4_relaxed_dot_i8x16_i7x16_add_s')))
c = c.replace(a, new + a)
wr(p, c)
# regenerate the prebuilt template source from the edited template, exactly as wabt's CMake does
subprocess.check_call(['cmake', '-D', f'out={W}/src/prebuilt/wasm2c_simd_source_declarations.cc', '-D', f'in={W}/src/template/wasm2c_simd.declarations.c',
                       '-D', 'symbol=s_simd_source_declarations', '-P', f'{W}/scripts/gen-wasm2c-templates.cmake'])
print('patched: 20 relaxed-simd opcodes handled by wasm2c')
