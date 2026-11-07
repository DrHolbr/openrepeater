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
						<p>This page does not export pins, drive outputs, or key a transmitter. Stored numbers are names from the presets and the ICS manual baseline. A BCM header candidate is not a measurement on this Pi, and it is not a configured libgpiod line. Numbers 496 through 507 are not line offsets on gpiochip0 and are not indexes on the 8-line raspberrypi-exp-gpio chip, so those preset outputs stay unsupported. The five board options remain selectable; selecting one is not a claim the output can be driven.</p>
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
									<th>Output supported</th>
									<th>Drivable</th>
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
									<td><?php echo htmlspecialchars($row['chip_candidate'] === null ? 'unsupported' : $row['chip_candidate']); ?></td>
									<td><?php echo htmlspecialchars($row['line_offset_candidate'] === null ? '' : (string) $row['line_offset_candidate']); ?></td>
									<td>no</td>
									<td>no</td>
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
