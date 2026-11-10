<?php
#####################################################################################################
# Bench safety gate
#
# A marker file means this host is the orp-test bench. Radio start, reboot,
# GPIO setup, mixer changes, and publishing into the SvxLink trees are refused.
# With no marker, the historical command and path behavior stays in place.
#####################################################################################################

class BenchGuard {

	const DEFAULT_MARKER = '/etc/openrepeater/bench-mode';
	const DEFAULT_PREVIEW = '/var/lib/openrepeater/bench-preview';
	const DEFAULT_MODE_FILE = '/etc/openrepeater/operating-mode';

	private $markerPath;

	public function __construct($markerPath) {
		$this->markerPath = $markerPath;
	}

	public static function testHarnessActive() {
		if (getenv('ORP_BENCH_TEST_HARNESS') !== '1') {
			return false;
		}
		// The web server never honors the harness, even on this host.
		// A CLI or local test server does, and then it must not read the
		// installed operating-mode token, marker, or hostname.
		return PHP_SAPI === 'cli' || PHP_SAPI === 'phpdbg' || PHP_SAPI === 'cli-server';
	}

	public static function harnessPathAllowed($path) {
		if (!is_string($path) || $path === '' || $path[0] !== '/' || strpos($path, "\0") !== false || strpos($path, '..') !== false) {
			return false;
		}
		$blocked = array('/etc/', '/usr/', '/var/www/', '/var/lib/openrepeater/');
		foreach ($blocked as $prefix) {
			if (strpos($path, $prefix) === 0 || $path === rtrim($prefix, '/')) {
				return false;
			}
		}
		return true;
	}

	public static function detect() {
		if (self::testHarnessActive()) {
			$env = getenv('ORP_BENCH_MARKER');
			if (is_string($env) && $env !== '' && self::harnessPathAllowed($env)) {
				return new self($env);
			}
			return new self(rtrim(sys_get_temp_dir(), '/') . '/orp-no-such-bench-marker');
		}
		return new self(self::DEFAULT_MARKER);
	}

	public function markerPath() {
		return $this->markerPath;
	}

	public function modeFilePath() {
		if (self::testHarnessActive()) {
			$env = getenv('ORP_OPERATING_MODE_FILE');
			if (is_string($env) && $env !== '' && self::harnessPathAllowed($env)) {
				return $env;
			}
			return rtrim(sys_get_temp_dir(), '/') . '/orp-no-such-operating-mode';
		}
		return self::DEFAULT_MODE_FILE;
	}

	// A usable token is exactly bench or functional-test. A missing file is
	// not a token. A symlink, a group-writable file, or a world-writable file
	// is not a token. Outside the harness the file must be owned by root.
	public function modeToken() {
		$path = $this->modeFilePath();
		clearstatcache(true, $path);
		if (!is_file($path) || is_link($path)) {
			return '';
		}
		$perms = fileperms($path);
		if ($perms === false || ($perms & 0022) !== 0) {
			return '';
		}
		if (!self::testHarnessActive()) {
			$owner = fileowner($path);
			if ($owner !== 0) {
				return '';
			}
		}
		$raw = file_get_contents($path);
		if (!is_string($raw)) {
			return '';
		}
		$token = trim($raw);
		if ($token === 'bench' || $token === 'functional-test') {
			return $token;
		}
		return '';
	}

	public function operatingMode() {
		$token = $this->modeToken();
		if ($token === 'functional-test') {
			return 'functional-test';
		}
		if ($token === 'bench' || $this->hostname() === 'orp-test' || (is_file($this->markerPath) && !is_link($this->markerPath))) {
			return 'bench';
		}
		return 'legacy';
	}

	public function isBench() {
		// Only the bench token keeps publication in the preview directory.
		// functional-test is a different mode: it publishes a no-PTT runtime
		// and may start the svxlink process. Deleting the marker does not
		// select it. A missing or untrusted token on orp-test stays bench.
		return $this->operatingMode() === 'bench';
	}

	public function hostname() {
		if (self::testHarnessActive()) {
			$override = getenv('ORP_BENCH_HOSTNAME_FILE');
			if (!is_string($override) || $override === '' || !self::harnessPathAllowed($override)) {
				return '';
			}
			$file = $override;
		} else {
			$file = '/etc/hostname';
		}
		if (self::testHarnessActive() && is_link($file)) {
			return '';
		}
		if (!is_file($file)) {
			return '';
		}
		$raw = file_get_contents($file);
		if ($raw === false) {
			return '';
		}
		return trim($raw);
	}

	public static function componentsAreReal($path) {
		if (!is_string($path) || $path === '' || $path[0] !== '/') {
			return false;
		}
		if (strpos($path, "\0") !== false || strpos($path, '..') !== false) {
			return false;
		}
		$parts = explode('/', $path);
		$acc = '';
		$last = count($parts) - 1;
		for ($i = 0; $i <= $last; $i++) {
			$part = $parts[$i];
			if ($part === '') {
				continue;
			}
			if ($part === '.' || $part === '..') {
				return false;
			}
			$acc .= '/' . $part;
			if (is_link($acc)) {
				return false;
			}
			if (!file_exists($acc) && $i !== $last) {
				return false;
			}
		}
		return true;
	}

	public static function previewAllowed($dir) {
		if (!is_string($dir) || $dir === '' || $dir[0] !== '/') {
			return false;
		}
		if (strpos($dir, "\0") !== false || strpos($dir, '..') !== false) {
			return false;
		}
		if ($dir === self::DEFAULT_PREVIEW) {
			return self::componentsAreReal($dir);
		}
		if (!self::testHarnessActive()) {
			return false;
		}
		$temp = rtrim(sys_get_temp_dir(), '/');
		$pattern = '#^' . preg_quote($temp, '#') . '/orp-preview-[A-Za-z0-9._-]+$#';
		if (!preg_match($pattern, $dir)) {
			return false;
		}
		if (!self::componentsAreReal($dir)) {
			return false;
		}
		if (!is_dir($dir)) {
			return true;
		}
		$mode = fileperms($dir);
		if ($mode !== false && ($mode & 0002) !== 0) {
			return false;
		}
		if (function_exists('posix_geteuid') && function_exists('fileowner')) {
			$owner = fileowner($dir);
			$euid = posix_geteuid();
			if ($owner !== false && $owner !== $euid && (int) $owner !== 0) {
				return false;
			}
		}
		return true;
	}

	public function previewDir() {
		// The marker file is not a path authority. A preview= line is ignored.
		// A set but invalid ORP_BENCH_PREVIEW does not fall back to the live
		// bench-preview directory. That directory exists on the bench.
		$env = getenv('ORP_BENCH_PREVIEW');
		if (self::testHarnessActive() && is_string($env) && $env !== '') {
			if (self::previewAllowed($env)) {
				return $env;
			}
			return null;
		}
		if (self::testHarnessActive()) {
			$standIn = getenv('ORP_BENCH_DEFAULT_PREVIEW');
			if (is_string($standIn) && $standIn !== '' && self::previewAllowed($standIn)) {
				return $standIn;
			}
		}
		return self::DEFAULT_PREVIEW;
	}

	public static function writeContained($path, $data) {
		if (!self::componentsAreReal($path) || is_link($path)) {
			return false;
		}
		$dir = dirname($path);
		if (!is_dir($dir) || is_link($dir) || !self::componentsAreReal($dir)) {
			return false;
		}
		$tmp = $dir . '/.' . basename($path) . '.' . getmypid() . '.tmp';
		if (@file_put_contents($tmp, $data) === false) {
			return false;
		}
		if (is_link($path)) {
			@unlink($tmp);
			return false;
		}
		if (!rename($tmp, $path)) {
			@unlink($tmp);
			return false;
		}
		return true;
	}

	public function mixerUpdatesAllowed() {
		return !$this->isBench();
	}

	public function commandAllowed($service, $option) {
		$service = (string) $service;
		$option = (string) $option;
		if ($option === 'unmask') {
			return false;
		}
		if ($this->operatingMode() === 'legacy') {
			return true;
		}
		if ($this->operatingMode() === 'functional-test') {
			$allowed = array(
				'svxlink' => array('start', 'stop', 'status', 'restart'),
				'config' => array('publish'),
				'info' => array('timezone', 'cpu_type', 'cpu_speed', 'cpu_load', 'cpu_temp', 'uptime', 'memory_usage', 'disk_usage', 'os'),
				'audio' => array('inputs', 'outputs', 'version'),
				'system' => array('uptime', 'user'),
			);
			return isset($allowed[$service]) && in_array($option, $allowed[$service], true);
		}
		$blocked = array(
			'svxlink' => array('start', 'restart', 'enable', 'gpio_up', 'gpio_down'),
			'remotetrx' => array('start', 'restart', 'enable'),
			'svxreflector' => array('start', 'restart', 'enable'),
			'system' => array('restart', 'stop'),
			'set_mixer' => array('set_mixer'),
			'alsa' => array('restore', 'backup'),
		);
		if ($service === 'set_mixer') {
			return false;
		}
		if (isset($blocked[$service]) && in_array($option, $blocked[$service], true)) {
			return false;
		}
		return true;
	}
}
?>
