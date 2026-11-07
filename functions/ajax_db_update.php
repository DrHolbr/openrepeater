<?php
require_once(__DIR__ . '/../includes/classes/RequestGuard.php');
RequestGuard::requireMutation();

require_once(rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/includes/autoloadClasses.php');
$Database = new Database();

$updates = array();
foreach ($_POST as $key => $value) {
	if ($key === 'csrf_token') {
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
foreach ($updates as $key => $value) {
	if ($Database->update_existing_setting($key, $value) !== true) {
		http_response_code(400);
		header('Content-Type: text/plain; charset=UTF-8');
		echo "refused\n";
		exit;
	}
}
header('Content-Type: text/plain; charset=UTF-8');
echo "updated\n";
