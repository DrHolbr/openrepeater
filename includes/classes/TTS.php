<?php
// ─────────────────────────────────────────────────────────────────────────────
//  TTS — shared text-to-speech helper for OpenRepeater modules
//
//  Provides speech synthesis via flite (default), pic02wave (optional), or
//  espeak (fallback). Used by any module that needs to generate voice-prompt
//  WAVs (AlertMode, NetMode, …).
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
//    • Engines are tried in priority order: primary engine → espeak fallback
//
//  All methods are static; there is no instance state.
// ─────────────────────────────────────────────────────────────────────────────

class TTS {

	private static $db_path    = '/var/lib/openrepeater/db/openrepeater.db';
	private static $log_file   = '/tmp/orp_tts.log';

	// ── Defaults (also used as the seed for missing settings rows) ──────────
	public static function defaults() {
		return [
			'tts_engine'            => 'flite',   // 'flite' | 'pic02wave' | 'espeak'
			'tts_flite_voice'       => 'slt',     // flite voice name (slt, awb, kal, rms; slt is best for announcements)
			'tts_pic02wave_voice'   => 'default', // pic02wave voice option
			'tts_gain_db'           => '0',       // post-synthesis gain (dB), applied by sox
			'tts_espeak_voice'      => 'en-us',   // used when engine=espeak or as fallback
			'tts_target_rate'       => '16000',   // svxlink wants 16 kHz mono
		];
	}

	private static function logln($m) {
		@file_put_contents(self::$log_file, '['.date('c').'] '.$m."\n", FILE_APPEND);
	}

	// ── Settings: bootstrap defaults (INSERT OR IGNORE) and read ────────────
	public static function get_settings() {
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

	public static function find_flite() {
		return self::find_bin('flite', ['/usr/bin/flite', '/usr/local/bin/flite']);
	}

	public static function find_pic02wave() {
		return self::find_bin('pic02wave', ['/usr/bin/pic02wave', '/usr/local/bin/pic02wave']);
	}

	public static function find_sox() {
		return self::find_bin('sox', ['/usr/bin/sox', '/usr/local/bin/sox']);
	}

	public static function find_espeak() {
		$e = self::find_bin('espeak', ['/usr/bin/espeak', '/usr/local/bin/espeak']);
		if (!$e) $e = self::find_bin('espeak-ng', ['/usr/bin/espeak-ng', '/usr/local/bin/espeak-ng']);
		return $e;
	}

	// ── Core synthesis ──────────────────────────────────────────────────────
	// Synthesize $text into $out_wav (16 kHz mono 16-bit). $opts overrides any
	// setting (used by the live preview before saving). Returns bool success.
	// Tries configured engine first, then falls back to espeak if it fails.
	public static function synth($text, $out_wav, $opts = []) {
		$s    = array_merge(self::get_settings(), is_array($opts) ? $opts : []);
		$sox  = self::find_sox();
		$rate = (int)($s['tts_target_rate'] ?: 16000);
		if ($rate <= 0) $rate = 16000;

		$engine = $s['tts_engine'] ?: 'flite';
		$raw = $out_wav.'.tts_raw.wav';
		$ok  = false;

		// Try primary engine first
		if ($engine === 'flite') {
			$ok = self::synth_flite($text, $raw, $s);
			if (!$ok) self::logln('flite synthesis failed; trying espeak fallback');
		} elseif ($engine === 'pic02wave') {
			$ok = self::synth_pic02wave($text, $raw, $s);
			if (!$ok) self::logln('pic02wave synthesis failed; trying espeak fallback');
		} elseif ($engine === 'espeak') {
			$ok = self::synth_espeak($text, $raw, $s);
		}

		// Fallback to espeak if primary engine failed
		if (!$ok && $engine !== 'espeak') {
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

	private static function synth_flite($text, $raw_wav, $s) {
		$flite = self::find_flite();
		if ($flite === '') { self::logln('flite not found'); return false; }
		$voice = $s['tts_flite_voice'] ?: 'slt';
		
		// Use temp file to avoid shell escaping issues
		$txt = $raw_wav.'.txt';
		@file_put_contents($txt, $text);
		
		$cmd = $flite.' -voice '.escapeshellarg($voice).' -f '.escapeshellarg($txt).' -o '.escapeshellarg($raw_wav).' 2>>'.escapeshellarg(self::$log_file);
		@exec($cmd, $o, $rc);
		@unlink($txt);
		
		$ok = ($rc === 0 && file_exists($raw_wav) && filesize($raw_wav) > 0);
		self::logln('flite '.($ok ? 'OK' : 'FAIL rc='.$rc).' voice='.$voice.' -> '.basename($raw_wav));
		return $ok;
	}

	private static function synth_pic02wave($text, $raw_wav, $s) {
		$pic02wave = self::find_pic02wave();
		if ($pic02wave === '') { self::logln('pic02wave not found'); return false; }
		
		// pic02wave reads from stdin and writes to file
		$txt = $raw_wav.'.txt';
		@file_put_contents($txt, $text);
		
		$cmd = 'cat '.escapeshellarg($txt).' | '.$pic02wave.' > '.escapeshellarg($raw_wav).' 2>>'.escapeshellarg(self::$log_file);
		@exec($cmd, $o, $rc);
		@unlink($txt);
		
		$ok = ($rc === 0 && file_exists($raw_wav) && filesize($raw_wav) > 0);
		self::logln('pic02wave '.($ok ? 'OK' : 'FAIL rc='.$rc).' -> '.basename($raw_wav));
		return $ok;
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
		$parts = [];
		$parts[] = 'Engine: '.$s['tts_engine'];
		$parts[] = 'flite: '.(self::find_flite() ? 'available' : 'NOT found');
		$parts[] = 'pic02wave: '.(self::find_pic02wave() ? 'available' : 'NOT found');
		$parts[] = 'espeak: '.(self::find_espeak() ? 'available' : 'NOT found');
		$parts[] = 'sox: '.(self::find_sox() ? 'available' : 'NOT found');
		return implode(' · ', $parts);
	}
}
?>
