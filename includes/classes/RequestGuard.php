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
		if (!isset($_SESSION['username']) || !is_string($_SESSION['username']) || $_SESSION['username'] === '') {
			return false;
		}
		if (!isset($_SESSION['userID']) || $_SESSION['userID'] === '' || $_SESSION['userID'] === null) {
			return false;
		}
		return true;
	}

	public static function deny($code) {
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
		if ($code === 405) {
			header('Allow: POST');
		}
		echo $messages[$code];
		exit;
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
			'system' => array('restart', 'stop', 'uptime', 'user'),
			'info' => array('timezone', 'cpu_type', 'cpu_speed', 'cpu_load', 'cpu_temp', 'uptime', 'memory_usage', 'disk_usage', 'os'),
			'audio' => array('inputs', 'outputs', 'version'),
		);
		return isset($allowed[$service]) && in_array($option, $allowed[$service], true);
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
		$host = isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : '';
		if (isset($_SERVER['HTTP_ORIGIN']) && $_SERVER['HTTP_ORIGIN'] !== '') {
			return self::hostMatches($host, $_SERVER['HTTP_ORIGIN']);
		}
		if (isset($_SERVER['HTTP_REFERER']) && $_SERVER['HTTP_REFERER'] !== '') {
			return self::hostMatches($host, $_SERVER['HTTP_REFERER']);
		}
		return true;
	}

	private static function hostMatches($expectedHost, $url) {
		$parts = parse_url($url);
		if (!is_array($parts) || empty($parts['host'])) {
			return false;
		}
		$got = $parts['host'];
		if (isset($parts['port'])) {
			$got .= ':' . $parts['port'];
		}
		return strcasecmp($got, $expectedHost) === 0;
	}
}
