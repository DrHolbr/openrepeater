<?php
if ($argc < 4) {
	fwrite(STDERR, "usage: preset_roundtrip_check.php root db id\n");
	exit(1);
}
$root = $argv[1];
$dbPath = $argv[2];
$id = (int) $argv[3];
require_once $root . '/includes/classes/GpioMap.php';
$defs = GpioMap::loadDefinitions($root . '/includes/board_definitions.php');
if (!isset($defs[$id])) {
	fwrite(STDERR, "FAIL: preset {$id} is missing\n");
	exit(1);
}
$board = $defs[$id];
$db = new SQLite3($dbPath, SQLITE3_OPEN_READONLY);
$stored = array();
$result = $db->query('SELECT portNum, portLabel, rxMode, rxGPIO, txGPIO, rxGPIO_active, txGPIO_active, rxAudioDev, txAudioDev FROM ports ORDER BY portNum');
while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
	$stored[(int) $row['portNum']] = $row;
}
if (count($stored) !== count($board['ports'])) {
	fwrite(STDERR, "FAIL: preset {$id} stored " . count($stored) . " ports, definition has " . count($board['ports']) . "\n");
	exit(1);
}
$expectGpio = array();
foreach ($board['ports'] as $portNum => $port) {
	if (!isset($stored[$portNum])) {
		fwrite(STDERR, "FAIL: preset {$id} did not store port {$portNum}\n");
		exit(1);
	}
	$row = $stored[$portNum];
	foreach (array('portLabel', 'rxMode', 'rxGPIO', 'txGPIO', 'rxGPIO_active', 'txGPIO_active', 'rxAudioDev', 'txAudioDev') as $field) {
		if ((string) $row[$field] !== (string) $port[$field]) {
			fwrite(STDERR, "FAIL: preset {$id} port {$portNum} {$field} is {$row[$field]}\n");
			exit(1);
		}
	}
	$expectGpio[(string) $port['rxGPIO']] = array('in', $port['rxGPIO_active'], 'Port');
	$expectGpio[(string) $port['txGPIO']] = array('out', $port['txGPIO_active'], 'Port');
	foreach (array('rxGPIO' => 'in', 'txGPIO' => 'out') as $field => $direction) {
		$class = GpioMap::classifyNumber($port[$field]);
		if ((int) $port[$field] > 27 && $class['bcm'] !== null) {
			fwrite(STDERR, "FAIL: preset {$id} {$field} {$port[$field]} was treated as BCM\n");
			exit(1);
		}
		$mapped = array(
			'stored_number' => (string) $port[$field],
			'class' => $class['class'],
			'line_offset_candidate' => $class['line_offset_candidate'],
			'direction' => $direction,
			'preset_active' => $port[$field . '_active'],
		);
		$line = GpioMap::typedConfigLine($mapped);
		if (strpos($line, 'PTT_PIN') !== false || strpos($line, 'gpio' . $port[$field]) !== false) {
			fwrite(STDERR, "FAIL: preset {$id} emitted a sysfs pin for {$port[$field]}\n");
			exit(1);
		}
		if ($class['activation'] !== 'not-applied') {
			fwrite(STDERR, "FAIL: preset {$id} guessed an activation\n");
			exit(1);
		}
		$bcm = $class['bcm'] === null ? 'bcm=null' : 'bcm=' . $class['bcm'];
		$offset = $class['line_offset_candidate'] === null ? 'offset=null' : 'offset=' . $class['line_offset_candidate'];
		$pin = $class['expander_pin'] === null ? 'pin=' : 'pin=' . $class['expander_pin'];
		echo "preset {$id} port {$portNum} {$field}={$port[$field]} {$direction} active={$port[$field . '_active']} class={$class['class']} {$bcm} {$offset} {$pin} audio={$port[$field === 'rxGPIO' ? 'rxAudioDev' : 'txAudioDev']}\n";
	}
}
if (!empty($board['modules'])) {
	foreach ($board['modules'] as $name => $module) {
		if (empty($module['relay']) || !is_array($module['relay'])) {
			continue;
		}
		foreach ($module['relay'] as $relay) {
			$expectGpio[(string) $relay['gpio']] = array('out', $module['relays_gpio_active_state'], 'RemoteRelay');
			echo "preset {$id} relay gpio={$relay['gpio']} out active={$module['relays_gpio_active_state']} label={$relay['label']} module-row=not-stored\n";
		}
	}
}
$gpios = array();
$result = $db->query('SELECT gpio_num, direction, active, type FROM gpio_pins ORDER BY gpio_num');
while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
	$gpios[(string) $row['gpio_num']] = array($row['direction'], $row['active'], $row['type']);
}
if ($gpios != $expectGpio) {
	fwrite(STDERR, "FAIL: preset {$id} gpio rows are not the preset ports and relays\n");
	exit(1);
}
$enabled = $db->querySingle("SELECT COUNT(*) FROM modules WHERE moduleEnabled != '0'");
if ((int) $enabled !== 0) {
	fwrite(STDERR, "FAIL: preset {$id} enabled a module row\n");
	exit(1);
}
echo "ok: preset {$id} {$board['manufacturer']} {$board['model']} {$board['version']} stored the port and gpio rows and left every module disabled\n";
