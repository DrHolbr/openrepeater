<?php
/**
 * Cloud-side checks for bench safety, GPIO naming, and PHP 8 database reads.
 * No GPIO line is requested and no radio service is started.
 */

$failures = 0;

function check($cond, $msg) {
	global $failures;
	if ($cond) {
		echo "ok: $msg\n";
		return;
	}
	fwrite(STDERR, "FAIL: $msg\n");
	$failures++;
}

$root = dirname(__DIR__, 2);
require_once $root . '/includes/classes/BenchGuard.php';
require_once $root . '/includes/classes/GpioMap.php';
require_once $root . '/includes/classes/SVXLink.php';
require_once $root . '/includes/classes/SVXLink_GPIO.php';
require_once $root . '/includes/classes/Database.php';
require_once $root . '/includes/classes/Modules.php';

$missing = tempnam(sys_get_temp_dir(), 'orp-missing-');
unlink($missing);
putenv('ORP_BENCH_MARKER=' . $missing);
$off = BenchGuard::detect();
check($off->isBench() === false, 'absent marker is not bench mode');
check($off->commandAllowed('svxlink', 'start') === true, 'without the marker, svxlink start stays allowed');
check($off->commandAllowed('svxlink', 'status') === true, 'svxlink status stays allowed');
check($off->commandAllowed('svxlink', 'unmask') === false, 'unmask is refused even without the marker');
check($off->commandAllowed('system', 'restart') === true, 'without the marker, reboot stays allowed');

$svx = new SVXLink(array(), array(), array());
check($svx->configDestination('svxlink.conf') === '/etc/svxlink/svxlink.conf', 'unmarked svxlink.conf path stays /etc/svxlink');
check($svx->configDestination('Logic.tcl') === '/usr/share/svxlink/events.d/local/Logic.tcl', 'unmarked Logic.tcl path stays in the legacy local events tree');
check($svx->configDestination('ORP_RepeaterLogic_Port1.tcl') === '/usr/share/svxlink/events.d/ORP_RepeaterLogic_Port1.tcl', 'unmarked ORP event path stays in the legacy events tree');

$preview = sys_get_temp_dir() . '/orp-preview-' . getmypid();
$marker = sys_get_temp_dir() . '/orp-bench-' . getmypid();
file_put_contents($marker, "host=orp-test\nradio=blocked\npreview={$preview}\n");
putenv('ORP_BENCH_MARKER=' . $marker);
$on = BenchGuard::detect();
check($on->isBench() === true, 'marker file enables bench mode');
check($on->previewDir() === $preview, 'preview directory is read from the marker');
check($on->mixerUpdatesAllowed() === false, 'bench mode does not allow mixer updates');
foreach (array(
	array('svxlink', 'start'),
	array('svxlink', 'restart'),
	array('svxlink', 'enable'),
	array('svxlink', 'gpio_up'),
	array('svxlink', 'gpio_down'),
	array('remotetrx', 'start'),
	array('svxreflector', 'restart'),
	array('system', 'restart'),
	array('system', 'stop'),
	array('set_mixer', 'anything'),
	array('alsa', 'restore'),
) as $pair) {
	check($on->commandAllowed($pair[0], $pair[1]) === false, "bench blocks {$pair[0]} {$pair[1]}");
}
check($on->commandAllowed('svxlink', 'status') === true, 'bench still allows svxlink status');
check($on->commandAllowed('info', 'os') === true, 'bench still allows info reads');
check($on->commandAllowed('audio', 'inputs') === true, 'bench still allows audio listing');

check($svx->configDestination('svxlink.conf') === $preview . '/svxlink.conf', 'bench svxlink.conf goes to the preview directory');
check($svx->configDestination('gpio.conf') === $preview . '/gpio.conf', 'bench gpio.conf goes to the preview directory');
check($svx->configDestination('ORP_RepeaterLogic_Port1.tcl') === $preview . '/ORP_RepeaterLogic_Port1.tcl', 'bench ORP tcl goes to the preview directory');
check(strpos($svx->configDestination('svxlink.conf'), '/usr/local/share/svxlink') === false, 'bench publish path is not the bootstrap share tree');
check(strpos($svx->configDestination('svxlink.conf'), '/etc/svxlink/') === false, 'bench publish path is not /etc/svxlink');

$ports = array(
	1 => array(
		'rxAudioDev' => 'alsa:plughw:0|1',
		'txAudioDev' => 'alsa:plughw:0|1',
		'rxMode' => 'gpio',
		'rxGPIO' => '26',
		'txGPIO' => '498',
	),
);
$svx = new SVXLink(
	array('txTailValueSec' => 2, 'txTone' => '', 'rxTone' => ''),
	$ports,
	array()
);
$cfg = $svx->build_rx(1) + $svx->build_tx(1);
$svx->write_config($cfg, 'svxlink.conf', 'ini');
$written = file_get_contents($preview . '/svxlink.conf');
check(is_string($written) && $written !== '', 'bench preview svxlink.conf was written');
check(strpos($written, "\nPTT_PIN=") === false && strpos($written, "\nPTT_TYPE=") === false, 'bench preview has no active PTT lines');
check(strpos($written, 'BENCH DISARMED') !== false, 'bench preview marks disarmed transmitter lines');
check(strpos($written, "\nSQL_DET=GPIO") === false, 'bench preview does not leave SQL_DET=GPIO active');
check(!file_exists('/etc/svxlink/svxlink.conf'), 'bench write did not create /etc/svxlink/svxlink.conf');
check(!file_exists('/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port1.tcl'), 'bench write did not create a bootstrap ORP event file');

file_put_contents($preview . '/ORP_keep.tcl', "keep\n");
$svx->delete_custom_evnets();
check(!file_exists($preview . '/ORP_keep.tcl'), 'bench event cleanup stays inside the preview directory');

$gpio = new SVXLink_GPIO(array(
	array('gpio_num' => '26', 'direction' => 'in', 'active' => 'low'),
	array('gpio_num' => '498', 'direction' => 'out', 'active' => 'high'),
));
$safe = $gpio->build_gpio_config();
check(strpos($safe, '/sys/class/gpio') === false, 'bench gpio.conf has no sysfs GPIO_PATH');
check(strpos($safe, 'gpio498') === false, 'bench gpio.conf does not emit gpio498');
check(strpos($safe, 'GPIO_OUT_HIGH=""') !== false, 'bench gpio outputs are empty');
check(strpos($safe, 'GPIO_OUT_LOW=""') !== false, 'bench gpio active-low outputs are empty');

putenv('ORP_BENCH_MARKER=' . $missing);
$legacy = (new SVXLink_GPIO(array(
	array('gpio_num' => '498', 'direction' => 'out', 'active' => 'high'),
)))->build_gpio_config();
check(strpos($legacy, 'GPIO_PATH=/sys/class/gpio') !== false, 'without the marker the legacy sysfs gpio.conf text remains');
check(strpos($legacy, 'gpio498') !== false, 'without the marker the legacy writer still names gpio498');

$defs = GpioMap::loadDefinitions($root . '/includes/board_definitions.php');
$rows = GpioMap::report($defs);
check(count($rows) > 0, 'GPIO report has rows');
$sawHigh = false;
$sawLow = false;
$sawCos = false;
foreach ($rows as $row) {
	check($row['drivable'] === false, $row['source'] . ' ' . $row['logical_name'] . ' ' . $row['stored_number'] . ' is not drivable');
	check($row['libgpiod_chip'] === null && $row['libgpiod_offset'] === null, $row['logical_name'] . ' ' . $row['stored_number'] . ' has no libgpiod assignment');
	if ($row['source'] === 'orp_preset' && $row['version'] === '3.1+' && $row['port'] === 1 && $row['logical_name'] === 'txGPIO') {
		$sawHigh = true;
		check($row['stored_number'] === '498', '2X 3.1+ TX stored number is 498');
		check($row['preset_active'] === 'high', '2X 3.1+ TX preset active level is high');
		check($row['class'] === 'unresolved_sysfs_number', '498 is not a BCM header pin');
		check($row['physical_pin'] === null && $row['bcm'] === null, '498 has no BCM offset or physical pin');
	}
	if ($row['source'] === 'orp_preset' && $row['version'] === '2.1 - PROTOTYPE' && $row['port'] === 1 && $row['logical_name'] === 'txGPIO') {
		$sawLow = true;
		check($row['preset_active'] === 'low', '2X prototype TX preset active level is low');
		check($row['stored_number'] === '498', 'prototype TX stored number is still 498');
	}
	if ($row['source'] === 'orp_preset' && $row['version'] === '3.1+' && $row['port'] === 1 && $row['logical_name'] === 'rxGPIO') {
		$sawCos = true;
		check($row['stored_number'] === '26' && $row['bcm'] === 26 && $row['physical_pin'] === 37, 'RX 26 is BCM 26 physical pin 37');
		check($row['preset_active'] === 'low', '2X 3.1+ RX preset active level is low');
		check($row['class'] === 'bcm_header_candidate', '26 is only a header candidate');
	}
	if ($row['source'] === 'orp_preset' && $row['version'] === '3.1+' && $row['port'] === 2 && $row['logical_name'] === 'rxGPIO') {
		check($row['bcm'] === 23 && $row['physical_pin'] === 16, 'RX 23 is BCM 23 physical pin 16');
	}
}
check($sawHigh && $sawLow && $sawCos, 'both TX polarities and the port 1 COS row are present');

$manual498 = null;
$manual506 = null;
foreach ($rows as $row) {
	if ($row['source'] !== 'ics_manual_baseline') {
		continue;
	}
	if ($row['logical_name'] === 'GPA2') {
		$manual498 = $row;
	}
	if ($row['logical_name'] === 'PTT' && $row['port'] === 1) {
		$manual506 = $row;
	}
}
check($manual498 && $manual498['stored_number'] === '498' && $manual498['class'] === 'unresolved_sysfs_number', 'ICS baseline lists 498 as GPA2 and unresolved');
check($manual506 && $manual506['stored_number'] === '506' && $manual506['physical_pin'] === null, 'ICS baseline lists port 1 PTT as 506, not a header pin');

foreach (array(13 => 33, 24 => 18, 25 => 22, 27 => 13, 12 => 32) as $bcm => $phys) {
	$class = GpioMap::classifyNumber((string) $bcm);
	check($class['bcm'] === $bcm && $class['physical_pin'] === $phys, "BCM {$bcm} maps to physical pin {$phys}");
}
check(GpioMap::classifyNumber('499')['class'] === 'unresolved_sysfs_number', '499 is an unresolved sysfs number');
check(GpioMap::classifyNumber('507')['physical_pin'] === null, '507 is not a physical header pin');
check(GpioMap::allowsRequestMethod('GET') === true, 'GET diagnostics are allowed');
check(GpioMap::allowsRequestMethod('POST') === false, 'POST diagnostics are refused');

$info = sys_get_temp_dir() . '/gpioinfo';
file_put_contents($info, "#!/bin/sh\nprintf 'args:[%s]\\n' \"\$1\"\n");
chmod($info, 0755);
$chip = GpioMap::readOnlyChipInfo($info);
check($chip === "args:[]\n", 'gpioinfo is executed with no arguments');
$set = sys_get_temp_dir() . '/gpioset';
$stamp = sys_get_temp_dir() . '/gpioset-stamp';
@unlink($stamp);
file_put_contents($set, "#!/bin/sh\ntouch " . escapeshellarg($stamp) . "\n");
chmod($set, 0755);
$refused = GpioMap::readOnlyChipInfo($set);
check(strpos($refused, 'refused:') === 0, 'a binary that is not gpioinfo is refused');
check(!file_exists($stamp), 'the refused binary was not executed');

$dbCopy = sys_get_temp_dir() . '/openrepeater-' . getmypid() . '.db';
copy($root . '/install/sql/openrepeater.db', $dbCopy);
putenv('ORP_DB_PATH=' . $dbCopy);
putenv('ORP_FLAG_STORE=sqlite');
$db = new Database();
$settings = $db->get_settings();
check(is_array($settings) && isset($settings['orp_Mode']) && $settings['orp_Mode'] === 'simplex', 'get_settings reads the stock database');
check($db->get_settings('orp_Mode') === 'simplex', 'single-key get_settings no longer passes extra arguments');
check($db->get_version() !== '', 'version_info is readable');
$modules = $db->get_modules();
check(is_array($modules), 'empty module select returns an array');
foreach ($modules as $ignored) {
	break;
}
$db->set_update_flag(true);
check($db->get_update_flag() === true, 'sqlite update flag can be set without Memcached');
$db->set_update_flag(false);
check($db->get_update_flag() === false, 'sqlite update flag can be cleared');
$dbPorts = GpioMap::fromStoredPorts($db->get_ports());
$sawDbTx = false;
foreach ($dbPorts as $row) {
	check($row['drivable'] === false && $row['libgpiod_offset'] === null, 'database port row is not programmed');
	if ($row['logical_name'] === 'txGPIO') {
		$sawDbTx = true;
		check($row['stored_number'] === '506', 'stock database TX number is 506');
		check($row['preset_active'] === 'high', 'stock database TX active level is high');
		check($row['class'] === 'unresolved_sysfs_number', 'stock database TX 506 is unresolved');
	}
	if ($row['logical_name'] === 'rxGPIO') {
		check($row['stored_number'] === '26' && $row['physical_pin'] === 37, 'stock database RX 26 is physical pin 37');
	}
}
check($sawDbTx, 'stock database has a TX row');

$_SERVER['DOCUMENT_ROOT'] = $root;
putenv('ORP_BENCH_MARKER=' . $marker);
$modulesObj = new Modules();
check(strpos($modulesObj->svxlinkEventsPath(), $preview . '/events.d/') === 0, 'bench module links stay in the preview tree');
check(is_dir($preview . '/events.d'), 'bench preview events directory was created');
putenv('ORP_BENCH_MARKER=' . $missing);
$modulesOff = new Modules();
check($modulesOff->svxlinkEventsPath() === '/usr/share/svxlink/events.d/', 'without the marker, module link path is unchanged');

$autoload = file_get_contents($root . '/includes/autoloadClasses.php');
check(strpos($autoload, 'function __autoload') === false, 'PHP 8 autoload no longer defines __autoload');
check(strpos($autoload, 'spl_autoload_register') !== false, 'autoload uses spl_autoload_register');

if ($failures > 0) {
	fwrite(STDERR, "$failures failure(s)\n");
	exit(1);
}
echo "php safety checks passed\n";
exit(0);
