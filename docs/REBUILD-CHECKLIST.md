# Spare-card bring-up checklist

Ordered work for a **second** Raspberry Pi and a blank SD card. The live repeater (ORP 2.1.3, Buster, SvxLink 19.09.1, UI `orp.marionhamradio.com`, WireGuard `openrepeater` = `10.253.0.4`) stays in service and is not upgraded in place.

Check the box on the bench log, not in this file. This file is the order of operations. Background and the A/B UI choice are in [UPGRADE-SVXLINK-26.md](UPGRADE-SVXLINK-26.md). File-level risks are in [CUSTOM-SURFACE.md](CUSTOM-SURFACE.md).

**Stop rule.** If a step fails, fix it before the next step. Do not open the ORP **Rebuild & Restart** button against this card until step 8 explicitly allows it.

## 0. Before touching a new image

- [ ] Spare Pi and blank card identified. Live card labeled and left in the radio until cutover day.
- [ ] Note the live board (ICS Pi Repeater preset or whatever `gpio.conf` and ALSA actually show), callsign, CTCSS frequencies, ident mode, and whether ident-only-after-TX is on. Read them from the live UI or database when host access exists. Do not invent them here.
- [ ] When host access exists, copy off-box and **do not commit**: `openrepeater.db`, `/etc/svxlink/`, sounds under `/var/lib/openrepeater/sounds/`, AlertMode and NetMode module directories, WireGuard config, cloudflared config. Keys stay in that offline copy.
- [ ] Record SvxLink's exact version string from the live node (`svxlink --version`) so the "19.09.1 lineage" note can be confirmed or corrected.

## 1. Operating system

- [ ] Flash Raspberry Pi OS **64-bit Lite**. First choice: **Trixie**. If the Pi model, ICS codec, or a required package is unavailable, reflash **Bookworm 64-bit Lite** and stay there.
- [ ] Write the OS name, image date, and Pi model into the bench log.
- [ ] Boot on the bench with no radio connected. User, hostname, timezone, and SSH for the bench only.
- [ ] `apt update` and install current packages **for that release**. Do not add Buster archive lines. Do not dist-upgrade a Buster root into this card.

## 2. Audio and GPIO

- [ ] The ICS (or other) audio device appears in `aplay -l` / `arecord -l`. Record card and device numbers. The 2X preset in git expects `alsa:plughw:0` channel 1 and channel 0; the spare may enumerate differently.
- [ ] Mixer: for the ICS preset, `Lineout` at `80% unmute` is the fork's known-good starting point (`includes/board_definitions.php`). Confirm the control actually exists (`amixer scontrols`). Names change between images.
- [ ] Playback and capture with `aplay` / `arecord` through the repeater audio path (speaker or dummy load, not the live antenna).
- [ ] GPIO: identify the libgpiod chip and line for COS and PTT. The in-tree 2X preset lists RX 26 and 23 and TX **498** and **499**. Treat 498/499 as Buster-era numbers to translate, not as lines to export.
- [ ] COS follows the receiver. PTT keys the transmitter. Active-high vs active-low matches the live node.
- [ ] SvxLink 26's GPIO configuration is in use. `GPIO_PATH=/sys/class/gpio` from `includes/classes/SVXLink_GPIO.php` is not copied onto this card.

## 3. Stock SvxLink 26.05.2

- [ ] Install SvxLink. `svxlink --version` prints **26.05.2**. If apt offers an older build, install the `26.05.2` tag from upstream instead of settling.
- [ ] Hand-write a minimal `svxlink.conf`: one local RX, one local TX, one repeater logic, `EVENT_HANDLER` left at the 26.05 default. No `ORP_*.tcl`. No files copied from the live `/usr/share/svxlink/events.d/`.
- [ ] `svxlink` starts, logs a clean startup, and prints which TCL files it loaded.
- [ ] Receiver opens squelch, transmitter follows, hang time is sane, timeout fires.
- [ ] Add CTCSS with the live frequencies. Confirm the 26.05 key names (`CTCSS_FQ`, open/close thresholds, `CTCSS_LEVEL`, `SQL_DET`, `TX_CTCSS`, `REPORT_CTCSS`) before copying values from the old config.
- [ ] Add `IDENT_ONLY_AFTER_TX` only after the 26.05 manual still documents that key. Prove both states: periodic ident, and ident only after a transmission.
- [ ] Stock courtesy tone and stock ident (Morse or voice) behave correctly **before** any local TCL file exists.

## 4. One local TCL override

Do this before porting `SVXLink_TCL`.

- [ ] Add a single file under `/usr/share/svxlink/events.d/local/` that 26.05 actually loads (startup log names it).
- [ ] The file contains one namespace and one handler (courtesy `send_rgr_sound` **or** short ident, not both).
- [ ] It does not copy `RepeaterLogic.tcl`. It uses `override` and `$SUPER` if the stock handler should still run.
- [ ] Restart. The behavior matches the live node for that one feature.
- [ ] Remove the file. Stock behavior returns. Put the file back.
- [ ] Then add the second handler the same way. Logic-level vs repeater-level is chosen so a simplex link port is not given repeater ident audio by accident.

## 5. EchoLink

- [ ] `ModuleEchoLink.conf` written from the 26.05 module documentation, using the station's existing EchoLink credentials from the offline copy.
- [ ] Module loads. One outbound test connection works. DTMF enable/disable matches the live node.
- [ ] The ORP `modules/EchoLink/` PHP generator is not used for this test.

## 6. AlertMode and NetMode

- [ ] Source the modules from the live web root or from `DrHolbr/openrepeater-modules`. They are gitignored in this repo (`modules/.gitignore` keeps only Help, Parrot, and EchoLink).
- [ ] Diff any TCL they install against the 26.05 rules in the upgrade doc. Load them only after stock SvxLink still starts with those files removed.
- [ ] Install `flite` and `sox`. Install `espeak` or `espeak-ng`. Install Pic02wave only if that engine is actually selected; the binary name in `TTS.php` is `pic02wave`.
- [ ] Generate one prompt WAV at 16 kHz mono (the `TTS::synth()` contract) and play it through the module on the bench.
- [ ] Module enable, DTMF, and the announcement content match the live station.

## 7. Cloudflare tunnel and WireGuard

Leave both **stopped** on the spare while the live node is on the air.

- [ ] Bench hostname resolves only on the bench LAN.
- [ ] WireGuard config is present and **not** running. Peer name `openrepeater`, address `10.253.0.4`, same keys as the live node. No second active peer.
- [ ] cloudflared config is present and **not** running. Ingress still documents `orp.marionhamradio.com` and the local web port. If Option B changes that port, write the new ingress beside the old one and apply it only at cutover.
- [ ] Firewall on the spare matches the live node's exposed services. No extra ports opened "for testing" and left open.

## 8. Choose the UI (after 3–6 pass)

- [ ] **Option A** or **Option B** recorded in the bench log, with a reason. See the upgrade doc. This checklist does not authorize the choice in advance.
- [ ] Option A: ORP from `alertmode-dev` is installed, PHP version is the OS default, pages load, and **Rebuild & Restart stays disabled** until `SVXLink_TCL` / `write_config()` no longer write into `events.d/` or emit sysfs GPIO. `orp_helper` exists or restarts are manual.
- [ ] Option B: the chosen SvxLink-Dash / Bootstrap dashboard is the only UI. Ident, CTCSS, courtesy, and EchoLink are whatever passed in steps 3–5. AlertMode and NetMode stay modules.
- [ ] A settings change in the chosen UI restarts SvxLink and leaves the last-known-good config restorable (copy of `/etc/svxlink` taken before the change).

## 9. Cutover

- [ ] Bench test on a dummy load or off-air radio: COS, PTT, CTCSS, courtesy, short ident, ident-only-after-TX, EchoLink, one voice prompt.
- [ ] Live card still boots. Offline backup from step 0 is readable.
- [ ] Power down, swap the card, power up.
- [ ] Repeat the RF checks on the real radio.
- [ ] Start WireGuard. `10.253.0.4` answers and the live card is powered off so the address is unique.
- [ ] Start cloudflared. `https://orp.marionhamradio.com` reaches this card.
- [ ] Rollback drill is understood by the person on site: old card back in the slot, restore tunnel ingress if it was edited. Old card keeps the same WireGuard keys.

## Out of scope for this checklist

- Dist-upgrading the live Buster card.
- Merging `3.0.x-DEV` into `alertmode-dev`.
- Rewriting the PHP/TCL generators (that is follow-up engineering after step 4 shows the new handler shape).
- Committing database files, sound libraries, WireGuard keys, or tunnel credentials.
