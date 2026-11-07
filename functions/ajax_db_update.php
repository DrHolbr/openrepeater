<?php
require_once(__DIR__ . '/../includes/classes/RequestGuard.php');
RequestGuard::requireMutation();

################################################################################
# AUTOLOAD CLASSES
require_once(rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/includes/autoloadClasses.php');
################################################################################
$Database = new Database();

foreach($_POST as $key=>$value){
	if ($key === 'csrf_token') { continue; }
	// SPECIAL FORMATING
	if ($key == "callSign") { $value = strtoupper($value); }
	if ($key == "echolink_callSign") { $value = strtoupper($value); }
	
	$query = $Database->update("UPDATE settings SET value='$value' WHERE keyID='$key'");	
}

if ($query) { return true; } else { return false; }
?>