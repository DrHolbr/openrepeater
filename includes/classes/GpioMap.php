<?php
#####################################################################################################
# Read-only GPIO name map
#
# Logical names and stored numbers come from includes/board_definitions.php.
# BCM 0-27 is translated to the Raspberry Pi 40-pin header only as a candidate.
# Numbers outside that range stay unresolved. Nothing in this class drives a pin.
#####################################################################################################

class GpioMap {

	public static function headerMap() {
		// Physical header pin for each BCM offset on the 40-pin Raspberry Pi header.
		return array(
			0 => 27, 1 => 28, 2 => 3, 3 => 5, 4 => 7, 5 => 29, 6 => 31, 7 => 26,
			8 => 24, 9 => 21, 10 => 19, 11 => 23, 12 => 32, 13 => 33, 14 => 8, 15 => 10,
			16 => 36, 17 => 11, 18 => 12, 19 => 35, 20 => 38, 21 => 40, 22 => 15, 23 => 16,
			24 => 18, 25 => 22, 26 => 37, 27 => 13,
		);
	}

	public static function classifyNumber($number) {
		$digits = (string) $number;
		$empty = array(
			'class' => 'unresolved',
			'bcm' => null,
			'physical_pin' => null,
			'chip_candidate' => null,
			'line_offset_candidate' => null,
			'expander_pin' => null,
			'support_state' => 'unresolved-evidence-gap',
			'activation' => 'not-applied',
			'evidence' => 'The stored value is not a decimal GPIO number. No line is requested.',
		);
		if ($digits === '' || !ctype_digit($digits)) {
			return $empty;
		}
		$n = (int) $digits;
		$map = self::headerMap();
		if ($n >= 0 && $n <= 27 && array_key_exists($n, $map)) {
			return array(
				'class' => 'bcm_header_candidate',
				'bcm' => $n,
				'physical_pin' => $map[$n],
				// gpiochip0 on the Pi 3B+ SoC is pinctrl-bcm2835. The line
				// offset equals the BCM number. This is not a reading from
				// the running Pi and it is not a command to drive the line.
				'chip_candidate' => 'gpiochip0',
				'line_offset_candidate' => $n,
				'expander_pin' => null,
				'support_state' => 'header-candidate-not-driven',
				'activation' => 'not-applied',
				'evidence' => 'BCM ' . $n . ' is header pin ' . $map[$n] . ' and gpiochip0 line ' . $n . '. Not driven.',
			);
		}
		if ($n >= 496 && $n <= 511) {
			$offset = $n - 496;
			$pin = null;
			if ($offset <= 7) {
				$pin = 'GPA' . $offset;
			}
			$evidence = 'If the old kernel gpio base was 496, this is MCP23017 line offset ' . $offset . '.';
			if ($pin !== null) {
				$evidence .= ' The ICS manual names ' . $n . ' as ' . $pin . '.';
			} else {
				$evidence .= ' The ICS manual does not name the MCP23017 pin for ' . $n . '.';
			}
			$evidence .= ' It is not a BCM number. orp-test has no MCP23017, so the line is not present. Activation is not applied.';
			return array(
				'class' => 'conditional_mcp23017_offset',
				'bcm' => null,
				'physical_pin' => null,
				'chip_candidate' => 'mcp23017-if-base-496',
				'line_offset_candidate' => $offset,
				'expander_pin' => $pin,
				'support_state' => 'conditional-expander-chip-absent',
				'activation' => 'not-applied',
				'evidence' => $evidence,
			);
		}
		return array(
			'class' => 'unresolved_evidence_gap',
			'bcm' => null,
			'physical_pin' => null,
			'chip_candidate' => null,
			'line_offset_candidate' => null,
			'expander_pin' => null,
			'support_state' => 'unresolved-evidence-gap',
			'activation' => 'not-applied',
			'evidence' => 'No board document in this tree assigns ' . $n . ' to a BCM line or a conditional expander offset. Activation is not applied.',
		);
	}

	public static function loadDefinitions($path) {
		$board_definitions = array();
		include $path;
		return $board_definitions;
	}

	private static function row($source, $manufacturer, $model, $version, $port, $logical, $number, $direction, $active, $note) {
		$class = self::classifyNumber($number);
		return array(
			'source' => $source,
			'manufacturer' => $manufacturer,
			'model' => $model,
			'version' => $version,
			'port' => $port,
			'logical_name' => $logical,
			'stored_number' => (string) $number,
			'direction' => $direction,
			'preset_active' => $active,
			'class' => $class['class'],
			'bcm' => $class['bcm'],
			'physical_pin' => $class['physical_pin'],
			'libgpiod_chip' => null,
			'libgpiod_offset' => null,
			'chip_candidate' => $class['chip_candidate'],
			'line_offset_candidate' => $class['line_offset_candidate'],
			'expander_pin' => $class['expander_pin'],
			'support_state' => $class['support_state'],
			'activation' => 'not-applied',
			'output_supported' => false,
			'drivable' => false,
			'note' => $note . ' ' . $class['evidence'],
		);
	}

	public static function typedConfigLine($row) {
		$number = (string) $row['stored_number'];
		if ($row['class'] === 'bcm_header_candidate') {
			return '# not-applied gpiochip0 line ' . $row['line_offset_candidate']
				. ' direction ' . $row['direction']
				. ' active ' . $row['preset_active'];
		}
		if ($row['class'] === 'conditional_mcp23017_offset') {
			return '# not-applied stored ' . $number
				. ' conditional MCP23017 offset ' . $row['line_offset_candidate']
				. ' if base 496; chip absent; not a BCM number';
		}
		return '# not-applied stored ' . $number . ' unresolved; activation not applied';
	}

	public static function fromDefinitions($definitions) {
		$rows = array();
		foreach ($definitions as $board) {
			$note = 'ORP preset value. Header pin is a BCM candidate only. Not evidence of attached wiring. Not configured as a libgpiod line.';
			if (!empty($board['ports'])) {
				foreach ($board['ports'] as $portNum => $port) {
					if (isset($port['rxGPIO']) && $port['rxGPIO'] !== '') {
						$rows[] = self::row(
							'orp_preset',
							$board['manufacturer'],
							$board['model'],
							$board['version'],
							$portNum,
							'rxGPIO',
							$port['rxGPIO'],
							'in',
							isset($port['rxGPIO_active']) ? $port['rxGPIO_active'] : '',
							$note
						);
					}
					if (isset($port['txGPIO']) && $port['txGPIO'] !== '') {
						$rows[] = self::row(
							'orp_preset',
							$board['manufacturer'],
							$board['model'],
							$board['version'],
							$portNum,
							'txGPIO',
							$port['txGPIO'],
							'out',
							isset($port['txGPIO_active']) ? $port['txGPIO_active'] : '',
							$note . ' Output is not driven.'
						);
					}
				}
			}
		}
		return $rows;
	}

	public static function unsupportedComments() {
		// Mirrors the "Not Yet Supported by ORP" comments in includes/board_definitions.php.
		$items = array(
			array('CTCSS1', 24, 'low'),
			array('CTCSS2', 25, 'low'),
			array('CTCSS_ENC1', 13, 'low'),
			array('CTCSS2_ENC', 27, 'low'),
		);
		$rows = array();
		foreach ($items as $item) {
			$rows[] = self::row(
				'orp_source_comment_unsupported',
				'ICS Controllers',
				'Pi Repeater 2X',
				'comment only',
				null,
				$item[0],
				$item[1],
				'comment',
				$item[2],
				'Present only as a source comment. ORP does not configure this signal. Not evidence of attached wiring.'
			);
		}
		return $rows;
	}

	public static function icsManualBaseline() {
		// ICS PI-REPEATER-2X manual, section "Hardware GPIO Pin number assignments".
		// Pi 3B baseline. The manual says expander numbers move across OS revisions.
		$signals = array(
			array('PTT', 1, 506),
			array('PTT', 2, 507),
			array('COS', 1, 26),
			array('COS', 2, 23),
			array('CTCSS', 1, 24),
			array('CTCSS', 2, 25),
			array('GPA0', null, 496),
			array('GPA1', null, 497),
			array('GPA2', null, 498),
			array('GPA3', null, 499),
			array('GPA4', null, 500),
			array('GPA5', null, 501),
			array('GPA6', null, 502),
			array('GPA7', null, 503),
		);
		$rows = array();
		foreach ($signals as $item) {
			$rows[] = self::row(
				'ics_manual_baseline',
				'ICS Controllers',
				'Pi Repeater 2X',
				'manual HW3.x/HW4.x Pi 3B baseline',
				$item[1],
				$item[0],
				$item[2],
				'manual',
				'',
				'Manual baseline only. Not measured on orp-test. Not programmed.'
			);
		}
		return $rows;
	}

	public static function fromStoredPorts($ports) {
		$rows = array();
		if (!is_array($ports)) {
			return $rows;
		}
		foreach ($ports as $port) {
			$note = 'Row in the tracked OpenRepeater ports table. Not a measurement on this Pi and not a configured libgpiod line.';
			if (isset($port['rxGPIO']) && $port['rxGPIO'] !== '') {
				$rows[] = self::row('openrepeater_db', 'database', 'ports', 'openrepeater.db', $port['portNum'], 'rxGPIO', $port['rxGPIO'], 'in', isset($port['rxGPIO_active']) ? $port['rxGPIO_active'] : '', $note);
			}
			if (isset($port['txGPIO']) && $port['txGPIO'] !== '') {
				$rows[] = self::row('openrepeater_db', 'database', 'ports', 'openrepeater.db', $port['portNum'], 'txGPIO', $port['txGPIO'], 'out', isset($port['txGPIO_active']) ? $port['txGPIO_active'] : '', $note . ' Output is not driven.');
			}
		}
		return $rows;
	}

	public static function fromStoredGpios($gpios) {
		$rows = array();
		if (!is_array($gpios)) {
			return $rows;
		}
		foreach ($gpios as $pin) {
			$rows[] = self::row(
				'openrepeater_db',
				'database',
				'gpio_pins',
				'openrepeater.db',
				null,
				isset($pin['description']) ? $pin['description'] : 'gpio_num',
				$pin['gpio_num'],
				isset($pin['direction']) ? $pin['direction'] : '',
				isset($pin['active']) ? $pin['active'] : '',
				'Row in gpio_pins. Not exported and not driven.'
			);
		}
		return $rows;
	}

	public static function report($definitions) {
		return array_merge(
			self::fromDefinitions($definitions),
			self::unsupportedComments(),
			self::icsManualBaseline()
		);
	}

	public static function allowsRequestMethod($method) {
		return strtoupper((string) $method) === 'GET';
	}

	public static function readOnlyChipInfo($binary) {
		if (basename((string) $binary) !== 'gpioinfo') {
			return 'refused: diagnostic binary must be gpioinfo';
		}
		if (!is_file($binary) || !is_executable($binary)) {
			return null;
		}
		$out = shell_exec(escapeshellarg($binary) . ' 2>&1');
		if ($out === null) {
			return null;
		}
		if (strlen($out) > 65536) {
			$out = substr($out, 0, 65536);
		}
		return $out;
	}
}
?>
