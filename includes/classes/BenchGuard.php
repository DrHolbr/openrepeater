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

	private $markerPath;

	public function __construct($markerPath) {
		$this->markerPath = $markerPath;
	}

	public static function testHarnessActive() {
		if (getenv('ORP_BENCH_TEST_HARNESS') !== '1') {
			return false;
		}
		$host = @file_get_contents('/etc/hostname');
		if (is_string($host) && trim($host) === 'orp-test') {
			return false;
		}
		if (is_file(self::DEFAULT_MARKER)) {
			return false;
		}
		return true;
	}

	public static function detect() {
		$env = getenv('ORP_BENCH_MARKER');
		if (self::testHarnessActive() && is_string($env) && $env !== '') {
			$path = $env;
		} else {
			$path = self::DEFAULT_MARKER;
		}
		return new self($path);
	}

	public function markerPath() {
		return $this->markerPath;
	}

	public function isBench() {
		// The bench hostname is root-owned. Deleting the marker must not
		// turn publishing and radio commands back on for orp-test.
		if ($this->hostname() === 'orp-test') {
			return true;
		}
		return is_file($this->markerPath);
	}

	public function hostname() {
		$file = '/etc/hostname';
		$override = getenv('ORP_BENCH_HOSTNAME_FILE');
		if (self::testHarnessActive() && is_string($override) && $override !== '') {
			$file = $override;
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
		return self::componentsAreReal($dir);
	}

	public function previewDir() {
		// The marker file is not a path authority. A preview= line is ignored.
		// ORP_BENCH_PREVIEW works only in the cloud harness, never on hostname orp-test.
		$env = getenv('ORP_BENCH_PREVIEW');
		if (self::testHarnessActive() && is_string($env) && self::previewAllowed($env)) {
			return $env;
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
		if (!$this->isBench()) {
			return true;
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
