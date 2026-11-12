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
# Replaced when LogicBase.tcl sources locale.tcl. A leftover stub means the
# native speller did not load; the phonetic assertions below then fail.
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
# locale.tcl spellWord lowercases the word and plays one Default clip per
# letter. PHONETIC_SPELLING defaults to 1, so the clip is phonetic_<letter>.
# This records that procedure. It is not an RF or end-of-communication result.
proc spelling_rows {call {phonetic 1}} {
	set call [string tolower $call]
	set rows {}
	for {set i 0} {$i < [string length $call]} {incr i} {
		set char [string index $call $i]
		if {![regexp {[a-z0-9]} $char]} {
			continue
		}
		if {$phonetic} {
			lappend rows [list playMsg Default phonetic_$char]
		} else {
			lappend rows [list playMsg Default $char]
		}
	}
	return $rows
}
proc default_spell_rows {} {
	set rows {}
	foreach row $::trace {
		if {[lindex $row 0] eq "playMsg" && [lindex $row 1] eq "Default"} {
			lappend rows $row
		}
	}
	return $rows
}
proc spelled {call {phonetic 1}} {
	if {[default_spell_rows] ne [spelling_rows $call $phonetic]} {
		return 0
	}
	return 1
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
if {[saw spellWord FIXTURE] || [spelled FIXTURE]} {
	fail "CW-only short identification also spelled the call sign"
}
puts "ok: 26.05 checkPeriodicIdentify plays FIXTURE/R on a 5 minute modulus"

# The next minute is not a multiple of 5.
set ::fake_now [_real_clock scan "2026-01-01 00:06:00" -gmt 1]
reset_trace
::Logic::checkPeriodicIdentify
if {[saw CW::play FIXTURE/R] || [saw spellWord FIXTURE] || [spelled FIXTURE]} {
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

# repeater_down is the upstream end-of-transmission handler. Calling it here
# does not close a receiver and is not an end-of-communication observation.
set ::fake_now [_real_clock scan "2026-01-01 00:20:00" -gmt 1]
reset_trace
::RepeaterLogic::repeater_down IDLE
if {![spelled FIXTURE]} {
	fail "repeater_down IDLE did not spell FIXTURE through locale.tcl"
}
if {![saw playMsg repeater] || ![saw playSilence 250]} {
	fail "repeater_down IDLE did not follow the call with the repeater clip and silence"
}
if {[spelled OTHER]} {
	fail "repeater_down IDLE spelled a substituted call sign"
}
puts "ok: 26.05 repeater_down IDLE spells the configured call sign as phonetic clips"

reset_trace
set ::Logic::prev_ident [expr {$::fake_now - 10}]
::RepeaterLogic::repeater_down IDLE
if {[spelled FIXTURE] || [saw spellWord FIXTURE]} {
	fail "repeater_down IDLE spelled the call sign inside the 120 second window"
}
if {![saw playTone 400] || ![saw playTone 360]} {
	fail "repeater_down IDLE did not play the courtesy tones inside 120 seconds"
}
puts "ok: 26.05 repeater_down IDLE uses courtesy tones inside 120 seconds"

reset_trace
set ::Logic::prev_ident 0
::RepeaterLogic::repeater_down SQL_FLAP_SUP
if {[spelled FIXTURE] || [saw spellWord FIXTURE] || [saw CW::play FIXTURE/R]} {
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
if {![spelled FIXTURE]} {
	fail "voice short identification did not spell FIXTURE through locale.tcl"
}
if {[saw CW::play FIXTURE/R]} {
	fail "voice short identification played CW"
}
if {[spelled OTHER] || [saw spellWord OTHER]} {
	fail "voice short identification spelled a substituted call sign"
}
puts "ok: 26.05 send_short_ident spells only the configured call sign when voice is enabled"

# The same speller uses plain letter clips when PHONETIC_SPELLING is 0.
set ::cfg(RepeaterLogic,PHONETIC_SPELLING) 0
set ::Logic::short_cw_id_enable 0
set ::Logic::short_voice_id_enable 1
reset_trace
::Logic::checkPeriodicIdentify
if {![spelled FIXTURE 0]} {
	fail "PHONETIC_SPELLING 0 did not spell FIXTURE as plain letters"
}
if {[spelled FIXTURE 1]} {
	fail "PHONETIC_SPELLING 0 still used phonetic clips"
}
puts "ok: 26.05 spellWord follows PHONETIC_SPELLING"
puts "svxlink 26.05 identification procedures passed"
