# GPIO map for the bench UI

This map is a naming table. It is not a wiring diagram for `orp-test`, and it is not permission to drive a pin. No `gpioinfo` capture from the Pi is included here. The 7:29 PM EST snapshot did not have PHP, nginx, or a GPIO listing. Every output below stays disconnected.

## How to read a row

| Column | Meaning |
| --- | --- |
| Logical name | The OpenRepeater field or the signal name in a source document (`rxGPIO`, `txGPIO`, `COS`, `PTT`, `GPA2`). |
| Stored number | The integer written in that source. It is not automatically a BCM offset, a header pin, or a libgpiod line. |
| Direction | `in`, `out`, or a non-electrical label such as `manual` or `comment`. |
| Preset active | The active level stored next to that number (`high` or `low`). Empty when the source does not state one. This is not a measurement of a switch on the bench. |
| Class | `bcm_header_candidate` when the stored number is 0–27. `conditional_mcp23017_offset` when it is 496–511 and only if the old kernel base was 496. Anything else is `unresolved_evidence_gap`. |
| BCM | Set only for a header candidate. It is the same integer as the stored number. |
| Physical pin | The 40-pin header pin for that BCM number. Absent for unresolved numbers. |
| libgpiod chip / offset | Always empty in this stage. Nothing is passed to SvxLink as `SQL_GPIOD_*` or `PTT_GPIOD_*`. |
| Drivable | Always no. The UI does not export the line, request it as an output, or run `gpioset`. |

Header candidates use the standard 40-pin map (BCM 26 is physical pin 37, BCM 23 is physical pin 16, BCM 24 is pin 18, BCM 25 is pin 22, BCM 13 is pin 33, BCM 27 is pin 13, BCM 12 is pin 32). That translation is a naming aid. It does not mean a wire is attached on this Pi, and it does not mean `gpiochip0` was observed.

## What the bootstrap build implies

The bench bootstrap configures SvxLink with `CMAKE_DISABLE_FIND_PACKAGE_GPIOD=TRUE`, prefix `/usr/local`, and `SYSCONF_INSTALL_DIR=/etc`. `libgpiod3` is installed on the image. The SvxLink binary this bootstrap is compiling is not being linked to it. This UI therefore does not publish GPIOD squelch or PTT into that tree, and it does not rebuild SvxLink to turn GPIOD on. Read-only diagnostics, when the `gpiod` tools package is present, are `gpioinfo` with no arguments. `gpioget` and `gpioset` are not called.

## ORP board presets

Source: `includes/board_definitions.php`. These are presets a wizard can copy into the database. They are not a survey of `orp-test`.

### ICS Controllers Pi Repeater 2X, version 3.1+

| Logical | Stored | Direction | Preset active | Class | BCM | Physical | Note |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Port 1 `rxGPIO` | 26 | in | low | header candidate | 26 | 37 | COS name in the ICS manual also uses GPIO26 |
| Port 1 `txGPIO` | 498 | out | high | conditional offset 2, GPA2 if base 496 | | | Not a BCM number. Chip absent on orp-test. Not programmed |
| Port 2 `rxGPIO` | 23 | in | low | header candidate | 23 | 16 | COS name in the ICS manual also uses GPIO23 |
| Port 2 `txGPIO` | 499 | out | high | conditional offset 3, GPA3 if base 496 | | | Not a BCM number. Chip absent on orp-test. Not programmed |

The same file's comments, marked "Not Yet Supported by ORP", list CTCSS1 24 low, CTCSS2 25 low, CTCSS_ENC1 13 low, and CTCSS2_ENC 27 low. Those are comments, not configured pins. If the numbers were BCM values they would be header pins 18, 22, 33, and 13. The comments do not say a connector on this bench uses them.

### ICS Controllers Pi Repeater 2X, version 2.1 prototype

Same stored numbers as 3.1+ for the two ports. The prototype stores both TX lines as active **low**. The 3.1+ preset stores them as active **high**. Both are kept. Neither is driven. The difference is the preset text, not a measured polarity.

### ICS Controllers Pi Repeater 1X, version 1.0+

Port 1 only: RX 26 active low (header candidate, BCM 26, physical 37), TX 498 active high (conditional MCP23017 offset 2, GPA2 only if the base was 496, not driven).

### Other presets in the same file

These are other products in the preset list, not an identification of the bench board.

| Board | Logical | Stored | Direction | Preset active | Class | BCM | Physical |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F5UII/F8ASB SVXLink Card 1.11+ port 1 | rx / tx | 19 / 16 | in / out | low / high | header candidate | 19 / 16 | 35 / 36 |
| F5UII/F8ASB SVXLink Card 1.11+ port 2 | rx / tx | 18 / 17 | in / out | low / high | header candidate | 18 / 17 | 12 / 11 |
| Richard Neese SVXLink Basic Board 1.0 port 1 | rx / tx | 23 / 24 | in / out | high / high | header candidate | 23 / 24 | 16 / 18 |
| Richard Neese SVXLink Basic Board 1.0 port 2 | rx / tx | 25 / 18 | in / out | high / high | header candidate | 25 / 18 | 22 / 12 |

The F5UII card also lists relay GPIOs 20, 21, 22, and 23 as outputs in a module block. They remain not drivable. Relay 23 collides as a number with the ICS port 2 RX candidate; they are different presets.

## ICS manual baseline

Source: ICS PI-REPEATER-2X manual, section "Hardware GPIO Pin number assignments" (HW3.x / HW4.x text). The manual says expander numbers move between Raspberry Pi models and OS revisions, and that the table is a Pi 3B baseline (a Pi Zero needs a further offset above 128). The same manual's 40-pin header drawing labels physical pin 37 as COS port 1, pin 16 as COS port 2, pin 18 as CTCSS port 1, pin 22 as CTCSS port 2, pin 33 as CTCSS EN port 1, pin 13 as CTCSS EN port 2, and pin 32 as `GPIO_INTA`. The overlay example in that manual is `dtoverlay=mcp23017,addr=0x20,gpiopin=12`. COS polarity is described as switch-selectable on the board. That switch position was not read on `orp-test`.

Reading of the assignment table:

| Signal | Port 1 stored | Port 2 stored | Expander name | Expander stored |
| --- | --- | --- | --- | --- |
| PTT | 506 | 507 | GPA0 | 496 |
| COS | 26 | 23 | GPA1 | 497 |
| CTCSS | 24 | 25 | GPA2 | 498 |
| TX audio | right / left (not a GPIO) | | GPA3 | 499 |
| RX audio | right / left (not a GPIO) | | GPA4 | 500 |
| | | | GPA5–GPA7 | 501–503 |

506, 507, and 496–503 are not BCM offsets and not header pins. If the old kernel base was 496, the stored number minus 496 is the MCP23017 line offset. The manual names 496–503 as GPA0–GPA7. It does not name an MCP pin for 506 or 507, so those stay offsets 10 and 11 with no invented GPB name. orp-test has no MCP23017, so the line is absent and activation is not applied. `gpioinfo` has not been captured for this page.

## Conflict that this stage does not resolve

Three different TX numbers exist in the repository:

| Source | Port 1 TX number | Active level |
| --- | --- | --- |
| `board_definitions.php` ICS 2X 3.1+ | 498 | high |
| `board_definitions.php` ICS 2X prototype | 498 | low |
| `install/sql/openrepeater.db` `ports` and `gpio_pins` | 506 | high |
| ICS manual Pi 3B baseline | 506 | not stated as a software level |

The stock database row is `gpio_num=506`, direction `out`, active `high`, description `PORT 1 TX: Port 1`. Its RX row is 26, direction `in`, active `low`. 506 matches the manual's PTT baseline and is offset 10 only if the base was 496. 498 matches the manual's GPA2 baseline, not its PTT row. Neither number is written as `PTT_PIN` or `gpio498`. The bench UI does not drive either line.

The database also contains sample module option text. That text is not station credentials for this bench and is not repeated here. Review it on the Pi before any network module is enabled. This install does not enable modules and does not start SvxLink.

## What the software does with this table

With `/etc/openrepeater/bench-mode` present:

- `SVXLink_GPIO` writes a preview with empty `GPIO_IN_*` and `GPIO_OUT_*` lists and no `GPIO_PATH=/sys/class/gpio`.
- Preview `svxlink.conf` comments `PTT_*`, `GPIO_SQL_PIN`, and `SQL_DET=GPIO` / `GPIOD`.
- Those files go to `/var/lib/openrepeater/bench-preview`, not `/etc/svxlink`, `/etc/openrepeater/svxlink`, `/usr/share/svxlink`, or `/usr/local/share/svxlink`.
- The GPIO Map page is read-only. POST is refused. The only external command it may run is `gpioinfo` with no arguments.

Without the marker, the old sysfs `gpio.conf` text is unchanged so this branch does not alter an unmarked host's writer. The installer creates the marker only after the bench checks pass.
