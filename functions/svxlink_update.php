 <?php
# Copyright ©2018 - Aaron Crawford, N3MBH - info(at)openrepeater(dot)com
# Licended under GPL v2 or later

/*
This script reads settings from the OpenRepeater database and builds new configuration
files for SVXLink. 
*/

/* ---------------------------------------------------------- */
/* SESSION, VERB, AND CSRF BEFORE ANY DATABASE OR HELPER USE */
require_once(__DIR__ . '/../includes/classes/RequestGuard.php');
RequestGuard::requireMutation();
if ((!isset($_SESSION['username'])) || (!isset($_SESSION['userID']))){
	RequestGuard::deny(401);
} else { // If they are, show the page.
/* ---------------------------------------------------------- */

// Declare Config Arrays
$config_array = array();
$config_array['GLOBAL'] = array(); // Declare empty for prioritization


/* ---------------------------------------------------------- */
/* --- LOAD CLASSES --- */

# AUTOLOAD CLASSES
require_once(rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/includes/autoloadClasses.php');

// Access database for Settings, Modules, Ports, and GPIOs
$classDB = new Database();
$settings = $classDB->get_settings();
$module = $classDB->get_modules();
$ports = $classDB->get_ports();
$gpio = $classDB->get_gpios();

$classSVXLink = new SVXLink($settings, $ports, $module);
$classSVXLinkTCL = new SVXLink_TCL($settings);
$classSVXLinkGPIO = new SVXLink_GPIO($gpio);

/* ---------------------------------------------------------- */
/* --- BENCH: do not publish configs or restart the radio --- */

$benchGuard = BenchGuard::detect();

if ($benchGuard->operatingMode() === 'functional-test' && !$benchGuard->uiBlocksLifted()) {
	$runtime = $classSVXLink->disconnectedRuntimeConfig();
	$wrote = $classSVXLink->write_config($runtime, 'svxlink.conf', 'ini');
	$publish = shell_exec('sudo /usr/sbin/orp_helper config publish 2>&1');
	$lifecycle = shell_exec('sudo /usr/sbin/orp_helper svxlink restart 2>&1');
	$notice = 'functional_published=1';
	if ($wrote !== true || (is_string($publish) && strpos($publish, 'refused:') !== false)) {
		$notice = 'functional_publish_failed=1';
	} elseif (is_string($lifecycle) && (strpos($lifecycle, 'masked') !== false || strpos($lifecycle, 'service-disabled') !== false)) {
		$notice = 'functional_published=1&service_masked=1';
	}
	$url = RequestGuard::safeReturnUrl(isset($_POST['return_url']) ? $_POST['return_url'] : '');
	$join = (strpos($url, '?') === false) ? '?' : '&';
	header('Location: '.$url.$join.$notice);
	exit;
}

/* ---------------------------------------------------------- */
/* --- LOGIC SETTINGS --- */

$classSVXLink->delete_custom_evnets(); // Purge Previous Custom Event Files

switch ($settings['orp_Mode']) {

	###############################################
	# Repeater Setup
	###############################################

    case "repeater":

		foreach ($ports as $key => $val) {
			// Build Ports
			$config_array += $classSVXLink->build_rx($key); // Build RX
			$config_array += $classSVXLink->build_tx($key); // Build TX


			// If there is more than one port, build 1st port as repeater, and additional ports as simplex links
			if ($key == 1) {
				// Build Repeater Logic
				$new_logic_name = 'ORP_RepeaterLogic_Port' . $key;
				$new_logic_filename = $new_logic_name . '.tcl';
	
				$config_array += $classSVXLink->build_logic_repeater($new_logic_name, $key);
	
				$new_event = $classSVXLinkTCL->alias_RepeaterLogic($new_logic_name);

				$new_event = $classSVXLinkTCL->override_courtesy_tone($new_event);

				$classSVXLink->write_config($new_event, $new_logic_filename, 'text');
				
				$logicListArray = array($new_logic_name);
			
				
			} else {
				// Build Link/Simplex Logic
				$new_logic_name = 'ORP_SimplexLogic_Port' . $key;
				$new_logic_filename = $new_logic_name . '.tcl';
	
				$config_array += $classSVXLink->build_logic_simplex($new_logic_name, $key);
	
				$new_event = $classSVXLinkTCL->alias_SimplexLogic($new_logic_name);
				$classSVXLink->write_config($new_event, $new_logic_filename, 'text');

				$logicListArray[] = $new_logic_name;
					
			}
			
		}


		if (count($logicListArray) > 1) {
			// BUILD LINK SECTION
			$config_array += $classSVXLink->build_link( 'LinkSection', $logicListArray );			
		}


		// GLOBAL SETTINGS
		$config_array['GLOBAL'] += $classSVXLink->build_global();

		// Build GPIO Config
		$gpioConfigFile = $classSVXLinkGPIO->build_gpio_config();

		# Insert Logic TCL Overrides
 		$logicOverride = $classSVXLinkTCL->logic_override();


		// WRITE CONFIGURATION & TCL FILES
		$classSVXLink->write_config($config_array, 'svxlink.conf', 'ini');
 		$classSVXLink->write_config($logicOverride, 'Logic.tcl', 'text');
		$classSVXLink->write_config($gpioConfigFile, 'gpio.conf', 'text');

        break;


	###############################################
	# Simplex Setup
	###############################################

    case "simplex":

		foreach ($ports as $key => $val) {
			// Build Ports
			$config_array += $classSVXLink->build_rx($key); // Build RX
			$config_array += $classSVXLink->build_tx($key); // Build TX

			// Simplex Logic
			$new_logic_name = 'ORP_SimplexLogic_Port' . $key;
			$new_logic_filename = $new_logic_name . '.tcl';

			$config_array += $classSVXLink->build_logic_simplex($new_logic_name, $key, true);

			$new_event = $classSVXLinkTCL->alias_SimplexLogic($new_logic_name);
			$classSVXLink->write_config($new_event, $new_logic_filename, 'text');
		}

		// GLOBAL SETTINGS
		$config_array['GLOBAL'] += $classSVXLink->build_global();

		// Build GPIO Config
		$gpioConfigFile = $classSVXLinkGPIO->build_gpio_config();

		# Insert Logic TCL Overrides
 		$logicOverride = $classSVXLinkTCL->logic_override();

		// WRITE CONFIGURATION & TCL FILES
		$classSVXLink->write_config($config_array, 'svxlink.conf', 'ini');
 		$classSVXLink->write_config($logicOverride, 'Logic.tcl', 'text');
		$classSVXLink->write_config($gpioConfigFile, 'gpio.conf', 'text');

        break;


	###############################################
	# Advanced Setup
	###############################################

    case "advanced":
		// Process advanced mode overrides
		$adv_results = $classDB->select_key_value('SELECT * from advanced', 'keyID', 'value');
		foreach($adv_results as $adv_key => $adv_value) {
			// Remove Window Newline characters and trim off leading and trailing whitespace.
			$advanced[$adv_key] = trim(str_replace("\r", "", $adv_value)) . "\n";
		}
	
		// WRITE CONFIGURATION & TCL FILES
		$classSVXLink->write_config($advanced['svxlink_config'], 'svxlink.conf', 'text'); // Overridden svxlink.confg
		if (!$benchGuard->isBench()) {
			$customLogic = '/etc/openrepeater/svxlink/local-events.d/CustomLogic.tcl';
			if (is_file($customLogic) && !is_link($customLogic)) {
				unlink($customLogic);
			}
		}
		$classSVXLink->write_config($advanced['gpio_config'], 'gpio.conf', 'text'); // Overridden GPIO config
		$classSVXLink->write_config($classSVXLinkTCL->logic_override(), 'Logic.tcl', 'text');
        break;

}

	
/* ---------------------------------------------------------- */
/* FINISH UP */

$publishFailed = $classSVXLink->publishFailed();
$onBench = $benchGuard->isBench();

if (!$publishFailed) {
	$classDB->set_update_flag(false);
}

if ($publishFailed || ($onBench && !$benchGuard->uiBlocksLifted()) || ($benchGuard->operatingMode() === 'functional-test' && !$benchGuard->uiBlocksLifted())) {
	if ($publishFailed) {
		$notice = 'preview_failed=1';
	} else {
		$notice = 'bench_preview_ok=1';
	}
	if (isset($_SESSION["new_repeater_settings"])) {
		session_destroy();
		$url = '../login.php';
	} else {
		$url = RequestGuard::safeReturnUrl(isset($_POST['return_url']) ? $_POST['return_url'] : '');
	}
	$join = (strpos($url, '?') === false) ? '?' : '&';
	header('Location: '.$url.$join.$notice);
	exit;
}

if ($benchGuard->uiBlocksLifted()) {
	$publish = shell_exec('sudo /usr/sbin/orp_helper config publish 2>&1');
	if (!is_string($publish) || strpos($publish, 'refused:') !== false) {
		$notice = 'functional_publish_failed=1';
		$url = RequestGuard::safeReturnUrl(isset($_POST['return_url']) ? $_POST['return_url'] : '');
		$join = (strpos($url, '?') === false) ? '?' : '&';
		header('Location: '.$url.$join.$notice);
		exit;
	}
}

########
# GPIO setup runs only when root has created the tx-armed flag. Without
# that flag the published runtime stays disconnected. An armed start skips
# the snapshot and native-start checks. An unarmed start still refuses a
# PTT_TYPE other than NONE and a config that does not match the snapshot.
if ($benchGuard->txArmed()) {
	$gpioDown = shell_exec('sudo /usr/sbin/orp_helper svxlink gpio_down 2>&1');
	$gpioUp = shell_exec('sudo /usr/sbin/orp_helper svxlink gpio_up 2>&1');
	if ((is_string($gpioDown) && strpos($gpioDown, 'refused:') !== false) || (is_string($gpioUp) && strpos($gpioUp, 'refused:') !== false)) {
		$notice = 'functional_publish_failed=1';
		$url = RequestGuard::safeReturnUrl(isset($_POST['return_url']) ? $_POST['return_url'] : '');
		$join = (strpos($url, '?') === false) ? '?' : '&';
		header('Location: '.$url.$join.$notice);
		exit;
	}
}
########

$shellout = shell_exec('sudo /usr/sbin/orp_helper svxlink restart');

/* WHAT PAGE TO GO BACK TO */
if (isset($_SESSION["new_repeater_settings"])) {
	// Wizard was run. Go ahead and destroy session and logout
	session_destroy();
	header('location: ../login.php');
} else {
	header('Location: ' . RequestGuard::safeReturnUrl(isset($_POST['return_url']) ? $_POST['return_url'] : ''));
}	
?>

<?php
/* ---------------------------------------------------------- */
// SESSION CHECK TO SEE IF USER IS LOGGED IN.
 } // close ELSE to end login check from top of page
/* ---------------------------------------------------------- */
?>
