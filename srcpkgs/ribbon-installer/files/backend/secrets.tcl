# secrets.tcl - the secrets dict on stdin (docs/INSTALLER-PROTOCOL.md:
# `password "..." passphrase "..."`) -> password NUL passphrase NUL on
# stdout, for ribbon-install --secrets-stdin to read with `read -d ''`.
# Nothing is written to disk.
fconfigure stdin -encoding utf-8
fconfigure stdout -encoding utf-8 -translation binary
set d [read stdin]
if {[catch {dict size $d}]} {
    puts stderr "ribbon-install: the secrets on stdin are not a Tcl dict"
    exit 1
}
foreach k {password passphrase} {
    set v ""
    if {[dict exists $d $k]} { set v [dict get $d $k] }
    if {[string first \0 $v] >= 0 || [string first \n $v] >= 0} {
        puts stderr "ribbon-install: the $k can't contain a NUL or a new line"
        exit 1
    }
    puts -nonewline "$v\0"
}
