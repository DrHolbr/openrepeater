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

session_start();
if ((!isset($_SESSION['username'])) || (!isset($_SESSION['userID']))) {
	http_response_code(403);
	header('Content-Type: application/json');
	echo json_encode(['status' => 'error', 'message' => 'Not authorized.']);
	exit;
}

require_once(rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/includes/classes/TTS.php');

function tts_preview_fail($msg, $code = 400) {
	http_response_code($code);
	header('Content-Type: application/json');
	echo json_encode(['status' => 'error', 'message' => $msg]);
	exit;
}

// Build an options override from the POST values. Only override keys that
// were actually supplied, so blanks fall back to the stored/default values.
$overrides = [];
$map = [
	'engine'           => 'tts_engine',
	'voice'            => 'tts_piper_voice',
	'length_scale'     => 'tts_piper_length_scale',
	'noise_scale'      => 'tts_piper_noise_scale',
	'noise_w'          => 'tts_piper_noise_w',
	'sentence_silence' => 'tts_piper_sentence_silence',
	'gain_db'          => 'tts_gain_db',
	'espeak_voice'     => 'tts_espeak_voice',
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

// Stream the WAV back.
header('Content-Type: audio/wav');
header('Content-Length: ' . filesize($wav));
header('Cache-Control: no-store');
readfile($wav);
@unlink($wav);
exit;
?>
