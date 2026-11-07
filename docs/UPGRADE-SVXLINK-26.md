# Upgrade path: SvxLink 26 on a new Pi OS card

**Status: staging only.** This document plans a parallel-SD rebuild. It does not change the PHP or TCL generators, does not build an image, and does not claim that OpenRepeater on this branch runs on SvxLink 26.

The live repeater stays on its current card until a spare card has passed the checklist in [REBUILD-CHECKLIST.md](REBUILD-CHECKLIST.md). An in-place Debian dist-upgrade of that Buster card is out of scope.

## What is running today

| Item | Value |
| --- | --- |
| OpenRepeater | 2.1.3 image, plus the `alertmode-dev` delta in this fork |
| SvxLink lineage | 19.09.1 era (the image's stack, not a git pin in this repo) |
| OS | Raspberry Pi OS / Debian Buster era |
| Public UI | `orp.marionhamradio.com` |
| WireGuard | peer `openrepeater` at `10.253.0.4` |
| Upstream ORP | Tag `2.1.3` (2021) is still the published release. `3.0.x-DEV` exists in this fork and upstream and is not a released product |

`alertmode-dev` is `2.1.3` plus the custom commits listed in [CUSTOM-SURFACE.md](CUSTOM-SURFACE.md). `3.0.x-DEV` is a different line. It has some PHP 8 work and it does not contain the AlertMode / TTS / ident-after-use work. Do not rebase this branch onto `3.0.x-DEV` and call that the upgrade.

## Target

Build a second card. Leave the live card bootable and labeled.

1. **OS.** Raspberry Pi OS **64-bit Lite**. Prefer **Trixie** (Debian 13) when the Pi model and the ICS audio device enumerate on it. Fall back to **Bookworm** (Debian 12) 64-bit Lite when a required piece (SvxLink package, flite, or the ICS codec) is only known-good there. Record the choice on the spare card before any UI work. One OS for the whole bring-up.
2. **SvxLink.** **26.05.2**, confirmed with `svxlink --version` on the spare. Debian and Raspberry Pi OS may ship an earlier 26.05.x or nothing current. Install the distro package only when it prints `26.05.2`. Otherwise build the `26.05.2` tag from [sm0svx/svxlink](https://github.com/sm0svx/svxlink). Do not reuse 19.09 event files, `gpio.conf`, or generated `ORP_*.tcl` from the live card.
3. **UI.** Decide after stock SvxLink, audio, GPIO, and EchoLink work. See Option A and Option B below. This PR does not pick one.

## Why the TCL generators cannot be copied forward

SvxLink 26.05 rewrote the TCL event system so it follows the C++ hierarchy. Upstream's 26.05 notes warn that local event-handler changes can break, and they tell operators who hit that to move every local TCL change out of the way, confirm stock behavior, then put handlers back one at a time.

The hierarchy for a repeater logic is:

```text
LogicBase -> Logic -> RepeaterLogicType -> RepeaterLogic
```

Rules that matter for this fork:

- Leave `/usr/share/svxlink/events.d/` untouched. Local changes belong in `events.d/local/`.
- Do not copy a whole file out of `events.d/` into `local/`. Start from an empty file, open the namespace, and copy only the handlers being changed.
- A logic core no longer needs its own TCL file. `RepeaterLogic2.tcl`-style copies are obsolete. Type-wide handlers live in `XyzLogicType.tcl`. `XyzLogic.tcl` is only a local-modification template.
- Handlers inherit. A function defined on `Logic` applies to simplex and repeater. Replace a handler only at the level that should change.
- Smaller changes use the `override` prefix and `$SUPER` to call the inherited handler (see upstream `squelch_timeout.tcl`).
- A file in `local/` loads only when it is named the way 26.05 expects. SvxLink prints the files it loaded at startup. Later files override earlier ones.

What this tree does on every **Rebuild & Restart** (`functions/svxlink_update.php` → `includes/classes/SVXLink_TCL.php` and `SVXLink.php`):

| Generator | What it writes on 19.09 | Why 26.05 rejects it |
| --- | --- | --- |
| `alias_RepeaterLogic()` / `alias_SimplexLogic()` | Reads `/usr/share/svxlink/events.d/RepeaterLogic.tcl` or `SimplexLogic.tcl`, string-replaces the logic name with `ORP_RepeaterLogic_PortN` / `ORP_SimplexLogic_PortN`, and writes that full copy under `events.d/` | Per-instance logic TCL files are gone. Writing into `events.d/` is forbidden. `RepeaterLogic.tcl` is now a thin template; the handlers live higher up (`RepeaterLogicType`, `Logic`). |
| `alias_RepeaterLogic()` beep strip | Regex-deletes the stock `playTone 400 900 50 … playSilence 500` roger beep from the copied file | The beep is no longer in that file in that form. The regex matches nothing or deletes the wrong block. |
| `override_courtesy_tone()` | Regex-replaces `proc send_rgr_sound` inside the copied repeater file | `send_rgr_sound` is inherited. The courtesy tone has to be a small `local/` override at the repeater level, or a `Logic` override when simplex links must share it. |
| `logic_override()` | Writes `namespace eval Logic { send_short_ident; send_long_ident }` to `/usr/share/svxlink/events.d/local/Logic.tcl` | Closest to the new layout, and still wrong as a wholesale proc replacement: it drops inherited behavior, and a `Logic` override also hits simplex ports. Revalidate signatures (`spellWord`, `playMsg`, `playTime`, `CW::`) and pick `Logic` vs `RepeaterLogic`. |
| `write_config()` / `delete_custom_evnets()` | Writes `ORP_*.tcl` into `events.d/` and deletes `events.d/ORP_*` on the next rebuild | Those paths are inside the stock tree. A rebuild on 26.05 can delete or shadow files SvxLink expects to load. |

`functions/svxlink_update_functions/tcl_identification.php`, `tcl_courtesy_tones.php`, and `tcl_TEMP.php` are **not included** by the current `svxlink_update.php`. The live path is the class above. The old files still contain `send_short_ident`, `send_long_ident`, `send_rgr_sound`, `repeater_up` / `repeater_down`, and `Logic::prev_ident`. Leave them unused. If a card on the desk still `include`s them from an older tree, they are in the same revalidation set.

Until those writers are redesigned, do not point this UI's **Rebuild & Restart** at a 26.05 install. Hand-write `svxlink.conf` and one local handler on the spare first.

Ident-after-use and CTCSS are **configuration keys**, not TCL procs. They still need a man-page check on 26.05, and they are much smaller than the event rewrite:

- `IDENT_ONLY_AFTER_TX` (0/1) from `ID_Short_IdentOnlyAfterTX`
- RX: `SQL_DET=CTCSS`, `CTCSS_FQ`, `CTCSS_OPEN_THRESH`, `CTCSS_CLOSE_THRESH`, `REPORT_CTCSS`
- TX: `CTCSS_FQ`, `CTCSS_LEVEL`, `TX_CTCSS=ALWAYS`

GPIO is a separate break. `SVXLink_GPIO` still writes `GPIO_PATH=/sys/class/gpio` and `gpioN` names. Bookworm and Trixie do not expose the sysfs GPIO interface this 19.09 config expects. SvxLink 26 uses libgpiod. The ICS Pi Repeater 2X preset in `includes/board_definitions.php` uses RX GPIOs 26 and 23 and TX GPIOs **498** and **499**. Those high TX numbers belong to the Buster-era map on that board. Re-derive chip and line on the spare from the live `gpio.conf` and the board, then translate them. Do not copy `gpio.conf` onto the new card.

## Option A — keep this ORP UI

Carry `alertmode-dev` forward as the configuration UI on the new card.

Keep:

- General Settings CTCSS block and Identification "Identify Only After Transmission"
- Text-to-Speech block (`settings.php`, `includes/classes/TTS.php`, `functions/tts_preview.php`)
- Courtesy-tone page and the identification audio library
- EchoLink / Help / Parrot module pages that already live in git
- AlertMode and NetMode, which are gitignored here and live on the repeater (and in the private `DrHolbr/openrepeater-modules` repo)

Work that has to land before the UI is allowed to rewrite SvxLink:

1. Retarget `SVXLink_TCL` so a rebuild writes only `events.d/local/` fragments that 26.05 actually loads. One handler per change. Use `override` / `$SUPER` when the stock handler should still run.
2. Stop writing `ORP_*` copies into `events.d/`, and stop deleting files there.
3. Replace the sysfs `gpio.conf` writer with the 26.05 GPIO configuration for this board.
4. Confirm every `svxlink.conf` key this class emits against the 26.05 manual (`CTCSS_*`, `IDENT_ONLY_AFTER_TX`, `PTT_*`, `SQL_DET`, `EVENT_HANDLER`).
5. Run the PHP UI on the new OS's PHP (Bookworm 8.2, Trixie 8.4). This branch is the PHP 7.3-era 2.1.3 UI with a few `??` additions. `3.0.x-DEV` is a reference for PHP 8 fixes only. Mine specific fixes from it after something fatals. Do not merge that branch.
6. The UI restarts SvxLink through `/usr/sbin/orp_helper`, which is part of the image and is not in this repository. The spare needs an equivalent helper, or restart stays a manual `systemctl restart svxlink`.

The UI can be installed read-only for comparison while step 1–4 are unfinished. Saving from it on a 26.05 host is the hazard.

## Option B — dashboard UI, modules kept

Leave the ORP PHP generators on the Buster card. On the spare, run SvxLink 26.05.2 with a dashboard that already targets that version, and keep AlertMode and NetMode as SvxLink modules.

Candidates to evaluate on the bench (none is chosen here):

- [f5vmr/SvxLink-Dash](https://github.com/f5vmr/SvxLink-Dash-V3.1) (Flask). Its own notes expect SvxLink 26.05 and can configure simplex/repeater, EchoLink, courtesy tone, and GPIO.
- The Bootstrap dashboards in the same family (SvxLink-Dash V4 / the "Svxlink-Bootstrap" images described around that project). Treat them as separate codebases. Check which one matches the spare's OS before cloning one onto the card.

Still required under this option:

- Express CTCSS, `IDENT_ONLY_AFTER_TX`, courtesy tone, and Morse/voice ident in `svxlink.conf` plus a 26.05-style `events.d/local/` handler. The behavior lives in this fork's settings; the dashboard will not import the SQLite database.
- Revalidate AlertMode and NetMode TCL the same way as the ORP generators. Their voice prompts can keep using `TTS.php` only if something still calls it (a small CLI rebuild is enough). The WAV contract is 16 kHz mono, which is independent of the TCL rewrite.
- EchoLink configuration moves to the dashboard or to `ModuleEchoLink.conf` written by hand.
- Public URL `orp.marionhamradio.com` then points at whatever port the dashboard listens on. Update the Cloudflare tunnel origin when that port changes.

## WireGuard and Cloudflare tunnel

Do this on the spare only after RF, ident, and EchoLink are proven. Config files, keys, and tunnel credentials stay on the hosts. Do not commit them.

- Live overlay peer: name `openrepeater`, address `10.253.0.4`.
- Public name: `orp.marionhamradio.com`.
- Copy the existing WireGuard config onto the spare when cutting over. Reuse the same key and address. A second peer with the same address will collide with the live node, so bring the spare up with WireGuard **down** until the swap.
- Copy `cloudflared` config the same way. Confirm the tunnel still publishes `orp.marionhamradio.com` to the local web port after the swap.
- If Option B changes the local HTTP port, change the tunnel ingress on cutover day and write down the previous ingress for rollback.
- Hostname, DNS, and the tunnel can stay pointed at the live node until the card swap. No dual-publish.

## Cutover and rollback

1. Spare card passes [REBUILD-CHECKLIST.md](REBUILD-CHECKLIST.md) on the bench, including a dummy-load or off-air radio test.
2. Live card is unchanged, labeled, and still boots the current Buster image.
3. Schedule the swap. Power down. Exchange cards (or change the boot device). Leave the old card next to the radio.
4. Confirm COS, PTT, CTCSS, courtesy tone, short ident (including ident-only-after-TX), one EchoLink connection, and one AlertMode or NetMode prompt.
5. Start WireGuard and cloudflared. Confirm `10.253.0.4` and `orp.marionhamradio.com`.
6. Rollback is the old card back in the slot. If the spare used the same WireGuard keys, the old card already has them and should come back as `10.253.0.4` with no registry edit. If the tunnel ingress was edited, restore the previous ingress.

Take a copy of `/var/lib/openrepeater/db/openrepeater.db`, `/etc/svxlink/`, `/etc/openrepeater/`, the sounds directory, and the WireGuard and cloudflared directories **before** the swap, and keep that copy off the new card's git tree.

## What this branch intentionally leaves undone

- No edits under `includes/classes/SVXLink_TCL.php`, `SVXLink.php`, or `functions/svxlink_update.php`.
- No PHP 8 port and no merge from `3.0.x-DEV`.
- No image build, no `orp_helper` rewrite, no systemd units.
- No secrets, tunnel tokens, or host addresses beyond the public name and the overlay address above.
