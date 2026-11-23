<?php
// Lists stock and uploaded courtesy clips and refuses delete or rename of a stock name.
$audioClass = $argv[1];
$stockList = $argv[2];
$stockDir = $argv[3];
$library = $argv[4];
require $audioClass;

$expected = file($stockList, FILE_IGNORE_NEW_LINES);
if (!is_array($expected) || count($expected) !== 39) {
	fwrite(STDERR, "stock list is not 39 names\n");
	exit(1);
}
$onDisk = array();
foreach (scandir($stockDir) as $name) {
	if (substr($name, -4) === '.wav') {
		$onDisk[] = $name;
	}
}
sort($expected);
sort($onDisk);
if ($expected !== $onDisk) {
	fwrite(STDERR, "stock list does not match the installer clips\n");
	exit(1);
}

$toneDir = $library . '/courtesy_tones';
if (!mkdir($toneDir, 0755, true) && !is_dir($toneDir)) {
	fwrite(STDERR, "library was not created\n");
	exit(1);
}
file_put_contents($toneDir . '/Beep.wav', "stock\n");
file_put_contents($toneDir . '/keep.wav', "upload\n");
$_SERVER['HTTP_HOST'] = 'localhost';
$audio = new AudioFiles();
$table = $audio->display_audio_files('courtesy_tones', 'Beep.wav', 'courtesy');
$html = $table['table'] . $table['modals'];
foreach (array('Beep.wav', 'keep.wav', 'type="audio/wav"', '>Stock<', 'setCourtesyTone') as $needle) {
	if (strpos($html, $needle) === false) {
		fwrite(STDERR, "library html missing {$needle}\n");
		exit(1);
	}
}
if (strpos($html, 'xhrFields') !== false
	|| strpos($html, 'name="delfile[]" value="Beep.wav"') !== false
	|| strpos($html, 'name="delfile[]" value="keep.wav"') === false) {
	fwrite(STDERR, "stock row is deletable or the preview is an XHR blob\n");
	exit(1);
}
$refused = $audio->audio_delete_files('courtesy_tones', array('Beep.wav'));
if ($refused['msgType'] !== 'error' || strpos($refused['msgText'], 'cannot be deleted') === false) {
	fwrite(STDERR, "stock delete was accepted\n");
	exit(1);
}
if (file_get_contents($toneDir . '/Beep.wav') !== "stock\n") {
	fwrite(STDERR, "stock delete changed the file\n");
	exit(1);
}
$renamed = $audio->audio_rename_file('courtesy_tones', 'Beep.wav', 'Other Beep');
if ($renamed['msgType'] !== 'error' || strpos($renamed['msgText'], 'cannot be renamed') === false) {
	fwrite(STDERR, "stock rename was accepted\n");
	exit(1);
}
if (!is_file($toneDir . '/Beep.wav')) {
	fwrite(STDERR, "stock rename moved the file\n");
	exit(1);
}
$deleted = $audio->audio_delete_files('courtesy_tones', array('keep.wav'));
if ($deleted['msgType'] !== 'success' || is_file($toneDir . '/keep.wav')) {
	fwrite(STDERR, "uploaded tone was not deleted\n");
	exit(1);
}
exit(0);
