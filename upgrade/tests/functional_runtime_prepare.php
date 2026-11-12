<?php
function fail($msg) {
	fwrite(STDERR, "FAIL: {$msg}\n");
	exit(1);
}
$root = $argv[1];
$dbPath = $argv[2];
$sqlite = new SQLite3($dbPath);
$sqlite->exec('UPDATE settings SET value = "FIXTURE" WHERE keyID = "callSign"');
file_put_contents($argv[7], (string)$sqlite->querySingle('SELECT txGPIO FROM ports'));
$sqlite->close();
$host = $argv[3];
$marker = $argv[4];
$mode = $argv[5];
$preview = $argv[6];
require $root . '/includes/classes/BenchGuard.php';
require $root . '/includes/classes/SVXLink.php';
require $root . '/includes/classes/Database.php';
putenv('ORP_BENCH_TEST_HARNESS=1');
putenv('ORP_BENCH_HOSTNAME_FILE=' . $host);
putenv('ORP_BENCH_MARKER=' . $marker);
putenv('ORP_OPERATING_MODE_FILE=' . $mode);
putenv('ORP_BENCH_PREVIEW=' . $preview);
putenv('ORP_SVXLINK_PREFIX=/usr');
putenv('ORP_DB_PATH=' . $dbPath);
putenv('ORP_FLAG_STORE=sqlite');
$db = new Database();
$settings = $db->get_settings();
$ports = $db->get_ports();
$svx = new SVXLink($settings, $ports, array());
if ($svx->configDestination('svxlink.conf') !== $preview . '/svxlink.conf') {
	fail('config destination was not the stage file');
}
if ($svx->configDestination('gpio.conf') !== null) {
	fail('functional-test still has a gpio.conf destination');
}
$cfg = $svx->disconnectedRuntimeConfig();
if ($svx->write_config($cfg, 'svxlink.conf', 'ini') !== true) {
	fail('disconnected runtime was not staged');
}
$staged = file_get_contents($preview . '/svxlink.conf');
foreach (array('PTT_TYPE=NONE', 'SQL_DET=SIGLEV', 'udp:127.0.0.1:17001', 'udp:127.0.0.1:17002', 'EVENT_HANDLER=/usr/share/svxlink/events.tcl', 'CALLSIGN=FIXTURE') as $needle) {
	if (strpos($staged, $needle) === false) {
		fail('staged config missing ' . $needle);
	}
}
if (preg_match('/^[^#].*(PTT_PIN|GPIO_SQL_PIN|GPIO_PATH|PTT_TYPE=GPIO)/m', $staged)) {
	fail('staged config contains GPIO or PTT hardware');
}
echo "ok: staged no-PTT config targets the preview file\n";
