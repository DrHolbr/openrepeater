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
