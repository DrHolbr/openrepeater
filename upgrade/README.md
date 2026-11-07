# upgrade/

Staging notes for the SvxLink 26 / Pi OS rebuild. This directory is documentation only. It does not build an image and it does not replace the generators under `includes/classes/` or `functions/`.

Read these, in order:

1. [docs/UPGRADE-SVXLINK-26.md](../docs/UPGRADE-SVXLINK-26.md) — target OS, SvxLink 26.05.2, TCL inheritance break, Option A vs Option B, WireGuard / Cloudflare, rollback.
2. [docs/CUSTOM-SURFACE.md](../docs/CUSTOM-SURFACE.md) — fork vs stock OpenRepeater 2.1.3, and which files must be revalidated.
3. [docs/REBUILD-CHECKLIST.md](../docs/REBUILD-CHECKLIST.md) — spare-card order of operations.

## Scratch facts (so the next edit starts in the right files)

Live path today: `functions/svxlink_update.php` → `SVXLink_TCL` + `SVXLink::write_config()`.

| Output | Path written now | 26.05 expectation |
| --- | --- | --- |
| `ORP_RepeaterLogic_PortN.tcl`, `ORP_SimplexLogic_PortN.tcl` | `/usr/share/svxlink/events.d/` | Do not write here. Per-instance logic TCL files are obsolete. |
| `Logic.tcl` (`send_short_ident`, `send_long_ident`) | `/usr/share/svxlink/events.d/local/` | Allowed only as a small, correctly named local override. |
| `svxlink.conf`, `gpio.conf` | `/etc/svxlink/` | Conf keys need a manual check. `gpio.conf` still describes sysfs (`/sys/class/gpio`). |
| Courtesy tone | Regex replace of `send_rgr_sound` inside the copied repeater file | One local handler. |

`functions/svxlink_update_functions/tcl_*.php` is unused by `svxlink_update.php`. Do not wire those includes back up.

Hierarchy to target when a generator is eventually rewritten:

```text
LogicBase -> Logic -> RepeaterLogicType -> RepeaterLogic
```

Local file rules: empty file, namespace, only the handlers that change, `override` / `$SUPER` for a partial change, confirm the filename in the SvxLink startup log.

UI decision is open. Option A keeps this ORP tree. Option B uses a SvxLink-Dash / Bootstrap dashboard and keeps AlertMode and NetMode as modules. Neither is implemented in this branch.
