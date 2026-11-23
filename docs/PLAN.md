# OpenRepeater UI on the source-built SvxLink host

There is no bench mode and no functional-test mode. The UI rebuild reads the database and writes the repeater configuration to `/etc/svxlink` and the SvxLink share tree, then runs GPIO setup from the stored wiring and restarts svxlink. That is the same publish path as stock OpenRepeater 2.1.3.

## What a rebuild does

1. `functions/svxlink_update.php` builds `svxlink.conf`, `gpio.conf`, and the logic files from the stored settings, ports, modules, identification, and courtesy tone.
2. Receiver squelch and transmitter PTT come from the stored port rows. A COS port writes `SQL_DET=GPIO` and `GPIO_SQL_PIN`. A GPIO transmitter writes `PTT_TYPE=GPIO` and `PTT_PIN`. The rebuild does not replace those with `PTT_TYPE=NONE` or strip the GPIO lists.
3. Each file keeps its own destination. `svxlink.conf` and `gpio.conf` are separate files under `/etc/svxlink`.
4. GPIO setup runs `/usr/sbin/svxlink_gpio_down` and then `/usr/sbin/svxlink_gpio_up`. The helper executes those binaries. It does not source them. A missing file, a symlink, a non-executable, or a file not owned by root is refused, and the binary's exit code is returned.
5. svxlink is then restarted. Enable, start, stop, and restart are accepted. Host reboot, host shutdown, and host halt are separate helper verbs. The dashboard reboot and shutdown buttons send those verbs only after an authenticated POST whose Origin and CSRF token match. A test harness prints the verdict and does not execute `shutdown` or `halt`.

## What stays

- The helper allowlist is closed. www-data can run the named commands in sudoers and cannot pass an arbitrary argument.
- Config paths reject `..` and a symlink component. A write uses a temp file in the destination directory and rename.
- `events.d`, `events.d/local`, and `Logic.tcl` are checked for owner and file type before a courtesy or ident publish replaces them.
- Courtesy and identification clip bodies reject `$`, backticks, and `[`. A selected stock or uploaded WAV is copied into the share tree the logic file names.
- Zip upload, backup restore, and module install stay inside their parent directories and do not follow symlinks.
- The installer removes old bench files when they are present: `/etc/openrepeater/bench-mode`, `/etc/openrepeater/operating-mode`, `/etc/openrepeater/tx-armed`, `/var/lib/openrepeater/bench-preview`, and `/etc/svxlink/functional-test.d`. It does not create them. It does not mask or unmask a unit. An existing `/dev/null` mask is left in place, and the installer prints `kept existing mask`. Staged companion files, when present, are read from `/var/lib/openrepeater/staged`. The helper does not recognize a bench-mode file or a functional-test token.
- Test runs set `ORP_BENCH_TEST_HARNESS=1` and `ORP_ROOT` so a fixture is prefixed. That is process isolation for the suite. It is not an operating mode, and the installed UI does not set it.

## Installed build

`720b6ba` is the installed build. Later commits on this branch are not installed. `5177405` is not an install candidate. Mixer hardware has not been retested on the Pi. Cloud and x86 test results are not Pi results.
