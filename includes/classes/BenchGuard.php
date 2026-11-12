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
		$collapsed = preg_replace('#/{2,}#', '/', $path);
		if (!is_string($collapsed) || $collapsed === '') {
			return false;
		}
		$blocked = array('/etc/', '/usr/', '/var/www/', '/var/lib/openrepeater/');
		foreach ($blocked as $prefix) {
			if (strpos($collapsed, $prefix) === 0 || $collapsed === rtrim($prefix, '/')) {
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

	// Same predicate as orp_helper native_functional_token. One switch lifts
	// the bench UI blocks. Production without this token is unchanged.
	public function trustedFunctionalTest() {
		$path = $this->modeFilePath();
		clearstatcache(true, $path);
		if (!is_file($path) || is_link($path)) {
			return false;
		}
		$perms = fileperms($path);
		if ($perms === false || ($perms & 0022) !== 0) {
			return false;
		}
		$owner = fileowner($path);
		if ($owner === false || (int) $owner !== 0) {
			return false;
		}
		$hostFile = '/etc/hostname';
		if (self::testHarnessActive()) {
			$override = getenv('ORP_BENCH_HOSTNAME_FILE');
			if (!is_string($override) || $override === '' || !self::harnessPathAllowed($override)) {
				return false;
			}
			$hostFile = $override;
		}
		if (is_link($hostFile) || !is_file($hostFile)) {
			return false;
		}
		if ($this->hostname() !== 'orp-test') {
			return false;
		}
		if (!$this->openrepeaterDirTrusted(dirname($path))) {
			return false;
		}
		$raw = file_get_contents($path);
		return is_string($raw) && trim($raw) === 'functional-test';
	}

	public function uiBlocksLifted() {
		return $this->trustedFunctionalTest();
	}

	// Root-only flag at /etc/openrepeater/tx-armed. Absent unless root
	// creates it. Same file checks as the token, with no required text.
	// Without it, publish stays the disconnected runtime.
	public function txArmed() {
		$file = $this->txArmedFile();
		clearstatcache(true, $file);
		if (!is_file($file) || is_link($file)) {
			return false;
		}
		$perms = fileperms($file);
		if ($perms === false || ($perms & 0022) !== 0) {
			return false;
		}
		$owner = fileowner($file);
		if ($owner === false || (int) $owner !== 0) {
			return false;
		}
		if (!$this->openrepeaterDirTrusted(dirname($file))) {
			return false;
		}
		$raw = file_get_contents($file);
		return $raw === "armed" || $raw === "armed\n";
	}

	// Missing remotetrx.conf has no PTT lines. A real PTT_TYPE other than
	// NONE or Dummy means start would key a radio unless tx-armed is set.
	public function remotetrxPttDisconnected() {
		$path = $this->remotetrxConf();
		if ($path === '') {
			return true;
		}
		if (is_link($path)) {
			return false;
		}
		if (!is_file($path)) {
			return true;
		}
		$raw = file_get_contents($path);
		if (!is_string($raw)) {
			return false;
		}
		if (!$this->pttValuesAllowed($raw, array('NONE', 'Dummy'))) {
			return false;
		}
		$cfg = $this->cfgDirValue($raw);
		if ($cfg === false) {
			return false;
		}
		if ($cfg === null || $cfg === '') {
			return true;
		}
		$cfg = $this->resolveCfgDir($path, $cfg);
		if ($cfg === '') {
			return false;
		}
		if (is_link($cfg) || (file_exists($cfg) && !is_dir($cfg))) {
			return false;
		}
		if (!is_dir($cfg)) {
			return true;
		}
		$entries = scandir($cfg);
		if ($entries === false) {
			return false;
		}
		foreach ($entries as $entry) {
			if ($entry === '.' || $entry === '..') {
				continue;
			}
			$full = $cfg . '/' . $entry;
			if (is_link($full) || !is_file($full) || substr($entry, -5) !== '.conf') {
				return false;
			}
			$child = file_get_contents($full);
			if (!is_string($child) || !$this->pttValuesAllowed($child, array('NONE', 'Dummy'))) {
				return false;
			}
		}
		return true;
	}

	private function pttValuesAllowed($raw, array $allowed) {
		$saw = false;
		foreach (preg_split('/\r\n|\n|\r/', (string) $raw) as $line) {
			$line = trim($line);
			if (!preg_match('/^PTT_TYPE\s*=\s*(.*)$/', $line, $match)) {
				continue;
			}
			$value = trim($match[1]);
			$len = strlen($value);
			if ($len >= 2) {
				$quote = $value[0];
				if (($quote === '"' || $quote === "'") && $value[$len - 1] === $quote) {
					$value = substr($value, 1, -1);
				}
			}
			$saw = true;
			if (!in_array($value, $allowed, true)) {
				return false;
			}
		}
		return true;
	}

	// false means the key is repeated. Async::Config keeps the last one,
	// so more than one line is refused instead of guessing.
	private function cfgDirValue($raw) {
		$found = null;
		$count = 0;
		foreach (preg_split('/\r\n|\n|\r/', (string) $raw) as $line) {
			$line = trim($line);
			if (!preg_match('/^CFG_DIR\s*=\s*(.*)$/', $line, $match)) {
				continue;
			}
			$value = trim($match[1]);
			$len = strlen($value);
			if ($len >= 2) {
				$quote = $value[0];
				if (($quote === '"' || $quote === "'") && $value[$len - 1] === $quote) {
					$value = substr($value, 1, -1);
				}
			}
			$found = $value;
			$count++;
		}
		if ($count > 1) {
			return false;
		}
		return $found;
	}

	// A relative value is the conf directory plus the text. The kernel
	// resolves "." and "..". There is no path-normalization loop.
	private function resolveCfgDir($conf, $value) {
		if ($value === '') {
			return '';
		}
		if ($value[0] !== '/') {
			return dirname($conf) . '/' . $value;
		}
		if (self::testHarnessActive()) {
			$root = getenv('ORP_ROOT');
			if (!is_string($root) || rtrim($root, '/') === '' || rtrim($root, '/') === '/') {
				return '';
			}
			$value = rtrim($root, '/') . $value;
			if (!self::harnessPathAllowed($value)) {
				return '';
			}
		}
		return $value;
	}

	// The directory that holds the token. A loose harness file skips this
	// anchor only while the harness is active. Production always checks the
	// directory. A named ACL entry that grants write shows up as group-write
	// in the mode, which the file's perm&022 check already refuses.
	// getfacl is not used.
	private function openrepeaterDirTrusted($dir) {
		if (self::testHarnessActive() && basename($dir) !== 'openrepeater') {
			return true;
		}
		clearstatcache(true, $dir);
		if (!is_dir($dir) || is_link($dir)) {
			return false;
		}
		$owner = fileowner($dir);
		if ($owner === false || (int) $owner !== 0) {
			return false;
		}
		$perms = fileperms($dir);
		return $perms !== false && ($perms & 0022) === 0;
	}

	private function remotetrxConf() {
		if (self::testHarnessActive()) {
			$root = getenv('ORP_ROOT');
			if (!is_string($root) || $root === '') {
				return '';
			}
			$root = rtrim($root, '/');
			if ($root === '' || $root === '/') {
				return '';
			}
			$joined = $root . '/etc/svxlink/remotetrx.conf';
			if (!self::harnessPathAllowed($joined)) {
				return '';
			}
			return $joined;
		}
		return '/etc/svxlink/remotetrx.conf';
	}

	private function txArmedFile() {
		if (self::testHarnessActive()) {
			$override = getenv('ORP_TX_ARMED_FILE');
			if (is_string($override) && $override !== '' && self::harnessPathAllowed($override)) {
				return $override;
			}
			$root = getenv('ORP_ROOT');
			if (is_string($root) && $root !== '' && $root[0] === '/') {
				$joined = rtrim($root, '/') . '/etc/openrepeater/tx-armed';
				if (self::harnessPathAllowed($joined)) {
					return $joined;
				}
			}
			return rtrim(sys_get_temp_dir(), '/') . '/orp-no-such-tx-armed';
		}
		return '/etc/openrepeater/tx-armed';
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

	public static function pathInside($root, $path) {
		$root = rtrim((string) $root, '/');
		$path = rtrim((string) $path, '/');
		return $path === $root || strpos($path, $root . '/') === 0;
	}

	// Delete a file or directory only when it is a real child of $parent.
	// A symlink is unlinked and is not followed.
	public static function removeTreeConfined($path, $parent) {
		if (!is_string($path) || !is_string($parent) || $path === '' || $parent === '') {
			return false;
		}
		if (is_link($parent) || !is_dir($parent)) {
			return false;
		}
		$parentReal = realpath($parent);
		if ($parentReal === false) {
			return false;
		}
		if (!file_exists($path) && !is_link($path)) {
			return true;
		}
		if (is_link($path)) {
			$dir = dirname($path);
			if (is_link($dir) || !is_dir($dir)) {
				return false;
			}
			$dirReal = realpath($dir);
			if ($dirReal === false || !self::pathInside($parentReal, $dirReal)) {
				return false;
			}
			return unlink($path);
		}
		if (!is_dir($path)) {
			$dirReal = realpath(dirname($path));
			$fileReal = realpath($path);
			if ($dirReal === false || $fileReal === false || !self::pathInside($parentReal, $dirReal) || !self::pathInside($parentReal, $fileReal) || $fileReal === $parentReal) {
				return false;
			}
			return unlink($path);
		}
		$real = realpath($path);
		if ($real === false || !self::pathInside($parentReal, $real) || $real === $parentReal) {
			return false;
		}
		return self::removeTreeWalk($real, $parentReal);
	}

	private static function removeTreeWalk($dir, $root) {
		if (is_link($dir)) {
			return unlink($dir);
		}
		if (!is_dir($dir) || !self::pathInside($root, $dir) || $dir === $root) {
			return false;
		}
		$list = scandir($dir);
		if (!is_array($list)) {
			return false;
		}
		foreach ($list as $name) {
			if ($name === '.' || $name === '..') {
				continue;
			}
			$child = $dir . '/' . $name;
			if (is_link($child)) {
				if (!unlink($child)) {
					return false;
				}
				continue;
			}
			if (is_dir($child)) {
				if (!self::removeTreeWalk($child, $root)) {
					return false;
				}
				continue;
			}
			if (!unlink($child)) {
				return false;
			}
		}
		return rmdir($dir);
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
		// Trusted functional-test lifts bench blocks except enable.
		// GPIO stays blocked until the root-only tx-armed flag exists.
		// No token keeps the old answers. Mixer control is not supported.
		if ($this->uiBlocksLifted()) {
			if ($option === 'enable' && in_array($service, array('svxlink', 'remotetrx', 'svxreflector'), true)) {
				return false;
			}
			if (($option === 'gpio_up' || $option === 'gpio_down') && !$this->txArmed()) {
				return false;
			}
			if ($service === 'set_mixer') {
				return false;
			}
			if ($service === 'remotetrx' && ($option === 'start' || $option === 'restart') && !$this->txArmed() && !$this->remotetrxPttDisconnected()) {
				return false;
			}
			return true;
		}
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
