#!/usr/bin/env python3
"""Experiment: Tint's lexer Token holds `std::variant<int64_t, double, std::string, std::string_view>`; in the profile of the Cosmopolitan build (libc++ 19) its move constructor, destructor and
visitation dispatch show up as separate calls and cost about 0.5 ms per 160-function shader module more than with libstdc++. This replaces that one variant by a plain tagged union with the same
behaviour, to test whether libc++'s std::variant is the cause of the remaining x86-64 shader-compile gap. usage: token_union.py <dawn-source-dir>

Second change in the same files: `enum class Type` gets the underlying type uint8_t. Reason (found with perf annotate): libc++'s std::optional writes one byte of its storage (`__null_state_`) when it
holds no value, and the caller of each Lexer::try_*() then loads Token::type_ (4 bytes) from that same address before testing the optional's flag; a load wider than the store just before it cannot be
forwarded and stalls (about 12-15 cycles per call, in Lexer::next() every token tries eight such functions). With a 1-byte type the load is the same width and offset as the store and forwards."""
import sys, os
d = sys.argv[1]
h = os.path.join(d, 'src/tint/lang/wgsl/reader/parser/token.h')
c = os.path.join(d, 'src/tint/lang/wgsl/reader/parser/token.cc')
t = open(h).read()
old = '    std::variant<int64_t, double, std::string, std::string_view> value_;'
assert old in t
new = '''    struct Value {
        enum Tag : unsigned char { kInt, kDouble, kString, kView } tag;
        union { int64_t i; double d; std::string_view v; std::string s; };
        Value() : tag(kInt), i(0) {}
        Value(int64_t x) : tag(kInt), i(x) {}
        Value(double x) : tag(kDouble), d(x) {}
        Value(std::string_view x) : tag(kView), v(x) {}
        Value(const std::string& x) : tag(kString), s(x) {}
        Value(Value&& o) noexcept : tag(o.tag) {
            switch (tag) {
                case kInt: i = o.i; break;
                case kDouble: d = o.d; break;
                case kView: new (&v) std::string_view(o.v); break;
                case kString: new (&s) std::string(std::move(o.s)); break;
            }
        }
        Value(const Value&) = delete;
        Value& operator=(const Value&) = delete;
        ~Value() { if (tag == kString) s.~basic_string(); }
    } value_;'''
t = t.replace(old, new)
assert '    enum class Type {' in t
t = t.replace('    enum class Type {', '    enum class Type : uint8_t {', 1)
if '#include <cstdint>' not in t: t = t.replace('#include <variant>', '#include <cstdint>\n#include <variant>', 1)
open(h, 'w').write(t)
t = open(c).read()
for a, b in [('std::get_if<std::string_view>(&value_)', '(value_.tag == Value::kView ? &value_.v : nullptr)'),
             ('std::get<std::string>(value_)', 'value_.s'), ('std::get<double>(value_)', 'value_.d'), ('std::get<int64_t>(value_)', 'value_.i')]:
    assert a in t, a
    t = t.replace(a, b)
open(c, 'w').write(t)
print('token.h / token.cc: variant replaced by a tagged union')
