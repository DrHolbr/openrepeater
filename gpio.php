<?php
// --------------------------------------------------------
// SESSION CHECK TO SEE IF USER IS LOGGED IN.
session_start();
require_once(__DIR__ . '/includes/classes/RequestGuard.php');
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] !== 'GET' && $_SERVER['REQUEST_METHOD'] !== 'HEAD') {
	RequestGuard::requireMutation();
	RequestGuard::deny(405);
}
if ((!isset($_SESSION['username'])) || (!isset($_SESSION['userID']))){
	header('location: login.php');
} elseif (!isset($_SESSION['callsign'])) {
	header('location: wizard/index.php');
} else {
// --------------------------------------------------------

require_once __DIR__ . '/includes/classes/GpioMap.php';

if (!GpioMap::allowsRequestMethod(isset($_SERVER['REQUEST_METHOD']) ? $_SERVER['REQUEST_METHOD'] : 'GET')) {
	header('HTTP/1.1 405 Method Not Allowed');
	echo 'refused: GPIO diagnostics are read-only';
	exit;
}

$pageTitle = "GPIO Map";
include('includes/header.php');

$definitions = GpioMap::loadDefinitions(__DIR__ . '/includes/board_definitions.php');
$rows = array_merge(
	GpioMap::report($definitions),
	GpioMap::fromStoredPorts($Database->get_ports()),
	GpioMap::fromStoredGpios($Database->get_gpios())
);
$gpioinfoBin = getenv('ORP_GPIOINFO');
if (!is_string($gpioinfoBin) || $gpioinfoBin === '') {
	$gpioinfoBin = 'gpioinfo';
}
$chipInfo = GpioMap::readOnlyChipInfo($gpioinfoBin);
?>

			<div class="row-fluid sortable">
				<div class="box span12">
					<div class="box-header well" data-original-title>
						<h2><i class="icon-info-sign"></i> GPIO map (read-only)</h2>
					</div>
					<div class="box-content">
						<p>This page does not export pins, drive outputs, or key a transmitter. A number from 0 to 27 is only a BCM header candidate on gpiochip0. A number from 496 to 511 is a conditional MCP23017 offset if the old kernel base was 496, and it is never a BCM number. orp-test has no MCP23017, so that line is absent and activation is not applied. A number with no source name stays an evidence gap, not a guessed output.</p>
						<table class="table table-striped table-bordered">
							<thead>
								<tr>
									<th>Source</th>
									<th>Board</th>
									<th>Port</th>
									<th>Logical name</th>
									<th>Stored number</th>
									<th>Direction</th>
									<th>Preset active</th>
									<th>Class</th>
									<th>BCM</th>
									<th>Physical pin</th>
									<th>Chip candidate</th>
									<th>Line offset candidate</th>
									<th>Expander pin if base 496</th>
									<th>Support</th>
									<th>Activation</th>
								</tr>
							</thead>
							<tbody>
							<?php foreach ($rows as $row) { ?>
								<tr>
									<td><?php echo htmlspecialchars($row['source']); ?></td>
									<td><?php echo htmlspecialchars($row['manufacturer'] . ' ' . $row['model'] . ' ' . $row['version']); ?></td>
									<td><?php echo htmlspecialchars((string) $row['port']); ?></td>
									<td><?php echo htmlspecialchars($row['logical_name']); ?></td>
									<td><?php echo htmlspecialchars($row['stored_number']); ?></td>
									<td><?php echo htmlspecialchars($row['direction']); ?></td>
									<td><?php echo htmlspecialchars($row['preset_active']); ?></td>
									<td><?php echo htmlspecialchars($row['class']); ?></td>
									<td><?php echo htmlspecialchars($row['bcm'] === null ? '' : (string) $row['bcm']); ?></td>
									<td><?php echo htmlspecialchars($row['physical_pin'] === null ? '' : (string) $row['physical_pin']); ?></td>
									<td><?php echo htmlspecialchars($row['chip_candidate'] === null ? '' : $row['chip_candidate']); ?></td>
									<td><?php echo htmlspecialchars($row['line_offset_candidate'] === null ? '' : (string) $row['line_offset_candidate']); ?></td>
									<td><?php echo htmlspecialchars($row['expander_pin'] === null ? '' : $row['expander_pin']); ?></td>
									<td><?php echo htmlspecialchars($row['support_state']); ?></td>
									<td><?php echo htmlspecialchars($row['activation']); ?></td>
								</tr>
							<?php } ?>
							</tbody>
						</table>
						<h3>gpioinfo</h3>
						<?php if ($chipInfo === null) { ?>
						<p>gpioinfo is not installed or not executable. No pin was requested.</p>
						<?php } else { ?>
						<pre><?php echo htmlspecialchars($chipInfo); ?></pre>
						<?php } ?>
					</div>
				</div>
			</div>

<?php include('includes/footer.php'); ?>

<?php
}
?>
