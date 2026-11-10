<?php
$root = dirname(__DIR__, 2);
require $root . '/includes/classes/RequestGuard.php';

function fail($msg) {
	fwrite(STDERR, "FAIL: $msg\n");
	exit(1);
}

$cases = array(
	array('../dashboard.php', '../dashboard.php'),
	array('../courtesy_tone.php?preview_failed=1', '../courtesy_tone.php'),
	array('dashboard.php', '../dashboard.php'),
	array('not-a-page.php', '../dashboard.php'),
	array('https://evil.example/phish', '../dashboard.php'),
	array('//evil.example/phish', '../dashboard.php'),
	array('\\\\evil.example\\share', '../dashboard.php'),
	array("../dashboard.php\r\nLocation: https://evil.example", '../dashboard.php'),
	array('javascript:alert(1)', '../dashboard.php'),
	array('/etc/passwd', '../dashboard.php'),
	array('../foo/../../etc/passwd', '../dashboard.php'),
	array('', '../dashboard.php'),
	array(null, '../dashboard.php'),
);
foreach ($cases as $case) {
	$got = RequestGuard::safeReturnUrl($case[0]);
	if ($got !== $case[1]) {
		fail('return ' . var_export($case[0], true) . ' became ' . $got);
	}
}
echo "ok: return_url accepts only a same-site relative PHP path\n";
