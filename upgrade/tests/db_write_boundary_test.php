<?php
// The new prepared writers must report a failed execute or commit and leave the
// previous rows in place. This uses a copy of the stock database, not the Pi.
if ($argc < 2) {
	fwrite(STDERR, "usage: db_write_boundary_test.php root\n");
	exit(1);
}
$root = $argv[1];
require_once $root . '/includes/classes/Database.php';
if (isset($argv[2]) && $argv[2] === '--as-web') {
	exit(web_uid_fixture($argv[3]));
}
if (isset($argv[2]) && $argv[2] === '--partial-copy') {
	exit(partial_copy_fixture($argv[3]));
}
if (isset($argv[2]) && $argv[2] === '--marker-race') {
	exit(marker_race_loser($argv[3]));
}

function fail($message) {
	fwrite(STDERR, "FAIL: $message\n");
	exit(1);
}
function snap($path) {
	$db = new SQLite3($path, SQLITE3_OPEN_READONLY);
	$db->busyTimeout(1000);
	$out = array('settings' => array(), 'ports' => array(), 'gpio' => array(), 'flags' => array());
	$result = $db->query('SELECT keyID, value FROM settings ORDER BY keyID');
	while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
		$out['settings'][$row['keyID']] = $row['value'];
	}
	$result = $db->query('SELECT portNum, portLabel, rxGPIO, txGPIO FROM ports ORDER BY portNum');
	while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
		$out['ports'][] = $row['portNum'] . ':' . $row['portLabel'] . ':' . $row['rxGPIO'] . ':' . $row['txGPIO'];
	}
	$result = $db->query('SELECT gpio_num, type FROM gpio_pins ORDER BY gpio_num');
	while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
		$out['gpio'][] = $row['gpio_num'] . ':' . $row['type'];
	}
	$result = $db->query('SELECT keyID, value FROM system_flags ORDER BY keyID');
	while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
		$out['flags'][$row['keyID']] = $row['value'];
	}
	$db->close();
	return $out;
}
function partial_copy_fixture($layout) {
	global $root;
	$_SERVER['DOCUMENT_ROOT'] = $root;
	$_SERVER['HTTP_HOST'] = '127.0.0.1';
	putenv('ORP_DB_PATH=' . $layout . '/app.db');
	putenv('ORP_FLAG_STORE=sqlite');
	putenv('ORP_BENCH_TEST_HARNESS=1');
	putenv('ORP_BENCH_MARKER=' . $layout . '/no-marker');
	putenv('ORP_BENCH_HOSTNAME_FILE=' . $layout . '/hostname');
	putenv('ORP_SOUNDS_PATH=' . $layout . '/sounds');
	putenv('ORP_BACKUP_PATH=' . $layout . '/backup');
	putenv('ORP_MODULES_PATH=' . $layout . '/modules');
	require_once $root . '/includes/classes/BenchGuard.php';
	require_once $root . '/includes/classes/Modules.php';
	require_once $root . '/includes/classes/BackupRestore.php';
	$restore = new BackupRestore();
	$result = $restore->restore_backup();
	$keep = $layout . '/sounds/courtesy_tones/keep.wav';
	echo 'msg=' . (isset($result['msgText']) ? $result['msgText'] : '') . "\n";
	echo 'live_keep=' . (is_file($keep) ? file_get_contents($keep) : 'MISSING') . "\n";
	$stashes = glob($layout . '/sounds/.orp-stash-*');
	echo 'stash_count=' . (is_array($stashes) ? count($stashes) : 0) . "\n";
	return 0;
}
function marker_race_loser($layout) {
	global $root;
	$_SERVER['DOCUMENT_ROOT'] = $root;
	$_SERVER['HTTP_HOST'] = '127.0.0.1';
	putenv('ORP_DB_PATH=' . $layout . '/app.db');
	putenv('ORP_FLAG_STORE=sqlite');
	putenv('ORP_BENCH_TEST_HARNESS=1');
	putenv('ORP_BENCH_MARKER=' . $layout . '/no-marker');
	putenv('ORP_BENCH_HOSTNAME_FILE=' . $layout . '/hostname');
	putenv('ORP_SOUNDS_PATH=' . $layout . '/sounds');
	putenv('ORP_BACKUP_PATH=' . $layout . '/backup');
	putenv('ORP_MODULES_PATH=' . $layout . '/modules');
	putenv('ORP_MARKER_PAUSE_FILE=' . $layout . '/pause');
	require_once $root . '/includes/classes/BenchGuard.php';
	require_once $root . '/includes/classes/Modules.php';
	require_once $root . '/includes/classes/BackupRestore.php';
	$restore = new BackupRestore();
	$result = $restore->restore_backup();
	echo 'msg=' . (isset($result['msgText']) ? $result['msgText'] : '') . "\n";
	return 0;
}
function web_uid_fixture($layout) {
	$dbPath = $layout . '/db/openrepeater.db';
	putenv('ORP_DB_PATH=' . $dbPath);
	putenv('ORP_FLAG_STORE=sqlite');
	$db = new Database();
	$tables = array('settings', 'gpio_pins', 'ports', 'modules');
	$inode = fileinode($dbPath);
	$sibling = $layout . '/db/.orp-rename-probe.db';
	if (!copy($dbPath, $sibling)) {
		fwrite(STDERR, "copy for rename probe failed\n");
		return 1;
	}
	$warning = '';
	set_error_handler(function ($errno, $message) use (&$warning) {
		$warning = $message;
		return true;
	});
	$renamed = rename($sibling, $dbPath);
	restore_error_handler();
	echo 'rename_replaced=' . ($renamed ? '1' : '0') . "\n";
	echo 'rename_error=' . (strpos($warning, 'Operation not permitted') !== false ? 'EPERM' : 'other') . "\n";
	if ($renamed) {
		return 1;
	}
	if (is_file($sibling)) {
		unlink($sibling);
	}
	foreach (array('attach', 'vacuum', 'pragma', 'writefile', 'trigger', 'users') as $name) {
		$ok = $db->db_import($tables, $layout . '/' . $name . '.sql');
		echo $name . '_import=' . ($ok === true ? '1' : '0') . "\n";
	}
	$good = $db->db_import($tables, $layout . '/good.sql');
	echo 'good_import=' . ($good === true ? '1' : '0') . "\n";
	echo 'inode_same=' . (fileinode($dbPath) === $inode ? '1' : '0') . "\n";
	$read = new SQLite3($dbPath, SQLITE3_OPEN_READONLY);
	$sign = $read->querySingle("SELECT value FROM settings WHERE keyID='callSign'");
	echo 'callSign=' . $sign . "\n";
	$read->close();
	return ($good === true && !$renamed) ? 0 : 1;
}
function hold_read_lock($path) {
	$db = new SQLite3($path);
	$db->busyTimeout(0);
	if ($db->exec('BEGIN') === false) {
		fail('the test could not hold a read lock');
	}
	$result = $db->query('SELECT keyID FROM settings LIMIT 1');
	if ($result === false || $result->fetchArray() === false) {
		fail('the test could not hold a read lock');
	}
	return $db;
}
function port_row($label, $rx, $tx) {
	return array(
		'portLabel' => $label,
		'rxMode' => 'gpio',
		'rxGPIO' => (string) $rx,
		'txGPIO' => (string) $tx,
		'rxAudioDev' => 'alsa:plughw:0|0',
		'txAudioDev' => 'alsa:plughw:0|0',
		'rxGPIO_active' => 'low',
		'txGPIO_active' => 'high',
	);
}

$copy = sys_get_temp_dir() . '/orp-write-boundary-' . getmypid() . '.db';
if (!copy($root . '/install/sql/openrepeater.db', $copy)) {
	fail('could not copy the stock database');
}
chmod($copy, 0644);
putenv('ORP_DB_PATH=' . $copy);
putenv('ORP_FLAG_STORE=sqlite');
$db = new Database();
if ($db->update_existing_settings(array('callSign' => 'KEEPME')) !== true) {
	fail('a normal settings write did not succeed');
}
if (snap($copy)['settings']['callSign'] !== 'KEEPME') {
	fail('a normal settings write did not store the value');
}
echo "ok: a normal settings write commits\n";

$before = snap($copy);
$locked = hold_read_lock($copy);
$wrote = $db->update_existing_settings(array('callSign' => 'LOCKED'));
$caller = $wrote === true ? 'updated' : 'not-written';
$locked->exec('ROLLBACK');
$locked->close();
if ($wrote === true || $caller !== 'not-written') {
	fail('a locked commit was reported as success');
}
if (snap($copy) != $before) {
	fail('a locked commit changed rows');
}
echo "ok: a locked COMMIT returns not-written and leaves settings unchanged\n";

$before = snap($copy);
$locked = hold_read_lock($copy);
$wrote = $db->replace_port_form(array(port_row('SHOULD-NOT', '11', '12')));
$caller = $wrote === true ? 'updated' : 'not-written';
$locked->exec('ROLLBACK');
$locked->close();
if ($wrote === true || $caller !== 'not-written') {
	fail('a locked port replace was reported as success');
}
if (snap($copy) != $before) {
	fail('a locked port replace changed rows');
}
echo "ok: a locked port replace returns not-written and leaves ports unchanged\n";

chmod($copy, 0444);
$before = snap($copy);
$wrote = $db->update_existing_settings(array('callSign' => 'RO'));
chmod($copy, 0644);
if ($wrote === true) {
	fail('a read-only database reported a settings write');
}
if (snap($copy) != $before) {
	fail('a read-only settings write changed rows');
}
echo "ok: a read-only database refuses the settings write\n";

$writable = new SQLite3($copy);
$writable->exec("CREATE TRIGGER settings_abort_tail BEFORE UPDATE ON settings WHEN NEW.keyID = 'txTailValueSec' AND NEW.value = 'ABORTME' BEGIN SELECT RAISE(ABORT, 'fixture abort'); END;");
$writable->close();
$before = snap($copy);
$wrote = $db->update_existing_settings(array('callSign' => 'PARTIAL', 'txTailValueSec' => 'ABORTME'));
if ($wrote === true) {
	fail('a constraint abort was reported as success');
}
$after = snap($copy);
if ($after['settings']['callSign'] !== 'KEEPME' || $after['settings']['txTailValueSec'] !== $before['settings']['txTailValueSec']) {
	fail('a failed settings batch left a partial call sign write');
}
echo "ok: a constraint abort rolls back the whole settings batch\n";

$before = snap($copy);
$wrote = $db->replace_port_form(array(
	port_row('ONE', '11', '12'),
	port_row('TWO', '11', '13'),
));
if ($wrote === true) {
	fail('a duplicate gpio constraint was reported as success');
}
if (snap($copy)['ports'] !== $before['ports'] || snap($copy)['gpio'] !== $before['gpio']) {
	fail('a duplicate gpio constraint left a partial port replace');
}
echo "ok: a port constraint rolls back the delete and the inserts\n";

function module_rows($path) {
	$db = new SQLite3($path, SQLITE3_OPEN_READONLY);
	$db->busyTimeout(1000);
	$rows = array();
	$result = $db->query('SELECT moduleKey, moduleEnabled, svxlinkName, IFNULL(moduleOptions, "") AS moduleOptions FROM modules ORDER BY moduleKey');
	while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
		$rows[] = $row['moduleKey'] . ':' . $row['moduleEnabled'] . ':' . $row['svxlinkName'] . ':' . $row['moduleOptions'];
	}
	$db->close();
	return $rows;
}

$beforeModules = module_rows($copy);
$locked = hold_read_lock($copy);
$wrote = $db->set_module_enabled('1', 0);
$caller = $wrote === true ? 'activated' : 'not-written';
$locked->exec('ROLLBACK');
$locked->close();
if ($wrote === true || $caller !== 'not-written' || module_rows($copy) !== $beforeModules) {
	fail('a locked module enable was reported as success or changed a row');
}
echo "ok: a locked module enable returns not-written and leaves the row unchanged\n";

$beforeModules = module_rows($copy);
$locked = hold_read_lock($copy);
$wrote = $db->write_module_options('1', 'LOCKED');
$caller = $wrote === true ? 'saved' : 'not-written';
$locked->exec('ROLLBACK');
$locked->close();
if ($wrote === true || $caller !== 'not-written' || module_rows($copy) !== $beforeModules) {
	fail('a locked module options write was reported as success or changed a row');
}
echo "ok: a locked module options write returns not-written and leaves the row unchanged\n";

$writable = new SQLite3($copy);
$writable->exec("CREATE TRIGGER modules_abort_options BEFORE UPDATE ON modules WHEN NEW.moduleOptions = 'ABORTME' BEGIN SELECT RAISE(ABORT, 'fixture abort'); END;");
$writable->close();
$beforeModules = module_rows($copy);
$wrote = $db->write_module_options('1', 'ABORTME');
$caller = $wrote === true ? 'saved' : 'not-written';
if ($wrote === true || $caller !== 'not-written' || module_rows($copy) !== $beforeModules) {
	fail('a module constraint abort was reported as success or left a partial options write');
}
echo "ok: a module constraint abort leaves the previous options unchanged\n";

if ($db->write_module_options('1', 'kept-options') !== true || $db->set_module_enabled('1', 0) !== true) {
	fail('a normal module write did not succeed');
}
$saved = module_rows($copy);
$saw = false;
foreach ($saved as $row) {
	if (strpos($row, '1:0:') === 0 && substr($row, -12) === 'kept-options') {
		$saw = true;
	}
}
if (!$saw) {
	fail('a normal module write did not store the enabled bit and options');
}
echo "ok: a normal module write commits\n";

$dump = sys_get_temp_dir() . '/orp-write-boundary-' . getmypid() . '.sql';
if ($db->db_export(array('settings', 'gpio_pins', 'ports', 'modules'), $dump) !== true) {
	fail('a normal backup export did not succeed');
}
$exported = snap($copy);
if ($db->update_existing_settings(array('callSign' => 'AFTEREXPORT')) !== true) {
	fail('could not change the database before the restore check');
}
if ($db->db_import(array('settings', 'gpio_pins', 'ports', 'modules'), $dump) !== true) {
	fail('a normal backup import did not succeed');
}
if (snap($copy)['settings']['callSign'] !== $exported['settings']['callSign']) {
	fail('a normal backup import did not restore the previous call sign');
}
echo "ok: a normal backup export and import round trip\n";

$before = snap($copy);
$bad = sys_get_temp_dir() . '/orp-write-boundary-bad-' . getmypid() . '.sql';
copy($dump, $bad);
file_put_contents($bad, "\nINSERT INTO settings VALUES('callSign','CHANGED');\n", FILE_APPEND);
$wrote = $db->db_import(array('settings', 'gpio_pins', 'ports', 'modules'), $bad);
$caller = $wrote === true ? 'successfully restored' : 'not-written';
if ($wrote === true || $caller !== 'not-written' || snap($copy) != $before) {
	fail('a backup constraint failure was reported as success or changed rows');
}
echo "ok: a backup constraint failure returns not-written and leaves the previous rows unchanged\n";

file_put_contents($bad, "this is not sql;\n");
$wrote = $db->db_import(array('settings', 'gpio_pins', 'ports', 'modules'), $bad);
if ($wrote === true || snap($copy) != $before) {
	fail('invalid backup SQL was reported as success or changed rows');
}
echo "ok: invalid backup SQL leaves the previous rows unchanged\n";

if ($db->db_export(array('settings'), $bad . '/nested.sql') === true) {
	fail('an unwritable backup path was reported as success');
}
echo "ok: a backup export that cannot create the file returns failure\n";

$work = sys_get_temp_dir() . '/orp-restore-boundary-' . getmypid();
$sounds = $work . '/sounds';
$backup = $work . '/backup';
$modules = $work . '/modules';
foreach (array($sounds . '/courtesy_tones', $backup . '/restore/courtesy_tones', $modules) as $dir) {
	if (!mkdir($dir, 0755, true)) {
		fail('could not build the restore fixture');
	}
}
file_put_contents($sounds . '/courtesy_tones/keep.wav', 'keep');
file_put_contents($backup . '/restore/courtesy_tones/new.wav', 'new');
file_put_contents($backup . '/restore/backup.sql', "this is not sql;\n");
file_put_contents($work . '/hostname', "cloud\n");
$_SERVER['DOCUMENT_ROOT'] = $root;
$_SERVER['HTTP_HOST'] = '127.0.0.1';
putenv('ORP_BENCH_TEST_HARNESS=1');
putenv('ORP_BENCH_MARKER=' . $work . '/no-marker');
putenv('ORP_BENCH_HOSTNAME_FILE=' . $work . '/hostname');
putenv('ORP_SOUNDS_PATH=' . $sounds);
putenv('ORP_BACKUP_PATH=' . $backup);
putenv('ORP_MODULES_PATH=' . $modules);
require_once $root . '/includes/classes/BenchGuard.php';
require_once $root . '/includes/classes/Modules.php';
require_once $root . '/includes/classes/BackupRestore.php';
$before = snap($copy);
$restore = new BackupRestore();
$result = $restore->restore_backup();
$caller = (is_array($result) && isset($result['msgText'])) ? $result['msgText'] : '';
if (!is_array($result) || $result['msgType'] !== 'error' || strpos($caller, 'successfully restored') !== false) {
	fail('a bad backup restore was reported as success');
}
if (file_get_contents($sounds . '/courtesy_tones/keep.wav') !== 'keep' || is_file($sounds . '/courtesy_tones/new.wav')) {
	fail('a bad backup restore changed courtesy files');
}
if (snap($copy) != $before) {
	fail('a bad backup restore changed database rows');
}
echo "ok: a bad backup restore leaves courtesy files and database rows unchanged\n";

copy($dump, $backup . '/restore/backup.sql');
$before = snap($copy);
$locked = hold_read_lock($copy);
$lockedResult = $restore->restore_backup();
$lockedCaller = (is_array($lockedResult) && isset($lockedResult['msgText'])) ? $lockedResult['msgText'] : '';
$locked->exec('ROLLBACK');
$locked->close();
if (!is_array($lockedResult) || $lockedResult['msgType'] !== 'error' || strpos($lockedCaller, 'successfully restored') !== false) {
	fail('a locked restore was reported as success');
}
if (file_get_contents($sounds . '/courtesy_tones/keep.wav') !== 'keep' || is_file($sounds . '/courtesy_tones/new.wav')) {
	fail('a locked restore left courtesy files changed');
}
if (snap($copy) != $before) {
	fail('a locked restore changed database rows');
}
$stashes = glob($sounds . '/.orp-stash-*');
if ($stashes !== array() && $stashes !== false) {
	fail('a locked restore left a courtesy stash behind');
}
echo "ok: a locked restore rolls courtesy files back and leaves database rows unchanged\n";

$partial = sys_get_temp_dir() . '/orp-partial-copy-' . getmypid();
foreach (array($partial . '/sounds/courtesy_tones', $partial . '/backup/restore/courtesy_tones', $partial . '/modules') as $dir) {
	if (!mkdir($dir, 0777, true)) {
		fail('could not build the partial-copy fixture');
	}
}
copy($copy, $partial . '/app.db');
chmod($partial . '/app.db', 0666);
file_put_contents($partial . '/hostname', "cloud\n");
file_put_contents($partial . '/sounds/courtesy_tones/keep.wav', 'keep');
file_put_contents($partial . '/backup/restore/courtesy_tones/new.wav', 'new');
file_put_contents($partial . '/backup/restore/courtesy_tones/secret.wav', 'secret');
copy($dump, $partial . '/backup/restore/backup.sql');
exec('sudo -n chown -R www-data:www-data ' . escapeshellarg($partial) . ' && sudo -n chown root:root ' . escapeshellarg($partial . '/backup/restore/courtesy_tones/secret.wav') . ' && sudo -n chmod 000 ' . escapeshellarg($partial . '/backup/restore/courtesy_tones/secret.wav'), $unused, $partialSetup);
if ($partialSetup !== 0) {
	fail('could not make the unreadable incoming file');
}
$partialOut = array();
$partialRc = 1;
exec('sudo -n setpriv --reuid=33 --regid=33 --clear-groups --inh-caps=-all -- php ' . escapeshellarg(__FILE__) . ' ' . escapeshellarg($root) . ' --partial-copy ' . escapeshellarg($partial), $partialOut, $partialRc);
$partialText = implode("\n", $partialOut);
if ($partialRc !== 0 || strpos($partialText, 'live_keep=keep') === false || strpos($partialText, 'stash_count=0') === false || strpos($partialText, 'left unchanged') === false) {
	fwrite(STDERR, $partialText . "\n");
	fail('a partial copy changed the live courtesy tree');
}
echo "ok: a partial copy is discarded from the private stage and the live tree stays in place\n";

$escape = sys_get_temp_dir() . '/orp-ancestor-' . getmypid();
mkdir($escape . '/outside/audio/courtesy_tones', 0755, true);
mkdir($escape . '/backup/restore/courtesy_tones', 0755, true);
mkdir($escape . '/modules', 0755, true);
file_put_contents($escape . '/outside/audio/courtesy_tones/secret.wav', 'secret');
file_put_contents($escape . '/backup/restore/courtesy_tones/new.wav', 'new');
copy($dump, $escape . '/backup/restore/backup.sql');
copy($copy, $escape . '/app.db');
symlink($escape . '/outside', $escape . '/via');
file_put_contents($escape . '/hostname', "cloud\n");
putenv('ORP_DB_PATH=' . $escape . '/app.db');
putenv('ORP_SOUNDS_PATH=' . $escape . '/via/audio');
putenv('ORP_BACKUP_PATH=' . $escape . '/backup');
putenv('ORP_MODULES_PATH=' . $escape . '/modules');
$escapeRestore = new BackupRestore();
$escapeResult = $escapeRestore->restore_backup();
$escapeMsg = isset($escapeResult['msgText']) ? $escapeResult['msgText'] : '';
if ($escapeResult['msgType'] !== 'error' || strpos($escapeMsg, 'successfully restored') !== false || file_get_contents($escape . '/outside/audio/courtesy_tones/secret.wav') !== 'secret' || is_file($escape . '/outside/audio/courtesy_tones/new.wav')) {
	fail('an ancestor symlink let the restore replace an outside tree');
}
echo "ok: an ancestor symlink is not a trusted sounds anchor\n";

$childLink = sys_get_temp_dir() . '/orp-child-link-' . getmypid();
mkdir($childLink . '/sounds', 0755, true);
mkdir($childLink . '/outside', 0755, true);
mkdir($childLink . '/backup/restore/courtesy_tones', 0755, true);
mkdir($childLink . '/modules', 0755, true);
file_put_contents($childLink . '/outside/secret.wav', 'secret');
symlink($childLink . '/outside', $childLink . '/sounds/courtesy_tones');
file_put_contents($childLink . '/backup/restore/courtesy_tones/new.wav', 'new');
copy($dump, $childLink . '/backup/restore/backup.sql');
copy($copy, $childLink . '/app.db');
file_put_contents($childLink . '/hostname', "cloud\n");
putenv('ORP_DB_PATH=' . $childLink . '/app.db');
putenv('ORP_SOUNDS_PATH=' . $childLink . '/sounds');
putenv('ORP_BACKUP_PATH=' . $childLink . '/backup');
putenv('ORP_MODULES_PATH=' . $childLink . '/modules');
$childRestore = new BackupRestore();
$childResult = $childRestore->restore_backup();
if ($childResult['msgType'] !== 'error' || file_get_contents($childLink . '/outside/secret.wav') !== 'secret' || is_file($childLink . '/outside/new.wav')) {
	fail('a courtesy symlink let the restore write outside the sounds anchor');
}
echo "ok: a symlinked courtesy directory is not replaced\n";

$mixer = sys_get_temp_dir() . '/orp-mixer-' . getmypid();
mkdir($mixer . '/sounds/courtesy_tones', 0755, true);
mkdir($mixer . '/backup/restore/courtesy_tones', 0755, true);
mkdir($mixer . '/modules', 0755, true);
file_put_contents($mixer . '/sounds/courtesy_tones/keep.wav', 'keep');
file_put_contents($mixer . '/backup/restore/courtesy_tones/new.wav', 'new');
file_put_contents($mixer . '/backup/restore/alsamixer.state', "mixer\n");
copy($dump, $mixer . '/backup/restore/backup.sql');
copy($copy, $mixer . '/app.db');
file_put_contents($mixer . '/hostname', "cloud\n");
putenv('ORP_DB_PATH=' . $mixer . '/app.db');
putenv('ORP_SOUNDS_PATH=' . $mixer . '/sounds');
putenv('ORP_BACKUP_PATH=' . $mixer . '/backup');
putenv('ORP_MODULES_PATH=' . $mixer . '/modules');
putenv('ORP_RESTORE_FAULT=alsa-fail');
$beforeMixer = snap($mixer . '/app.db');
$mixerDb = new Database();
if ($mixerDb->update_existing_settings(array('callSign' => 'BEFOREMIX')) !== true) {
	fail('could not mark the database before the mixer failure');
}
$mixerRestore = new BackupRestore();
$mixerResult = $mixerRestore->restore_backup();
$mixerMsg = isset($mixerResult['msgText']) ? $mixerResult['msgText'] : '';
putenv('ORP_RESTORE_FAULT');
if (strpos($mixerMsg, 'left unchanged') !== false || strpos($mixerMsg, 'mixer state was not applied') === false || snap($mixer . '/app.db')['settings']['callSign'] !== $beforeMixer['settings']['callSign'] || file_get_contents($mixer . '/sounds/courtesy_tones/new.wav') !== 'new') {
	fwrite(STDERR, $mixerMsg . "\n");
	fail('a mixer failure was reported as an unchanged restore or rolled the database back');
}
echo "ok: a mixer failure leaves the restored rows in place and does not claim they were unchanged\n";

$collision = sys_get_temp_dir() . '/orp-collision-' . getmypid();
mkdir($collision . '/sounds/courtesy_tones', 0755, true);
mkdir($collision . '/backup/restore/courtesy_tones', 0755, true);
mkdir($collision . '/modules', 0755, true);
file_put_contents($collision . '/sounds/courtesy_tones/keep.wav', 'keep');
file_put_contents($collision . '/backup/restore/courtesy_tones/new.wav', 'new');
copy($dump, $collision . '/backup/restore/backup.sql');
copy($copy, $collision . '/app.db');
file_put_contents($collision . '/hostname', "cloud\n");
putenv('ORP_DB_PATH=' . $collision . '/app.db');
putenv('ORP_SOUNDS_PATH=' . $collision . '/sounds');
putenv('ORP_BACKUP_PATH=' . $collision . '/backup');
putenv('ORP_MODULES_PATH=' . $collision . '/modules');
putenv('ORP_RESTORE_FAULT=publish-collision');
$collisionRestore = new BackupRestore();
$collisionResult = $collisionRestore->restore_backup();
$collisionMsg = isset($collisionResult['msgText']) ? $collisionResult['msgText'] : '';
putenv('ORP_RESTORE_FAULT');
$collisionStash = glob($collision . '/sounds/.orp-stash-*');
$stashKeep = false;
if (is_array($collisionStash)) {
	foreach ($collisionStash as $stash) {
		if (is_file($stash . '/keep.wav') && file_get_contents($stash . '/keep.wav') === 'keep') {
			$stashKeep = true;
		}
	}
}
if (strpos($collisionMsg, 'needs recovery') === false || strpos($collisionMsg, 'left unchanged') !== false || !$stashKeep || !is_file($collision . '/backup/restore-recovery.json')) {
	fwrite(STDERR, $collisionMsg . "\n");
	fail('a populated publish collision claimed the original tree was restored');
}
$again = new BackupRestore();
$againResult = $again->restore_backup();
$againMsg = isset($againResult['msgText']) ? $againResult['msgText'] : '';
if (strpos($againMsg, 'needs recovery') === false || !$stashKeep) {
	fail('a second restore ignored the recovery notes');
}
echo "ok: a populated destination is reported as recovery required and the original tree is kept in the stash\n";
$collisionNote = json_decode(file_get_contents($collision . '/backup/restore-recovery.json'), true);
$mappedStash = is_array($collisionNote) && isset($collisionNote['moves'][0]['stash']) ? $collisionNote['moves'][0]['stash'] : '';
$mappedDest = is_array($collisionNote) && isset($collisionNote['moves'][0]['destination']) ? $collisionNote['moves'][0]['destination'] : '';
if ($collisionNote['phase'] !== 'ready' || $collisionNote['automated_recovery'] !== false || $mappedDest !== $collision . '/sounds/courtesy_tones' || !is_file($mappedStash . '/keep.wav') || file_get_contents($mappedStash . '/keep.wav') !== 'keep') {
	fail('the recovery note did not record the destination and stash before the failed publish');
}
echo "ok: the recovery note maps the destination to the stash that holds the original tree\n";

function marker_layout($name, $dump, $db) {
	$work = sys_get_temp_dir() . '/' . $name . '-' . getmypid();
	mkdir($work . '/sounds/courtesy_tones', 0755, true);
	mkdir($work . '/backup/restore/courtesy_tones', 0755, true);
	mkdir($work . '/modules', 0755, true);
	file_put_contents($work . '/sounds/courtesy_tones/keep.wav', 'keep');
	file_put_contents($work . '/backup/restore/courtesy_tones/new.wav', 'new');
	copy($dump, $work . '/backup/restore/backup.sql');
	copy($db, $work . '/app.db');
	file_put_contents($work . '/hostname', "cloud\n");
	putenv('ORP_DB_PATH=' . $work . '/app.db');
	putenv('ORP_SOUNDS_PATH=' . $work . '/sounds');
	putenv('ORP_BACKUP_PATH=' . $work . '/backup');
	putenv('ORP_MODULES_PATH=' . $work . '/modules');
	putenv('ORP_RESTORE_FAULT');
	return $work;
}
$dangling = marker_layout('orp-dangling-marker', $dump, $copy);
$danglingOutside = $dangling . '/outside.json';
symlink($danglingOutside, $dangling . '/backup/restore-recovery.json');
$danglingRestore = new BackupRestore();
$danglingResult = $danglingRestore->restore_backup();
if (file_exists($danglingOutside) || file_get_contents($dangling . '/sounds/courtesy_tones/keep.wav') !== 'keep' || strpos($danglingResult['msgText'], 'successfully restored') !== false || strpos($danglingResult['msgText'], 'needs recovery') === false) {
	fail('a dangling recovery marker was followed or the live tree changed');
}
echo "ok: a dangling recovery marker is not followed and creates nothing outside the backup directory\n";

$liveLink = marker_layout('orp-live-marker', $dump, $copy);
$liveOutside = $liveLink . '/outside.json';
file_put_contents($liveOutside, 'OLD');
symlink($liveOutside, $liveLink . '/backup/restore-recovery.json');
$liveLinkRestore = new BackupRestore();
$liveLinkResult = $liveLinkRestore->restore_backup();
if (file_get_contents($liveOutside) !== 'OLD' || file_get_contents($liveLink . '/sounds/courtesy_tones/keep.wav') !== 'keep' || strpos($liveLinkResult['msgText'], 'needs recovery') === false) {
	fail('a live recovery-marker symlink was followed');
}
echo "ok: a live recovery-marker symlink is not followed\n";

$existing = marker_layout('orp-existing-marker', $dump, $copy);
file_put_contents($existing . '/backup/restore-recovery.json', 'CANARY');
chmod($existing . '/backup/restore-recovery.json', 0644);
$existingRestore = new BackupRestore();
$existingResult = $existingRestore->restore_backup();
if (file_get_contents($existing . '/backup/restore-recovery.json') !== 'CANARY' || file_get_contents($existing . '/sounds/courtesy_tones/keep.wav') !== 'keep' || strpos($existingResult['msgText'], 'needs recovery') === false) {
	fail('an existing recovery marker was replaced');
}
echo "ok: an existing recovery marker is left untouched\n";

$unwritable = marker_layout('orp-marker-write', $dump, $copy);
chmod($unwritable . '/backup', 0555);
$unwritableRestore = new BackupRestore();
$unwritableResult = $unwritableRestore->restore_backup();
chmod($unwritable . '/backup', 0755);
if (file_get_contents($unwritable . '/sounds/courtesy_tones/keep.wav') !== 'keep' || is_file($unwritable . '/sounds/courtesy_tones/new.wav') || is_file($unwritable . '/backup/restore-recovery.json') || strpos($unwritableResult['msgText'], 'left unchanged') === false) {
	fail('a recovery-note write failure changed the live tree');
}
echo "ok: a recovery-note write failure leaves the live tree unchanged\n";

$updateFail = marker_layout('orp-marker-update', $dump, $copy);
$updateDb = new Database();
if ($updateDb->update_existing_settings(array('callSign' => 'BEFORENOTE')) !== true) {
	fail('could not mark the database before the recovery-note update failure');
}
putenv('ORP_RESTORE_FAULT=marker-update');
$updateRestore = new BackupRestore();
$updateResult = $updateRestore->restore_backup();
putenv('ORP_RESTORE_FAULT');
$updateNote = json_decode(file_get_contents($updateFail . '/backup/restore-recovery.json'), true);
$updateStash = is_array($updateNote) && isset($updateNote['moves'][0]['stash']) ? $updateNote['moves'][0]['stash'] : '';
$updateDest = is_array($updateNote) && isset($updateNote['moves'][0]['destination']) ? $updateNote['moves'][0]['destination'] : '';
$updateSign = snap($updateFail . '/app.db')['settings']['callSign'];
if (!is_array($updateNote) || $updateNote['phase'] !== 'ready' || $updateNote['automated_recovery'] !== false || $updateDest !== $updateFail . '/sounds/courtesy_tones' || file_get_contents($updateStash . '/keep.wav') !== 'keep' || $updateSign !== 'BEFORENOTE' || strpos($updateResult['msgText'], 'needs recovery') === false || strpos($updateResult['msgText'], 'automated recovery') === false || substr(sprintf('%o', fileperms($updateFail . '/backup/restore-recovery.json')), -4) !== '0600') {
	fwrite(STDERR, isset($updateResult['msgText']) ? $updateResult['msgText'] : '' . "\n");
	fail('a recovery-note update failure did not keep the destination and stash mapping');
}
echo "ok: a recovery-note update failure keeps the mapped stash and does not change the database\n";

$short = marker_layout('orp-marker-short', $dump, $copy);
putenv('ORP_MARKER_SHORT_WRITE=1');
$shortRestore = new BackupRestore();
$shortResult = $shortRestore->restore_backup();
putenv('ORP_MARKER_SHORT_WRITE');
if (is_file($short . '/backup/restore-recovery.json') || file_get_contents($short . '/sounds/courtesy_tones/keep.wav') !== 'keep' || strpos($shortResult['msgText'], 'left unchanged') === false) {
	fail('a partial recovery-note write left a file or changed the live tree');
}
echo "ok: a partial recovery-note write removes only the file that attempt created\n";

$race = marker_layout('orp-marker-race', $dump, $copy);
$raceProc = proc_open('php ' . escapeshellarg(__FILE__) . ' ' . escapeshellarg($root) . ' --marker-race ' . escapeshellarg($race), array(1 => array('pipe', 'w'), 2 => array('file', $race . '/loser.err', 'w')), $racePipes);
$raceDeadline = time() + 5;
while (!is_file($race . '/pause') && time() < $raceDeadline) {
	usleep(20000);
}
if (!is_file($race . '/pause')) {
	proc_terminate($raceProc);
	fail('the losing restore did not reach the exclusive create');
}
$winnerBytes = '{"winner":true,"stash":"/orig/stash"}';
$winnerCmd = 'python3 -c ' . escapeshellarg('import os,sys; p=sys.argv[1]; d=sys.stdin.buffer.read(); fd=os.open(p, os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_WRONLY, 0o600); os.write(fd, d); os.close(fd)');
$winnerProc = proc_open($winnerCmd . ' ' . escapeshellarg($race . '/backup/restore-recovery.json'), array(0 => array('pipe', 'r'), 1 => array('pipe', 'w'), 2 => array('pipe', 'w')), $winnerPipes);
fwrite($winnerPipes[0], $winnerBytes);
fclose($winnerPipes[0]);
$winnerRc = proc_close($winnerProc);
file_put_contents($race . '/pause.go', "go\n");
$raceOut = stream_get_contents($racePipes[1]);
$raceRc = proc_close($raceProc);
if ($winnerRc !== 0 || $raceRc !== 0 || file_get_contents($race . '/backup/restore-recovery.json') !== $winnerBytes || file_get_contents($race . '/sounds/courtesy_tones/keep.wav') !== 'keep' || strpos($raceOut, 'left unchanged') === false) {
	fwrite(STDERR, $raceOut);
	fail('a failed exclusive create deleted the other restore note');
}
echo "ok: a failed exclusive create leaves the other restore note in place\n";

$layout = sys_get_temp_dir() . '/orp-sticky-' . getmypid();
$stickyDb = $layout . '/db/openrepeater.db';
$victim = $layout . '/victim.db';
$goodDb = $layout . '/good.db';
$written = sys_get_temp_dir() . '/orp-written-' . getmypid() . '.txt';
$vacuum = sys_get_temp_dir() . '/orp-vacuum-' . getmypid() . '.db';
if (!mkdir($layout . '/db', 0755, true) || !copy($root . '/install/sql/openrepeater.db', $stickyDb) || !copy($stickyDb, $victim) || !copy($stickyDb, $goodDb)) {
	fail('could not build the sticky database layout');
}
exec('sqlite3 ' . escapeshellarg($stickyDb) . ' ' . escapeshellarg("UPDATE settings SET value='STICKY' WHERE keyID='callSign';"));
exec('sqlite3 ' . escapeshellarg($victim) . ' ' . escapeshellarg("UPDATE settings SET value='VICTIM' WHERE keyID='callSign';"));
exec('sqlite3 ' . escapeshellarg($goodDb) . ' ' . escapeshellarg("UPDATE settings SET value='RESTORED' WHERE keyID='callSign';"));
putenv('ORP_DB_PATH=' . $goodDb);
$exporter = new Database();
if ($exporter->db_export(array('settings', 'gpio_pins', 'ports', 'modules'), $layout . '/good.sql') !== true) {
	fail('could not export the sticky fixture backup');
}
$goodSql = file_get_contents($layout . '/good.sql');
$attacks = array(
	'attach' => "ATTACH DATABASE '" . str_replace("'", "''", $victim) . "' AS victim;\nUPDATE victim.settings SET value='PWNED' WHERE keyID='callSign';\n",
	'vacuum' => "VACUUM INTO '" . str_replace("'", "''", $vacuum) . "';\n",
	'pragma' => "PRAGMA writable_schema=ON;\n",
	'writefile' => "SELECT writefile('" . str_replace("'", "''", $written) . "','pwned');\n",
	'trigger' => "CREATE TRIGGER evil AFTER INSERT ON settings BEGIN SELECT RAISE(ABORT,'x'); END;\n",
	'users' => "INSERT INTO users (userID, username, password, salt) VALUES (9,'attacker','x','y');\n",
);
foreach ($attacks as $name => $suffix) {
	file_put_contents($layout . '/' . $name . '.sql', $goodSql . "\n" . $suffix);
}
chmod($victim, 0666);
exec('sudo -n chown root:www-data ' . escapeshellarg($layout . '/db') . ' ' . escapeshellarg($stickyDb) . ' && sudo -n chmod 1770 ' . escapeshellarg($layout . '/db') . ' && sudo -n chmod 0660 ' . escapeshellarg($stickyDb), $unused, $setupRc);
if ($setupRc !== 0) {
	fail('could not apply the root-owned sticky database policy');
}
$inodeBefore = trim(shell_exec('sudo -n stat -c %i ' . escapeshellarg($stickyDb)));
$usersBefore = trim(shell_exec('sudo -n sqlite3 ' . escapeshellarg($stickyDb) . ' ' . escapeshellarg('SELECT COUNT(*) FROM users;')));
$childOut = array();
$childRc = 1;
exec('sudo -n setpriv --reuid=33 --regid=33 --clear-groups --inh-caps=-all -- php ' . escapeshellarg(__FILE__) . ' ' . escapeshellarg($root) . ' --as-web ' . escapeshellarg($layout), $childOut, $childRc);
$childText = implode("\n", $childOut);
if ($childRc !== 0 || strpos($childText, 'rename_replaced=0') === false || strpos($childText, 'rename_error=EPERM') === false || strpos($childText, 'good_import=1') === false || strpos($childText, 'inode_same=1') === false || strpos($childText, 'callSign=RESTORED') === false) {
	fwrite(STDERR, $childText . "\n");
	fail('the www-data sticky restore did not publish in place');
}
foreach (array('attach', 'vacuum', 'pragma', 'writefile', 'trigger', 'users') as $name) {
	if (strpos($childText, $name . '_import=0') === false) {
		fail('untrusted backup SQL was accepted: ' . $name);
	}
}
$inodeAfter = trim(shell_exec('sudo -n stat -c %i ' . escapeshellarg($stickyDb)));
$usersAfter = trim(shell_exec('sudo -n sqlite3 ' . escapeshellarg($stickyDb) . ' ' . escapeshellarg('SELECT COUNT(*) FROM users;')));
$attacker = trim(shell_exec('sudo -n sqlite3 ' . escapeshellarg($stickyDb) . ' ' . escapeshellarg("SELECT COUNT(*) FROM users WHERE username='attacker';")));
$victimSign = trim(shell_exec('sqlite3 ' . escapeshellarg($victim) . ' ' . escapeshellarg("SELECT value FROM settings WHERE keyID='callSign';")));
if ($inodeBefore === '' || $inodeBefore !== $inodeAfter) {
	fail('the restore replaced the root-owned database inode');
}
if ($usersBefore !== $usersAfter || $attacker !== '0' || $victimSign !== 'VICTIM' || is_file($written) || is_file($vacuum)) {
	fail('untrusted backup SQL changed a database or wrote a file');
}
echo "ok: www-data restores in place on a root-owned sticky database and confined SQL has no side effects\n";
echo "database write boundary checks passed\n";
