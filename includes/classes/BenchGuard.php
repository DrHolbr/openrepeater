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
		return is_file($this->markerPath);
	}

	public function previewDir() {
		$fallback = self::DEFAULT_PREVIEW;
		if (!$this->isBench()) {
			return $fallback;
		}
		$raw = @file($this->markerPath, FILE_IGNORE_NEW_LINES);
		if ($raw === false) {
			return $fallback;
		}
		foreach ($raw as $line) {
			$line = trim($line);
			if (strpos($line, 'preview=') === 0) {
				$dir = trim(substr($line, strlen('preview=')));
				if ($dir !== '' && strpos($dir, "\0") === false) {
					return $dir;
				}
			}
		}
		return $fallback;
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
			'alsa' => array('restore'),
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
