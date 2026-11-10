<?php
// Read-only byte range of the native SvxLink log. The path is fixed.
// Session, origin, and CSRF are checked before the file is opened.

require_once(__DIR__ . '/../includes/classes/RequestGuard.php');
require_once(__DIR__ . '/../includes/classes/BenchGuard.php');
RequestGuard::requireRead();

function log_stream_fail($code, $message) {
	http_response_code($code);
	header('Content-Type: text/plain; charset=UTF-8');
	header('Cache-Control: no-store');
	header('Content-Length: ' . strlen($message));
	echo $message;
	exit;
}

function log_stream_path() {
	$fixed = '/var/log/svxlink';
	if (!BenchGuard::testHarnessActive()) {
		return $fixed;
	}
	$override = getenv('ORP_SVXLINK_LOG');
	if (!is_string($override) || $override === '') {
		return $fixed;
	}
	if ($override[0] !== '/') {
		log_stream_fail(403, "SvxLink log path is not available.\n");
	}
	if (strpos($override, "\0") !== false || strpos($override, '..') !== false) {
		log_stream_fail(403, "SvxLink log path is not available.\n");
	}
	$root = getenv('ORP_ROOT');
	$allowed = array();
	if (is_string($root) && $root !== '') {
		$allowed[] = rtrim($root, '/') . '/var/log/svxlink';
	}
	$tmp = rtrim(sys_get_temp_dir(), '/');
	if (strpos($override, $tmp . '/orp-log-') === 0) {
		$allowed[] = $override;
	}
	if (!in_array($override, $allowed, true)) {
		log_stream_fail(403, "SvxLink log path is not available.\n");
	}
	return $override;
}

function log_stream_range($header, $size) {
	if ($header === null || $header === '') {
		if ($size === 0) {
			return array(0, -1);
		}
		return array(0, $size - 1);
	}
	if (!is_string($header) || !preg_match('/^bytes=(\d*)-(\d*)$/', $header, $match)) {
		return null;
	}
	if ($match[1] === '' && $match[2] === '') {
		return null;
	}
	if ($match[1] === '') {
		$suffix = (int) $match[2];
		if ($suffix < 1 || $size === 0) {
			return false;
		}
		$length = min($suffix, $size);
		return array($size - $length, $size - 1);
	}
	$start = (int) $match[1];
	if ($start >= $size) {
		return false;
	}
	$end = ($match[2] === '') ? ($size - 1) : (int) $match[2];
	if ($end < $start) {
		return false;
	}
	if ($end >= $size) {
		$end = $size - 1;
	}
	return array($start, $end);
}

$path = log_stream_path();
if (is_link($path)) {
	log_stream_fail(403, "SvxLink log is not a regular file.\n");
}
if (!is_file($path)) {
	log_stream_fail(404, "SvxLink log is not present.\n");
}
if (!is_readable($path)) {
	log_stream_fail(403, "SvxLink log is not readable.\n");
}
$size = filesize($path);
if ($size === false) {
	log_stream_fail(403, "SvxLink log is not readable.\n");
}
if ($size === 0) {
	http_response_code(200);
	header('Content-Type: text/plain; charset=UTF-8');
	header('Cache-Control: no-store');
	header('Accept-Ranges: bytes');
	header('Content-Length: 0');
	exit;
}
$range = log_stream_range(isset($_SERVER['HTTP_RANGE']) ? $_SERVER['HTTP_RANGE'] : '', $size);
if ($range === null || $range === false) {
	http_response_code(416);
	header('Content-Type: text/plain; charset=UTF-8');
	header('Cache-Control: no-store');
	header('Content-Range: bytes */' . $size);
	header('Content-Length: 0');
	exit;
}
list($start, $end) = $range;
if ($end < $start) {
	$body = '';
} else {
	$length = $end - $start + 1;
	if ($length > 65536) {
		$end = $start + 65535;
		$length = 65536;
	}
	$handle = fopen($path, 'rb');
	if ($handle === false) {
		log_stream_fail(403, "SvxLink log is not readable.\n");
	}
	if (fseek($handle, $start) !== 0) {
		fclose($handle);
		log_stream_fail(403, "SvxLink log is not readable.\n");
	}
	$body = (string) fread($handle, $length);
	fclose($handle);
	$end = $start + strlen($body) - 1;
}
$partial = isset($_SERVER['HTTP_RANGE']) && $_SERVER['HTTP_RANGE'] !== '';
if ($partial && $size > 0) {
	http_response_code(206);
	header('Content-Range: bytes ' . $start . '-' . $end . '/' . $size);
} else {
	http_response_code(200);
}
header('Content-Type: text/plain; charset=UTF-8');
header('Cache-Control: no-store');
header('Accept-Ranges: bytes');
header('Content-Length: ' . strlen($body));
echo $body;
