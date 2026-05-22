<?php
// ─────────────────────────────────────────────────────────────────────────────
//  TTS — shared text-to-speech helper for OpenRepeater modules
//
//  Provides neural speech synthesis via Piper, with automatic fallback to
//  espeak when Piper or the selected voice is unavailable. Used by any module
//  that needs to generate voice-prompt WAVs (AlertMode, NetMode, …).
//
//  Design goals:
//    • One place that knows how to turn text into a svxlink-ready WAV
//      (16 kHz / mono / 16-bit), so modules don't each reimplement it.
//    • No dependency on other ORP classes — reads the settings table via a
//      raw SQLite3 connection, so it works identically in the web context
//      (autoloaded) and in CLI scripts (cli_rebuild.php).
//    • Settings live in the standard `settings` table (tts_* keys) and are
//      bootstrapped with sane defaults on first use, so upgraded installs
//      that predate this feature still work.
//
//  Voice models live under /var/lib/openrepeater/piper/voices as
//  <name>.onnx + <name>.onnx.json pairs (download from
//  https://huggingface.co/rhasspy/piper-voices).
//
//  All methods are static; there is no instance state.
// ─────────────────────────────────────────────────────────────────────────────

class TTS {

	private static $db_path    = '/var/lib/openrepeater/db/openrepeater.db';
	private static $voices_dir = '/var/lib/openrepeater/piper/voices';
	private static $log_file   = '/tmp/orp_tts.log';

	public static function voices_dir() { return self::$voices_dir; }

	// ── Defaults (also used as the seed for missing settings rows) ──────────
	public static function defaults() {
		return [
			'tts_engine'                 => 'piper',   // 'piper' | 'espeak'
			'tts_piper_voice'            => '',        // basename / rel path of .onnx; '' = first found
			'tts_piper_length_scale'     => '1.0',     // speed: <1 faster, >1 slower
			'tts_piper_noise_scale'      => '0.667',   // expressiveness
			'tts_piper_noise_w'          => '0.8',     // phoneme-duration variation
			'tts_piper_sentence_silence' => '0.2',     // seconds of pause between sentences
			'tts_gain_db'                => '0',       // post-synthesis gain (dB), applied by sox
			'tts_espeak_voice'           => 'en-us',   // used when engine=espeak or as fallback
			'tts_target_rate'            => '16000',   // svxlink wants 16 kHz mono
		];
	}

	private static function logln($m) {
		@file_put_contents(self::$log_file, '['.date('c').'] '.$m."\n", FILE_APPEND);
	}

	// Best-effort creation of the voices directory so users have a known place
	// to drop .onnx/.onnx.json files. Failure is non-fatal.
	private static function ensure_dirs() {
		if (!is_dir(self::$voices_dir)) {
			@mkdir(self::$voices_dir, 0755, true);
		}
	}

	// ── Settings: bootstrap defaults (INSERT OR IGNORE) and read ────────────
	public static function get_settings() {
		self::ensure_dirs();
		$defaults = self::defaults();
		$out = $defaults;
		if (!file_exists(self::$db_path)) return $out;
		try {
			$db = new SQLite3(self::$db_path);
			foreach ($defaults as $k => $v) {
				$st = $db->prepare("INSERT OR IGNORE INTO settings (keyID, value) VALUES (:k, :v)");
				$st->bindValue(':k', $k, SQLITE3_TEXT);
				$st->bindValue(':v', $v, SQLITE3_TEXT);
				@$st->execute();
				$st->close();

				$st = $db->prepare("SELECT value FROM settings WHERE keyID = :k");
				$st->bindValue(':k', $k, SQLITE3_TEXT);
				$res = @$st->execute();
				$row = $res ? $res->fetchArray(SQLITE3_ASSOC) : false;
				if ($row && $row['value'] !== '') { $out[$k] = $row['value']; }
				$st->close();
			}
			$db->close();
		} catch (Exception $e) {
			self::logln('get_settings error: '.$e->getMessage());
		}
		return $out;
	}

	// ── Executable discovery ────────────────────────────────────────────────
	private static function find_bin($name, $extra = []) {
		$p = trim((string)@shell_exec('which '.escapeshellarg($name).' 2>/dev/null'));
		if ($p && file_exists($p)) return $p;
		foreach ($extra as $try) { if (file_exists($try)) return $try; }
		return '';
	}

	public static function find_sox() {
		return self::find_bin('sox', ['/usr/bin/sox', '/usr/local/bin/sox']);
	}

	public static function find_espeak() {
		$e = self::find_bin('espeak', ['/usr/bin/espeak', '/usr/local/bin/espeak']);
		if (!$e) $e = self::find_bin('espeak-ng', ['/usr/bin/espeak-ng', '/usr/local/bin/espeak-ng']);
		return $e;
	}

	// Detect a usable Piper. Returns ['style' => 'binary'|'module'|'', 'cmd' => '…'].
	//   'binary' → classic `piper` CLI (pip install piper-tts / prebuilt binary)
	//   'module' → newer piper1-gpl invoked as `python3 -m piper`
	// Result is cached for the lifetime of the request/process (the module
	// probe spawns a subprocess, and synth() may be called many times per build).
	private static $piper_cache = null;
	public static function find_piper() {
		if (self::$piper_cache !== null) return self::$piper_cache;

		$bin = self::find_bin('piper', ['/usr/bin/piper', '/usr/local/bin/piper', '/opt/piper/piper']);
		if ($bin) { return self::$piper_cache = ['style' => 'binary', 'cmd' => escapeshellarg($bin)]; }

		$py = self::find_bin('python3', ['/usr/bin/python3', '/usr/local/bin/python3']);
		if ($py) {
			@exec(escapeshellarg($py).' -m piper --help 2>/dev/null', $o, $rc);
			if ($rc === 0) { return self::$piper_cache = ['style' => 'module', 'cmd' => escapeshellarg($py).' -m piper']; }
		}
		return self::$piper_cache = ['style' => '', 'cmd' => ''];
	}

	public static function piper_available() {
		$p = self::find_piper();
		return $p['style'] !== '';
	}

	// ── Voice discovery ─────────────────────────────────────────────────────
	// Returns a list of ['file'=>full path, 'rel'=>path under voices dir,
	// 'name'=>basename without .onnx], sorted by rel path.
	public static function list_voices() {
		$dir = self::$voices_dir;
		$out = [];
		if (!is_dir($dir)) return $out;
		try {
			$rii = new RecursiveIteratorIterator(
				new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS)
			);
			foreach ($rii as $f) {
				if ($f->isFile() && substr($f->getFilename(), -5) === '.onnx') {
					$full = $f->getPathname();
					$rel  = ltrim(substr($full, strlen($dir)), '/');
					$out[] = [
						'file' => $full,
						'rel'  => $rel,
						'name' => basename($f->getFilename(), '.onnx'),
					];
				}
			}
		} catch (Exception $e) {
			self::logln('list_voices error: '.$e->getMessage());
		}
		usort($out, function($a, $b) { return strcmp($a['rel'], $b['rel']); });
		return $out;
	}

	// Resolve a configured voice string → full .onnx path. Accepts a full
	// path, a path relative to the voices dir, or a bare basename. Falls back
	// to the first available voice if the configured one can't be found.
	public static function resolve_voice($voice) {
		$dir = self::$voices_dir;
		$voice = trim((string)$voice);
		if ($voice !== '') {
			if (file_exists($voice) && substr($voice, -5) === '.onnx') return $voice;
			$cand = $dir.'/'.$voice;
			if (file_exists($cand) && substr($cand, -5) === '.onnx') return $cand;
			if (file_exists($cand.'.onnx')) return $cand.'.onnx';
			foreach (self::list_voices() as $v) {
				if ($v['name'] === $voice || $v['rel'] === $voice || basename($v['file']) === $voice) {
					return $v['file'];
				}
			}
		}
		$all = self::list_voices();
		return $all ? $all[0]['file'] : '';
	}

	// ── Core synthesis ──────────────────────────────────────────────────────
	// Synthesize $text into $out_wav (16 kHz mono 16-bit). $opts overrides any
	// setting (used by the live preview before saving). Returns bool success.
	public static function synth($text, $out_wav, $opts = []) {
		$s    = array_merge(self::get_settings(), is_array($opts) ? $opts : []);
		$sox  = self::find_sox();
		$rate = (int)($s['tts_target_rate'] ?: 16000);
		if ($rate <= 0) $rate = 16000;

		$engine = ($s['tts_engine'] === 'espeak') ? 'espeak' : 'piper';
		$raw = $out_wav.'.tts_raw.wav';
		$ok  = false;

		if ($engine === 'piper') {
			$ok = self::synth_piper($text, $raw, $s);
			if (!$ok) self::logln('piper synthesis failed; trying espeak fallback');
		}
		if (!$ok) {
			$ok = self::synth_espeak($text, $raw, $s);
		}
		if (!$ok) { @unlink($raw); return false; }

		// Normalize to svxlink format (target rate, mono, 16-bit) + optional gain.
		if ($sox) {
			$gain = (float)$s['tts_gain_db'];
			$gain_arg = ($gain != 0.0) ? ' gain '.escapeshellarg(sprintf('%.2f', $gain)) : '';
			exec($sox.' '.escapeshellarg($raw).' -r '.$rate.' -c 1 -b 16 '.escapeshellarg($out_wav).$gain_arg.' 2>>'.escapeshellarg(self::$log_file), $o, $rc);
			if ($rc === 0 && file_exists($out_wav) && filesize($out_wav) > 0) {
				@unlink($raw);
				return true;
			}
			self::logln('sox normalize failed rc='.$rc.'; using raw output');
		}
		@rename($raw, $out_wav);
		return file_exists($out_wav) && filesize($out_wav) > 0;
	}

	private static function synth_piper($text, $raw_wav, $s) {
		$piper = self::find_piper();
		if ($piper['style'] === '') { self::logln('piper not found'); return false; }
		$voice = self::resolve_voice($s['tts_piper_voice']);
		if ($voice === '') { self::logln('no piper voice available on disk ('.self::$voices_dir.')'); return false; }

		// Feed text via a temp file to avoid any shell-escaping pitfalls.
		$txt = $raw_wav.'.txt';
		@file_put_contents($txt, $text);

		$args = self::piper_args($piper['style'], $voice, $raw_wav, $s);
		$cmd  = $piper['cmd'].' '.$args.' < '.escapeshellarg($txt).' 2>>'.escapeshellarg(self::$log_file);
		@exec($cmd, $o, $rc);
		@unlink($txt);

		$ok = ($rc === 0 && file_exists($raw_wav) && filesize($raw_wav) > 0);
		self::logln('piper '.($ok ? 'OK' : 'FAIL rc='.$rc).' voice='.basename($voice).' style='.$piper['style'].' -> '.basename($raw_wav));
		return $ok;
	}

	// Build Piper CLI args. Flag spelling differs between the classic binary
	// (underscores) and piper1-gpl run as a module (hyphens).
	private static function piper_args($style, $voice, $out_wav, $s) {
		if ($style === 'module') {
			$a  = '--model '.escapeshellarg($voice);
			$a .= ' --output-file '.escapeshellarg($out_wav);
			$a .= ' --length-scale '.escapeshellarg($s['tts_piper_length_scale']);
			$a .= ' --noise-scale '.escapeshellarg($s['tts_piper_noise_scale']);
			$a .= ' --noise-w-scale '.escapeshellarg($s['tts_piper_noise_w']);
			$a .= ' --sentence-silence '.escapeshellarg($s['tts_piper_sentence_silence']);
			return $a;
		}
		// classic binary
		$a  = '--model '.escapeshellarg($voice);
		$a .= ' --output_file '.escapeshellarg($out_wav);
		$a .= ' --length_scale '.escapeshellarg($s['tts_piper_length_scale']);
		$a .= ' --noise_scale '.escapeshellarg($s['tts_piper_noise_scale']);
		$a .= ' --noise_w '.escapeshellarg($s['tts_piper_noise_w']);
		$a .= ' --sentence_silence '.escapeshellarg($s['tts_piper_sentence_silence']);
		return $a;
	}

	private static function synth_espeak($text, $raw_wav, $s) {
		$espeak = self::find_espeak();
		if ($espeak === '') { self::logln('espeak not found'); return false; }
		$voice = $s['tts_espeak_voice'] ?: 'en-us';
		$cmd = $espeak.' -v '.escapeshellarg($voice).' -w '.escapeshellarg($raw_wav).' '.escapeshellarg($text).' 2>>'.escapeshellarg(self::$log_file);
		@exec($cmd, $o, $rc);
		$ok = (file_exists($raw_wav) && filesize($raw_wav) > 0);
		self::logln('espeak '.($ok ? 'OK' : 'FAIL rc='.$rc).' voice='.$voice.' -> '.basename($raw_wav));
		return $ok;
	}

	// Human-readable status string for the settings UI (which engine/voice is live).
	public static function status_summary() {
		$s = self::get_settings();
		$piper = self::find_piper();
		$parts = [];
		$parts[] = 'Engine: '.$s['tts_engine'];
		if ($piper['style'] !== '') {
			$parts[] = 'Piper: available ('.$piper['style'].')';
		} else {
			$parts[] = 'Piper: NOT found';
		}
		$parts[] = 'espeak: '.(self::find_espeak() ? 'available' : 'NOT found');
		$parts[] = 'sox: '.(self::find_sox() ? 'available' : 'NOT found');
		$voices = self::list_voices();
		$parts[] = count($voices).' voice'.(count($voices) === 1 ? '' : 's').' on disk';
		return implode(' · ', $parts);
	}
}
?>
