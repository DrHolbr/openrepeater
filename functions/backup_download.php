<?php
// Authenticated download of one backup archive. nginx denies /backup/.

require_once(__DIR__ . '/../includes/classes/RequestGuard.php');
require_once(__DIR__ . '/../includes/autoloadClasses.php');
RequestGuard::requireMutation();

$name = isset($_POST['file']) ? $_POST['file'] : '';
$backup = new BackupRestore();
$path = $backup->resolveBackupDownload($name);
if ($path === null) {
	http_response_code(403);
	header('Content-Type: text/plain; charset=UTF-8');
	header('X-Content-Type-Options: nosniff');
	header('Cache-Control: no-store');
	echo "refused\n";
	exit;
}

$size = filesize($path);
header('Content-Type: application/octet-stream');
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');
header('Content-Disposition: attachment; filename="' . $name . '"');
if ($size !== false) {
	header('Content-Length: ' . $size);
}
$defaultRoot = '/var/www/openrepeater/backup/';
if (strpos($path, $defaultRoot) === 0) {
	header('X-Accel-Redirect: /internal-backup/' . $name);
}
readfile($path);
exit;
