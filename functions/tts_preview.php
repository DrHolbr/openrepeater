<?php
// ─────────────────────────────────────────────────────────────────────────────
//  functions/tts_preview.php
//
//  Generates a short sample WAV using TTS settings supplied in the POST body
//  (the values currently shown in the General Settings form — NOT necessarily
//  saved yet) and streams it back as audio/wav so the browser can play it.
//
//  On error, returns JSON {status:error, message:…} with an appropriate code.
// ─────────────────────────────────────────────────────────────────────────────

// Capture any PHP notices/warnings so they don't corrupt the WAV bytes.
ini_set('zlib.output_compression', '0');
ob_start();
require_once(__DIR__ . '/../includes/classes/RequestGuard.php');
RequestGuard::requireMutation();

require_once(rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/includes/classes/TTS.php');

function tts_preview_fail(string $msg, int $code = 400): never {
	ob_end_clean();
	http_response_code($code);
	header('Content-Type: application/json');
	echo json_encode(['status' => 'error', 'message' => $msg]);
	exit;
}

// Build an options override from the POST values. Only override keys that
// were actually supplied, so blanks fall back to the stored/default values.
$overrides = [];
$map = [
	'engine'       => 'tts_engine',
	'flite_voice'  => 'tts_flite_voice',
	'pic02wave_voice' => 'tts_pic02wave_voice',
	'gain_db'      => 'tts_gain_db',
	'espeak_voice' => 'tts_espeak_voice',
];
foreach ($map as $post_key => $setting_key) {
	if (isset($_POST[$post_key]) && $_POST[$post_key] !== '') {
		$overrides[$setting_key] = $_POST[$post_key];
	}
}

$sample = isset($_POST['text']) && trim($_POST['text']) !== ''
	? substr(trim($_POST['text']), 0, 300)
	: 'This is a test of the OpenRepeater text to speech voice. The quick brown fox jumps over the lazy dog.';

// Synthesize to a temp file.
$tmp = tempnam(sys_get_temp_dir(), 'orp_tts_preview_');
if ($tmp === false) tts_preview_fail('Could not create temp file.', 500);
$wav = $tmp . '.wav';

$ok = TTS::synth($sample, $wav, $overrides);
@unlink($tmp);

if (!$ok || !file_exists($wav) || filesize($wav) <= 0) {
	@unlink($wav);
	// Give a useful diagnostic.
	tts_preview_fail('Synthesis failed. ' . TTS::status_summary(), 500);
}
$riff = file_get_contents($wav, false, null, 0, 12);
if (!is_string($riff) || substr($riff, 0, 4) !== 'RIFF' || substr($riff, 8, 4) !== 'WAVE') {
	@unlink($wav);
	tts_preview_fail('Synthesis did not return a WAV file.', 500);
}

// Discard any buffered notices/warnings, then stream only the WAV bytes.
while (ob_get_level() > 0) {
	ob_end_clean();
}
$size = filesize($wav);
header('Content-Type: audio/wav');
header('X-Content-Type-Options: nosniff');
header('Content-Length: ' . $size);
header('Content-Encoding: identity');
header('Cache-Control: no-store');
$sent = readfile($wav);
@unlink($wav);
if ($sent !== $size) {
	exit(1);
}
exit;
