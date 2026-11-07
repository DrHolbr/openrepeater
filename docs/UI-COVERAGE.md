# UI coverage

Installed `adda19c` passed the page gate on November 6, 2026, about 8:51–8:55 PM EST. Nine authenticated pages returned HTTP 200 and closed `</html>`. Seventy-two assets passed. Protected paths returned 403 and a missing PHP route returned 404. No new PHP warning or fatal was in the bounded post-deploy log. No POST other than login. No board preset was loaded, no module was uploaded or deleted, and no restart, shutdown, or radio control was activated. The page gate does not complete handler, preset, or FCC acceptance.

Status values: `page-render-passed` means the installed page closed and showed the named controls. `software-proven` means a cloud test exercised a handler on a throwaway database. `read-only-inventoried` means the control was seen and not operated. `not-accepted` means the page gate does not count the handler.

## Authenticated mutation boundary

`2e1cf4d` let `functions/ajax_system.php` call the helper with no session. A mutation now requires a positive account id whose users row still has the same username. An array, a nonnumeric id, a mismatched name, and a deleted row are refused before the helper. That check is not a claim that a cookie alone can forge those session fields. Origin comparison includes scheme, host, and port. `X-Forwarded-Proto` is ignored unless `ORP_TRUST_FORWARDED_PROTO=1`. The Pi is direct HTTP, so an https Origin does not match. CSRF is still required on its own. A cloud HTTP fixture covers the denial codes and one authenticated `svxlink status` POST. It does not unmask a radio. Spoken identification and preset propagation remain open. `upgrade/tests/svxlink26_ident_test.tcl` executes the pinned 26.05 `checkPeriodicIdentify` and `repeater_down` procedures. The root renderer copies stored Morse or voice identification fields that pass the type check. A custom clip and a Morse speed above 20 are refused and left stored. Heather speech files are not installed: `upgrade/install-svxlink-sounds.sh` extracts nothing while `upgrade/share/heather-16k-25.05.sha256` says `UNVERIFIED`. The five board-preset options are still not a completed round trip.

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
| `ports.php` | HTTP 200 | POST `svxlink_update.php`, `ajax_db_update.php`, `port_db_update.php`, `ports.php` | `orp_Mode`, port arrays, `board_id`, Load Preset, Load, Update Ports, Advanced Details. Five options: Pi Repeater 2X v3.1+, Pi Repeater 1X v1.0+, Pi Repeater 2X v2.1 PROTOTYPE, SVXLink Card v1.11+, SVXLink Basic Board v1.0 | `read-only-inventoried`. None of those buttons were triggered. Preset pin translation is not accepted from the option labels. |
| `modules.php` | HTTP 200. Upload and delete forms had an empty action because `htmlspecialchars` was not echoed | POST `svxlink_update.php`, two POST forms with an empty action | Upload & Install, Find Modules, `file[]`, `upload_file`, `deleteSelectedModule`, Delete | `software-proven` that both forms now post to `/modules.php`. Upload and delete were not submitted. |
| `identification.php` | `page-render-passed` on `adda19c`: `</html>`, `ID_Long_Mode`, `ID_Long_IntervalMin`, `ID_Long_AppendMorse`, `ID_Long_AppendTime`, Morse WPM/pitch/suffix, short-ID controls, empty-library message. Earlier `ac0613f` truncated at `natsort(null)` | POST `svxlink_update.php`, POST `ajax_db_update.php` | Rendered controls were not saved or published | `not-accepted` as an identification transmission. Publish rules are a later cloud fixture. End-of-communication timing is unverified. |
| `courtesy_tone.php` | `page-render-passed` on `adda19c`: complete document, `courtesyMode`, upload form, empty-library message | POST `svxlink_update.php`, two POST `ajax_db_update.php` | Upload was not submitted | `not-accepted` as audio behavior. |
| `dtmf.php` | HTTP 200 | POST `svxlink_update.php`, POST `ajax_db_update.php` | bench restart, close | `read-only-inventoried`. The DTMF disable code was not sent. |
| `log.php` | HTTP 200 | POST `svxlink_update.php` | bench restart, close | `read-only-inventoried`. |
| `backup.php`, password change, logout | Not exercised | Menu links only |  | Not run. |
| `wizard/index.php` | Not part of this authenticated nine-page GET. Earlier cloud test posts Save and Finish on a copy database | Wizard posts | Save Configuration, Finish & Logout | `software-proven` for the Memcached-free save path. Not rerun against the station database. |

A control listed above is not "working" until its handler has been executed and the persisted result or refusal has been checked. The native baseline did not do that, on purpose.
