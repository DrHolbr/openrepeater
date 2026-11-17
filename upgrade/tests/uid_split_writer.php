<?php
/**
 * Run as www-data. Arguments: action, path, optional second path.
 * Exit 0 only when the action's expected result happens.
 */
$root = dirname(__DIR__, 2);
require_once $root . '/includes/classes/BenchGuard.php';
require_once $root . '/includes/classes/SVXLink.php';

$action = isset($argv[1]) ? $argv[1] : '';
$path = isset($argv[2]) ? $argv[2] : '';
$extra = isset($argv[3]) ? $argv[3] : '';

function fail($msg) {
	fwrite(STDERR, "FAIL: $msg\n");
	exit(1);
}

if ($action === 'sqlite') {
	$before = stat($path);
	if ($before === false) {
		fail('database missing');
	}
	$db = new SQLite3($path);
	$db->exec('CREATE TABLE IF NOT EXISTS uid_probe (id INTEGER PRIMARY KEY, note TEXT)');
	$db->exec('BEGIN');
	$db->exec("INSERT INTO uid_probe (note) VALUES ('created')");
	$journal = $path . '-journal';
	if (!is_file($journal)) {
		fail('rollback journal was not created');
	}
	$db->exec('COMMIT');
	$after = stat($path);
	if ($before['ino'] !== $after['ino'] || $before['uid'] !== $after['uid'] || $before['mode'] !== $after['mode']) {
		fail('database inode changed during journaled insert');
	}
	$db->exec("UPDATE uid_probe SET note = 'updated' WHERE note = 'created'");
	$note = $db->querySingle("SELECT note FROM uid_probe WHERE note = 'updated'");
	if ($note !== 'updated') {
		fail('update was not readable');
	}
	if (@unlink($path)) {
		fail('www-data replaced the root-owned database file');
	}
	if (!is_file($path)) {
		fail('database file disappeared');
	}
	echo "ok sqlite\n";
	exit(0);
}

putenv('ORP_BENCH_TEST_HARNESS=1');
putenv('ORP_BENCH_HOSTNAME_FILE=' . $extra);
putenv('ORP_BENCH_PREVIEW=' . $path);
$svx = new SVXLink(array('txTailValueSec' => 1, 'txTone' => '', 'rxTone' => ''), array(
	1 => array(
		'rxAudioDev' => 'alsa:plughw:0|0',
		'txAudioDev' => 'alsa:plughw:0|0',
		'rxMode' => 'gpio',
		'rxGPIO' => '26',
		'txGPIO' => '498',
	),
), array());

if ($action === 'create' || $action === 'overwrite') {
	$file = $path . '/svxlink.conf';
	$body = $action === 'create' ? "created-by-www-data\n" : "overwritten-by-www-data\n";
	if (BenchGuard::writeContained($file, $body) !== true || !is_file($file)) {
		fail($action . ' did not create a preview file');
	}
	if (file_get_contents($file) !== $body) {
		fail($action . ' did not leave the expected bytes');
	}
	echo "ok $action\n";
	exit(0);
}

if ($action === 'publish') {
	$ok = $svx->write_config(array('Rx1' => array('TYPE' => 'Local', 'PTT_PIN' => 'gpio498')), 'svxlink.conf', 'ini');
	$file = $path . '/svxlink.conf';
	if ($ok !== true || !is_file($file) || $svx->publishFailed()) {
		fail('publish did not report success');
	}
	$body = file_get_contents($file);
	if (strpos($body, "\nPTT_PIN=") !== false || strpos($body, 'BENCH DISARMED') === false) {
		fail('publish left an active PTT line');
	}
	echo "ok publish\n";
	exit(0);
}

if ($action === 'fail-locked' || $action === 'fail-symlink') {
	$ok = $svx->write_config("PTT_PIN=gpio498\n", 'svxlink.conf', 'text');
	if ($ok !== false || $svx->publishFailed() !== true) {
		fail($action . ' was reported as success');
	}
	echo "ok $action\n";
	exit(0);
}

fail('unknown action');
