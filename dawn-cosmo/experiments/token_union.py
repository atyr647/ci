#!/usr/bin/env python3
"""Experiment: Tint's lexer Token holds `std::variant<int64_t, double, std::string, std::string_view>`; in the profile of the Cosmopolitan build (libc++ 19) its move constructor, destructor and
visitation dispatch show up as separate calls and cost about 0.5 ms per 160-function shader module more than with libstdc++. This replaces that one variant by a plain tagged union with the same
behaviour, to test whether libc++'s std::variant is the cause of the remaining x86-64 shader-compile gap. usage: token_union.py <dawn-source-dir>"""
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
open(h, 'w').write(t.replace(old, new))
t = open(c).read()
for a, b in [('std::get_if<std::string_view>(&value_)', '(value_.tag == Value::kView ? &value_.v : nullptr)'),
             ('std::get<std::string>(value_)', 'value_.s'), ('std::get<double>(value_)', 'value_.d'), ('std::get<int64_t>(value_)', 'value_.i')]:
    assert a in t, a
    t = t.replace(a, b)
open(c, 'w').write(t)
print('token.h / token.cc: variant replaced by a tagged union')
