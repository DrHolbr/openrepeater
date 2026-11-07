# Stage 2 plan: bench UI on Debian Trixie

**Status: review fixes on this branch, not deployed.** Head `0dd447a` was blocked before any install. The parent later reported the bootstrap completed at 7:39:03 PM EST with SvxLink 26.05.2 and the radio units still masked. This revision was not copied to the Pi and is not native UI proof. Production is untouched. This change does not merge.

The user goal is to make the existing OpenRepeater web UI usable on the bench Raspberry Pi 3B+ (Raspberry Pi OS / Debian Trixie arm64, PHP 8.x, nginx, SvxLink 26.05.2) without transmitting and without disturbing the image that is already building.

## Decision

Keep this UI (the stage-1 Option A) and do not start the SvxLink 26 event-handler rewrite. The smallest change that makes the pages load, and that cannot key a radio or clobber the bootstrap, is:

1. PHP 8 fixes on the load path (`__autoload`, empty query results, the extra argument to `select_single`, Memcached missing).
2. A root-owned bench marker. On hostname `orp-test` the block stays on even if that file is removed. Preview paths are fixed; a `preview=` line is not trusted. The helper sudoers entry is an explicit read-only command list, and `alsa backup` cannot chown an arbitrary path.
3. A read-only GPIO name map. No libgpiod line is assigned and no output is driven.
4. An installer that refuses to run until the bootstrap says it is finished, then installs nginx and PHP 8 only.

Option B (replace the UI with SvxLink-Dash) and a merge of `3.0.x-DEV` were not taken. Stage 1 is the open draft https://github.com/DrHolbr/openrepeater/pull/2. Its docs are not in this branch. `trixie-test-stage2` was not on the remote; this branch is `cursor/trixie-test-stage2-57fc`.

## Falsifiable done criteria

These are the checks this branch can meet without the Pi:

1. `bash upgrade/tests/run.sh` exits 0. It runs `php -l` on every PHP file, the PHP safety script, the installer fixtures, and a local login-page render.
2. With the bench marker, `orp_helper` prints `refused:` and does not call `systemctl`, `service`, `shutdown`, `amixer`, `alsactl`, or the GPIO setup binary for `svxlink start|restart|enable|gpio_up`, `system restart|stop`, `set_mixer`, and `alsa restore`. `svxlink unmask` is refused with or without the marker.
3. With the marker, generated `svxlink.conf` and `gpio.conf` are written only under the preview directory. The preview has no active `PTT_` line, no active `SQL_DET=GPIO`, no `GPIO_PATH=/sys/class/gpio`, and no `gpio498` token in `gpio.conf`.
4. Without the marker, `configDestination('svxlink.conf')` is still `/etc/svxlink/svxlink.conf`, and the legacy GPIO writer still emits sysfs text.
5. The installer exits 2 before copying files when the hostname is not `orp-test`, exits 3 when `/var/lib/orp-test/complete` is missing or `orp-test-bootstrap.service` is `activating`, and on a matching fixture leaves the planted SvxLink binary, `/etc/svxlink/svxlink.conf`, the completion marker, and the build sentinel byte-for-byte unchanged.
6. The generated nginx site contains `unix:/run/php/php8.4-fpm.sock` and does not contain `php5-fpm`, `ssl on`, or `listen 443`.
7. GPIO classification matches the tables in [GPIO-MAP.md](GPIO-MAP.md): 26 is BCM 26 physical pin 37, 23 is BCM 23 physical pin 16, 498/499/506/507 have no physical pin and are not drivable.

Cloud run of criterion 1 on 2026-11-07: PHP 8.3.6, `php safety checks passed`, `shell checks passed`, login page rendered, `index.php` HTTP 200, `harness passed`.

## Data and config shapes

### Bench marker `/etc/openrepeater/bench-mode`

```
host=orp-test
radio=blocked
reboot=blocked
gpio=readonly
publish=preview
preview=/var/lib/openrepeater/bench-preview
```

The file's presence is not required on hostname `orp-test`: that hostname stays in bench mode even if the file is removed. A `preview=` line in the file is not a path. The only publish directory on the bench is `/var/lib/openrepeater/bench-preview`. `ORP_BENCH_PREVIEW` is honored only when `ORP_BENCH_TEST_HARNESS=1`, `/etc/hostname` is not `orp-test`, and `/etc/openrepeater/bench-mode` does not exist. The harness path must be exactly one `orp-preview-<token>` segment under the temp directory, with no symlink in the path.

### Paths

| Tree | Who writes it today | This stage |
| --- | --- | --- |
| `/usr/local/bin/svxlink`, `/usr/local/share/svxlink`, `/etc/svxlink` | Bootstrap CMake: prefix `/usr/local`, `SYSCONF_INSTALL_DIR=/etc` | Not modified |
| `/usr/share/svxlink/events.d/` and `/etc/svxlink/` | `SVXLink::write_config()` on an unmarked host | Unchanged when the marker is absent |
| `/etc/openrepeater/svxlink/` | `install/default/svxlink` (`CFGFILE` and `gpio.conf`) | Not used and not created by the installer |
| `/var/lib/openrepeater/bench-preview/` | Bench marker | Only publish destination while the marker exists |
| `/var/www/openrepeater` | Debian package postinst and this installer | UI files |
| `/run/php/php8.*-fpm.sock` | The PHP 8 FPM package | nginx `fastcgi_pass`. PHP 5 and PHP 7 sockets are rejected |

`install/nginx/openrepeater` is the legacy reference: `unix:/var/run/php5-fpm.sock`, `ssl on`, and an HTTP-to-HTTPS rewrite. The installer does not copy it. The site it writes is `upgrade/nginx/openrepeater.conf.template` after the socket name is substituted. It listens on port 80 for `server_name orp-test` and denies `/install/`, `/upgrade/`, dotfiles, and `*.db`.

### Database

`install/sql/openrepeater.db` (copied only when `/var/lib/openrepeater/db/openrepeater.db` is absent):

| Table | Columns used here |
| --- | --- |
| `settings` | `keyID`, `value` |
| `ports` | `portNum`, `portLabel`, `rxMode`, `rxGPIO`, `txGPIO`, `rxAudioDev`, `txAudioDev`, `rxGPIO_active`, `txGPIO_active` |
| `gpio_pins` | `gpio_num`, `direction`, `active`, `description`, `type` |
| `system_flags` | `keyID`, `value` (UI rebuild flag when Memcached is absent) |
| `users` | existing account row; this branch adds no password |
| `version_info` | `version_num` (stock row reads `2.1.0`) |
| `modules` | left as stored; not enabled or started |

The stock `ports` row is RX 26 active low and TX 506 active high. The ICS 2X 3.1+ preset in `board_definitions.php` says TX 498. See [GPIO-MAP.md](GPIO-MAP.md). Sample module option blobs in that database are not station credentials and are not copied into this document.

### GPIO report row

`source`, `manufacturer`, `model`, `version`, `port`, `logical_name`, `stored_number`, `direction`, `preset_active`, `class`, `bcm`, `physical_pin`, `libgpiod_chip`, `libgpiod_offset`, `drivable`, `note`. `drivable` is false. Chip and offset are null.

## Harness

`upgrade/tests/run.sh` is the cloud harness. It does not contact the bench.

- `php -l` across the tree.
- `upgrade/tests/php_safety_test.php` for the marker, publish paths, disarmed config text, GPIO classes, the stock database, and the module link path.
- `upgrade/tests/install_and_helper_test.sh` for installer refusals, sentinel preservation, nginx text, idempotent database copy, and helper refusals. `ORP_INSTALL_OFFLINE=1` skips apt and uses a fake `systemctl`.
- PHP's built-in server renders `login.php`. That is not nginx and not the Pi.

## Phases and the checkpoint

| Phase | What landed | How it was checked |
| --- | --- | --- |
| 0 | Done criteria, shapes, this plan | Review against the repo and the 7:29 PM bench note |
| 1 | `BenchGuard`, helper refusals, publish redirect, rebuild/reboot UI block | PHP and shell tests above |
| 2 | PHP 8 autoload, empty selects, `select_single` arity, SQLite flag when Memcached is missing | `php -l`, database test, login render |
| 3 | `GpioMap`, read-only `gpio.php`, empty bench `gpio.conf` | Classification tests |
| 4 | `upgrade/install-orp-ui.sh` | Fixture installer |

**Checkpoint, held:** do not port `SVXLink_TCL` to the 26.05 `override` / `$SUPER` layout, do not write `/etc/svxlink` or `/usr/local/share/svxlink`, and do not rebuild SvxLink with libgpiod. Those are later steps, after the parent has a finished binary, a clean `svxlink --version`, and an explicit decision to publish config. The tests fail if a bench publish lands in the live trees or if a PTT line stays active in the preview.

## Decision trail

1. **Bench identity.** The 7:29 PM note names hostname `orp-test`, Debian 13.7 Trixie, `aarch64`, guard `/etc/orp-test-image`, state directory `/var/lib/orp-test`, completion file `/var/lib/orp-test/complete`. The installer requires all of those. A fixture with hostname `pi` exits 2 and creates no web root.
2. **Do not touch the running build.** At that snapshot the oneshot was activating, the log was at 79% in `MsgHandler.cpp.o`, the completion file and `/usr/local/bin/svxlink` were absent, and `svxlink`, `remotetrx`, and `svxreflector` were masked and inactive. The installer exits 3 when the marker is missing or the bootstrap unit is `active` or `activating`. It does not stop the timer, does not delete `build.swap`, and hashes the bootstrap paths before and after.
3. **SvxLink GPIO was compiled out.** CMake is invoked with `CMAKE_DISABLE_FIND_PACKAGE_GPIOD=TRUE`. Publishing `SQL_DET=GPIOD` into that binary's config would not be a working port, and rebuilding SvxLink would replace bootstrap artifacts. Diagnostics use `gpioinfo` only, after the separate `gpiod` package is installed. The UI never calls `gpioset` or `gpioget`.
4. **Three config trees already disagree.** Class writers use `/etc/svxlink` and `/usr/share/svxlink`. `install/default/svxlink` uses `/etc/openrepeater/svxlink`. The bootstrap install uses `/etc/svxlink` and `/usr/local/share/svxlink`. Bench mode writes to the preview directory instead of picking one of those trees and overwriting it.
5. **Legacy nginx is not deployable.** `install/nginx/openrepeater` points at the PHP 5 socket and turns on the old `ssl on` directive. The new site is HTTP on port 80, PHP 8 only, with the database paths denied. TLS and the public name stay off this card.
6. **PHP 8 load failures are specific.** `__autoload()` is gone in PHP 8, so every page died before a class loaded. `get_settings($key)` called `select_single` with two extra arguments, which PHP 8 rejects. `select_all` / `select_key_value` returned an undefined variable on zero rows, and `foreach` of that is a `TypeError`. `new Memcached` fatals when the extension is absent; the rebuild flag then uses `system_flags`. `3.0.x-DEV` was not merged. Its Database diff is hundreds of lines and is a different product line.
7. **TX numbers disagree, so none are driven.** Preset 498/499, database 506, and the ICS manual's PTT 506 / GPA2 498 are all recorded in [GPIO-MAP.md](GPIO-MAP.md). Active level for COS is a preset value; the ICS manual also says the board switch selects COS polarity. No switch was read. Default is disconnected.
8. **Rebuild stays in the database.** `functions/svxlink_update.php` returns before it reads `RepeaterLogic.tcl`, deletes `ORP_*` files, or calls `orp_helper`. The update flag is left set so the bar does not pretend a restart happened. Reboot and shutdown buttons are disabled in the page, and the helper still refuses the commands.
9. **Private modules stay private.** `DrHolbr/openrepeater-modules` pull request 1 is already merged there. This public tree still gitignores everything under `modules/` except Help, Parrot, and EchoLink. Those private trees were not readable here and were not vendored. Their TCL against SvxLink 26.05.2 is untested. The installer does not clone that repository.
10. **Packages.** After the marker exists, apt installs only `nginx`, `php-fpm`, `php-cli`, `php-sqlite3`, `gpiod`, `sudo`, and `sqlite3`, with `--no-install-recommends --no-upgrade`. No dist-upgrade. No second SvxLink package. The bootstrap's cmake, gcc, and `libgpiod3` are left at the versions already installed.

## Install, after the parent confirms bootstrap completion

Prerequisites on the Pi, checked by the script itself:

- root
- `/etc/hostname` and the live hostname are `orp-test`
- `uname -m` is `aarch64`
- `/etc/os-release` has `VERSION_ID=13` and `VERSION_CODENAME=trixie`
- `/etc/orp-test-image` exists
- `/var/lib/orp-test/complete` exists
- `orp-test-bootstrap.service` is not `active` or `activating`
- `svxlink.service`, `remotetrx.service`, and `svxreflector.service` are masked
- at least 512 MiB free
- the bootstrap timer is left enabled

From a checkout of this branch:

```bash
sudo bash upgrade/install-orp-ui.sh
```

The script is safe to run again. It backs up an existing web root, nginx site, `/etc/openrepeater`, helper, sudoers fragment, and `/var/lib/openrepeater` under `/var/backups/orp-ui/<timestamp>/` before replacing UI files. It does not replace an existing `openrepeater.db`.

Rollback stops the web UI and leaves the bench safety marker in place. Do not delete `/etc/openrepeater/bench-mode`. That file is what keeps publish, reboot, and radio start blocked. It is root-owned; the web user cannot remove it.

```bash
sudo systemctl disable --now nginx php8.4-fpm
sudo cp -a /var/backups/orp-ui/<timestamp>/var/www/openrepeater /var/www/openrepeater
sudo cp -a /var/backups/orp-ui/<timestamp>/etc/nginx/sites-available/openrepeater /etc/nginx/sites-available/openrepeater
sudo rm -f /etc/nginx/sites-enabled/openrepeater
# keep /etc/openrepeater/bench-mode
# do not unmask svxlink, remotetrx, or svxreflector
# do not delete /var/lib/orp-test or /usr/local/bin/svxlink
test -f /etc/openrepeater/bench-mode && echo "bench marker still present"
```

Confirm afterward:

```bash
systemctl is-enabled svxlink.service remotetrx.service svxreflector.service
systemctl is-active svxlink.service remotetrx.service svxreflector.service
test -f /var/lib/orp-test/complete && echo complete
```

Expected enablement is `masked` and activity is `inactive`. If a unit is not masked, stop and restore the mask. Do not start it.

## Files to fetch for the bench

- This branch, then `upgrade/install-orp-ui.sh` (it copies the rest of the tree).
- `docs/PLAN.md` and `docs/GPIO-MAP.md` for the gate and the pin names.
- Do not fetch a second copy of SvxLink, do not copy `/usr/local` off the Pi, and do not copy private module trees into this checkout.

## Threat model

The installer runs as root. The web server runs as `www-data`. A previous install, or the web process itself, may have planted a symbolic link or may still be able to replace a directory entry.

Experiment on a disposable fixture, not the Pi: `test -f` on a symlink is true, so a "copy only if missing" check skips the copy. `chmod` of that symlink changes the target's mode (`600` became `640`). A shell redirect through the symlink overwrites the target's bytes. If an ancestor is a symlink, the final component is an ordinary file inside the other tree, so a leaf-only `-L` check does not see it, and `chmod` still changes that file. Replacing the path with a symlink after a passed check and then calling `chmod` changes the canary as well. `chown -h` does not. The premise "inspect a path inside a www-data-writable tree, then chmod or chown it" is false.

Privileged mutation is allowed only for a direct child of a trust anchor: a real directory owned by the installer and not writable by group or other. The walk starts at `/` on the bench and at the fixture root in the cloud harness. A symlink aborts the install and is not followed. A directory is tightened to mode `755` only after its parent is already an anchor, which is what stops a swap. The web tree is replaced as a directory inode; it is not `chown -R`'d. The database file stays root-owned. Its directory is mode `1770` only after that inode exists, so `www-data` can create SQLite journals and cannot replace the database file. Test-only path overrides do not work when `/etc/hostname` is `orp-test` or the real marker exists.

| Path | Owner | Mode | Who may write | Installer may mutate it |
| --- | --- | --- | --- | --- |
| `/etc/openrepeater` | root | `755` | root | Yes, it is an anchor |
| `/etc/openrepeater/bench-mode` | root | `644` | root | Yes, parent is an anchor |
| `/var/lib/openrepeater` | root | `755` | root | Yes |
| `/var/lib/openrepeater/bench-preview` | root | `1770` | root, plus new files by `www-data` | Directory inode only, after it is a real child of an anchor. `www-data` creates and replaces its own preview files. Root does not chown those files. A failed write returns false |
| `/var/lib/openrepeater/db` | root | `1770` | root, plus new files by `www-data` | Tighten to `755` before touching the database file, then restore `1770` |
| `/var/lib/openrepeater/db/openrepeater.db` | root | `660` | root and the `www-data` group | Only when it is a regular file and the directory is an anchor |
| `/var/www/openrepeater` | `www-data` after publish | `755` | owner of the new inode | Replace the directory from `/var/www`. Do not walk a previous tree |
| `/etc/svxlink`, `/usr/local`, `/var/lib/orp-test` | bootstrap | unchanged | not this installer | No |

## Review fixes after 0dd447a

1. `/etc/openrepeater` and `bench-mode` stay root-owned and mode `755` / `644`. The web tree is the only tree given to `www-data`. `preview=` in the marker is ignored. The only preview paths accepted are `/var/lib/openrepeater/bench-preview` and a test directory under the system temp dir named `orp-preview-*`. A symlink is not a publish target. Hostname `orp-test` stays in bench mode if the marker file is removed.
2. sudoers names each read-only helper command. It does not allow the helper with arbitrary arguments, `alsa`, `set_mixer`, or `svxlink start`. `alsa backup` accepts only the two fixed state-file paths, refuses symlinks, and does not `chown` when `alsactl` fails. Bench mode returns before either command.
3. Login selects `userID` (SQLite keeps the case in the query). A wrong password and an unknown user both redirect to `incorrectLogin` and do not open `gpio.php`. A matching password sets `userID` and can open the GPIO page and the dashboard.
4. The marker is written before the web tree. Package installs use `policy-rc.d` so apt does not start nginx. `nginx -t` runs while nginx is stopped. A failed test removes the site symlink, does not enable nginx, and leaves the marker. Rollback in this document no longer deletes `bench-mode`.

## What was not verified

These need the parent, on the Pi, after review:

- Bootstrap actually reached `/var/lib/orp-test/complete` and `svxlink --version` is 26.05.2. The 7:29 PM sample was still at 79%.
- `ldd` on `/usr/local/bin/svxlink` and whether libgpiod is absent, as the CMake flag predicts.
- The three units are still masked after the real installer.
- nginx and PHP 8.4 FPM start, `nginx -t` passes, and `http://orp-test/` shows the login page. Cloud used PHP 8.3.6 and the built-in server, not nginx and not PHP 8.4.
- Login in a browser, a settings save, and the blocked Rebuild button. No account password is documented here.
- `gpioinfo` text, chip names, and line offsets. No pin was read.
- COS polarity switch position, audio devices, and anything involving RF. Not run, and the UI is not allowed to run them.
- SvxLink 26.05 TCL inheritance, EchoLink, AlertMode, NetMode, and DVR. Not ported. Private module sources were not available in this environment.
- Wi-Fi, WireGuard, and the public hostname. Left down.

## Unavailable in this environment

- The bench LAN and any production host. Not contacted.
- `/workspace/orp-test-image` and `/workspace/orp-test-stage2` from the bench note. They are not in this checkout. The bootstrap contract used here is the parent's written snapshot, not a re-read of that script.
- `DrHolbr/openrepeater-modules` contents.
- A PHP 8.4 binary. Lint and the login render used PHP 8.3.6. The installer still asks the Pi for a `php8*-fpm` socket and rejects PHP 5 and PHP 7.
- `nginx -t` and `gpioinfo` on real hardware.
