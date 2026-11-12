<?php
require_once(__DIR__ . '/../includes/classes/RequestGuard.php');
RequestGuard::requireMutation();

require_once(rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/includes/autoloadClasses.php');

function port_form_fail() {
	http_response_code(400);
	header('Content-Type: text/plain; charset=UTF-8');
	echo "refused\n";
	exit;
}

$fields = array('portLabel', 'rxMode', 'rxGPIO', 'rxGPIO_active', 'txGPIO', 'txGPIO_active', 'rxAudioDev', 'txAudioDev');
$columns = array();
foreach ($fields as $field) {
	if (!isset($_POST[$field]) || !is_array($_POST[$field])) {
		port_form_fail();
	}
	$columns[$field] = array_values($_POST[$field]);
}
$count = count($columns['portLabel']);
if ($count < 1 || $count > 8) {
	port_form_fail();
}
foreach ($fields as $field) {
	if (count($columns[$field]) !== $count) {
		port_form_fail();
	}
}
$rows = array();
$seenGpio = array();
for ($i = 0; $i < $count; $i++) {
	$label = $columns['portLabel'][$i];
	$mode = $columns['rxMode'][$i];
	$rx = $columns['rxGPIO'][$i];
	$tx = $columns['txGPIO'][$i];
	$rxActive = $columns['rxGPIO_active'][$i];
	$txActive = $columns['txGPIO_active'][$i];
	$rxAudio = $columns['rxAudioDev'][$i];
	$txAudio = $columns['txAudioDev'][$i];
	if (!is_string($label) || !preg_match('/^[A-Za-z0-9][A-Za-z0-9 ._:-]{0,40}$/', $label)) {
		port_form_fail();
	}
	if ($mode !== 'gpio' && $mode !== 'vox') {
		port_form_fail();
	}
	if (!preg_match('/^[0-9]{1,4}$/', $rx) || !preg_match('/^[0-9]{1,4}$/', $tx) || $rx === $tx) {
		port_form_fail();
	}
	if (($rxActive !== 'high' && $rxActive !== 'low') || ($txActive !== 'high' && $txActive !== 'low')) {
		port_form_fail();
	}
	if (!preg_match('/^alsa:plughw:[0-9]+\|[0-9]+$/', $rxAudio) || !preg_match('/^alsa:plughw:[0-9]+\|[0-9]+$/', $txAudio)) {
		port_form_fail();
	}
	if (isset($seenGpio[$rx]) || isset($seenGpio[$tx])) {
		port_form_fail();
	}
	$seenGpio[$rx] = true;
	$seenGpio[$tx] = true;
	$rows[] = array(
		'portLabel' => $label,
		'rxMode' => $mode,
		'rxGPIO' => $rx,
		'rxGPIO_active' => $rxActive,
		'txGPIO' => $tx,
		'txGPIO_active' => $txActive,
		'rxAudioDev' => $rxAudio,
		'txAudioDev' => $txAudio,
	);
}
$Database = new Database();
if ($Database->replace_port_form($rows) !== true) {
	http_response_code(500);
	header('Content-Type: text/plain; charset=UTF-8');
	echo "not-written\n";
	exit;
}
header('Content-Type: text/plain; charset=UTF-8');
echo "updated\n";
