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
	'ID_Short_Mode' => 'morse',
	'ID_Long_Mode' => 'disabled',
	'ID_Short_IntervalMin' => '10',
	'ID_Long_IntervalMin' => '60',
	'ID_Morse_WPM' => '20',
	'ID_Short_IdentOnlyAfterTX' => 'False',
	'ID_Short_AppendMorse' => 'False',
	'ID_Long_AppendMorse' => 'False',
	'repeaterDTMF_disable' => 'False',
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
$config = array('GLOBAL' => array());
$config += $svx->build_rx(1);
$config += $svx->build_tx(1);
$config += $svx->build_logic_repeater('ORP_RepeaterLogic_Port1', 1);
$config['GLOBAL'] += $svx->build_global();
if (($config['TX_Port1']['PTT_TYPE'] ?? '') !== 'GPIO' || ($config['TX_Port1']['PTT_PIN'] ?? '') !== 'gpio18') {
	fail('stored transmitter pin was not kept');
}
if (($config['RX_Port1']['SQL_DET'] ?? '') !== 'GPIO' || ($config['RX_Port1']['GPIO_SQL_PIN'] ?? '') !== 'gpio17') {
	fail('stored squelch pin was not kept');
}
$gpioBuilder = new SVXLink_GPIO(array(
	array('gpio_num' => '18', 'direction' => 'out', 'active' => 'high'),
));
$gpioTextIn = $gpioBuilder->build_gpio_config();
$conf = $fixture . '/etc/svxlink/svxlink.conf';
$gpio = $fixture . '/etc/svxlink/gpio.conf';
if ($svx->write_config($config, 'svxlink.conf', 'ini') !== true) {
	fail('svxlink.conf was not written');
}
if ($svx->write_config($gpioTextIn, 'gpio.conf', 'text') !== true) {
	fail('gpio.conf was not written');
}
$confText = file_get_contents($conf);
$gpioText = file_get_contents($gpio);
if ($confText === false || $gpioText === false || $confText === $gpioText) {
	fail('svxlink.conf and gpio.conf were not separate files');
}
foreach (array(
	'[GLOBAL]',
	'LOGICS=ORP_RepeaterLogic_Port1',
	'[ORP_RepeaterLogic_Port1]',
	'TYPE=Repeater',
	'RX=RX_Port1',
	'TX=TX_Port1',
	'[RX_Port1]',
	'[TX_Port1]',
	'PTT_TYPE=GPIO',
	'PTT_PIN=gpio18',
) as $needle) {
	if (strpos($confText, $needle) === false) {
		fail('svxlink.conf is missing ' . $needle);
	}
}
foreach (array('GPIO_OUT_HIGH', 'GPIO_OUT_LOW', 'GPIO_IN_HIGH', 'GPIO_IN_LOW', 'GPIO_PATH') as $gpioKey) {
	if (strpos($confText, $gpioKey) !== false) {
		fail('gpio.conf content was written into svxlink.conf');
	}
}
if (strpos($gpioText, 'GPIO_OUT_HIGH="gpio18"') === false) {
	fail('gpio.conf did not keep the stored output');
}
echo "ok: publish writes stored PTT and GPIO to separate files\n";
echo "ok: svxlink.conf has GLOBAL, LOGICS, and the repeater logic section\n";
