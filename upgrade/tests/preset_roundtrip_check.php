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
$result = $db->query('SELECT portNum, rxGPIO, txGPIO, rxGPIO_active, txGPIO_active FROM ports ORDER BY portNum');
while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
	$stored[(int) $row['portNum']] = $row;
}
foreach ($board['ports'] as $portNum => $port) {
	if (!isset($stored[$portNum])) {
		fwrite(STDERR, "FAIL: preset {$id} did not store port {$portNum}\n");
		exit(1);
	}
	$row = $stored[$portNum];
	if ((string) $row['rxGPIO'] !== (string) $port['rxGPIO'] || (string) $row['txGPIO'] !== (string) $port['txGPIO']) {
		fwrite(STDERR, "FAIL: preset {$id} port {$portNum} numbers changed\n");
		exit(1);
	}
	if ($row['rxGPIO_active'] !== $port['rxGPIO_active'] || $row['txGPIO_active'] !== $port['txGPIO_active']) {
		fwrite(STDERR, "FAIL: preset {$id} port {$portNum} polarity changed\n");
		exit(1);
	}
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
	}
}
echo "ok: preset {$id} {$board['model']} {$board['version']} kept direction, polarity, and non-BCM numbers\n";
