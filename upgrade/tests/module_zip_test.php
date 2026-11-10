<?php
// Module archives stay inside the upload directory. A PHP build without
// ZipArchive returns the package refusal instead of a fatal error.
if ($argc < 2) {
	fwrite(STDERR, "usage: module_zip_test.php missing|hostile\n");
	exit(1);
}
$mode = $argv[1];
$root = dirname(__DIR__, 2);
require $root . '/includes/classes/BenchGuard.php';
require $root . '/includes/classes/Database.php';
require $root . '/includes/classes/Modules.php';

function zip_fail($message) {
	fwrite(STDERR, "FAIL: {$message}\n");
	exit(1);
}

$fixture = getenv('ORP_TEST_TMPDIR');
if (!is_string($fixture) || $fixture === '' || $fixture[0] !== '/') {
	$fixture = sys_get_temp_dir();
}
$work = rtrim($fixture, '/') . '/orp-zip-' . getmypid();
if (!mkdir($work, 0755, true) && !is_dir($work)) {
	zip_fail('could not create the zip fixture');
}
$modulesDir = $work . '/modules';
mkdir($modulesDir, 0755);
$outside = $work . '/outside.txt';
file_put_contents($outside, 'KEEP');
$_SERVER['DOCUMENT_ROOT'] = $work;
putenv('ORP_BENCH_TEST_HARNESS=1');
putenv('ORP_BENCH_HOSTNAME_FILE=' . $work . '/no-host');
putenv('ORP_BENCH_MARKER=' . $work . '/no-marker');
putenv('ORP_MODULES_PATH=' . $modulesDir);
putenv('ORP_DB_PATH=' . $work . '/unused.db');

$modules = new Modules();

if ($mode === 'missing') {
	if (class_exists('ZipArchive', false)) {
		zip_fail('ZipArchive is loaded; the missing-extension process must not include it');
	}
	$result = $modules->upload_module(null);
	$text = is_array($result) && isset($result['msgText']) ? $result['msgText'] : '';
	if ($result['msgType'] !== 'error' || $text !== Modules::zipSupportMessage()) {
		zip_fail('missing ZipArchive did not return the php8.4-zip refusal');
	}
	if ($modules->unzip_module($work . '/none.zip') !== false) {
		zip_fail('unzip_module did not refuse without ZipArchive');
	}
	echo "ok: missing ZipArchive names the php8.4-zip package\n";
	exit(0);
}

if ($mode !== 'hostile') {
	zip_fail('unknown mode');
}
if (!class_exists('ZipArchive', false)) {
	zip_fail('ZipArchive is required for the hostile archive checks');
}

function write_zip($path, $entries) {
	$zip = new ZipArchive();
	if ($zip->open($path, ZipArchive::CREATE) !== true) {
		zip_fail('could not create ' . $path);
	}
	foreach ($entries as $entry) {
		if (isset($entry['link'])) {
			$zip->addFromString($entry['name'], $entry['link']);
			$zip->setExternalAttributesName($entry['name'], ZipArchive::OPSYS_UNIX, 0120777 << 16);
			continue;
		}
		$zip->addFromString($entry['name'], $entry['data']);
		if (!empty($entry['deflate'])) {
			$zip->setCompressionName($entry['name'], ZipArchive::CM_DEFLATE, 9);
		}
	}
	$zip->close();
}

function assert_closed($modules, $archive, $label, $outside, $modulesDir) {
	if ($modules->unzip_module($archive) !== false) {
		zip_fail($label . ' was accepted');
	}
	if (file_get_contents($outside) !== 'KEEP') {
		zip_fail($label . ' changed the outside file');
	}
	if (file_exists($modulesDir . '/escaped.txt') || file_exists(dirname($modulesDir) . '/escaped.txt')) {
		zip_fail($label . ' wrote escaped.txt');
	}
	$temp = $modulesDir . '/tempModuleDir';
	if (is_link($temp)) {
		zip_fail($label . ' replaced the upload directory with a symlink');
	}
}

$slip = $work . '/slip.zip';
write_zip($slip, array(array('name' => '../escaped.txt', 'data' => 'nope')));
assert_closed($modules, $slip, 'a parent-directory entry', $outside, $modulesDir);

$absolute = $work . '/absolute.zip';
write_zip($absolute, array(array('name' => '/tmp/orp-zip-escaped.txt', 'data' => 'nope')));
assert_closed($modules, $absolute, 'an absolute entry', $outside, $modulesDir);
if (file_exists('/tmp/orp-zip-escaped.txt')) {
	zip_fail('an absolute entry wrote /tmp/orp-zip-escaped.txt');
}

$nested = $work . '/nested.zip';
write_zip($nested, array(array('name' => 'safe/../../escaped.txt', 'data' => 'nope')));
assert_closed($modules, $nested, 'a nested parent entry', $outside, $modulesDir);

$slash = $work . '/slash.zip';
write_zip($slash, array(array('name' => 'svxlink\\events.d\\bad.tcl', 'data' => 'nope')));
assert_closed($modules, $slash, 'a backslash entry', $outside, $modulesDir);

$link = $work . '/link.zip';
write_zip($link, array(array('name' => 'svxlink/events.d/link.tcl', 'link' => $outside)));
assert_closed($modules, $link, 'a symlink entry', $outside, $modulesDir);
$temp = $modulesDir . '/tempModuleDir';
if (is_dir($temp)) {
	$found = scandir($temp);
	foreach ($found as $name) {
		if ($name === '.' || $name === '..') {
			continue;
		}
		if (is_link($temp . '/' . $name)) {
			zip_fail('a symlink entry was extracted');
		}
	}
}

$deep = $work . '/deep.zip';
write_zip($deep, array(array('name' => 'a/b/c/d/e/f/g/h/i.txt', 'data' => 'deep')));
assert_closed($modules, $deep, 'a too-deep entry', $outside, $modulesDir);

$bomb = $work . '/bomb.zip';
write_zip($bomb, array(array('name' => 'bomb.txt', 'data' => str_repeat('A', 3 * 1024 * 1024), 'deflate' => true)));
assert_closed($modules, $bomb, 'a highly compressed entry', $outside, $modulesDir);
if (file_exists($modulesDir . '/tempModuleDir/bomb.txt')) {
	zip_fail('a zip bomb was extracted');
}

$good = $work . '/good.zip';
write_zip($good, array(
	array('name' => 'Probe/info.ini', 'data' => "[Module_Info]\nmod_name = Probe\n"),
	array('name' => 'Probe/svxlink/events.d/ModuleProbe.tcl', 'data' => "proc probe {} {}\n"),
));
if ($modules->unzip_module($good) !== true) {
	zip_fail('a single-folder module was refused');
}
$info = $modulesDir . '/tempModuleDir/info.ini';
$tcl = $modulesDir . '/tempModuleDir/svxlink/events.d/ModuleProbe.tcl';
if (!is_file($info) || is_link($info) || !is_file($tcl) || is_link($tcl)) {
	zip_fail('the module files were not extracted inside the upload directory');
}
$infoReal = realpath($info);
$rootReal = realpath($modulesDir . '/tempModuleDir');
if ($infoReal === false || $rootReal === false || strpos($infoReal, $rootReal . '/') !== 0) {
	zip_fail('the extracted file is outside the upload directory');
}
if (is_dir($modulesDir . '/tempModuleDir/Probe')) {
	zip_fail('the single wrapper folder was left in place');
}
if (file_get_contents($outside) !== 'KEEP') {
	zip_fail('a valid module changed the outside file');
}
$upper = $modules->upload_module(array(
	'name' => array('Probe.ZIP'),
	'tmp_name' => array($work . '/missing.zip'),
	'size' => array(32),
	'error' => array(0),
));
$upperText = is_array($upper) && isset($upper['msgText']) ? $upper['msgText'] : '';
if (strpos($upperText, 'supported format') !== false) {
	zip_fail('a .ZIP upload was rejected by extension');
}

$lying = $work . '/lying.zip';
$zip = new ZipArchive();
if ($zip->open($lying, ZipArchive::CREATE) !== true) {
	zip_fail('could not create the lying archive');
}
$zip->addFromString('bomb.txt', str_repeat('A', Modules::ZIP_MAX_ENTRY + 65536));
$zip->setCompressionName('bomb.txt', ZipArchive::CM_DEFLATE, 9);
$zip->close();
$raw = file_get_contents($lying);
$local = strpos($raw, "PK\x03\x04");
$central = strpos($raw, "PK\x01\x02");
if ($local === false || $central === false) {
	zip_fail('the lying archive has no zip headers');
}
$raw = substr_replace($raw, pack('V', 32), $local + 22, 4);
$raw = substr_replace($raw, pack('V', 32), $central + 24, 4);
file_put_contents($lying, $raw);
$check = new ZipArchive();
if ($check->open($lying) !== true) {
	zip_fail('the lying archive did not open');
}
$declared = $check->statIndex(0);
$check->close();
if (!is_array($declared) || (int) $declared['size'] !== 32) {
	zip_fail('the lying archive did not publish a 32-byte size');
}
if ($modules->unzip_module($lying) !== false) {
	zip_fail('a lying uncompressed size was accepted');
}
if (file_exists($modulesDir . '/tempModuleDir/bomb.txt') || file_get_contents($outside) !== 'KEEP') {
	zip_fail('a lying uncompressed size wrote past the cap');
}

$small = $work . '/lying-small.zip';
$zip = new ZipArchive();
if ($zip->open($small, ZipArchive::CREATE) !== true) {
	zip_fail('could not create the short lying archive');
}
$zip->addFromString('note.txt', 'abcdefghijklmnopqrstuvwxyz0123456789');
$zip->close();
$raw = file_get_contents($small);
$local = strpos($raw, "PK\x03\x04");
$central = strpos($raw, "PK\x01\x02");
if ($local === false || $central === false) {
	zip_fail('the short lying archive has no zip headers');
}
$raw = substr_replace($raw, pack('V', 8), $local + 22, 4);
$raw = substr_replace($raw, pack('V', 8), $central + 24, 4);
file_put_contents($small, $raw);
$check = new ZipArchive();
if ($check->open($small) !== true) {
	zip_fail('the short lying archive did not open');
}
$declared = $check->statIndex(0);
$check->close();
if (!is_array($declared) || (int) $declared['size'] !== 8 || (int) $declared['size'] >= 36) {
	zip_fail('the short lying archive did not publish an 8-byte size');
}
if ($modules->unzip_module($small) !== false || file_exists($modulesDir . '/tempModuleDir/note.txt')) {
	zip_fail('a declared size smaller than the streamed bytes was accepted');
}

$db = $work . '/modules.db';
if (!copy($root . '/install/sql/openrepeater.db', $db) || !chmod($db, 0600)) {
	zip_fail('could not copy the module database');
}
putenv('ORP_DB_PATH=' . $db);
$marker = $work . '/bench-marker';
file_put_contents($marker, "bench\n");
putenv('ORP_BENCH_MARKER=' . $marker);
$preview = rtrim($fixture, '/') . '/orp-preview-mod-' . getmypid();
mkdir($preview, 0755);
putenv('ORP_BENCH_PREVIEW=' . $preview);
$modSounds = $modulesDir . '/SoundMod/svxlink/sounds/en_US';
mkdir($modSounds, 0755, true);
file_put_contents($modSounds . '/clip.wav', 'clip');
$soundsReal = $preview . '/sounds/en_US/SoundMod';
mkdir($soundsReal, 0755, true);
file_put_contents($soundsReal . '/keep', 'KEEP');
$linked = new Modules();
if ($linked->initialize_module('SoundMod', 0) !== true) {
	zip_fail('inactive install failed');
}
if (is_link($soundsReal) || file_get_contents($soundsReal . '/keep') !== 'KEEP') {
	zip_fail('inactive install changed the sounds directory');
}
if ($linked->initialize_module('SoundMod', 1) !== false || file_get_contents($soundsReal . '/keep') !== 'KEEP') {
	zip_fail('activation replaced a real sounds directory');
}
if (BenchGuard::removeTreeConfined($soundsReal, dirname($soundsReal)) !== true) {
	zip_fail('could not remove the sounds fixture');
}
if ($linked->initialize_module('SoundMod', 1) !== true || !is_link($preview . '/sounds/en_US/SoundMod')) {
	zip_fail('activation did not link sounds');
}
echo "ok: hostile module archives stay inside the upload directory\n";
exit(0);
