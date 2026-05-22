# OpenRepeater — Piper TTS

Both **AlertMode** and **NetMode** now generate their voice prompts through a
shared TTS helper that uses **Piper** (a fast, local neural TTS) instead of
eSpeak. A new **Text-to-Speech** section in **General Settings** lets you pick
the voice and tune speed / expressiveness / volume, with a **Test Voice**
button for instant previews. eSpeak remains as an automatic fallback.

## What changed

| File | Change |
|------|--------|
| `includes/classes/TTS.php` | **New.** Shared synthesis helper (Piper + espeak fallback + sox normalization). Autoloaded in the web UI and reachable from the modules' `cli_rebuild.php`. |
| `functions/tts_preview.php` | **New.** Streams a sample WAV for the Test Voice button. |
| `settings.php` | Added the Text-to-Speech settings section. |
| `includes/js/page-settings.js` | Added the Test Voice handler. |
| `modules/AlertMode/build_config.php` | Prompts now generated via `TTS::synth()`. |
| `modules/NetMode/build_config.php` | Prompts now generated via `TTS::synth()`. |
| `modules/NetMode/custom_submit.php` | (From the prior fix) preserves the `nets` array on form save. |

No database migration is needed — the `tts_*` settings rows are created
automatically the first time you open General Settings or rebuild.

## One-time host setup

Piper and its voices are **not** bundled (the voice models are tens of MB
each). Install them on the repeater host:

### 1. Install Piper

On a Raspberry Pi / Debian:

```bash
sudo apt update && sudo apt install -y sox        # if not already present
pip install piper-tts                              # provides the `piper` command
```

If `pip install piper-tts` isn't an option on your platform, download a
prebuilt binary from https://github.com/rhasspy/piper/releases and put `piper`
somewhere on `PATH` (e.g. `/usr/local/bin/piper`). The newer `piper1-gpl`
(`pip install piper1-gpl`, invoked as `python3 -m piper`) is also detected
automatically.

Verify:

```bash
echo "hello from the repeater" | piper --model /tmp/none 2>&1 | head    # should complain about model, not "command not found"
```

### 2. Install at least one voice

Voices are `<name>.onnx` + `<name>.onnx.json` pairs. Put **both** files in:

```
/var/lib/openrepeater/piper/voices/
```

(That directory is created automatically the first time the TTS code runs; you
can also `sudo mkdir -p` it.) Example — the popular US English "lessac" medium
voice:

```bash
cd /var/lib/openrepeater/piper/voices
sudo wget https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx
sudo wget https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json
```

Browse and listen to all voices at https://rhasspy.github.io/piper-samples/ ,
then grab the matching files from
https://huggingface.co/rhasspy/piper-voices .

You can drop multiple voices in that folder; they'll all appear in the
**Piper Voice** dropdown.

### 3. Permissions

The voice files just need to be world-readable (the default after `wget`).
Synthesis runs as the web user during a normal rebuild and as root during a
DTMF-triggered rebuild (via the existing `cli_rebuild.php` sudo rule), so make
sure `/var/lib/openrepeater/piper/voices/` is readable by both (it is by
default).

## Using it

1. Open **General Settings → Text-to-Speech**.
2. The **Status** line shows what was detected (Piper available?, voices on
   disk, sox, espeak).
3. Pick a **Piper Voice**, adjust **Speed** (`length_scale`),
   **Expressiveness** (`noise_scale`), **Sentence Pause**, and **Volume Gain**.
4. Click **Test Voice** to hear a sample immediately (nothing is saved yet —
   it previews the values currently in the form).
5. Settings auto-save on change (same as the rest of General Settings).
6. Click **Rebuild & Restart** so AlertMode/NetMode regenerate their prompts
   with the new voice.

## Tuning tips for repeater audio

- **Speed (`length_scale`)**: 1.0 is natural; `0.9` is a touch quicker and
  crisper for short IDs. Values below ~0.8 start to sound rushed over RF.
- **Expressiveness (`noise_scale`)**: the 0.667 default is fine. Drop toward
  `0.4` for a flatter, more "announcer" feel.
- **Volume Gain**: if Piper speech sits quieter than your courtesy tones,
  add `+3` to `+6` dB.
- **Voice quality level**: `medium` voices are the sweet spot for a Pi. `high`
  voices sound better but use noticeably more CPU per prompt; `low`/`x_low`
  are faster but rougher.

## Fallback behaviour

If Piper isn't installed, no voice is selected, or synthesis fails for any
prompt, the helper automatically falls back to eSpeak so announcements still
work. Set **Engine** to **eSpeak** explicitly if you'd rather not use Piper at
all. Synthesis activity is logged to `/tmp/orp_tts.log`.
