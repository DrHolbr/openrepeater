<?php
function fail($msg) {
	fwrite(STDERR, "FAIL: {$msg}\n");
	exit(1);
}

$root = dirname(__DIR__, 2);
require $root . '/includes/classes/BenchGuard.php';
require $root . '/includes/classes/SVXLink.php';
require $root . '/includes/classes/Database.php';

$tmp = sys_get_temp_dir() . '/orp-stage-only-' . getmypid();
$preview = sys_get_temp_dir() . '/orp-preview-stage-' . getmypid();
$live = $tmp . '/etc/svxlink';
mkdir($live, 0755, true);
mkdir($preview, 0755, true);
$liveFile = $live . '/svxlink.conf';
file_put_contents($liveFile, "SECRET\n");
chmod($liveFile, 0600);
$before = file_get_contents($liveFile);
$inode = fileinode($liveFile);

$dbPath = $tmp . '/app.db';
if (!copy($root . '/install/sql/openrepeater.db', $dbPath) || !chmod($dbPath, 0600)) {
	fail('could not make a writable copy of the stock database');
}
$host = $tmp . '/hostname';
$marker = $tmp . '/no-marker';
$mode = $tmp . '/operating-mode';
file_put_contents($host, "orp-test\n");
file_put_contents($mode, "functional-test\n");
chmod($mode, 0644);

putenv('ORP_BENCH_TEST_HARNESS=1');
putenv('ORP_BENCH_HOSTNAME_FILE=' . $host);
putenv('ORP_BENCH_MARKER=' . $marker);
putenv('ORP_OPERATING_MODE_FILE=' . $mode);
putenv('ORP_BENCH_PREVIEW=' . $preview);
putenv('ORP_LIVE_CONFIG_ROOT=' . $tmp);
putenv('ORP_DB_PATH=' . $dbPath);
putenv('ORP_FLAG_STORE=sqlite');

$db = new Database();
$svx = new SVXLink($db->get_settings(), $db->get_ports(), array());
if ($svx->configDestination('svxlink.conf') !== $liveFile) {
	fail('the destination string was not the fixture live path');
}
if ($svx->write_config($svx->disconnectedRuntimeConfig(), 'svxlink.conf', 'ini') !== true) {
	fail('staging the disconnected runtime failed');
}
if (file_get_contents($liveFile) !== $before || fileinode($liveFile) !== $inode) {
	fail('PHP wrote the live svxlink.conf');
}
$staged = file_get_contents($preview . '/svxlink.conf');
if (!is_string($staged) || strpos($staged, 'PTT_TYPE=NONE') === false) {
	fail('the stage file was not written');
}
chmod($liveFile, 0000);
if ($svx->write_config($svx->disconnectedRuntimeConfig(), 'svxlink.conf', 'ini') !== true) {
	fail('an unreadable live path made staging fail');
}
chmod($liveFile, 0600);
if (file_get_contents($liveFile) !== $before) {
	fail('the unreadable live path was still changed');
}
echo "ok: PHP stages svxlink.conf and does not open the live path\n";
