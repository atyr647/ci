# ::kit::net::FilePath (srcpkgs/ribbon-kit/files/lib/net.tcl): a file:// URL becomes a path WITHOUT Tcl substitution
# (an index's kit root or a chunk hash is part of the URL: a [command] in it must stay text), %XX decoded as UTF-8.
set top [file dirname [file dirname [file normalize [info script]]]]
namespace eval ::kit { proc env {n {d ""}} { return $d } ; proc fail {c m} { error $m } }
namespace eval ::kit::net {}
set src [open $top/srcpkgs/ribbon-kit/files/lib/net.tcl r]; fconfigure $src -encoding utf-8; set text [read $src]; close $src
# only the one proc: net.tcl needs the rest of kit (kitfmt, tls) that a unit test of FilePath does not
regexp {proc ::kit::net::FilePath \{url\} \{.*?\n\}\n} $text body
eval $body
set fails 0
proc ok {what cond} { global fails; if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails } }
set pwn [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] kit-filepath-pwn-[pid]]
ok "a plain path"                         {[::kit::net::FilePath file:///srv/repo/kits/abc.kit] eq "/srv/repo/kits/abc.kit"}
ok "%20 and %25 decode"                   {[::kit::net::FilePath file:///srv/my%20repo/100%25] eq "/srv/my repo/100%"}
ok "%C3%A9 is one UTF-8 character"        {[::kit::net::FilePath file:///srv/caf%C3%A9] eq "/srv/café"}
ok "a % not followed by two hex digits stays" {[::kit::net::FilePath file:///srv/a%zz%4] eq "/srv/a%zz%4"}
set p [::kit::net::FilePath "file:///srv/repo/kits/\[file mkdir $pwn\]x.kit"]
ok "a \[command\] in the URL is text, not run" {![file exists $pwn] && $p eq "/srv/repo/kits/\[file mkdir $pwn\]x.kit"}
set p [::kit::net::FilePath "file:///srv/\$env(HOME)/\\x41"]
ok "\$variables and backslashes stay as they are" {$p eq "/srv/\$env(HOME)/\\x41"}
catch {file delete -force $pwn}
if {$fails} { exit 1 }
puts "all FilePath checks passed"
