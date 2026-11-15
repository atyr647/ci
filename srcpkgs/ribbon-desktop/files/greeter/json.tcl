# json.tcl - the little JSON greetd speaks, without tcllib.
#
# Encoding is explicit (the caller says what is a string, a list of
# strings or null); decoding turns objects into dicts, arrays into lists,
# true/false into 1/0 and null into "".

namespace eval json {}

# A JSON string literal.
proc json::str {s} {
	set out \"
	foreach ch [split $s ""] {
		scan $ch %c n
		switch -- $ch {
			\" { append out \\\" }
			\\ { append out \\\\ }
			\n { append out \\n }
			\r { append out \\r }
			\t { append out \\t }
			default {
				if {$n < 0x20} { append out [format \\u%04x $n] } else { append out $ch }
			}
		}
	}
	append out \"
}

# An array of strings.
proc json::strs {list} {
	set parts {}
	foreach s $list { lappend parts [str $s] }
	return \[[join $parts ,]\]
}

# An object from key / encoded-value pairs.
proc json::obj {args} {
	set parts {}
	foreach {k v} $args { lappend parts "[str $k]:$v" }
	return \{[join $parts ,]\}
}

proc json::decode {text} {
	set i 0
	set v [value $text i]
	skip $text i
	if {$i != [string length $text]} { error "json: trailing data at $i" }
	return $v
}

proc json::skip {text iv} {
	upvar 1 $iv i
	while {$i < [string length $text] && [string is space [string index $text $i]]} { incr i }
}

proc json::value {text iv} {
	upvar 1 $iv i
	skip $text i
	set ch [string index $text $i]
	switch -- $ch {
		\{ {
			incr i
			set d [dict create]
			skip $text i
			if {[string index $text $i] eq "\}"} { incr i; return $d }
			while 1 {
				skip $text i
				if {[string index $text $i] ne "\""} { error "json: key expected at $i" }
				set k [string_ $text i]
				skip $text i
				if {[string index $text $i] ne ":"} { error "json: ':' expected at $i" }
				incr i
				dict set d $k [value $text i]
				skip $text i
				set c [string index $text $i]; incr i
				if {$c eq "\}"} { return $d }
				if {$c ne ","} { error "json: ',' or '\}' expected at [expr {$i - 1}]" }
			}
		}
		\[ {
			incr i
			set l {}
			skip $text i
			if {[string index $text $i] eq "\]"} { incr i; return $l }
			while 1 {
				lappend l [value $text i]
				skip $text i
				set c [string index $text $i]; incr i
				if {$c eq "\]"} { return $l }
				if {$c ne ","} { error "json: ',' or '\]' expected at [expr {$i - 1}]" }
			}
		}
		\" { return [string_ $text i] }
		t { return [literal $text i true 1] }
		f { return [literal $text i false 0] }
		n { return [literal $text i null ""] }
		default {
			if {[regexp -start $i {\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][-+]?\d+)?} $text num]} {
				incr i [string length $num]
				return $num
			}
			error "json: unexpected '$ch' at $i"
		}
	}
}

proc json::literal {text iv word v} {
	upvar 1 $iv i
	if {[string range $text $i [expr {$i + [string length $word] - 1}]] ne $word} { error "json: bad literal at $i" }
	incr i [string length $word]
	return $v
}

proc json::string_ {text iv} {
	upvar 1 $iv i
	incr i
	set out ""
	set n [string length $text]
	while {$i < $n} {
		set j [string first \" $text $i]
		set k [string first \\ $text $i]
		if {$j < 0} break
		if {$k < 0 || $j < $k} {
			append out [string range $text $i [expr {$j - 1}]]
			set i [expr {$j + 1}]
			return $out
		}
		append out [string range $text $i [expr {$k - 1}]]
		set e [string index $text [expr {$k + 1}]]
		set i [expr {$k + 2}]
		switch -- $e {
			n { append out \n } r { append out \r } t { append out \t }
			b { append out \b } f { append out \f }
			u {
				scan [string range $text $i [expr {$i + 3}]] %4x cp
				incr i 4
				# a surrogate pair: one character outside the BMP
				if {$cp >= 0xd800 && $cp < 0xdc00 && [string range $text $i [expr {$i + 1}]] eq "\\u"} {
					scan [string range $text [expr {$i + 2}] [expr {$i + 5}]] %4x lo
					if {$lo >= 0xdc00 && $lo < 0xe000} {
						set cp [expr {0x10000 + (($cp - 0xd800) << 10) + ($lo - 0xdc00)}]
						incr i 6
					}
				}
				if {$cp > 0xffff && [string length [format %c 0x10000]] != 1} { set cp 0xfffd }
				append out [format %c $cp]
			}
			default { append out $e }
		}
	}
	error "json: unterminated string"
}
