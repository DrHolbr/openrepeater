<?php
#####################################################################################################
# SXVLink GPIO Config Class
#####################################################################################################

class SVXLink_GPIO {

    private $gpioArray;
    private $gpioInHighArray = array();
    private $gpioInLowArray = array();
    private $gpioOutHighArray = array();
    private $gpioOutLowArray = array();
    

	public function __construct($gpioArray) {
		$this->gpioArray = $gpioArray;
	}



	###############################################
	# Process GPIO Pins
	###############################################

	private function process_gpio_pins() {
		
		// Loop through each GPIO in database and assign to appropriate arrays
		foreach ($this->gpioArray as $key => $val) {	
			if ($this->gpioArray[$key]['direction'] == "in") {
				if ($this->gpioArray[$key]['active'] == "low") {
					$this->gpioInLowArray[] = $this->gpioArray[$key]['gpio_num'];		
				} else {
					$this->gpioInHighArray[] = $this->gpioArray[$key]['gpio_num'];					
				}
			}
		
			if ($this->gpioArray[$key]['direction'] == "out") {
				if ($this->gpioArray[$key]['active'] == "low") {
					$this->gpioOutLowArray[] = $this->gpioArray[$key]['gpio_num'];		
				} else {
					$this->gpioOutHighArray[] = $this->gpioArray[$key]['gpio_num'];					
				}
			}
		
		}
	}



	###############################################
	# Build GPIO Config File
	###############################################


	public function build_gpio_config() {
		if (BenchGuard::detect()->isBench()) {
			return $this->build_bench_gpio_config();
		}
		
		$this->process_gpio_pins();
		
		// Reformat arrays into space delminated lists of gpio pin numbers prefixed with 'gpio'
		if (!empty($this->gpioInHighArray)) { $gpioInHighString = 'gpio'. implode(' gpio', $this->gpioInHighArray); } else { $gpioInHighString = ''; }
		if (!empty($this->gpioInLowArray)) { $gpioInLowString = 'gpio'. implode(' gpio', $this->gpioInLowArray); } else { $gpioInLowString = ''; }
		if (!empty($this->gpioOutHighArray)) { $gpioOutHighString = 'gpio'. implode(' gpio', $this->gpioOutHighArray); } else { $gpioOutHighString = ''; }
		if (!empty($this->gpioOutLowArray)) { $gpioOutLowString = 'gpio'. implode(' gpio', $this->gpioOutLowArray); } else { $gpioOutLowString = ''; }

		$gpioConfigFile = '
			###############################################################################
			#
			# Configuration file for the SvxLink server GPIO Pins
			#
			###############################################################################
		
			# GPIO system pin path
			# RPi/odroid/nanopi/pine64 = /sys/class/gpio, orangpi = /sys/class/gpio_sw	
			GPIO_PATH=/sys/class/gpio
		
			# Space separated list of GPIO pins that point IN and have an
			# Active HIGH state (3.3v = ON, 0v = OFF)
			GPIO_IN_HIGH="'.$gpioInHighString.'"
		
			# Space separated list of GPIO pins that point IN and have an
			# Active LOW state (0v = ON, 3.3v = OFF)
			GPIO_IN_LOW="'.$gpioInLowString.'"
		
			# Space separated list of GPIO pins that point OUT and have an
			# Active HIGH state (3.3v = ON, 0v = OFF)
			GPIO_OUT_HIGH="'.$gpioOutHighString.'"
		
			# Space separated list of GPIO pins that point OUT and have an
			# Active LOW state (0v = ON, 3.3v = OFF)
			GPIO_OUT_LOW="'.$gpioOutLowString.'"
		
			# User that should own the GPIO device files
			GPIO_USER="svxlink"
		
			# Group for the GPIO device files
			GPIO_GROUP="daemon"
		
			# File access mode for the GPIO device files
			GPIO_MODE="0664"
		';	

		#Clean up tabs/white spaces
		$gpioConfigFile = trim(preg_replace('/\t+/', '', $gpioConfigFile));

		return $gpioConfigFile;
	}


	private function build_bench_gpio_config() {
		$lines = array();
		$lines[] = '# Bench GPIO preview. Read-only. No sysfs path. No pins are exported.';
		$lines[] = '# Outputs are disconnected. Do not copy this file onto the radio.';
		foreach ($this->gpioArray as $row) {
			$num = isset($row['gpio_num']) ? $row['gpio_num'] : '';
			$dir = isset($row['direction']) ? $row['direction'] : '';
			$active = isset($row['active']) ? $row['active'] : '';
			$lines[] = '# stored gpio_num=' . $num . ' direction=' . $dir . ' active=' . $active . ' (not configured)';
		}
		$lines[] = 'GPIO_IN_HIGH=""';
		$lines[] = 'GPIO_IN_LOW=""';
		$lines[] = 'GPIO_OUT_HIGH=""';
		$lines[] = 'GPIO_OUT_LOW=""';
		return implode("\n", $lines) . "\n";
	}


}
?>