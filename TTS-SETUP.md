# OpenRepeater — Text-to-Speech (Flite, Pic02wave, eSpeak)

**AlertMode** and **NetMode** now generate their voice prompts through a shared
TTS helper that supports **Flite** (default, recommended), **Pic02wave** (optional),
and **eSpeak** (automatic fallback). A new **Text-to-Speech** section in **General
Settings** lets you pick the engine and voice, adjust volume, and instantly preview
with a **Test Voice** button.

## What changed

| File | Change |
|------|--------|
| `includes/classes/TTS.php` | **Rewritten.** Shared synthesis helper (Flite + Pic02wave + espeak fallback + sox normalization). Autoloaded in the web UI and reachable from the modules' `cli_rebuild.php`. |
| `functions/tts_preview.php` | Updated parameter mapping for new engines. |
| `settings.php` | Updated the Text-to-Speech settings section. |
| `includes/js/page-settings.js` | (No changes needed; Test Voice handler still works). |
| `modules/AlertMode/build_config.php` | (No changes needed; uses `TTS::synth()` as before). |
| `modules/NetMode/build_config.php` | (No changes needed; uses `TTS::synth()` as before). |

No database migration is needed — the `tts_*` settings rows are created
automatically the first time you open General Settings or rebuild.

## One-time host setup

Flite is **included by default** on most Debian/Raspberry Pi systems. Pic02wave
and eSpeak are optional but recommended as fallbacks. Install on the repeater host:

### 1. Install Flite (likely already present)

On Raspberry Pi / Debian:

```bash
sudo apt update && sudo apt install -y flite sox
```

Verify:

```bash
flite -v slt -t "hello repeater"    # should generate a WAV file
```

### 2. (Optional) Install Pic02wave for additional options

```bash
sudo apt install -y pic2wave
```

Verify:

```bash
echo "hello repeater" | pic02wave > /tmp/test.wav && file /tmp/test.wav
```

### 3. (Recommended) Install eSpeak as a fallback

```bash
sudo apt install -y espeak
```

Verify:

```bash
espeak -v en-us -w /tmp/test.wav "hello repeater" && file /tmp/test.wav
```

All three tools should already be available on most Debian Buster+ systems.

## Using it

1. Open **General Settings → Text-to-Speech**.
2. The **Status** line shows which engines were detected (Flite, Pic02wave, eSpeak, sox).
3. Pick an **Engine**: Flite (recommended), Pic02wave, or eSpeak.
4. For **Flite**, choose a voice:
   - **SLT** (female, recommended for announcements)
   - **AWB** (male)
   - **Kal** (male)
   - **RMS** (male)
5. Adjust **Volume Gain** (dB) if needed (e.g., `+3` to `+6` dB if speech is too quiet).
6. Click **Test Voice** to hear a sample immediately (nothing is saved yet).
7. Settings auto-save on change (same as the rest of General Settings).
8. Click **Rebuild & Restart** so AlertMode/NetMode regenerate their prompts.

## Tuning tips for repeater audio

- **Flite voices**: SLT produces the clearest speech for repeater announcements.
- **Volume Gain**: if synthesis output sits quieter than your courtesy tones, add `+3` to `+6` dB.
- **Pic02wave**: primarily for experimentation; eSpeak fallback is more reliable.
- **eSpeak**: used automatically as a fallback if the primary engine isn't available or fails.

## Fallback behaviour

If the configured engine isn't installed, fails to synthesize a prompt, or produces
invalid output, the system automatically falls back to **eSpeak** so announcements
still work. If eSpeak also fails, synthesis returns an error and the module rebuild fails
gracefully. Synthesis activity is logged to `/tmp/orp_tts.log`.
