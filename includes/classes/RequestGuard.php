<?php
#####################################################################################################
# Shared request boundary for privileged and state-changing routes.
#
# A mutation is refused before a database, config write, or helper command:
#   405  the verb is not POST
#   401  there is no authenticated session
#   403  the origin is foreign, the CSRF token does not match, or the action
#        is outside the route allowlist
# Login is the exception: it checks the anonymous form token and then the
# password. It does not require an existing account session.
#####################################################################################################

class RequestGuard {

	public static function start() {
		if (session_status() !== PHP_SESSION_ACTIVE) {
			session_start();
		}
		return true;
	}

	public static function ensureToken() {
		self::start();
		if (!isset($_SESSION['csrf_token']) || !is_string($_SESSION['csrf_token']) || strlen($_SESSION['csrf_token']) < 32) {
			$_SESSION['csrf_token'] = bin2hex(random_bytes(32));
		}
		return $_SESSION['csrf_token'];
	}

	public static function rotateToken() {
		self::start();
		$_SESSION['csrf_token'] = bin2hex(random_bytes(32));
		return $_SESSION['csrf_token'];
	}

	public static function authenticated() {
		self::start();
		$username = isset($_SESSION['username']) ? $_SESSION['username'] : null;
		$userID = isset($_SESSION['userID']) ? $_SESSION['userID'] : null;
		if (!is_string($username) || $username === '' || strlen($username) > 64) {
			return false;
		}
		if (strpos($username, "\0") !== false || strpos($username, "\n") !== false || strpos($username, "\r") !== false) {
			return false;
		}
		$id = self::positiveAccountId($userID);
		if ($id === null) {
			return false;
		}
		return self::accountRowMatches($id, $username);
	}

	// A positive scalar account id. Arrays, floats, and padded or nonnumeric
	// strings are not an account. This does not by itself prove a cookie was
	// forged; it rejects a session that is not tied to one existing row.
	public static function positiveAccountId($userID) {
		if (is_int($userID)) {
			if ($userID < 1) {
				return null;
			}
			return $userID;
		}
		if (is_string($userID) && preg_match('/^[1-9][0-9]{0,8}$/', $userID)) {
			return (int)$userID;
		}
		return null;
	}

	public static function deny($code, $allow = 'POST') {
		$messages = array(
			401 => 'unauthorized',
			403 => 'forbidden',
			405 => 'method not allowed',
		);
		if (!isset($messages[$code])) {
			$code = 403;
		}
		http_response_code($code);
		header('Content-Type: text/plain; charset=UTF-8');
		header('Cache-Control: no-store');
		if ($code === 405 && is_string($allow) && $allow !== '') {
			header('Allow: ' . $allow);
		}
		echo $messages[$code];
		exit;
	}

	public static function requireRead() {
		self::start();
		$method = isset($_SERVER['REQUEST_METHOD']) ? $_SERVER['REQUEST_METHOD'] : 'GET';
		if ($method !== 'GET' && $method !== 'HEAD') {
			self::deny(405, 'GET, HEAD');
		}
		if (!self::authenticated()) {
			self::deny(401);
		}
		if (!self::originAllowed()) {
			self::deny(403);
		}
		if (!self::tokenMatches()) {
			self::deny(403);
		}
	}

	public static function requireMutation() {
		self::start();
		$method = isset($_SERVER['REQUEST_METHOD']) ? $_SERVER['REQUEST_METHOD'] : 'GET';
		if ($method !== 'POST') {
			self::deny(405);
		}
		if (!self::authenticated()) {
			self::deny(401);
		}
		if (!self::originAllowed()) {
			self::deny(403);
		}
		if (!self::tokenMatches()) {
			self::deny(403);
		}
	}

	// The login form posts before an account session exists. The token was
	// issued when the form was rendered. A mismatch is rejected before the
	// users table is read.
	public static function requireLoginPost() {
		self::start();
		$method = isset($_SERVER['REQUEST_METHOD']) ? $_SERVER['REQUEST_METHOD'] : 'GET';
		if ($method !== 'POST') {
			self::deny(405);
		}
		if (!self::originAllowed()) {
			self::deny(403);
		}
		if (!self::tokenMatches()) {
			self::deny(403);
		}
	}

	public static function helperActionAllowed($service, $option) {
		$allowed = array(
			'svxlink' => array('start', 'stop', 'status', 'restart'),
			'system' => array('uptime', 'user'),
			'info' => array('timezone', 'cpu_type', 'cpu_speed', 'cpu_load', 'cpu_temp', 'uptime', 'memory_usage', 'disk_usage', 'os'),
			'audio' => array('inputs', 'outputs', 'version'),
		);
		if (isset($allowed[$service]) && in_array($option, $allowed[$service], true)) {
			return true;
		}
		if (!class_exists('BenchGuard', false)) {
			require_once(__DIR__ . '/BenchGuard.php');
		}
		if (!BenchGuard::detect()->uiBlocksLifted()) {
			return false;
		}
		$lifted = array(
			'svxlink' => array('disable', 'gpio_up', 'gpio_down', 'unmask'),
			'system' => array('restart', 'stop'),
			'remotetrx' => array('start', 'stop', 'restart', 'status', 'disable', 'unmask'),
			'svxreflector' => array('start', 'stop', 'restart', 'status', 'disable', 'unmask'),
			'alsa' => array('backup', 'restore'),
		);
		if (!isset($lifted[$service]) || !in_array($option, $lifted[$service], true)) {
			return false;
		}
		if (($option === 'gpio_up' || $option === 'gpio_down') && !BenchGuard::detect()->txArmed()) {
			return false;
		}
		return true;
	}

	// A rebuild form may name the page to reopen. The result is always
	// ../<page>.php from functions/, and only for a page at the web root.
	// A bare name.php is not left relative to functions/. A scheme, a
	// protocol-relative URL, a backslash, or a control character falls
	// back to the dashboard.
	public static function safeReturnUrl($value) {
		$fallback = '../dashboard.php';
		if (!is_string($value) || $value === '') {
			return $fallback;
		}
		$path = strtok($value, '?');
		if (!is_string($path) || $path === '') {
			return $fallback;
		}
		if (preg_match('/[\x00-\x1f\x7f\\\\]/', $path)) {
			return $fallback;
		}
		if (strpos($path, '//') !== false || strpos($path, ':') !== false) {
			return $fallback;
		}
		if (!preg_match('#^(?:\.\./)?([A-Za-z0-9][A-Za-z0-9._-]*\.php)$#', $path, $match)) {
			return $fallback;
		}
		if (!in_array($match[1], self::returnPages(), true)) {
			return $fallback;
		}
		return '../' . $match[1];
	}

	private static function returnPages() {
		return array(
			'404.php',
			'advanced.php',
			'backup.php',
			'courtesy_tone.php',
			'dashboard.php',
			'dtmf.php',
			'gpio.php',
			'identification.php',
			'index.php',
			'log.php',
			'modules.php',
			'ports.php',
			'settings.php',
		);
	}

	public static function readUpdateAllowed($name) {
		return in_array($name, array('time', 'systemStatic', 'systemDynamic', 'svxlink', 'memory', 'disk'), true);
	}

	private static function submittedToken() {
		if (isset($_POST['csrf_token']) && is_string($_POST['csrf_token'])) {
			return $_POST['csrf_token'];
		}
		if (isset($_SERVER['HTTP_X_CSRF_TOKEN']) && is_string($_SERVER['HTTP_X_CSRF_TOKEN'])) {
			return $_SERVER['HTTP_X_CSRF_TOKEN'];
		}
		return '';
	}

	private static function tokenMatches() {
		$expected = isset($_SESSION['csrf_token']) ? $_SESSION['csrf_token'] : '';
		$got = self::submittedToken();
		if (!is_string($expected) || $expected === '' || $got === '') {
			return false;
		}
		return hash_equals($expected, $got);
	}

	private static function originAllowed() {
		$expected = self::effectiveRequestOrigin();
		if (isset($_SERVER['HTTP_ORIGIN']) && is_string($_SERVER['HTTP_ORIGIN']) && $_SERVER['HTTP_ORIGIN'] !== '') {
			return $expected !== null && self::sameOrigin($expected, $_SERVER['HTTP_ORIGIN']);
		}
		if (isset($_SERVER['HTTP_REFERER']) && is_string($_SERVER['HTTP_REFERER']) && $_SERVER['HTTP_REFERER'] !== '') {
			return $expected !== null && self::sameOrigin($expected, $_SERVER['HTTP_REFERER']);
		}
		return true;
	}

	// The bench Pi is reached over HTTP with no proxy. X-Forwarded-Proto is
	// ignored unless ORP_TRUST_FORWARDED_PROTO=1 is set for an explicit proxy.
	private static function effectiveRequestOrigin() {
		$scheme = 'http';
		if (!empty($_SERVER['HTTPS']) && strtolower((string)$_SERVER['HTTPS']) !== 'off') {
			$scheme = 'https';
		} elseif (isset($_SERVER['REQUEST_SCHEME']) && strtolower((string)$_SERVER['REQUEST_SCHEME']) === 'https') {
			$scheme = 'https';
		}
		if (getenv('ORP_TRUST_FORWARDED_PROTO') === '1' && isset($_SERVER['HTTP_X_FORWARDED_PROTO'])) {
			$forwarded = strtolower(trim((string)$_SERVER['HTTP_X_FORWARDED_PROTO']));
			if ($forwarded === 'http' || $forwarded === 'https') {
				$scheme = $forwarded;
			}
		}
		$hostHeader = isset($_SERVER['HTTP_HOST']) ? (string)$_SERVER['HTTP_HOST'] : '';
		if ($hostHeader === '' || strpos($hostHeader, "\n") !== false || strpos($hostHeader, "\r") !== false) {
			return null;
		}
		$host = $hostHeader;
		$port = null;
		if ($hostHeader[0] === '[') {
			if (!preg_match('/^\[([^\]]+)\](?::(\d+))?$/', $hostHeader, $match)) {
				return null;
			}
			$host = $match[1];
			if (isset($match[2]) && $match[2] !== '') {
				$port = (int)$match[2];
			}
		} elseif (substr_count($hostHeader, ':') === 1) {
			$pieces = explode(':', $hostHeader, 2);
			$host = $pieces[0];
			if (!preg_match('/^\d+$/', $pieces[1])) {
				return null;
			}
			$port = (int)$pieces[1];
		} elseif (substr_count($hostHeader, ':') > 1) {
			return null;
		}
		if ($host === '') {
			return null;
		}
		if ($port === null) {
			$port = ($scheme === 'https') ? 443 : 80;
		}
		if ($port < 1 || $port > 65535) {
			return null;
		}
		return array('scheme' => $scheme, 'host' => strtolower($host), 'port' => $port);
	}

	private static function sameOrigin($expected, $url) {
		$parts = parse_url($url);
		if (!is_array($parts) || empty($parts['scheme']) || empty($parts['host'])) {
			return false;
		}
		$scheme = strtolower($parts['scheme']);
		if ($scheme !== 'http' && $scheme !== 'https') {
			return false;
		}
		$port = isset($parts['port']) ? (int)$parts['port'] : (($scheme === 'https') ? 443 : 80);
		$host = strtolower($parts['host']);
		return $scheme === $expected['scheme']
			&& $host === $expected['host']
			&& $port === $expected['port'];
	}

	private static function accountRowMatches($id, $username) {
		$path = getenv('ORP_DB_PATH');
		if (!is_string($path) || $path === '') {
			$path = '/var/lib/openrepeater/db/openrepeater.db';
		}
		if (!is_file($path) || is_link($path)) {
			return false;
		}
		try {
			$db = new SQLite3($path, SQLITE3_OPEN_READONLY);
		} catch (Throwable $e) {
			return false;
		}
		$stmt = $db->prepare('SELECT username FROM users WHERE userID = :id');
		if ($stmt === false) {
			$db->close();
			return false;
		}
		$stmt->bindValue(':id', $id, SQLITE3_INTEGER);
		$result = $stmt->execute();
		$row = ($result instanceof SQLite3Result) ? $result->fetchArray(SQLITE3_ASSOC) : false;
		$db->close();
		if (!is_array($row) || !isset($row['username']) || !is_string($row['username'])) {
			return false;
		}
		return hash_equals($row['username'], $username);
	}
}
