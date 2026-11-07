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

The log page on this install still requested `/log`. The Range response was HTTP 200 `text/html`, chunked, 586 bytes, with `Content-Length` and `Content-Range` absent. Anonymous `/log` was also HTTP 200 HTML. That reproduces the `Invalid integer null` path. It is not a plaintext log and it is not evidence that log bytes were anonymous. `5bff6b4` is the unread stream fix and is not installed. `/var/log/svxlink` was readable by `www-data` and was not chmodded.

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
| `log.php` | HTTP 200 shell on `97077d5`. `GET /log` with `Range: bytes=-1225` was 200 `text/html` chunked, 586 bytes, both length headers null | POST `svxlink_update.php`; GET `functions/log_stream.php` on `5bff6b4` | Active Repeater Log, `logtail.js` | Native bug reproduced on `97077d5`. `5bff6b4` is `software-proven` for the fixed stream and is not installed. Anonymous `/log` on the installed tree is HTML, not log bytes. |
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

`orp_Mode`, Update Ports, and Advanced Details were not submitted. None of these loads ran on the station database. No pin was driven.

## Every named control

| Control | Where | Status |
| --- | --- | --- |
| Login username, password | `login.php` | `software-proven` session creation. Not a new account. |
| Change Password | `login.php` | Not run. The station password was not changed. |
| Rebuild & Restart | header modal | Native `97077d5` published through the tokenized rebuild while masked, then started only svxlink for the bounded run. A stale page is not that POST. |
| Dashboard Restart, Shutdown | `dashboard.php` | Not clicked. Bench helper still refuses host restart and stop. |
| GPIO table, POST | `gpio.php` | Page is read-only. POST is 405. No line was requested. `gpioinfo` was not captured in the 97077d5 window. |
| `callSign`, tails, timeout, DTMF disable, tones, CTCSS thresholds, TTS fields, Test Voice | `settings.php` | Second GET does not replace an existing threshold. Save and Test Voice were not submitted. The 97077d5 settings rows were unchanged. |
| `orp_Mode` | `ports.php` | Not submitted. |
| Port label, GPIO, audio, direction, polarity, Update Ports | `ports.php` | Not submitted. Load Preset is the separate table above. |
| Load Preset for boards 0–4 | `ports.php` | `software-proven` on a copy. Exact rows above. Not the station database. Not driven. |
| Advanced Details | `ports.php` | Modal only. No write. |
| Upload & Install, Delete module, Find Modules | `modules.php` | Form actions point at `modules.php`. Upload and delete were not submitted. Find Modules is an external link. One live `moduleEnabled` value differs across the 97077d5 window and was left as found. |
| Short and long identification fields, Morse suffix, WPM, pitch | `identification.php` | Not saved during the native window. The stored profile was published and the periodic CW lines were logged. End-of-communication ID is unverified. |
| Identification voice upload | `identification.php` | Not submitted. Speech pack is not installed. |
| `courtesyMode`, tone upload | `courtesy_tone.php` | Rendered. Not submitted. |
| DTMF page close / rebuild | `dtmf.php` | Not submitted. |
| Active Repeater Log | `log.php` | Native `/log` Range is chunked HTML. Stream fix is `5bff6b4`, not installed. |
| Create, upload, restore, delete backup | `backup.php` | Not run. |
| Advanced config textareas, standard mode, advanced mode | `advanced.php` | Not submitted. |
| Wizard agree, call sign, board, port, Save, Finish | `wizard/index.php` | `software-proven` on a copy for the Memcached-free save and the Finish POST form. Not the station database. |
| Heather installer | `upgrade/install_heather_sounds.py` | Pin reviewed in cloud fixtures. Not installed. Playback unverified. Next review is the installer pin on the Pi, not a speech claim. |
