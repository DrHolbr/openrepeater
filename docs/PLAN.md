# Stage 2 plan: bench UI on Debian Trixie

**Status: `04d7dbe15ac2832b27c600e69eb094027bfaf611` is installed on orp-test.** It was installed 1:58–2:01 AM EST on November 10, 2026, through `upgrade/install-orp-ui.sh`. svxlink was masked for that install and then returned to inactive and disabled. `remotetrx` and `svxreflector` were not left running. The rollback tree is `/var/backups/orp-rollback-143d5e7-04d7dbe`. The Pi has `php8.4-zip` `8.4.27-1~deb13u1`, `libzip5`, and `nodejs` `20.19.2`. `run.sh` passed natively at this commit, which supersedes the unfinished native run of `78112bf`. The earlier `143d5e7` page pass is the previous installed tree, not the current one. Production is untouched. This change does not merge.

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
6. **PHP 8 load failures are specific.** `__autoload()` is gone in PHP 8, so every page died before a class loaded. `get_settings($key)` called `select_single` with two extra arguments, which PHP 8 rejects. `select_all` / `select_key_value` returned an undefined variable on zero rows, and `foreach` of that is a `TypeError`. `class_exists('Memcached')` autoloads, and the old autoloader died with `File Not Found: .../Memcached.php` when the extension was absent. The probe no longer autoloads. The rebuild flag uses `system_flags`. A missing OpenRepeater class still errors when instantiated. `3.0.x-DEV` was not merged. Its Database diff is hundreds of lines and is a different product line.
7. **TX numbers disagree, so none are driven.** Preset 498/499, database 506, and the ICS manual's PTT 506 / GPA2 498 are all recorded in [GPIO-MAP.md](GPIO-MAP.md). Active level for COS is a preset value; the ICS manual also says the board switch selects COS polarity. No switch was read. Default is disconnected.
8. **Rebuild does not start the radio on the bench.** `functions/svxlink_update.php` builds the preview files and then redirects. It does not call `orp_helper` for GPIO or a restart when the host is in bench mode or the preview write failed. Reboot and shutdown buttons are disabled in the page, and the helper still refuses those commands. Live `/etc/svxlink` and `/usr/share/svxlink` are not the publish target.
9. **Private modules stay private.** `DrHolbr/openrepeater-modules` pull request 1 is already merged there. This public tree still gitignores everything under `modules/` except Help, Parrot, and EchoLink. Those private trees were not readable here and were not vendored. Their TCL against SvxLink 26.05.2 is untested. The installer does not clone that repository.
10. **Packages.** After the marker exists, apt installs `nginx`, `gpiod`, `sudo`, and `sqlite3` with `--no-install-recommends --no-upgrade`. PHP is separate: `php8.4-fpm`, `php8.4-cli`, `php8.4-common`, `php8.4-sqlite3`, `php8.4-opcache`, and `php8.4-zip`, and only when the candidate origin is Debian `trixie` or `trixie-security`. No `php-memcached`. No dist-upgrade. No PHP repository outside Debian. No second SvxLink package. The bootstrap's cmake, gcc, and `libgpiod3` are left at the versions already installed. An existing `openrepeater.db` is not replaced.
11. **Identification publish rules cite SvxLink 26.05 where they accept a setting, and cite 97.119 where they refuse one SvxLink would still load.** `IDENT_ONLY_AFTER_TX=1` is published. In `Logic.tcl` from the 26.05 tag, `checkPeriodicIdentify` keeps `SHORT_IDENT_INTERVAL` as a minute modulus and skips `send_short_ident` only when `ident_only_after_tx` is set and `need_ident` is 0. The man page sentence that the interval becomes seconds is not that procedure, so minutes are not rewritten. An interval above 10 minutes is refused by this project, with that distinction stated in the error, and the stored number is left alone. Multiplying the configured minutes by 60 is not a SvxLink event trace. End-of-communication identification and spoken English call-sign audio are unverified. A shutdown command is not evidence the transmitter unkeyed. Opening General Settings inserts missing `rxCtcssOpenThresh`, `rxCtcssCloseThresh`, and `txCtcssLevel` rows (10, 5, 9). A second open does not change an existing value, and it does not write the call sign or the tone fields. The matrix is [COMPLIANCE.md](COMPLIANCE.md). The page inventory is [UI-COVERAGE.md](UI-COVERAGE.md).
12. **Functional test publishes only a root-rendered no-PTT snapshot for the source install.** `447a54b` installed a web-writable file. That is withdrawn. `a08a980` looked for plugins under the multiarch directories and would refuse on this Pi, where the bootstrap installed them at `/usr/local/lib/svxlink`. The helper now requires that directory, `RepeaterLogic.so`, `SimplexLogic.so`, `DummyLogic.so`, `/usr/local/bin/svxlink`, `/usr/local/share/svxlink/events.tcl`, the 26.05 `events.d` files, and `/usr/local/share/svxlink/sounds`. It does not accept `/usr/lib` or `/usr/share`. `CFG_DIR` is the empty `/etc/svxlink/functional-test.d`. Existing files in `svxlink.d` are left there and are not loaded. The call sign is copied only as a plain `[A-Z0-9]{3,12}` token. The database is not modified. Start compares the installed bytes with a fresh render. While `/etc/systemd/system/svxlink.service` is a symlink to `/dev/null`, start does not call systemctl and does not remove the mask. The installer writes the reviewed unit to `/usr/local/lib/systemd/system/svxlink.service` only. That unit runs `/usr/local/bin/svxlink` as user `svxlink` with the published config and has no GPIO setup service. This is not a native 26.05.2 process proof. The cloud fixture matches the source layout and does not execute the distro `svxlink` binary.

13. **Privileged HTTP routes require a session, POST, and the CSRF token before any helper or database write.** `functions/ajax_system.php` on `2e1cf4d` dispatched `orp_helper` from a cookie-free POST. The native review showed `status` returning HTTP 200 after a real 26.05.2 start/restart/stop had already passed. That route, `svxlink_update.php`, `ajax_db_update.php`, `port_db_update.php`, `tts_preview.php`, and the page and wizard POSTs now share `RequestGuard`. No cookie or a random session is HTTP 401. A missing or wrong token, or a foreign `Origin`, is HTTP 403. A GET that carries a lifecycle action is HTTP 405. Login still accepts the token printed on the login form and does not read the users table until that token matches. The repeater controls in `page-dashboard.js` send the token from the dashboard meta tag. The account password is not rewritten by these checks. The endpoint matrix is in [UI-COVERAGE.md](UI-COVERAGE.md).
14. **Speech clips are a separate root install, not part of this UI milestone.** Native 26.05.2 created `/usr/local/share/svxlink/sounds` and left `en_US` absent. The English clips are the Heather sound pack from the SvxLink project, installed by root as real files under `/usr/local/share/svxlink/sounds/en_US`. They must be root-owned, not a symlink, and not writable by `www-data`. The web installer does not download them. Preflight already reports the absence. Until those files are present, no run claims spoken identification. The fixed no-PTT snapshot also does not publish the stored identification schedule, port rows, or board preset.
15. **Native 26.05 squelch threshold names.** The rendered receiver uses `SQL_SIGLEV_OPEN_THRESH` and `SQL_SIGLEV_CLOSE_THRESH`. `SQL_DET=SIGLEV` stays. The old `SIGLEV_OPEN_THRESH` and `SIGLEV_CLOSE_THRESH` names are what 26.05.2 logged as deprecated.

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

## PHP 8.4 package policy

The bench install uses these Debian Trixie packages: `php8.4-fpm`, `php8.4-cli`, `php8.4-common`, `php8.4-sqlite3`, `php8.4-opcache`, and `php8.4-zip`. `php8.4-zip` provides `ZipArchive`, which module upload requires. It does not install `php-memcached`. It does not add a PHP repository, and it does not accept another major or minor series if that is what apt offers.

`apt-get update` uses the sources already enabled on the machine. The install refuses to continue unless an enabled Debian archive stanza (`trixie` or `trixie-updates` from `deb.debian.org` or `ftp.debian.org`) and an enabled `trixie-security` stanza are both present. Deb822 `Enabled: no`, `deb-src` only, comments, and backup filenames (`*.bak`, `*.save`, `*.disabled`, `*.dpkg-old`) are not enabled sources. A one-line `deb` entry with `enabled=no` is ignored. The Raspberry Pi archive (`archive.raspberrypi.com`) can sit beside the Debian stanzas. It is not a Debian PHP origin and it does not by itself satisfy the requirement.

For each of the six packages, the apt candidate must be PHP 8.4 and every origin listed for that candidate version must be an authorized Debian suite (`trixie-security`, `trixie`, or `trixie-updates` on the Debian archive hosts above). A third-party origin publishing the same version fails the install before any package is installed. A missing origin fails as well. Dependencies of those packages may still come from Debian `trixie` or `trixie-updates`.

A package that is missing or older than that candidate is installed or upgraded with `apt-get install` of that package list only. `--no-upgrade` is not applied to those packages. `nginx`, `gpiod`, `sudo`, and `sqlite3` still use `--no-upgrade`. There is no `dist-upgrade` and no `full-upgrade`. After that install, the same comparison is repeated. The nginx site accepts only a `php8.4-fpm` socket.

This is a package-origin and freshness rule for the distro runtime. It does not name a vulnerability and it does not claim that moving to the candidate closes one. The cloud harness still typechecks with the image's PHP 8.3 CLI; that is not the runtime the installer selects for the Pi. Commit `04d7dbe` is what is installed on the bench, including this origin rule and `php8.4-zip`.

The installer still refuses svxlink, remotetrx, and svxreflector unless each unit is masked. That is the state used for the 04d7dbe install. Functional-test is a different safe state: the operating-mode token is exactly `functional-test`, the file is not a symlink and not group or world writable, and on the bench it is owned by root. The extended-ACL rejection runs only when `getfacl` is installed. In that state each unit may instead be `inactive` and `disabled`. An enabled unit, a running unit, or a disabled unit without that token is still refused before any file is written. A functional-test install does not replace those unit files, does not enable them, and does not install a vendor unit over them. The installer does not unmask anything. nginx denies `/backup/` outright. `backup.php` posts the archive name to `functions/backup_download.php`, which checks the session, CSRF, and same origin, then returns that one regular `.orp` file. A symlink or a path outside the backup directory is refused.

`upgrade/tests/run.sh` requires the Debian package `nodejs` (the `node` binary) for `upgrade/tests/logtail_client_test.js`. That package is test-only. The station install does not install it. The Pi already has `nodejs` `20.19.2` for that test. If `node` is missing, the harness stops and names `nodejs`.

## Wizard save without the Memcached extension

The supported PHP 8.4 set does not load Memcached, and this tree has no `includes/classes/Memcached.php`. Wizard Save calls `Database::update()`, which calls `set_update_flag()`. That called `class_exists('Memcached')`. The default is to autoload. The autoloader then stopped the response with `File Not Found: /var/www/openrepeater/includes/classes/Memcached.php`. The SQLite `system_flags` path never ran. On the installed `10c4df4` UI that text was the Save response. The nginx log showed five PHP warnings at `wizard/index.php` line 15 and no Memcached line, because the file error was printed by the application and the warnings were `session_name()` after `session_start()`.

The extension check is now `extension_loaded('memcached')` and `class_exists('Memcached', false)`. Neither asks the autoloader for an OpenRepeater file. When the extension is absent, the rebuild flag is stored in `system_flags`. The autoloader loads a class only when `includes/classes/<Name>.php` is a real file. Instantiating a missing OpenRepeater class still raises `Class not found`.

`session_name("open_repeater_wizard")` ran after the login session was active. On PHP 8 that warns and does not change the cookie. The call is removed, so the wizard stays on the authenticated session.

Save (`process_page=wizard_update`, `page=wizard_complete`) writes the posted settings and returns the finish page. It does not publish SvxLink files. Finish redirects to `functions/svxlink_update.php`. On the bench that request stays in the preview directory and does not start a radio or write `/etc/svxlink`. The installer copies `install/sql/openrepeater.db` only when the database file is missing, so deploying this fix does not replace the account, settings, ports, or modules. The open wizard page was not retried from here.

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
- nginx and PHP 8.4 FPM on `10c4df4` start, `nginx -t` passes, and the login page loads. Cloud used PHP 8.3.6 and the built-in server, not nginx and not PHP 8.4. The wizard Save fix and the Debian origin check are not part of that installed commit.
- An authenticated wizard Save on the installed UI. The reported response was the Memcached file error. No Save retry was run from here, and no account password is documented here.
- `gpioinfo` text, chip names, and line offsets. No pin was read.
- COS polarity switch position, audio devices, and anything involving RF. Not run, and the UI is not allowed to run them.
- SvxLink 26.05 TCL inheritance, EchoLink, AlertMode, NetMode, and DVR. Not ported. Private module sources were not available in this environment.
- Wi-Fi, WireGuard, and the public hostname. Left down.

## Unavailable in this environment

- The bench LAN and any production host. Not contacted.
- `/workspace/orp-test-image` and `/workspace/orp-test-stage2` from the bench note. They are not in this checkout. The bootstrap contract used here is the parent's written snapshot, not a re-read of that script.
- `DrHolbr/openrepeater-modules` contents.
- A PHP 8.4 binary in this cloud. Lint and the wizard HTTP test used the image PHP CLI. The installer asks the Pi for `php8.4-fpm` only.

## Tracked follow-ups

6. The station database hash moved from `ae65ca06` to `54ff78f7`. The change is still unattributed. Investigation is pending. Do not treat either hash as a new baseline until that is explained.
7. The `143d5e7` tree had no `/var/www/openrepeater/sounds` directory, so restore could not use that anchor. `04d7dbe` is the installed tree and includes the real-directory sounds and backup anchors. The suite restores courtesy files into a real directory, not a symlink. A live restore of the station backup was not part of the install report.
8. `login.php` still builds the password check with `SQLite3::escapeString` inside SQL and a double SHA-256. A later change may store `password_hash` and rehash on login. It must keep accepting the existing bench account. That migration is not in this commit.
- `nginx -t` and `gpioinfo` on real hardware.
