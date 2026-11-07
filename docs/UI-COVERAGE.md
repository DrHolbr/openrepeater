# UI coverage

Installed `adda19c` passed the page gate on November 6, 2026, about 8:51–8:55 PM EST. Nine authenticated pages returned HTTP 200 and closed `</html>`. Seventy-two assets passed. Protected paths returned 403 and a missing PHP route returned 404. No new PHP warning or fatal was in the bounded post-deploy log. No POST other than login. No board preset was loaded, no module was uploaded or deleted, and no restart, shutdown, or radio control was activated. The page gate does not complete handler, preset, or FCC acceptance.

Status values: `page-render-passed` means the installed page closed and showed the named controls. `software-proven` means a cloud test exercised a handler on a throwaway database. `read-only-inventoried` means the control was seen and not operated. `not-accepted` means the page gate does not count the handler.

## Native 5992620, measured on orp-test

Installed `599262001d38b97001bbc65ab1aef007d608f696`. The database snapshot stayed `daa1ce8b2132210591a78597b1a0f336b077b9a62fbeb9bf26951df39a28f2fd` and `/usr/local/bin/svxlink` stayed `d814861a156bdf35a30d9ecc95365452c8cc51685854695bf68b037d62f6a687`. No account, port, module, or settings row changed.

Seventeen routes were exercised over HTTP, not a mocked helper: `ajax_system.php`, `ajax_db_update.php`, `port_db_update.php`, `svxlink_update.php`, `tts_preview.php`, and `advanced.php`, `backup.php`, `courtesy_tone.php`, `dashboard.php`, `dtmf.php`, `identification.php`, `log.php`, `modules.php`, `ports.php`, `settings.php`, `gpio.php`, and `wizard/index.php`. Each no-cookie POST and random-session POST was 401. Each valid session with a missing token, a wrong token, or a foreign Origin was 403. That is 85 checks. The live database hash, live config hash, and helper command count stayed unchanged. GET on the five function routes was 405. A different scheme or port was 403. A spoofed `X-Forwarded-Proto` did not make an https Origin match HTTP. `status;true` was 403. GPIO POST was 405.

A tokenized `svxlink_update.php` publish returned the masked-service flag. The published file was `PTT_TYPE=NONE`, `SQL_SIGLEV_OPEN_THRESH=30`, `SQL_SIGLEV_CLOSE_THRESH=10`, loopback UDP, and an empty `functional-test.d`. After unmask of svxlink only, tokenized start, status, restart, and stop returned 200. The process log was `SvxLink v1.10.2@26.05.2`, the Tcl handler loaded, and both stops were clean. There were no warning lines. Final state: svxlink inactive, unmasked, and disabled; `remotetrx` and `svxreflector` stayed masked. Nine pages returned 200 with a CSRF meta tag. Seventy-two assets returned 200. Fifty-six PHP files linted clean. nginx and PHP 8.4.27 matched the Debian candidate. The wizard Finish fixture returned a POST form and was not allowed to publish the live config.

`97077d5` was not part of that install.

## Native 97077d5, measured on orp-test

Installed `97077d5f8d4f17198d3bf5794c5e65f58ac8525c`. The helper and `RequestGuard` matched that payload. The stored identification profile validated without an edit: short interval 10 minutes, long 60 minutes, after-TX off, short voice off and CW on, long voice on and CW on, CW 15 WPM at 600 Hz. The published call sign matched the database. The call sign is not repeated here.

The process PID 67175 started at 9:59:28 PM EST. The log recorded a long CW identification at 10:00:00 PM EST and a short CW identification at 10:10:00 PM EST, then `NOTICE: Exiting` at 10:10:29 PM EST. Nine missing-speech warnings came from the enabled long voice path. There were no other warnings in that slice. `sounds/en_US` was absent. A passive IPv4 loopback capture to UDP 17002 retained 501 datagrams, 1026048 payload bytes, and 346986 nonzero bytes, SHA256 `cf82dd88322d0d2683f5e607d9899491f336c28ccfb8b6a2031b123e84288857`. The payload was not decoded. No receiver opened, so `repeater_down` was not observed. Final state: svxlink inactive, unmasked, and disabled; `remotetrx` and `svxreflector` masked.

The full native tclsh run of `svxlink26_ident_test.tcl` against `/usr/local/share/svxlink/events.d` passed the four periodic checks and then failed `repeater_down IDLE did not spell FIXTURE`. `locale.tcl` had replaced the harness stub. Its `spellWord` plays `playMsg Default phonetic_<letter>` for the word. The stub had expected one `spellWord FIXTURE` row. That is a harness mismatch, not a station failure to spell, and not an end-of-communication result.

Accounts, all 34 settings, the ports row, both GPIO rows, and the CTCSS rows were identical before and after. The database file hash changed from `daa1ce8b2132210591a78597b1a0f336b077b9a62fbeb9bf26951df39a28f2fd` to `ae65ca06082f85aeb1091ba66ca7e7f4604889997efb1efefffc0fb957b29c3c` because one `moduleEnabled` value and the `system_flags` row identities differed. No module or settings POST from the test is recorded. The difference is unattributed and was not restored. The binary stayed `d814861a156bdf35a30d9ecc95365452c8cc51685854695bf68b037d62f6a687`. The final config SHA256 is `465cac40d5703f7a9f80ef29ce275eb3e48b3645827938cbe01ca4f8ffb5c5e2`.

The log page on the `97077d5` install still requested `/log`. The Range response was HTTP 200 `text/html`, chunked, 586 bytes, with `Content-Length` and `Content-Range` absent. Anonymous `/log` was also HTTP 200 HTML. That reproduced `Invalid integer null`. It was not a plaintext log.

## Native 5bff6b4 log stream, measured on orp-test

Installed `5bff6b455a41971303047a15c86e903d115c2afa` on November 6, 2026, about 10:14–10:20 PM EST. `41f3703` was not part of that install. The user was told to reload `http://192.168.155.216/log.php`. No browser was driven.

Authenticated `GET` and `HEAD` of `functions/log_stream.php` with `Range: bytes=-1225` returned 206 `text/plain`. `Content-Range` was `bytes 12640-13864/13865` and `Content-Length` was `1225`. The body was the 1225-byte suffix of `/var/log/svxlink`. `HEAD` had the same numbers and an empty body. `?file=/etc/passwd` did not change the suffix. No cookie and a random session were 401. A missing or wrong CSRF token, and a foreign or cross-scheme Origin, were 403. `POST` was 405 with `Allow: GET, HEAD`. A null range, a repeated range, a zero suffix, and an out-of-bounds range were 416 with `Content-Range: bytes */13865` and `Content-Length: 0`. A request without `Range` was 200 and matched the whole file. Gzip, deflate, and brotli did not turn the response into a chunked body without a length. The live log bytes were not changed. The log file stayed a regular `svxlink:svxlink` mode `0644` file. Empty, missing, and unreadable HTTP cases were not run against the live file.

The deployed client requests `functions/log_stream.php`, sends the CSRF header, and uses `jQuery.text()`. The pinned Node stub passed populated, empty, missing, null-header, and forbidden cases. That is not a GUI test. The one-millisecond poll was left as it is.

Before, after install, and after the tests, the database file was byte-identical, SHA256 `ae65ca06082f85aeb1091ba66ca7e7f4604889997efb1efefffc0fb957b29c3c`. The earlier unattributed `moduleEnabled` and `system_flags` difference was not restored. The binary stayed `d814861a156bdf35a30d9ecc95365452c8cc51685854695bf68b037d62f6a687`. The config stayed `465cac40d5703f7a9f80ef29ce275eb3e48b3645827938cbe01ca4f8ffb5c5e2`. Nine pages returned 200 with a CSRF meta tag. Seventy-two assets returned 200. Fifty-eight PHP files linted clean. nginx and PHP 8.4.27 matched. svxlink was left inactive, unmasked, and disabled. `remotetrx` and `svxreflector` stayed inactive and masked. English clips were still absent. Heather was not installed.

That paragraph describes the log install. The Tcl harness result is in the next section.

## Native 41f3703 Tcl harness, measured on orp-test

Installed `41f37034a34c68290c2e5858c37320dfc9d348f6` on November 6, 2026, about 10:23–10:37 PM EST. `tclsh upgrade/tests/svxlink26_ident_test.tcl /usr/local/share/svxlink/events.d` exited 0 on all nine checks, including phonetic `repeater_down` and plain-letter spelling. `locale.tcl` was `01f54727222129ee2e212aa3e698aa75cac94dcaf05773147e2c6cda8b8a874a`. That run records audio primitives. It is not a receiver end-of-communication, heard speech, or RF. The log suffix check passed again: 206, `bytes 12640-13864/13865`, length 1225. The database stayed `ae65ca06082f85aeb1091ba66ca7e7f4604889997efb1efefffc0fb957b29c3c`. The binary and config hashes were unchanged. PHP 8.4.27 and nginx matched. svxlink was left inactive, unmasked, and disabled. The other two units stayed masked.

Heather was not installed by `41f3703`. Two bounded runs expired at 90 and 420 seconds while still reading the bzip2 archive. 476 files were in a private stage. `/usr/local/share/svxlink/sounds/en_US` was absent. `/tmp` is a different filesystem from the sound directory on this Pi.

## Native 143d5e7 Heather install, measured on orp-test

Installed `143d5e7e7fc235d34ead677f2383b02c69e23da0` on November 6, 2026, about 10:40–10:46 PM EST. The first Heather publish took 8.205 seconds and the repeat took 8.026 seconds. `en_US` has 584 regular WAV files and 13 directories, all root-owned, files mode `0644`, directories mode `0755`, and zero symlinks. The repeat left the previous tree at `en_US.bak.20261107T034451Z`. A copied-database publish produced `SimplexLogic`/`TYPE=Simplex`, then `RepeaterLogic`/`TYPE=Repeater`, both with `PTT_TYPE=NONE` and the installed `events.tcl`. `orp_Mode=advanced` refused and left the previous file hash unchanged. The nine Tcl checks and the log range check passed. Nine pages returned 200. Fifty-eight PHP files linted. nginx and PHP 8.4.27 matched. The database stayed `ae65ca06082f85aeb1091ba66ca7e7f4604889997efb1efefffc0fb957b29c3c`. The binary and live config were unchanged. svxlink was left inactive, unmasked, and disabled. The other two units stayed masked. The clips are installed files. They were not played, and an end-of-communication identification was not executed.

The prepared settings and port writers in that install did not check SQLite execute or commit results. `b1672a3337005146c453752843a078718eebe8b9` checks those results, plus module enable, module options, and backup import, on a copy of the stock database. A locked commit, a read-only file, a constraint abort, and invalid backup SQL return failure and leave the previous rows in place. Callers report `not-written` or the existing error text. That commit is not this native install. Command: `php upgrade/tests/db_write_boundary_test.php .` from the repository root. It is also in `bash upgrade/tests/run.sh`.

## Authenticated mutation boundary

`2e1cf4d` let `functions/ajax_system.php` call the helper with no session. A mutation now requires a positive account id whose users row still has the same username. An array, a nonnumeric id, a mismatched name, and a deleted row are refused before the helper. That check is not a claim that a cookie alone can forge those session fields. Origin comparison includes scheme, host, and port. `X-Forwarded-Proto` is ignored unless `ORP_TRUST_FORWARDED_PROTO=1`. The Pi is direct HTTP, so an https Origin does not match. CSRF is still required on its own. A cloud HTTP fixture covers the denial codes and one authenticated `svxlink status` POST. It does not unmask a radio. Heather 25.05 is pinned at `e79e61bec17a24fad093edfb21e7f8ca51af33b9590db954b4789271db2957dd` and is not installed. Playback is unverified. The five Load Preset posts below are a copied database, not the station database.

| Endpoint | Verb | Anonymous | Missing or bad CSRF | Foreign Origin | Authenticated POST |
| --- | --- | --- | --- | --- | --- |
| `functions/ajax_system.php` lifecycle fields | POST | 401 before helper | 403 before helper | 403 before helper | allowlist, then BenchGuard, then helper |
| `functions/ajax_system.php?post_option=start` | GET | 405 | 405 | 405 | 405 |
| `functions/ajax_system.php?update=` | GET | 401 | session required, no CSRF | read allowlist only | read allowlist |
| `functions/svxlink_update.php` | GET | 405 | 405 | 405 | 405 |
| `functions/svxlink_update.php` | POST | 401 | 403 | 403 | publish path after the token matches |
| `functions/ajax_db_update.php` | POST | 401 before SQL | 403 before SQL | 403 | settings update, `csrf_token` is not a setting |
| `functions/port_db_update.php` | POST | 401 | 403 | 403 | port replace |
| `functions/tts_preview.php` | POST | 401 | 403 | 403 | preview audio |
| `login.php` password post | POST | form token required before the users table | 403 | 403 | creates the session and rotates the token |
| `wizard/index.php` | POST | 401 | 403 | 403 | wizard steps; Finish posts to `svxlink_update.php` |
| `modules.php`, `identification.php`, `courtesy_tone.php`, `ports.php`, `advanced.php`, `backup.php`, `settings.php`, `dtmf.php`, `dashboard.php`, `log.php` | POST | 401 | 403 | 403 | existing page action |
| `gpio.php` | POST | 401 | 403 | 403 | 405, diagnostics stay read-only |
| page GET routes | GET | 302 to `login.php` | not a mutation | not a mutation | render, including the CSRF meta tag |

| Route | Native ac0613f | Forms seen | Controls seen | This commit |
| --- | --- | --- | --- | --- |
| `dashboard.php` | HTTP 200, bench text, document not accepted as functional | POST `functions/svxlink_update.php` | `return_url`; enabled Restart and Shutdown labels plus disabled "Restart blocked on bench" and "Shutdown blocked on bench" | `read-only-inventoried`. Buttons were not activated. Bench still refuses the helper start, restart, and reboot commands. |
| `gpio.php` | HTTP 200, read-only table, unresolved 498 and 506 text. Render did not include `pinctrl-bcm2835` or `raspberrypi-exp-gpio` | POST `functions/svxlink_update.php` | `return_url`, disabled bench restart | `read-only-inventoried`. No GPIO line was requested. Chip names remain a diagnostic-visibility note, not proof `gpioinfo` is broken. |
| `settings.php` | `page-render-passed` on `adda19c`. The GET inserted only missing `rxCtcssOpenThresh=10`, `rxCtcssCloseThresh=5`, and `txCtcssLevel=9`. Existing rows, including call sign and RX/TX tones, compared unchanged. Warnings at lines 134, 142, and 176 were absent after that | POST `svxlink_update.php`, POST `ajax_db_update.php` | Save was not clicked | `software-proven` in cloud that a second GET does not replace an existing threshold. The native insert is a real database migration, not a hidden default. |
| `ports.php` | HTTP 200 on `5992620` | POST `svxlink_update.php`, `ajax_db_update.php`, `port_db_update.php`, `ports.php` | `orp_Mode`, port arrays, `board_id`, Load Preset, Load, Update Ports, Advanced Details. Five options below | `software-proven` on a copied database for Load only. Update Ports and `orp_Mode` were not posted. Not the station database and not driven. After the prototype load, publish stays `PTT_TYPE=NONE` with no `gpio498`. |
| `modules.php` | HTTP 200. Upload and delete forms had an empty action because `htmlspecialchars` was not echoed | POST `svxlink_update.php`, two POST forms with an empty action | Upload & Install, Find Modules, `file[]`, `upload_file`, `deleteSelectedModule`, Delete | `software-proven` that both forms now post to `/modules.php`. Upload and delete were not submitted. |
| `identification.php` | `page-render-passed` on `adda19c`. `97077d5` did not save these controls; the already-stored profile was published | POST `svxlink_update.php`, POST `ajax_db_update.php` | `ID_Short_Mode`, `ID_Short_IntervalMin`, `ID_Short_IdentOnlyAfterTX`, `ID_Short_AppendMorse`, `ID_Long_Mode`, `ID_Long_IntervalMin`, `ID_Long_AppendTime`, `ID_Long_AppendTone`, `ID_Long_AppendMorse`, `ID_Morse_Suffix`, `ID_Morse_WPM`, `ID_Morse_Pitch`, voice upload | Periodic CW was observed on the process. The Save controls were not posted in that window. End-of-communication identification is unverified. Speech files are absent. |
| `courtesy_tone.php` | `page-render-passed` on `adda19c`: complete document, `courtesyMode`, upload form, empty-library message | POST `svxlink_update.php`, two POST `ajax_db_update.php` | Upload was not submitted | `not-accepted` as audio behavior. |
| `dtmf.php` | HTTP 200 | POST `svxlink_update.php`, POST `ajax_db_update.php` | bench restart, close | `read-only-inventoried`. The DTMF disable code was not sent. |
| `log.php` | Native `5bff6b4`: authenticated Range `bytes=-1225` is 206 `text/plain`, `Content-Length: 1225`, `Content-Range: bytes 12640-13864/13865` | GET/HEAD `functions/log_stream.php` | Active Repeater Log | Installed and measured. 401, 403, 405, and 416 were measured. The browser was not driven. Empty, missing, and unreadable files were not applied to the live log. |
| `backup.php`, password change, logout | Not exercised | Menu links only |  | Not run. |
| `wizard/index.php` | Not part of this authenticated nine-page GET. Earlier cloud test posts Save and Finish on a copy database | Wizard posts | Save Configuration, Finish & Logout | `software-proven` for the Memcached-free save path. Not rerun against the station database. |

A control listed above is not "working" until its handler has been executed and the persisted result or refusal has been checked. The native baseline did not do that, on purpose.

## Load Preset rows on a copied database

Each row is the HTTP POST of that `board_id` with a session and CSRF token, bench mode, so the mixer is not called. The account password, `callSign=TEST`, and module option blobs stayed put. Every `moduleEnabled` stayed 0. The card's Remote Relay block stores GPIO rows only; there is no `modules.svxlinkName` of `Remote Relay`, so no module row is enabled. 498 and 499 stay conditional offsets with `bcm=null`. The published runtime after the last load is still `PTT_TYPE=NONE` and does not contain `gpio498`.

| Preset | Port | RX | TX | Audio RX / TX |
| --- | --- | --- | --- | --- |
| 0 ICS Pi Repeater 2X 3.1+ | 1 | 26 in low, BCM 26 | 498 out high, offset 2, GPA2 | `alsa:plughw:0\|1` / same |
| 0 | 2 | 23 in low, BCM 23 | 499 out high, offset 3, GPA3 | `alsa:plughw:0\|0` / same |
| 1 ICS Pi Repeater 1X 1.0+ | 1 | 26 in low, BCM 26 | 498 out high, offset 2, GPA2 | `alsa:plughw:0\|1` / same |
| 2 F5UII/F8ASB SVXLink Card 1.11+ | 1 | 19 in low, BCM 19 | 16 out high, BCM 16 | `alsa:plughw:0\|0` / same |
| 2 | 2 | 18 in low, BCM 18 | 17 out high, BCM 17 | `alsa:plughw:1\|0` / same |
| 2 relays |  |  | 20, 21, 22, 23 out high, type RemoteRelay | module row not stored |
| 3 Richard Neese SVXLink Basic Board 1.0 | 1 | 23 in high, BCM 23 | 24 out high, BCM 24 | `alsa:plughw:0\|0` / same |
| 3 | 2 | 25 in high, BCM 25 | 18 out high, BCM 18 | `alsa:plughw:1\|0` / same |
| 4 ICS Pi Repeater 2X 2.1 prototype | 1 | 26 in low, BCM 26 | 498 out low, offset 2, GPA2 | `alsa:plughw:0\|1` / same |
| 4 | 2 | 23 in low, BCM 23 | 499 out low, offset 3, GPA3 | `alsa:plughw:0\|0` / same |

`orp_Mode`, Update Ports, and Advanced Details were not part of the native installs. On a copied database they now have the results in the form matrix below. None of these loads ran on the station database. No pin was driven.

Numbers 0–27 are BCM header candidates only. The map is `GpioMap::headerMap()` in `includes/classes/GpioMap.php`: the stored number is the BCM number and the gpiochip0 line, and the physical pin is the 40-pin header pin. That is not a `gpioinfo` reading and it is not a claim the line is wired.

498 and 499 are not BCM numbers. `includes/board_definitions.php` stores them for the ICS 2X presets. The ICS PI-REPEATER-2X manual, section "Hardware GPIO Pin number assignments", names 498 as GPA2 and 499 as GPA3. `docs/GPIO-MAP.md` records the same table. The conditional offset is the stored number minus 496, and only if the old kernel gpio base was 496. orp-test has no MCP23017, so the chip is absent and activation is not applied.

## Every named control

| Control | Where | Status |
| --- | --- | --- |
| Login username, password | `login.php` | `software-proven` session creation. Not a new account. |
| Change Password | `login.php` | Cloud test changes only a throwaway account. The station password was not changed. |
| Rebuild & Restart | header modal | Native `97077d5` published through the tokenized rebuild while masked, then started only svxlink for the bounded run. A stale page is not that POST. |
| Dashboard Restart, Shutdown | `dashboard.php` | Not clicked on the Pi. Cloud `POST` is 403 and does not call the helper. A real host reboot stays a later native step. |
| GPIO table, POST | `gpio.php` | Page is read-only. POST is 405. No line was requested. `gpioinfo` was not captured in the 97077d5 window. |
| `callSign`, tails, timeout, DTMF disable, tones, CTCSS thresholds, TTS fields, Test Voice | `settings.php` | Native settings rows were unchanged on `5bff6b4`. Cloud form posts are in the matrix below and are not deployed. |
| `orp_Mode` | `ports.php` | Stored and applied on publish in the cloud fixture: simplex is `SimplexLogic`/`TYPE=Simplex`, repeater is `RepeaterLogic`/`TYPE=Repeater`, both with `PTT_TYPE=NONE`. An unsupported value does not replace the file. Not executed on the Pi. |
| Port label, GPIO, audio, direction, polarity, Update Ports | `ports.php` | Cloud post keeps 26/498 and 23/499 and a RemoteRelay row. Not deployed. |
| Load Preset for boards 0–4 | `ports.php` | `software-proven` on a copy. Exact rows above. Not the station database. Not driven. |
| Advanced Details | `ports.php` | The same Update Ports post stores VOX and active level. Not a separate write. Not deployed. |
| Upload & Install, Delete module, Find Modules | `modules.php` | Cloud upload stays disabled and does not run PHP or Tcl. Help cannot be deleted. Find Modules is an external link. The live module difference was preserved on `5bff6b4`. Not deployed. |
| Short and long identification fields, Morse suffix, WPM, pitch | `identification.php` | Cloud interval 7 is published. Custom mode is stored and refused. End-of-communication ID is unverified. Not deployed. |
| Identification voice upload | `identification.php` | A script upload is refused. Speech pack is not installed. Not deployed. |
| `courtesyMode`, tone upload | `courtesy_tone.php` | Stored, not applied. Custom says unsupported. A path-like upload is refused. Not executed on the Pi. |
| DTMF page | `dtmf.php` | No inputs. The pin is saved from General Settings and is not in the no-PTT file. Not deployed. |
| Active Repeater Log | `log.php` | Installed `5bff6b4`. The 1225-byte suffix and the denial matrix were measured. Reload `log.php` for the new client. No browser was driven. |
| Create, upload, restore, delete backup | `backup.php` | Cloud create, restore, and delete stay in the backup directory. Not deployed. |
| Advanced config textareas, standard mode, advanced mode | `advanced.php` | Text is stored. Publish stays `PTT_TYPE=NONE` and does not copy `gpio498`. Not deployed. |
| Wizard agree, call sign, board, port, Save, Finish | `wizard/index.php` | `software-proven` on a copy for the Memcached-free save and the Finish POST form. Not the station database. |
| Heather installer | `upgrade/install_heather_sounds.py` | Installed files on `143d5e7`: 584 WAVs, zero links, root `0644`/`0755`. Playback is not executed. |

## Form matrix on a copied database

Command: `bash upgrade/tests/control_roundtrip_test.sh`. It is also in `bash upgrade/tests/run.sh`. The database is a copy of `install/sql/openrepeater.db`. Deployed SHA for the log milestone is `5bff6b455a41971303047a15c86e903d115c2afa`. These form results are not on that install.

| Control | Expected | Handler | Evidence | Deployed SHA | Remaining gate |
| --- | --- | --- | --- | --- | --- |
| `orp_Mode=simplex` | Stored, then published as upstream `SimplexLogic` `TYPE=Simplex`. Repeater stays `RepeaterLogic` `TYPE=Repeater`. Both keep `PTT_TYPE=NONE`, loopback UDP, and the installed `events.tcl`. | `POST functions/ajax_db_update.php`, then `orp_helper config publish` | Cloud fixture only. `LOGICS=SimplexLogic` and `TYPE=Simplex`, then the repeater pair. No `PTT_PIN`. `advanced` returns refusal and the previous file hash is unchanged. | not deployed | Not run on the Pi. Simplex does not execute `repeater_down`. Identification intervals stay the same limits. |
| Update Ports and Advanced Details | Label, COS/VOX, polarity, and audio persist. A `../` label is refused and the previous row stays. A `RemoteRelay` GPIO row stays. | `POST functions/port_db_update.php` | Port 1 is `ROUNDTRIP vox 26 498`. Port 2 is `23/499`. GPIO 20 remains `RemoteRelay`. | not deployed | Not run on the station database. No pin driven. |
| Settings Save | Existing keys update. An unknown or quoted key is 400 and does not add a row. | `POST functions/ajax_db_update.php` | `txTailValueSec=4`. Call sign stays `TEST`. | not deployed | Native settings were not posted. |
| Test Voice | Pending. A missing engine returns an error and does not write settings. | `POST functions/tts_preview.php` | JSON `Synthesis failed` in the cloud fixture. No WAV was produced. | not deployed | Pending: engine present, a real sample, and browser playback. |
| ID interval | A 1–10 minute Morse interval is published. | `ajax_db_update.php`, then `orp_helper config publish` | `SHORT_IDENT_INTERVAL=7`. | not deployed | Not the Pi process. |
| Custom ID | Pending. Stored and refused by publish. The previous runtime file is unchanged. | same | Mode stays `custom`. Config SHA256 unchanged. | not deployed | Pending: not a 26.05 identification. End of a communication is unverified. |
| Voice and courtesy upload | Pending for a valid WAV. Script names and slash names are refused and no library file is written. | `identification.php`, `courtesy_tone.php` | `.php` refused. Slash name refused by `plainFileName`. | not deployed | Pending: `sox` conversion of a real WAV. Speech pack is absent. |
| `courtesyMode` | Stored. Not applied. Custom is unsupported. The installed Logic.tcl send_rgr_sound remains the procedure. | courtesy_tone.php to ajax_db_update.php | Page says not applied, and custom says unsupported. Publish prints courtesy=not-applied and writes no playTone or playFile. | not deployed | Not executed on the Pi. A beep or a clip is not claimed. |
| DTMF submit | The reference page has no inputs. The pin is a settings field and stays out of the no-PTT file. | `settings.php` to `ajax_db_update.php` | Pin `2468` stored. No `ONLINE_CMD` in the snapshot. | not deployed | Not a transmitter disable test. |
| Module upload and delete | Pending for a reviewed module. A probe zip stays disabled, does not execute PHP or Tcl, and cannot remove Help. | `modules.php` | Cloud fixture only. `ProbeMod` enabled `0`. No `/usr/local` link. | not deployed | Pending: activation of a reviewed module. Not executed on the Pi. |
| Backup create, restore, delete | Archive stays in the backup directory. Restore returns the copied settings and does not change the admin password. `../` is not deleted. | `backup.php` | Call sign returns to `TEST`. Admin hash unchanged. Outside canary remains. | not deployed | Not the station backup directory. |
| Advanced textareas | Stored. Not applied. `orp_Mode=advanced` is refused by publish and the previous file stays. | `advanced.php` | The page says it is not applied. Cloud publish refusal leaves the repeater snapshot hash unchanged. | not deployed | Not executed on the Pi. |
| Change Password | Only the logged-in throwaway account changes. | `login.php` `setPassword` | Throwaway can log in with the new password. Admin hash unchanged. | not deployed | Station password was not changed. |
| Host restart and shutdown | Pending. Stay blocked. The helper is not called. | `ajax_system.php` | 403 `bench mode blocks system restart` and `system stop`. | `5bff6b4` still blocks these | Pending: a coordinated native host test. Not enabled here. |
| Active Repeater Log | Decimal range and length. Denial matrix. | `functions/log_stream.php` | Native 206, length 1225, range `12640-13864/13865`. 401, 403, 405, 416 measured. | `5bff6b4` | Browser was not driven. Reload `log.php`. |
