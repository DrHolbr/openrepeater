<?php
// Privileged helper dispatcher. Session, verb, origin, and CSRF are checked
// before BenchGuard or orp_helper. A GET cannot carry post_service.

require_once(__DIR__ . '/../includes/classes/RequestGuard.php');

$method = isset($_SERVER['REQUEST_METHOD']) ? $_SERVER['REQUEST_METHOD'] : 'GET';
if ($method !== 'POST' && (isset($_GET['post_service']) || isset($_GET['post_option']))) {
	RequestGuard::deny(405);
}

if ($method === 'POST') {
	RequestGuard::requireMutation();
	$service = isset($_POST['post_service']) ? $_POST['post_service'] : '';
	$option = isset($_POST['post_option']) ? $_POST['post_option'] : '';
	if (!RequestGuard::helperActionAllowed($service, $option)) {
		RequestGuard::deny(403);
	}
	require_once(__DIR__ . '/../includes/classes/BenchGuard.php');
	if (!BenchGuard::detect()->commandAllowed($service, $option)) {
		http_response_code(403);
		header('Content-Type: text/plain; charset=UTF-8');
		echo 'refused: bench mode blocks ' . $service . ' ' . $option;
		exit;
	}
	echo exec_orp_helper($service, $option);
	exit;
}

if ($method === 'GET' && isset($_GET['update'])) {
	RequestGuard::start();
	if (!RequestGuard::authenticated()) {
		RequestGuard::deny(401);
	}
	if (!RequestGuard::readUpdateAllowed($_GET['update'])) {
		RequestGuard::deny(403);
	}
	require_once('../includes/classes/System.php');
	$classSystem = new System();
	switch ($_GET['update']) {
		case 'time':
			$outputArray = $classSystem->system_time();
			break;
		case 'systemStatic':
			$outputArray = $classSystem->system_static();
			break;
		case 'systemDynamic':
			$outputArray = $classSystem->system_dynamic();
			break;
		case 'svxlink':
			$outputArray = $classSystem->svxlink_status();
			break;
		case 'memory':
			$outputArray = $classSystem->memory_usage();
			break;
		case 'disk':
			$outputArray = $classSystem->disk_usage();
			break;
		default:
			RequestGuard::deny(403);
	}
	header('Content-Type: application/json; charset=UTF-8');
	echo json_encode($outputArray);
	exit;
}

RequestGuard::deny(405);

function exec_orp_helper($opt1, $opt2) {
	if (getenv('ORP_HELPER_STUB') === '1' && BenchGuard::testHarnessActive()) {
		$log = getenv('ORP_HELPER_LOG');
		if (is_string($log) && $log !== '') {
			file_put_contents($log, $opt1 . ' ' . $opt2 . "\n", FILE_APPEND);
		}
		if ($opt2 === 'status') {
			return 'inactive';
		}
		return 'stub';
	}
	$command = 'sudo orp_helper';
	$command .= ' ' . $opt1;
	$command .= ' ' . $opt2;
	ob_start();
	passthru($command);
	return trim(ob_get_clean());
}
