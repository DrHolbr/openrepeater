# Source the pinned SvxLink 26.05 Logic.tcl, then the rendered local override.
# Audio primitives are recorded. This does not start svxlink and is not RF.

set basedir [lindex $argv 0]
set mode [lindex $argv 1]
set ::basedir $basedir
set ::logic_name RepeaterLogic
set ::logic_type Repeater
set ::mycall FIXTURE
set ::loaded_modules ""
set ::active_module ""
set ::trace {}

namespace eval :: {
variable overridden_cnt 0

proc sourceTclWithOverrides {filename} {
	set found 0
	foreach path [list \
		[file join $::basedir events.d $filename] \
		[file join $::basedir events.d local $filename]] {
		if {[file readable $path]} {
			uplevel 1 [list source $path]
			set found 1
		}
	}
	if {!$found} {
		error "Could not source TCL file '$filename'"
	}
}
proc mixin {ns} {
	set ns "[uplevel namespace current]::${ns}"
	foreach var [uplevel namespace eval ${ns} info vars ${ns}::*] {
		set varname [namespace tail ${var}]
		uplevel namespace upvar ${ns} ${varname} ${varname}
	}
	uplevel namespace eval $ns namespace export *
	uplevel namespace import -force ${ns}::*
	set path [list {*}[uplevel namespace path] $ns]
	uplevel namespace path [list $path]
}
proc override {pliteral pname pargs pbody} {
	variable overridden_cnt
	if {$pliteral ne "proc"} {
		error "missing proc literal"
	}
	if {[llength [uplevel info procs $pname]] == 0} {
		error "no '$pname' procedure"
	}
	set super_name overridden_[incr overridden_cnt]_$pname
	set decl "
		rename $pname $super_name
		proc $pname {$pargs} {
			set SUPER $super_name
			$pbody
		}"
	eval uplevel {$decl}
}
}

proc getConfigValue {section key default} {
	set name ${section},${key}
	if {[info exists ::cfg($name)]} {
		return $::cfg($name)
	}
	return $default
}
proc printInfo {msg} {}
proc printWarning {msg} {}
proc playMsg {args} {lappend ::trace [list playMsg {*}$args]}
proc playSilence {ms} {lappend ::trace [list playSilence $ms]}
proc playTone {freq dur amp} {lappend ::trace [list playTone $freq $dur $amp]}
proc playFile {path} {lappend ::trace [list playFile $path]}
proc spellWord {word} {lappend ::trace [list spellWord $word]}

sourceTclWithOverrides RepeaterLogicType.tcl

proc fail {msg} {
	puts stderr "FAIL: $msg"
	puts stderr $::trace
	exit 1
}
proc saw {args} {
	set want $args
	foreach row $::trace {
		if {$row eq $want} {
			return 1
		}
	}
	return 0
}
proc saw_kind {kind} {
	foreach row $::trace {
		if {[lindex $row 0] eq $kind} {
			return 1
		}
	}
	return 0
}

set ::RepeaterLogic::Logic::sql_rx_id "?"
set ::trace {}
::RepeaterLogic::send_rgr_sound

if {$mode eq "default"} {
	if {![saw playTone 440 500 100] || ![saw playSilence 100]} {
		fail "default send_rgr_sound did not play the upstream 440 Hz tone"
	}
	if {[saw playTone 660 500 200]} {
		fail "default send_rgr_sound played the beep override"
	}
} elseif {$mode eq "beep"} {
	if {![saw playTone 660 500 200] || ![saw playSilence 200]} {
		fail "beep send_rgr_sound did not play 660 Hz"
	}
	if {[saw playTone 440 500 100]} {
		fail "beep send_rgr_sound still played the upstream 440 Hz tone"
	}
} elseif {$mode eq "disabled"} {
	if {[saw_kind playTone]} {
		fail "disabled send_rgr_sound played a tone"
	}
	if {![saw playSilence 100]} {
		fail "disabled send_rgr_sound did not play silence"
	}
} else {
	fail "unknown courtesy mode $mode"
}
if {[saw_kind playFile]} {
	fail "send_rgr_sound played a file"
}

# The 120 second repeater_down path stays the upstream courtesy tones.
set ::trace {}
set ::RepeaterLogic::Logic::prev_ident [expr {[clock seconds] - 10}]
::RepeaterLogic::repeater_down IDLE
if {![saw playTone 400 900 50] || ![saw playTone 360 900 50]} {
	fail "repeater_down inside 120 seconds did not keep the upstream tones"
}
if {[saw playTone 660 500 200]} {
	fail "repeater_down inside 120 seconds used the beep override"
}
puts "ok: 26.05 $mode send_rgr_sound and the 120 second repeater_down path"
