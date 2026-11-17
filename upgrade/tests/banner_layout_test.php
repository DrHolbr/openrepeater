<?php
// The functional-test notice must stay in normal flow. A fixed height or a
// fixed/absolute bar lets the logo header cover wrapped lines and the button.
$root = dirname(__DIR__, 2);
$css = file_get_contents($root . '/theme/css/openrepeater.css');
$header = file_get_contents($root . '/includes/header.php');
if ($css === false || $header === false) {
	fwrite(STDERR, "FAIL: banner sources were not read\n");
	exit(1);
}

function banner_fail($message) {
	fwrite(STDERR, "FAIL: {$message}\n");
	exit(1);
}

$css = preg_replace('/\/\*.*?\*\//s', '', $css);
if (!preg_match_all('/([^{]+)\{([^}]*)\}/', $css, $blocks, PREG_SET_ORDER)) {
	banner_fail('openrepeater.css has no rules');
}

$sawStatic = false;
foreach ($blocks as $block) {
	$selector = trim($block[1]);
	$body = $block[2];
	$aboutBar = preg_match('/\.server_bar(?:_wrap)?\b/', $selector) === 1;
	if (!$aboutBar) {
		continue;
	}
	if (preg_match('/position\s*:\s*(fixed|absolute)\b/i', $body)) {
		banner_fail("{$selector} is fixed or absolute");
	}
	$isBar = preg_match('/(^|,)\s*\.server_bar\s*(,|$)/', $selector) === 1
		&& strpos($selector, '.server_bar_') === false;
	if ($isBar) {
		if (preg_match('/overflow\s*:\s*hidden\b/i', $body)) {
			banner_fail('.server_bar hides overflow');
		}
		if (preg_match('/height\s*:\s*[0-9]+px/i', $body)) {
			banner_fail('.server_bar has a fixed height');
		}
		if (preg_match('/position\s*:\s*static\b/i', $body) && preg_match('/height\s*:\s*auto\b/i', $body)) {
			$sawStatic = true;
		}
	}
	if (preg_match('/\.server_bar\s+span\b/', $selector) && preg_match('/display\s*:\s*none\b/i', $body)) {
		banner_fail('.server_bar span is hidden');
	}
}
if (!$sawStatic) {
	banner_fail('.server_bar is not in normal flow');
}

if (!preg_match('/class="server_bar"(?!_)/', $header)) {
	banner_fail('header has no server_bar');
}
if (!preg_match(
	'/class="server_bar".*Functional test: this mode assumes no radio is attached\..*Start, stop, and restart are available\..*Enable stays blocked\..*\/etc\/openrepeater\/tx-armed\..*class="rebuild_button"/s',
	$header
)) {
	banner_fail('the functional-test notice or its button is missing');
}
$barPos = strpos($header, 'class="server_bar"');
$buttonPos = strpos($header, 'class="rebuild_button"', $barPos);
$spacerPos = strpos($header, 'class="server_bar_spacer"', $barPos);
$navbarPos = strpos($header, 'class="navbar"');
if ($barPos === false || $buttonPos === false || $spacerPos === false || $navbarPos === false
	|| !($barPos < $buttonPos && $buttonPos < $spacerPos && $spacerPos < $navbarPos)) {
	banner_fail('the button is not inside the banner ahead of the logo bar');
}

echo "ok: the functional-test banner stays in normal flow\n";
