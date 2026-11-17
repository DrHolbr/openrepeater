<?php
// Session shapes that are not one existing account row. This does not forge
// a cookie. It calls RequestGuard::authenticated() with fields set in this
// process and a throwaway database.
if ($argc < 3) {
	fwrite(STDERR, "usage: auth_account_gate_test.php db sessiondir\n");
	exit(1);
}
$dbPath = $argv[1];
$sessionDir = $argv[2];
putenv('ORP_DB_PATH=' . $dbPath);
session_save_path($sessionDir);
session_start();
require_once(dirname(__DIR__, 2) . '/includes/classes/RequestGuard.php');

function gate_check($condition, $label) {
	if (!$condition) {
		fwrite(STDERR, "FAIL: {$label}\n");
		exit(1);
	}
	echo "ok: {$label}\n";
}

$_SESSION['username'] = 'nonexistent';
$_SESSION['userID'] = array('invalid-array');
gate_check(RequestGuard::authenticated() === false, 'an array user id is not an account');

$_SESSION['userID'] = 'not-a-user-id';
gate_check(RequestGuard::authenticated() === false, 'a nonnumeric user id is not an account');

$_SESSION['userID'] = 0;
gate_check(RequestGuard::authenticated() === false, 'user id 0 is not an account');

$_SESSION['userID'] = '01';
gate_check(RequestGuard::authenticated() === false, 'a padded user id is not an account');

$_SESSION['username'] = 'admin';
$_SESSION['userID'] = 99;
gate_check(RequestGuard::authenticated() === false, 'a missing account id is refused');

$_SESSION['username'] = 'other';
$_SESSION['userID'] = 1;
gate_check(RequestGuard::authenticated() === false, 'a username that does not match the row is refused');

$_SESSION['username'] = 'admin';
$_SESSION['userID'] = 1;
gate_check(RequestGuard::authenticated() === true, 'admin and account id 1 match the users row');

$_SESSION['userID'] = '1';
gate_check(RequestGuard::authenticated() === true, 'the decimal string 1 matches the same row');

$db = new SQLite3($dbPath);
$db->exec("DELETE FROM users WHERE userID = 1");
$db->close();
$_SESSION['username'] = 'admin';
$_SESSION['userID'] = 1;
gate_check(RequestGuard::authenticated() === false, 'a deleted account is refused');
echo "account identity gate checks passed\n";
