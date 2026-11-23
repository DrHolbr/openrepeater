<?php
// The GPIO map table stays inside its panel. A wide row scrolls there, and a
// long class token can break instead of pushing the last columns past the box.
$root = dirname(__DIR__, 2);
$page = file_get_contents($root . '/gpio.php');
$css = file_get_contents($root . '/theme/css/openrepeater.css');
if ($page === false || $css === false) {
	fwrite(STDERR, "FAIL: gpio layout sources were not read\n");
	exit(1);
}

function gpio_fail($message) {
	fwrite(STDERR, "FAIL: {$message}\n");
	exit(1);
}

if (!preg_match('/<div class="gpio-map-scroll">\s*<table class="table table-striped table-bordered">.*<\/table>\s*<\/div>/s', $page)) {
	gpio_fail('the GPIO table is not inside gpio-map-scroll');
}
if (substr_count($page, 'class="gpio-map-scroll"') !== 1) {
	gpio_fail('the GPIO scroll container is not opened once');
}
if (!preg_match('/\.gpio-map-scroll\s*\{[^}]*overflow-x\s*:\s*auto\b/s', $css)) {
	gpio_fail('gpio-map-scroll does not scroll horizontally');
}
if (!preg_match('/\.gpio-map-scroll\s+th,\s*\.gpio-map-scroll\s+td\s*\{[^}]*overflow-wrap\s*:\s*break-word\b/s', $css)) {
	gpio_fail('GPIO cells do not break long tokens');
}

echo "ok: the GPIO map table scrolls inside its panel\n";
