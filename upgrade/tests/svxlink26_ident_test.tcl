# Execute the pinned SvxLink 26.05 identification procedures.
# Audio primitives are recorded. The procedures themselves are the upstream files.
# This is not a transmission and it does not claim a legal result.

set fixture [lindex $argv 0]
set ::svx26 $fixture
set ::logic_name RepeaterLogic
set ::logic_type Repeater
set ::mycall FIXTURE
set ::loaded_modules ""
set ::active_module ""
set ::report_ctcss 0
set ::trace {}

array set ::cfg {
	RepeaterLogic,SHORT_IDENT_INTERVAL 5
	RepeaterLogic,LONG_IDENT_INTERVAL 0
	RepeaterLogic,IDENT_ONLY_AFTER_TX 0
	RepeaterLogic,SHORT_VOICE_ID_ENABLE 0
	RepeaterLogic,SHORT_CW_ID_ENABLE 1
	RepeaterLogic,SHORT_ANNOUNCE_ENABLE 0
	RepeaterLogic,LONG_VOICE_ID_ENABLE 0
	RepeaterLogic,LONG_CW_ID_ENABLE 0
	RepeaterLogic,LONG_ANNOUNCE_ENABLE 0
	RepeaterLogic,CW_WPM 20
	RepeaterLogic,CW_PITCH 600
	RepeaterLogic,CW_AMP -6
}

proc getConfigValue {section key default} {
	set name ${section},${key}
	if {[info exists ::cfg($name)]} {
		return $::cfg($name)
	}
	return $default
}
proc sourceTclWithOverrides {name} {
	set path [file join $::svx26 $name]
	if {[file exists $path]} {
		source $path
	}
}
proc sourceTcl {path} {source $path}
# SvxLink's binary provides mixin. It links the named namespace's variables
# into the logic namespace so "variable Logic::prev_ident" is ::Logic::prev_ident.
proc mixin {ns} {
	set dest [uplevel 1 {namespace current}]
	namespace eval ${dest}::${ns} {}
	foreach v [info vars ::${ns}::*] {
		set tail [namespace tail $v]
		namespace upvar ::${ns} $tail ${dest}::${ns}::$tail
	}
}
proc printInfo {msg} {lappend ::trace [list info $msg]}
proc printWarning {msg} {lappend ::trace [list warning $msg]}
proc spellWord {word} {lappend ::trace [list spellWord $word]}
proc playMsg {args} {lappend ::trace [list playMsg {*}$args]}
proc playSilence {ms} {lappend ::trace [list playSilence $ms]}
proc playTone {args} {lappend ::trace [list playTone {*}$args]}
proc playTime {hour minute} {lappend ::trace [list playTime $hour $minute]}
proc playFile {path} {lappend ::trace [list playFile $path]}

source [file join $fixture Logic.tcl]
source [file join $fixture RepeaterLogicType.tcl]

rename ::CW::play ::CW::_real_play
proc ::CW::play {args} {
	lappend ::trace [list CW::play {*}$args]
}

rename clock _real_clock
set ::fake_now 0
proc clock {args} {
	set cmd [lindex $args 0]
	if {$cmd eq "seconds"} {
		return $::fake_now
	}
	if {$cmd eq "format"} {
		return [_real_clock format $::fake_now {*}[lrange $args 2 end]]
	}
	return [_real_clock {*}$args]
}

proc fail {msg} {
	puts stderr "FAIL: $msg"
	puts stderr $::trace
	exit 1
}
proc saw {kind value} {
	foreach row $::trace {
		if {[lindex $row 0] eq $kind && [lindex $row 1] eq $value} {
			return 1
		}
	}
	return 0
}
proc reset_trace {} {
	set ::trace {}
	set ::Logic::prev_ident 0
	set ::Logic::need_ident 0
}

# 00:05 UTC. (0*60+5) % 5 == 0, so the 26.05 modulus selects a short identification.
set ::fake_now [_real_clock scan "2026-01-01 00:05:00" -gmt 1]
reset_trace
::Logic::checkPeriodicIdentify
if {![saw CW::play FIXTURE/R]} {
	fail "periodic short CW identification did not play FIXTURE/R"
}
if {[saw spellWord FIXTURE]} {
	fail "CW-only short identification also spelled the call sign"
}
puts "ok: 26.05 checkPeriodicIdentify plays FIXTURE/R on a 5 minute modulus"

# The next minute is not a multiple of 5.
set ::fake_now [_real_clock scan "2026-01-01 00:06:00" -gmt 1]
reset_trace
::Logic::checkPeriodicIdentify
if {[saw CW::play FIXTURE/R] || [saw spellWord FIXTURE]} {
	fail "checkPeriodicIdentify identified on a minute the modulus does not select"
}
puts "ok: 26.05 checkPeriodicIdentify stays quiet one minute later"

# Fewer than 120 seconds since the previous identification.
set ::fake_now [_real_clock scan "2026-01-01 00:10:00" -gmt 1]
reset_trace
set ::Logic::prev_ident [expr {$::fake_now - 30}]
::Logic::checkPeriodicIdentify
if {[saw CW::play FIXTURE/R]} {
	fail "the 120 second minimum did not suppress the short identification"
}
puts "ok: 26.05 checkPeriodicIdentify waits 120 seconds between short identifications"

# IDENT_ONLY_AFTER_TX and need_ident are the variables the procedure reads.
set ::Logic::ident_only_after_tx 1
set ::Logic::need_ident 0
reset_trace
set ::Logic::ident_only_after_tx 1
set ::Logic::need_ident 0
::Logic::checkPeriodicIdentify
if {[saw CW::play FIXTURE/R]} {
	fail "ident_only_after_tx did not suppress a short identification when need_ident is 0"
}
set ::Logic::need_ident 1
set ::trace {}
::Logic::checkPeriodicIdentify
if {![saw CW::play FIXTURE/R]} {
	fail "ident_only_after_tx suppressed a short identification after need_ident was set"
}
puts "ok: 26.05 ident_only_after_tx follows need_ident and does not convert the interval to seconds"
set ::Logic::ident_only_after_tx 0

# End of a communication is repeater_down, not the periodic procedure.
set ::fake_now [_real_clock scan "2026-01-01 00:20:00" -gmt 1]
reset_trace
::RepeaterLogic::repeater_down IDLE
if {![saw spellWord FIXTURE]} {
	fail "repeater_down IDLE did not spell FIXTURE"
}
puts "ok: 26.05 repeater_down IDLE spells the configured call sign"

reset_trace
set ::Logic::prev_ident [expr {$::fake_now - 10}]
::RepeaterLogic::repeater_down IDLE
if {[saw spellWord FIXTURE]} {
	fail "repeater_down IDLE spelled the call sign inside the 120 second window"
}
puts "ok: 26.05 repeater_down IDLE uses courtesy tones inside 120 seconds"

reset_trace
set ::Logic::prev_ident 0
::RepeaterLogic::repeater_down SQL_FLAP_SUP
if {[saw spellWord FIXTURE] || [saw CW::play FIXTURE/R]} {
	fail "SQL_FLAP_SUP identified the station"
}
if {![saw playMsg interference]} {
	fail "SQL_FLAP_SUP did not play the interference message"
}
puts "ok: 26.05 repeater_down SQL_FLAP_SUP does not spell the call sign"

# Voice enable is the other stock path. CW stays off.
set ::Logic::short_cw_id_enable 0
set ::Logic::short_voice_id_enable 1
set ::fake_now [_real_clock scan "2026-01-01 00:25:00" -gmt 1]
reset_trace
::Logic::checkPeriodicIdentify
if {![saw spellWord FIXTURE]} {
	fail "voice short identification did not spell FIXTURE"
}
if {[saw CW::play FIXTURE/R]} {
	fail "voice short identification played CW"
}
if {[saw spellWord OTHER]} {
	fail "voice short identification spelled a substituted call sign"
}
puts "ok: 26.05 send_short_ident spells only the configured call sign when voice is enabled"
puts "svxlink 26.05 identification procedures passed"
