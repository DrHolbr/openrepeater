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

	public static function detect() {
		$env = getenv('ORP_BENCH_MARKER');
		if (is_string($env) && $env !== '') {
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
		$file = getenv('ORP_BENCH_HOSTNAME_FILE');
		if (!is_string($file) || $file === '') {
			$file = '/etc/hostname';
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

	public static function previewAllowed($dir) {
		if (!is_string($dir) || $dir === '' || $dir[0] !== '/') {
			return false;
		}
		if (strpos($dir, "\0") !== false || strpos($dir, '..') !== false) {
			return false;
		}
		if ($dir === self::DEFAULT_PREVIEW) {
			return true;
		}
		$temp = rtrim(sys_get_temp_dir(), '/') . '/orp-preview-';
		return strpos($dir, $temp) === 0;
	}

	public function previewDir() {
		// The marker file is not a path authority. A preview= line is ignored.
		$env = getenv('ORP_BENCH_PREVIEW');
		if (is_string($env) && self::previewAllowed($env)) {
			return $env;
		}
		return self::DEFAULT_PREVIEW;
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
