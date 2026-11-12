#!/bin/bash
# Fixture for the orp-test source install: /usr/local, no vendor unit,
# and administrative masks pointing at /dev/null.

plant_native_layout() {
	local root=$1 file
	install -d -m 0755 \
		"$root" \
		"$root/usr/local/bin" \
		"$root/usr/local/lib/svxlink" \
		"$root/usr/local/share/svxlink/events.d" \
		"$root/usr/local/share/svxlink/sounds" \
		"$root/etc/svxlink" \
		"$root/etc/systemd/system" \
		"$root/var/lib" \
		"$root/var/spool" \
		"$root/var/log"
	if [ ! -f "$root/usr/local/bin/svxlink" ]; then
		printf 'bin\n' > "$root/usr/local/bin/svxlink"
	fi
	chmod 755 "$root/usr/local/bin/svxlink"
	for file in RepeaterLogic.so SimplexLogic.so DummyLogic.so; do
		printf 'plugin\n' > "$root/usr/local/lib/svxlink/$file"
		chmod 644 "$root/usr/local/lib/svxlink/$file"
	done
	printf 'events\n' > "$root/usr/local/share/svxlink/events.tcl"
	chmod 644 "$root/usr/local/share/svxlink/events.tcl"
	for file in globals.tcl squelch_timeout.tcl Module.tcl CW.tcl SelCall.tcl locale.tcl \
		LogicBase.tcl Logic.tcl SimplexLogicType.tcl RepeaterLogicType.tcl \
		ReflectorLogicType.tcl ReflectorV2LogicType.tcl SimplexLogic.tcl \
		RepeaterLogic.tcl ReflectorLogic.tcl
	do
		printf 'tcl\n' > "$root/usr/local/share/svxlink/events.d/$file"
		chmod 644 "$root/usr/local/share/svxlink/events.d/$file"
	done
	chmod 755 "$root/usr/local/lib" "$root/usr/local/lib/svxlink" \
		"$root/usr/local/share" "$root/usr/local/share/svxlink" \
		"$root/usr/local/share/svxlink/events.d" \
		"$root/usr/local/share/svxlink/sounds" \
		"$root/etc" "$root/etc/svxlink" "$root/etc/systemd" "$root/etc/systemd/system"
	for file in svxlink.service remotetrx.service svxreflector.service; do
		ln -sfn /dev/null "$root/etc/systemd/system/$file"
	done
	touch "$root/etc/passwd" "$root/etc/group"
	if ! grep -q '^svxlink:' "$root/etc/group"; then
		printf '%s\n' 'svxlink:x:200:' >> "$root/etc/group"
	fi
	if ! grep -q '^svxlink:' "$root/etc/passwd"; then
		printf '%s\n' 'svxlink:x:200:200::/var/lib/svxlink:/usr/sbin/nologin' >> "$root/etc/passwd"
	fi
}

# Stored identification the disconnected runtime is allowed to copy.
# Morse at 20 WPM, short interval 5, long identification disabled.
apply_ident_profile() {
	local db=$1
	sqlite3 "$db" "
UPDATE settings SET value='morse' WHERE keyID='ID_Short_Mode';
UPDATE settings SET value='5' WHERE keyID='ID_Short_IntervalMin';
UPDATE settings SET value='False' WHERE keyID='ID_Short_AppendMorse';
UPDATE settings SET value='False' WHERE keyID='ID_Short_IdentOnlyAfterTX';
UPDATE settings SET value='disabled' WHERE keyID='ID_Long_Mode';
UPDATE settings SET value='20' WHERE keyID='ID_Morse_WPM';
UPDATE settings SET value='600' WHERE keyID='ID_Morse_Pitch';
"
}
