# Custom surface on `alertmode-dev`

Inventory of this fork relative to stock OpenRepeater **2.1.3** (git tag `2.1.3`, merge-base `2b6b207`). Produced by `git diff 2.1.3...alertmode-dev` plus a read of the TCL writers. Use it to decide what must be re-proven on SvxLink 26.05.2.

**Status: inventory only.** Nothing here has been ported.

The 26.05 column means "revalidate against the TCL inheritance rewrite" (handlers, namespaces, and where files are written). Configuration keys and WAV synthesis are called out separately so they are not mixed into that rewrite.

## Delta vs tag `2.1.3`

Commits on `alertmode-dev` after `2.1.3`:

| Commit | What it added |
| --- | --- |
| `a10eb33` | ICS board ALSA: `Lineout` `58%` → `80% unmute` in `includes/board_definitions.php` |
| `7583728` | Wizard default `txTailValueSec` 4 → 2 (`wizard/index.php` only) |
| `0a03182` | TX/RX CTCSS UI wired through to `svxlink.conf` |
| `b80f8dc` | Ident-only-after-TX, TTS stack, custom-module note |
| `7c2929c` | TTS engines: Flite, Pic02wave, eSpeak fallback (Piper removed) |
| `fab64c6` | Merge of the TTS branch |
| `855388a` | TTS preview response handling |

`git diff --stat 2.1.3...HEAD` is 13 files. Functional ones are listed below. `.gitignore` only adds `claude.md` / `calude.md`. The two SQLite files under `install/` changed as binaries; treat the live database on the repeater as the source of settings, and keep it out of git.

## Files that differ from stock 2.1.3

| Path | Role | 26.05 TCL inheritance |
| --- | --- | --- |
| `includes/classes/TTS.php` | Shared synth: Flite (`slt`/`awb`/`kal`/`rms`), Pic02wave, eSpeak or eSpeak-NG fallback, sox to 16 kHz mono 16-bit. Reads `tts_*` rows from `/var/lib/openrepeater/db/openrepeater.db`. Log: `/tmp/orp_tts.log`. | No. Revalidate binaries and package names on the new OS. The code looks for `pic02wave`; Debian's pico package installs `pico2wave`. Flite voices and `espeak` vs `espeak-ng` need a bench check. WAV rate is unchanged. |
| `functions/tts_preview.php` | POST handler for the Test Voice button. Returns `audio/wav`. | No. |
| `settings.php` | CTCSS open/close thresholds, TX CTCSS level, Text-to-Speech section. | No. The **keys** it saves must match 26.05 `svxlink.conf` (see below). |
| `includes/js/page-settings.js` | Shows CTCSS fields only when a tone is selected. Test Voice posts to `tts_preview.php`. | No. |
| `TTS-SETUP.md` | Operator notes for the three engines. | No. Host commands in that file are Buster-era; follow [REBUILD-CHECKLIST.md](REBUILD-CHECKLIST.md) on the spare. |
| `identification.php` | Select **Identify Only After Transmission** (`ID_Short_IdentOnlyAfterTX`, default `False`). Seeds the row with `Database::ensure_setting()`. | No. Behavior is the conf key `IDENT_ONLY_AFTER_TX`, which must be confirmed in the 26.05 manual. |
| `includes/classes/Database.php` | `ensure_setting()` — `INSERT OR IGNORE` so new keys appear on old databases. | No. |
| `includes/classes/SVXLink.php` | Emits CTCSS and `IDENT_ONLY_AFTER_TX`. See the key table. | The file also sets `EVENT_HANDLER=/usr/share/svxlink/events.tcl` and writes TCL paths. Those writes are in the inheritance set. The keys themselves are a conf check. |
| `wizard/index.php` | Default `txTailValueSec` 4 → 2. Default `ID_Short_IdentOnlyAfterTX=False`. | No. |
| `includes/board_definitions.php` | ICS Controllers Pi Repeater 2X / 1X / 2X prototype: `Lineout` `80% unmute`. 2X preset: RX GPIO 26 and 23, TX GPIO 498 and 499, `alsa:plughw:0`. | No. ALSA mixer names and the GPIO map are a hardware revalidation on the new image. `498`/`499` are Buster-era numbers. |

### `svxlink.conf` keys this fork added or stopped always writing

From `includes/classes/SVXLink.php` (`build_rx`, `build_tx`, `build_logic_repeater`, `build_logic_simplex`):

| Setting row | Conf result | When |
| --- | --- | --- |
| `rxTone` | `SQL_DET=CTCSS` (otherwise `GPIO` or `VOX`) plus `CTCSS_FQ` | Tone non-empty |
| `rxCtcssOpenThresh` | `CTCSS_OPEN_THRESH` (default 10) | Tone non-empty |
| `rxCtcssCloseThresh` | `CTCSS_CLOSE_THRESH` (default 5) | Tone non-empty |
| `rxTone` | `REPORT_CTCSS` on the logic section | Tone non-empty. Stock 2.1.3 always wrote this. |
| `txTone` | TX `CTCSS_FQ` and logic `TX_CTCSS=ALWAYS` | Tone non-empty. Stock 2.1.3 always wrote `TX_CTCSS`. |
| `txCtcssLevel` | `CTCSS_LEVEL` (default 9) | Tone non-empty |
| `ID_Short_IdentOnlyAfterTX` | `IDENT_ONLY_AFTER_TX=1` or `0` | `1` only when short ID mode is not `disabled` and the select is `True` |

Confirm each name against SvxLink 26.05 `svxlink.conf(5)` on the spare before trusting a generated file.

## TCL generators (same as stock 2.1.3, all in the inheritance set)

These files did **not** change after tag `2.1.3`. They are still how the UI builds events, and they are the part SvxLink 26.05 will break. Detail is in [UPGRADE-SVXLINK-26.md](UPGRADE-SVXLINK-26.md).

| Path | Used at runtime? | Handlers it emits | Revalidate on 26.05? |
| --- | --- | --- | --- |
| `includes/classes/SVXLink_TCL.php` | Yes. `svxlink_update.php` calls `alias_RepeaterLogic`, `alias_SimplexLogic`, `override_courtesy_tone`, `logic_override`. | Full-file copy of `RepeaterLogic.tcl` / `SimplexLogic.tcl` renamed to `ORP_*_PortN`. Replaces `send_rgr_sound` (silence, `playTone 660 500 200`, or `playFile` of the courtesy WAV). Writes `Logic::send_short_ident` and `Logic::send_long_ident` (Morse via `CW::`, `spellWord`, custom `playFile`, optional time). | **Yes. Blocking.** |
| `includes/classes/SVXLink.php` `write_config()` / `delete_custom_evnets()` | Yes. | `ORP_*.tcl` → `/usr/share/svxlink/events.d/`. `Logic.tcl` → `/usr/share/svxlink/events.d/local/`. Deletes `events.d/ORP_*`. | **Yes. Blocking.** |
| `functions/svxlink_update.php` | Yes. | Orchestrates the writers, then `orp_helper svxlink gpio_down`, `gpio_up`, and `restart`. Advanced mode also unlinks `/etc/openrepeater/svxlink/local-events.d/CustomLogic.tcl`. | **Yes**, because it is the only path that publishes TCL. |
| `functions/svxlink_update_functions/tcl_identification.php` | **No.** Nothing includes it. | `send_short_ident`, `send_long_ident`. | **Yes if revived.** Leave it unused. |
| `functions/svxlink_update_functions/tcl_courtesy_tones.php` | **No.** Nothing includes it. | `send_rgr_sound`. | **Yes if revived.** Leave it unused. |
| `functions/svxlink_update_functions/tcl_TEMP.php` | **No.** Nothing includes it. | `repeater_up` / `repeater_down`, `Logic::prev_ident`, `Logic::min_time_between_ident`. | **Yes if revived.** This is the old inheritance style 26.05 removed. |

Courtesy-tone behavior to preserve when the local handler is rewritten: `courtesyMode` `disabled` (silence), `beep` (660 Hz, 500 ms tone, 200 ms long, then silence), or `custom` (`/var/lib/openrepeater/sounds/courtesy_tones/<file>`). The page is `courtesy_tone.php` and is stock 2.1.3.

Identification behavior to preserve: short and long modes `disabled` / `morse` / `voice` / `custom`, Morse amplitude/WPM/pitch/suffix, append-Morse, long-ID time, custom files under `/var/lib/openrepeater/sounds/identification/`. Plus the fork-only ident-after-TX flag, which is a conf key rather than a change to these procs.

## Modules

`modules/.gitignore` ignores everything except `Help/`, `Parrot/`, and `EchoLink/`. Those three are stock ORP 2.1.3 module UI (build a `Module*.conf`, DTMF help). Their generated conf still needs a schema check against 26.05, especially EchoLink. They do not ship custom TCL in this tree.

**AlertMode** and **NetMode** are the custom modules. They are not in this checkout. `TTS-SETUP.md` and `TTS.php` expect:

- `modules/AlertMode/build_config.php` calling `TTS::synth()`
- `modules/NetMode/build_config.php` calling `TTS::synth()`
- a `cli_rebuild.php` path that includes `TTS.php` outside the web request

The private repo named for them is `DrHolbr/openrepeater-modules`. This environment could not read it (GitHub 404), so the file list above is from comments in this tree, not from that repo. On the live card they may also exist only under the web root and not in git.

Any TCL those modules drop into `events.d/` or `events.d/local/` is in the 26.05 inheritance set. The WAV files they ask TTS to write are not.

## UI surfaces to keep in mind

| Page | Stock or fork | Notes for the spare |
| --- | --- | --- |
| `settings.php` | Fork | CTCSS thresholds, TX level, TTS engine/voice/gain, Test Voice |
| `identification.php` | Fork select on a stock page | Ident only after transmission |
| `courtesy_tone.php` | Stock | Still drives `send_rgr_sound` |
| `ports.php` | Stock | RX mode, GPIO pins, ALSA device strings |
| `modules.php` plus gitignored module folders | Split | Help / Parrot / EchoLink in git; AlertMode / NetMode on the host |
| `advanced.php` | Stock | Raw `svxlink.conf` override. On 26.05 this can paste a 19.09 config over a working one. Leave it alone during bring-up. |

## Suggested revalidation order

1. Stock 26.05.2 with a hand-written config. No files from this tree's generators.
2. One `events.d/local/` courtesy-tone handler, then one ident handler, using `override` / `$SUPER` where the stock proc should survive.
3. Conf keys: CTCSS, `IDENT_ONLY_AFTER_TX`, PTT, squelch.
4. EchoLink module conf from the 26.05 examples.
5. AlertMode and NetMode from the host or the modules repo, TCL first, then TTS WAVs.
6. Only then decide whether `svxlink_update.php` is allowed to write any of it (Option A) or the dashboard owns the files (Option B).
