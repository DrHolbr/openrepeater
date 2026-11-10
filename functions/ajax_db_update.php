<?php
require_once(__DIR__ . '/../includes/classes/RequestGuard.php');
RequestGuard::requireMutation();

require_once(rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/includes/autoloadClasses.php');
$Database = new Database();

$updates = array();
foreach ($_POST as $key => $value) {
	if ($key === 'csrf_token' || $key === 'action') {
		continue;
	}
	if (!is_string($key) || !is_string($value)) {
		http_response_code(400);
		header('Content-Type: text/plain; charset=UTF-8');
		echo "refused\n";
		exit;
	}
	if ($key === 'callSign') {
		$value = strtoupper($value);
	}
	if ($key === 'orp_Mode' && $value !== 'repeater' && $value !== 'simplex') {
		http_response_code(400);
		header('Content-Type: text/plain; charset=UTF-8');
		echo "unsupported\n";
		echo "orp_Mode is not repeater or simplex. Nothing was written.\n";
		exit;
	}
	if ($key === 'courtesyMode' && $value !== 'disabled' && $value !== 'beep' && $value !== 'custom') {
		http_response_code(400);
		header('Content-Type: text/plain; charset=UTF-8');
		echo "unsupported\n";
		echo "courtesyMode is not disabled, beep, or custom. Nothing was written.\n";
		exit;
	}
	$updates[$key] = $value;
}
foreach ($updates as $key => $value) {
	if (!$Database->has_setting($key) || strlen($value) > 4000 || strpos($value, "\0") !== false) {
		http_response_code(400);
		header('Content-Type: text/plain; charset=UTF-8');
		echo "refused\n";
		exit;
	}
}
if ($Database->update_existing_settings($updates) !== true) {
	http_response_code(500);
	header('Content-Type: text/plain; charset=UTF-8');
	echo "not-written\n";
	exit;
}
header('Content-Type: text/plain; charset=UTF-8');
echo "updated\n";
if (isset($updates['orp_Mode'])) {
	$logic = $updates['orp_Mode'] === 'simplex' ? 'SimplexLogic' : 'RepeaterLogic';
	$type = $updates['orp_Mode'] === 'simplex' ? 'Simplex' : 'Repeater';
	echo "stored-for-publish: LOGICS=${logic} TYPE=${type} PTT_TYPE=NONE. No GPIO line is configured.\n";
}
if (isset($updates['courtesyMode']) || isset($updates['courtesy'])) {
	if (isset($updates['courtesyMode']) && $updates['courtesyMode'] === 'custom') {
		echo "unsupported: a custom courtesy file is not published. The previous runtime was not changed.\n";
	} elseif (isset($updates['courtesyMode']) && ($updates['courtesyMode'] === 'disabled' || $updates['courtesyMode'] === 'beep')) {
		echo "stored-for-publish: courtesyMode=" . $updates['courtesyMode'] . " is in the database. The root publisher writes events.d/local/Logic.tcl on the next publish. It is not executed here.\n";
	}
	if (isset($updates['courtesy'])) {
		echo "stored-not-applied: the courtesy filename is not published.\n";
	}
}
