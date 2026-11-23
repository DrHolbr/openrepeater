<?php
// A rebuild writes the stored GPIO and PTT into separate live files.
$root = $argv[1];
$tmp = getenv('ORP_TEST_TMPDIR');
if (!is_string($tmp) || $tmp === '') {
	fwrite(STDERR, "FAIL: ORP_TEST_TMPDIR is unset\n");
	exit(1);
}
$fixture = rtrim($tmp, '/') . '/orp-publish-' . getmypid();
putenv('ORP_BENCH_TEST_HARNESS=1');
putenv('ORP_ROOT=' . $fixture);
$_SERVER['DOCUMENT_ROOT'] = $root;
require $root . '/includes/classes/PathGuard.php';
require $root . '/includes/classes/SVXLink.php';
require $root . '/includes/classes/SVXLink_GPIO.php';

function fail($msg) {
	fwrite(STDERR, "FAIL: {$msg}\n");
	exit(1);
}

$settings = array(
	'callSign' => 'W1AW',
	'txTailValueSec' => '1',
	'txTone' => '',
	'txCtcssLevel' => '',
	'rxTone' => '',
);
$ports = array(
	1 => array(
		'rxAudioDev' => 'alsa:plughw:0|0',
		'txAudioDev' => 'alsa:plughw:0|0',
		'rxMode' => 'cos',
		'rxGPIO' => '17',
		'txGPIO' => '18',
	),
);
$svx = new SVXLink($settings, $ports, array());
$tx = $svx->build_tx(1);
if (($tx['TX_Port1']['PTT_TYPE'] ?? '') !== 'GPIO' || ($tx['TX_Port1']['PTT_PIN'] ?? '') !== 'gpio18') {
	fail('stored transmitter pin was not kept');
}
$rx = $svx->build_rx(1);
if (($rx['RX_Port1']['SQL_DET'] ?? '') !== 'GPIO' || ($rx['RX_Port1']['GPIO_SQL_PIN'] ?? '') !== 'gpio17') {
	fail('stored squelch pin was not kept');
}
$conf = $fixture . '/etc/svxlink/svxlink.conf';
$gpio = $fixture . '/etc/svxlink/gpio.conf';
if ($svx->write_config(array('GLOBAL' => array('LOGICS' => 'RepeaterLogic'), 'TX_Port1' => $tx['TX_Port1']), 'svxlink.conf', 'ini') !== true) {
	fail('svxlink.conf was not written');
}
if ($svx->write_config("GPIO_OUT_HIGH=gpio18\n", 'gpio.conf', 'text') !== true) {
	fail('gpio.conf was not written');
}
$confText = file_get_contents($conf);
$gpioText = file_get_contents($gpio);
if ($confText === false || $gpioText === false || $confText === $gpioText) {
	fail('svxlink.conf and gpio.conf were not separate files');
}
if (strpos($confText, 'PTT_TYPE=GPIO') === false || strpos($confText, 'PTT_PIN=gpio18') === false) {
	fail('published svxlink.conf dropped the stored PTT');
}
if (strpos($confText, 'GPIO_OUT_HIGH') !== false) {
	fail('gpio.conf content replaced svxlink.conf');
}
if (strpos($gpioText, 'GPIO_OUT_HIGH=gpio18') === false) {
	fail('gpio.conf did not keep the stored output');
}
echo "ok: publish writes stored PTT and GPIO to separate files\n";
