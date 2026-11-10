<?php
#####################################################################################################
# Modules Framework Class
#####################################################################################################

class Modules {

    public $Database;
	public $modules_path;
	public $modulesUploadTempDir;
	private $includes_path;
	private $core_modules = ['Help','Parrot','EchoLink'];
	
	// SVXLink Locations
	private $svxlink_events_d_path = '/usr/share/svxlink/events.d/';
	private $svxlink_modules_d_path = '/usr/share/svxlink/modules.d/';
	private $svxlink_sounds = '/usr/share/svxlink/sounds/en_US/'; // Need to read config for language folder.


	public function __construct() {
		$this->Database = new Database();
		$modulesOverride = getenv('ORP_MODULES_PATH');
		if (is_string($modulesOverride) && $modulesOverride !== '' && $modulesOverride[0] === '/'
			&& strpos($modulesOverride, '..') === false && is_dir($modulesOverride) && !is_link($modulesOverride)) {
			$this->modules_path = rtrim($modulesOverride, '/') . '/';
		} elseif (is_string($modulesOverride) && $modulesOverride !== '') {
			$this->modules_path = rtrim(sys_get_temp_dir(), '/') . '/orp-no-such-modules/';
		} else {
			$this->modules_path = rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/modules/';
		}
		$this->includes_path = rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/includes/';
		$this->modulesUploadTempDir = $this->modules_path . 'tempModuleDir/';
		$guard = BenchGuard::detect();
		if ($guard->isBench()) {
			$preview = $guard->previewDir();
			if (is_string($preview) && BenchGuard::previewAllowed($preview) && !is_link($preview)) {
				$preview = rtrim($preview, '/');
				$this->svxlink_events_d_path = $preview . '/events.d/';
				$this->svxlink_modules_d_path = $preview . '/modules.d/';
				$this->svxlink_sounds = $preview . '/sounds/en_US/';
				foreach (array($this->svxlink_events_d_path, $this->svxlink_modules_d_path, $this->svxlink_sounds) as $dir) {
					$this->mkdirReal($dir);
				}
			}
		}
	}

	public function svxlinkEventsPath() {
		return $this->svxlink_events_d_path;
	}

	private function mkdirReal($dir) {
		if (is_link($dir) || is_dir($dir)) {
			return;
		}
		$parent = dirname($dir);
		if ($parent !== $dir && !is_dir($parent)) {
			$this->mkdirReal($parent);
		}
		if (!is_dir($parent) || is_link($parent) || is_link($dir) || !BenchGuard::componentsAreReal($parent)) {
			return;
		}
		mkdir($dir, 0750);
	}


	###############################################
	# Get Modules from DB
	###############################################

	public function get_modules() {
		# REWRITE PENDING
		# Currently Redirects to Database Class
		# Plan to pull logic form those classes once everything points here
		return $this->Database->get_modules();
	}



	###############################################
	# Get Settings for Selected Module
	###############################################

	public function get_module_settings($id) {
		$sql = 'SELECT moduleOptions FROM "modules" WHERE "moduleKey" = ' . $id;
		$module = $this->Database->select_single($sql);
		$moduleOptionsArray = unserialize($module['moduleOptions']);
		return $moduleOptionsArray;	
	}



	###############################################
	# Submit Settings for Selected Module
	###############################################

	public function save_module_settings($settings_array, $type = 'normal') {
		$moduleID = $settings_array['moduleKey'];
		unset($settings_array['moduleKey']); // Remove id after extracted above
		if (isset($settings_array['updateModuleSettings'])) {
			unset($settings_array['updateModuleSettings']); // Remove Action			
		}

		##########
		if ($type == 'normal') {
			$modules = $this->get_modules();

			// Check for custom form processor, if one exists...then insert inline with IN and OUT arrays for external processing
			$mod_custom_submit_file = $this->modules_path . $modules[$moduleID]['svxlinkName'] . '/custom_submit.php';
			if (file_exists($mod_custom_submit_file)) { 
				$inputArray = $settings_array;
				include($mod_custom_submit_file);
				$settings_array = $outputArray;
			}
		}
		##########

		$serializedSettings = serialize($settings_array);
		if ($this->Database->write_module_options($moduleID, $serializedSettings) === true) {
			return array(
				'msgType' => 'success',
				'msgText' => 'Successfully saved module settings.'
			);
		} else { 
			return array(
				'msgType' => 'error',
				'msgText' => 'There was a problem saving the module settings.'
			);
		}

	}



	###############################################
	# Activate Module
	###############################################

	public function activateMod($id) {
		$sql = 'SELECT * FROM "modules" WHERE "moduleKey" = "'.$id.'";';
		$select_result = $this->Database->select_key_value($sql, 'moduleKey', 'svxlinkName');
		$svxlink_name = $select_result[$id];

		# REWRITE PENDING
		# Currently Redirects to Database Class
		# Plan to pull logic form those classes once everything points here
		if ($this->Database->set_module_enabled($id, 1) !== true) {
			return array(
				'msgType' => 'error',
				'msgText' => 'The module was not activated. The previous row was left unchanged.'
			);
		}
		if ($this->initialize_module($svxlink_name, 1) !== true) {
			$this->Database->set_module_enabled($id, 0);
			return array(
				'msgType' => 'error',
				'msgText' => 'The module was not activated. No SvxLink link was left in place.'
			);
		}

		return array(
			'msgType' => 'success',
			'msgText' => 'The module has been successfully <strong>activated</strong>.'
		);
	}



	###############################################
	# Deactivate Module
	###############################################

	public function deactivateMod($id) {
		$sql = 'SELECT * FROM "modules" WHERE "moduleKey" = "'.$id.'";';
		$select_result = $this->Database->select_key_value($sql, 'moduleKey', 'svxlinkName');
		$svxlink_name = isset($select_result[$id]) ? $select_result[$id] : '';
		if ($this->unlink_module_files($svxlink_name) !== true) {
			return array(
				'msgType' => 'error',
				'msgText' => 'The module was not deactivated. The previous links were left unchanged.'
			);
		}
		if ($this->Database->set_module_enabled($id, 0) !== true) {
			return array(
				'msgType' => 'error',
				'msgText' => 'The module was not deactivated. The previous row was left unchanged.'
			);
		}

		return array(
			'msgType' => 'success',
			'msgText' => 'The module has been successfully <strong>deactivated</strong>.'
		);
	}



	###############################################
	# Upload Module
	###############################################

	public function upload_module($fileNameArray) {
		if (!class_exists('ZipArchive', false)) {
			return array(
				'msgType' => 'error',
				'msgText' => self::zipSupportMessage()
			);
		}

		$maxFileSize = 8388608; // size in bytes
		$allowedExts = array('zip');
	
		//Loop through each file
		for($i=0; $i<count($fileNameArray['name']); $i++) {
			//Get the temp file path
			$tmpFile1 = $fileNameArray['tmp_name'][$i];
			
			$temp_ext = explode(".", $fileNameArray['name'][$i]);
			$extension = strtolower((string) end($temp_ext));

			$uploadedModuleZip = $this->modules_path . 'tempModule.' . $extension;
			
			# Check File Size isn't too large
			if($fileNameArray['size'][$i] > $maxFileSize){
				return array(
					'msgType' => 'error',
					'msgText' => 'Sorry, but the file you tried to upload is <strong>too large</strong>.'
				);	
			}

			# Check to see if file is allowed type
			if(!in_array($extension, $allowedExts)) {
				return array(
					'msgType' => 'error',
					'msgText' => 'Sorry, but the file you tried to upload is not in a supported format. Files must modules packaged up with a .zip extension.'
				);	
			}

			# Check to see if system temp folder is writable
			if (!is_writable( sys_get_temp_dir() )) {
				return array(
					'msgType' => 'error',
					'msgText' => 'Sorry, it looks like there is a configuration issue. The system\'s temp folder is not writable'
				);	
			}

			# Check for error reported by file array
			if ($fileNameArray['error'][$i] > 0) {
				return array(
					'msgType' => 'error',
					'msgText' => 'There was a problem uploading the file'
				);	
			}


			if ($tmpFile1 != ""){
				if(file_exists($uploadedModuleZip)) {
				    unlink($uploadedModuleZip); //remove orphan
				}
				move_uploaded_file($tmpFile1, $uploadedModuleZip);

				if (file_exists($uploadedModuleZip)) {
					### SUCCESSFUL UPLOAD ###
					$unzip = $this->unzip_module($uploadedModuleZip);
					if ($unzip == true) {
						### SUCCESSFUL UNZIP ###
						$install_results = $this->install_module($this->modulesUploadTempDir);
						if ( is_array($install_results) ) {
							if (isset($install_results['Module_Info']['display_name'])) {
								$currDisplayName = trim($install_results['Module_Info']['display_name']);
								return array(
									'msgType' => 'success',
									'msgText' => 'The ' . $currDisplayName . ' module has been successfully installed. To use it, you must first activate it.'
								);	
							} else {
								return array(
									'msgType' => 'success',
									'msgText' => 'Module has been successfully installed. To use it, you must first activate it.'
								);	
							}

						} else {
							return array(
								'msgType' => 'error',
								'msgText' => 'There was a problem installing the module. Either this is not an OpenRepeater module, or the zip file was improperly constructed, or the module already exists.'
							);	
							
						}

							
					} else {
						### FAILED UNZIP ###
						return array(
							'msgType' => 'error',
							'msgText' => 'There was a problem Unzipping the file'
						);	
					}
										
				} else {
					// Failure
					return array(
						'msgType' => 'error',
						'msgText' => 'There was a problem uploading the file.'
					);						
				}
				
			}

		}

		# Some how it got thru validation, but nothing was done.
		return array(
			'msgType' => 'error',
			'msgText' => 'Don\'t know what happened, but nothing appears to have been done.'
		);	

	}



	###############################################
	# Archive Functions
	###############################################

	public static function zipSupportMessage() {
		return 'PHP ZipArchive is not available. Install the php8.4-zip package.';
	}

	public function unzip_module($selected_archive) {
		if (!class_exists('ZipArchive', false)) {
			return false;
		}
		if (!is_string($selected_archive) || $selected_archive === '' || is_link($selected_archive) || !is_file($selected_archive)) {
			return false;
		}
		$archiveBytes = filesize($selected_archive);
		if ($archiveBytes === false || $archiveBytes < 22 || $archiveBytes > self::ZIP_MAX_ARCHIVE) {
			$this->discardUploadedArchive($selected_archive);
			return false;
		}
		$temp = $this->modulesUploadTempDir;
		if (is_link($temp)) {
			$this->discardUploadedArchive($selected_archive);
			return false;
		}
		if (!is_dir($temp) && !mkdir($temp, 0755, true) && !is_dir($temp)) {
			$this->discardUploadedArchive($selected_archive);
			return false;
		}
		if (is_link($temp)) {
			$this->discardUploadedArchive($selected_archive);
			return false;
		}
		$root = realpath($temp);
		if ($root === false || !is_dir($root) || is_link($temp)) {
			$this->discardUploadedArchive($selected_archive);
			return false;
		}
		$this->discardChildren($root, $root);

		$zip = new ZipArchive();
		if ($zip->open($selected_archive) !== true) {
			$this->discardUploadedArchive($selected_archive);
			return false;
		}
		$count = $zip->numFiles;
		if ($count < 1 || $count > self::ZIP_MAX_ENTRIES) {
			$zip->close();
			$this->discardUploadedArchive($selected_archive);
			return false;
		}
		$plans = array();
		$total = 0;
		for ($i = 0; $i < $count; $i++) {
			$name = $zip->getNameIndex($i);
			if ($this->zipEntrySkipped($name)) {
				continue;
			}
			$stat = $zip->statIndex($i);
			if (is_array($stat)) {
				$opsys = 0;
				$attr = 0;
				if ($zip->getExternalAttributesIndex($i, $opsys, $attr)) {
					$stat['external_attributes'] = $attr;
				}
			}
			if (!is_array($stat) || !$this->zipEntryAllowed($name, $stat)) {
				$zip->close();
				$this->discardChildren($root, $root);
				$this->discardUploadedArchive($selected_archive);
				return false;
			}
			$uncompressed = (int) $stat['size'];
			$compressed = isset($stat['comp_size']) ? (int) $stat['comp_size'] : 0;
			$attr = isset($stat['external_attributes']) ? (int) $stat['external_attributes'] : 0;
			$isDir = substr($name, -1) === '/' || (($attr >> 16) & 0170000) === 0040000;
			$total += $uncompressed;
			if ($total > self::ZIP_MAX_TOTAL) {
				$zip->close();
				$this->discardChildren($root, $root);
				$this->discardUploadedArchive($selected_archive);
				return false;
			}
			$plans[] = array($i, rtrim($name, '/'), $isDir, $uncompressed, $compressed);
		}
		if (count($plans) < 1) {
			$zip->close();
			$this->discardUploadedArchive($selected_archive);
			return false;
		}
		foreach ($plans as $plan) {
			$relative = $plan[1];
			$isDir = $plan[2];
			$expected = $plan[3];
			$parent = $isDir ? $relative : dirname($relative);
			if ($parent !== '.' && !$this->mkdirInside($root, $parent)) {
				$zip->close();
				$this->discardChildren($root, $root);
				$this->discardUploadedArchive($selected_archive);
				return false;
			}
			$target = $root . '/' . $relative;
			if ($isDir) {
				if (!$this->mkdirInside($root, $relative)) {
					$zip->close();
					$this->discardChildren($root, $root);
					$this->discardUploadedArchive($selected_archive);
					return false;
				}
				continue;
			}
			if (is_link($target) || is_dir($target)) {
				$zip->close();
				$this->discardChildren($root, $root);
				$this->discardUploadedArchive($selected_archive);
				return false;
			}
			if (!$this->writeMemberCapped($zip, $plan[0], $target, $root)) {
				$zip->close();
				$this->discardChildren($root, $root);
				$this->discardUploadedArchive($selected_archive);
				return false;
			}
		}
		$zip->close();
		$this->discardUploadedArchive($selected_archive);
		if (!$this->flattenSingleFolder($root)) {
			$this->discardChildren($root, $root);
			return false;
		}
		return true;
	}


	
	###############################################
	# Install Module
	###############################################

	public function initialize_module($svxlink_name, $enabled = 0) {
		$svxlink_name = trim($svxlink_name);
		if (!preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/', $svxlink_name)) {
			return false;
		}

		if ($this->Database->exists('modules','svxlinkName',$svxlink_name) == false) {
			$nextId = $this->find_next_svxlink_id();
			if ($this->Database->insert_module_row($svxlink_name, $enabled, $nextId) !== true) {
				return false;
			}
		}

		// An inactive install does not link into SvxLink and does not remove
		// a sounds directory. Links are created only when the module is activated.
		if ((int) $enabled === 1 && !in_array($svxlink_name, $this->core_modules, true)) {
			$links = $this->link_module_files($svxlink_name);
			if ($links === false) {
				return false;
			}
		}

		// An uploaded default_settings.php is not included. The file can sit in
		// the module directory, but this request does not execute it.
		return true;

	}

	public function link_module_files($svxlink_name) {
		if (!is_string($svxlink_name) || !preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/', $svxlink_name)) {
			return false;
		}
		if (in_array($svxlink_name, $this->core_modules, true)) {
			return false;
		}
		$undo = array();
		$pairs = array(
			array($this->modules_path . $svxlink_name . '/svxlink/events.d/', $this->svxlink_events_d_path),
			array($this->modules_path . $svxlink_name . '/svxlink/modules.d/', $this->svxlink_modules_d_path),
		);
		foreach ($pairs as $pair) {
			if (!$this->link_each($pair[0], $pair[1], $undo)) {
				$this->undo_module_links($undo);
				return false;
			}
		}
		$sounds_src = $this->modules_path . $svxlink_name . '/svxlink/sounds/en_US';
		if (is_dir($sounds_src) && !is_link($sounds_src)) {
			if (!$this->place_link($sounds_src, $this->svxlink_sounds . $svxlink_name, $undo)) {
				$this->undo_module_links($undo);
				return false;
			}
		}
		return $undo;
	}

	public function undo_module_links($undo) {
		if (!is_array($undo)) {
			return;
		}
		for ($i = count($undo) - 1; $i >= 0; $i--) {
			$item = $undo[$i];
			if (!is_array($item) || !isset($item['path']) || !is_string($item['path'])) {
				continue;
			}
			if (!empty($item['created']) && is_link($item['path'])) {
				unlink($item['path']);
			}
			if (isset($item['prior']) && is_string($item['prior']) && !file_exists($item['path']) && !is_link($item['path'])) {
				symlink($item['prior'], $item['path']);
			}
		}
	}

	private function link_each($src, $destDir, &$undo) {
		if (!is_dir($src)) {
			return true;
		}
		if (!is_dir($destDir) || is_link($destDir)) {
			return false;
		}
		foreach ($this->read_dir($src) as $file) {
			if (!$this->place_link($file['filePath'], $destDir . $file['fileName'], $undo)) {
				return false;
			}
		}
		return true;
	}

	private function place_link($target, $link, &$undo) {
		$prior = null;
		if (is_link($link)) {
			$prior = readlink($link);
			if ($prior === false || !unlink($link)) {
				return false;
			}
		} elseif (file_exists($link)) {
			return false;
		}
		if (!symlink($target, $link)) {
			if ($prior !== null) {
				symlink($prior, $link);
			}
			return false;
		}
		$undo[] = array('path' => $link, 'prior' => $prior, 'created' => true);
		return true;
	}

	public function unlink_module_files($svxlink_name) {
		if (!is_string($svxlink_name) || !preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/', $svxlink_name)) {
			return false;
		}
		if (in_array($svxlink_name, $this->core_modules, true)) {
			return true;
		}
		$pairs = array(
			array($this->modules_path . $svxlink_name . '/svxlink/events.d/', $this->svxlink_events_d_path),
			array($this->modules_path . $svxlink_name . '/svxlink/modules.d/', $this->svxlink_modules_d_path),
		);
		foreach ($pairs as $pair) {
			if (!is_dir($pair[0]) || is_link($pair[0])) {
				continue;
			}
			foreach ($this->read_dir($pair[0]) as $file) {
				$link = $pair[1] . $file['fileName'];
				if (!is_link($link)) {
					continue;
				}
				$target = readlink($link);
				if ($target !== $file['filePath'] || !unlink($link)) {
					return false;
				}
			}
		}
		$sounds = $this->svxlink_sounds . $svxlink_name;
		$expected = $this->modules_path . $svxlink_name . '/svxlink/sounds/en_US';
		if (is_link($sounds)) {
			$target = readlink($sounds);
			if ($target !== $expected && $target !== $expected . '/') {
				return false;
			}
			if (!unlink($sounds)) {
				return false;
			}
		}
		return true;
	}

	private function removeModuleTree($path) {
		$path = rtrim((string) $path, '/');
		if ($path === '' || $path === '.' || is_link(dirname($path))) {
			return false;
		}
		return BenchGuard::removeTreeConfined($path, dirname($path));
	}

	private function writeMemberCapped($zip, $index, $target, $root) {
		$stream = $zip->getStreamIndex($index);
		if (!is_resource($stream)) {
			return false;
		}
		$tmpName = $root . '/.orp-member-' . bin2hex(random_bytes(6));
		$out = fopen($tmpName, 'wb');
		if ($out === false) {
			fclose($stream);
			return false;
		}
		$written = 0;
		while (!feof($stream)) {
			$chunk = fread($stream, 8192);
			if (!is_string($chunk)) {
				fclose($stream);
				fclose($out);
				@unlink($tmpName);
				return false;
			}
			if ($chunk === '') {
				break;
			}
			$written += strlen($chunk);
			if ($written > self::ZIP_MAX_ENTRY) {
				fclose($stream);
				fclose($out);
				@unlink($tmpName);
				return false;
			}
			if (fwrite($out, $chunk) !== strlen($chunk)) {
				fclose($stream);
				fclose($out);
				@unlink($tmpName);
				return false;
			}
		}
		fclose($stream);
		fclose($out);
		if (is_link($tmpName) || !rename($tmpName, $target) || is_link($target)) {
			@unlink($tmpName);
			return false;
		}
		$real = realpath($target);
		if ($real === false || !$this->pathIsInside($root, $real)) {
			@unlink($target);
			return false;
		}
		chmod($target, 0644);
		return true;
	}


	public function install_module($tempModulePath) {
		$error_level = 0;

		# Verify minimum files required exist
		$ini_path = $tempModulePath . 'info.ini';
		$build_config_path = $tempModulePath . 'build_config.php';
		$events_d_path = $tempModulePath . 'svxlink/events.d/';
		$modules_d_path = $tempModulePath . 'svxlink/modules.d/';

		if (!file_exists($ini_path)) { $error_level++; }
		if (!file_exists($build_config_path)) { $error_level++; }
		if (!file_exists($events_d_path)) { $error_level++; }
		if (!file_exists($modules_d_path)) { $error_level++; }

		if ($error_level > 0) {
			$this->removeModuleTree($tempModulePath);
			return false;
		}

		# Read INI and get SVXLink Name
		if (file_exists($ini_path)) {
			$mod_ini_array = parse_ini_file($ini_path, true);
		} else {
		    $error_level++;
		}

		if ( isset($mod_ini_array['Module_Info']['mod_name']) ) {
			$svxlink_name = trim($mod_ini_array['Module_Info']['mod_name']);
			if (!preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/', $svxlink_name) || in_array($svxlink_name, $this->core_modules, true)) {
				$this->removeModuleTree($tempModulePath);
				return false;
			}
			$new_module_path = $this->modules_path . $svxlink_name;
		} else {
			$this->removeModuleTree($tempModulePath);
			return false;			
		}
		
		# Check module doesn't already exist
		if (file_exists($new_module_path)) { $error_level++; }

		if ($error_level > 0) {
			$this->removeModuleTree($tempModulePath);
			return false;
		}
		
		# Move module into place
		rename($tempModulePath, $new_module_path);

		if (!file_exists($new_module_path)) { $error_level++; }

		if ($error_level > 0) {
			$this->removeModuleTree($tempModulePath);
			return false;
		}
		
		# Initiate Install and set module as inactive
		if ($this->initialize_module($svxlink_name, 0) !== true) {
			if (is_dir($new_module_path) && !is_link($new_module_path)) {
				rename($new_module_path, $tempModulePath);
			}
			if (is_dir($tempModulePath)) {
				$this->removeModuleTree($tempModulePath);
			}
			return false;
		}

		# Final Cleanup
		if (file_exists($tempModulePath) || is_link($tempModulePath)) { $this->removeModuleTree($tempModulePath); }
		
		return $mod_ini_array;

	}



	###############################################
	# Remove Module
	###############################################

	public function remove_module($svxlink_name) {
		$svxlink_name = trim($svxlink_name);

		### Prevent Removal of Core Modules ###
		if ( in_array($svxlink_name, $this->core_modules) ) {
			exit("This is a core module and cannot be removed!");
		}

		if ($this->unlink_module_files($svxlink_name) !== true) {
			return array(
				'msgType' => 'error',
				'msgText' => 'There was a problem deleting the module.'
			);
		}

		### Remove module dir ###
		
		$this->removeModuleTree($this->modules_path . $svxlink_name);
		if ( !file_exists( $this->modules_path . $svxlink_name ) ) {

		### Remove GPIO pins if module uses them ###
		$this->delete_gpios($svxlink_name);

		### Remove DB record in modules table ###

		$sql = 'DELETE FROM "modules" WHERE svxlinkName = "' . $svxlink_name . '";';
		$delete_result = $this->Database->delete_row($sql);
			if ($delete_result) { 
				$this->Database->set_update_flag(true);
				return array(
					'msgType' => 'success',
					'msgText' => 'Successfully deleted the module.'
				);
			} else {
				return array(
					'msgType' => 'error',
					'msgText' => 'There was a problem fully deleting the module.'
				);
			}
		} else {
			return array(
				'msgType' => 'error',
				'msgText' => 'There was a problem deleting the module.'
			);
		}
		
	}



	###############################################
	# Display All Modules
	###############################################

	public function display_all() {
		$modules = $this->get_modules();

		$return_html = '
		<table class="table table-striped">
			<thead>
				<tr>
					<th><div style="width:200px">Module</div></th>
					<th>Description</th>
				</tr>
			</thead>
			
			<tbody>
			';

		foreach($modules as $cur_mod) { 
			$mod_ini_file = $this->modules_path.$cur_mod['svxlinkName'].'/info.ini';
			$mod_settings_file = $this->modules_path.$cur_mod['svxlinkName'].'/settings.php';
			$dtmf_help_file = $this->modules_path.$cur_mod['svxlinkName'].'/dtmf.php';

			$curr_mod_ini = $this->read_ini($cur_mod['svxlinkName']);

			if (isset($curr_mod_ini['Module_Info']['display_name'])) {
				$currDisplayName = $curr_mod_ini['Module_Info']['display_name'];
			} else {
			    $currDisplayName = $cur_mod['svxlinkName'];
			}

			$return_html .= '
			<tr>
				<td>
					<div><h3>' . $currDisplayName . ' (' . $cur_mod['svxlinkID'] .'#)</h3></div>
 					<div>';
 			
 			if ($cur_mod['moduleEnabled']==1) { 
	 			$return_html .= '<span class="label-success label label-default">Active</span>';
	 		} else {
		 		$return_html .= '<span class="label-default label">Inactive</span>';
		 	}
			
			$return_html .= '</div><div>';
			
			// Activate / Deactiveate Link
			if ($cur_mod['moduleEnabled']==1) {
				$return_html .= '<a href="?deactivate='.$cur_mod['moduleKey'].'">Deactivate</a>';
			} else {
				$return_html .= '<a href="?activate='.$cur_mod['moduleKey'].'">Activate</a>';													
			}

			// Settings Link...if Applicable
			if ($cur_mod['moduleEnabled']==1 && file_exists($mod_settings_file)) {
				$return_html .= ' | <a href="modules.php?settings='.$cur_mod['moduleKey'].'">Settings</a>';
			}

			// Delete Link...if not core module			
			if ( $cur_mod['moduleEnabled']==0 && !in_array($cur_mod['svxlinkName'], $this->core_modules) ) {
				$return_html .= ' | <a href="#" data-toggle="modal" data-target="#deleteModule" onclick="deleteModule(\'' . $cur_mod['svxlinkName'] . '\',\'' . $currDisplayName . '\'); return false;">Delete</a>';
			}

			// DTMF Link...if Applicable
			if ($cur_mod['moduleEnabled']==1 && file_exists($dtmf_help_file)) {
				$return_html .= ' | <a href="dtmf.php#'.$cur_mod['svxlinkName'].'">DTMF</a>';
			}

			$return_html .= '</div></td><td>';
			
			if (isset($curr_mod_ini['Module_Info']['mod_desc'])) {
				$return_html .= $curr_mod_ini['Module_Info']['mod_desc'];
			} else {
			    $return_html .= "<em>(No Description)</em>";
			}

			// Version / Author Info
			if ( isset($curr_mod_ini['Module_Info']['version']) || isset($curr_mod_ini['Module_Info']['authors']) ) { $return_html .= '<br><br>'; }
			if (isset($curr_mod_ini['Module_Info']['version'])) { $return_html .= 'Version: ' . $curr_mod_ini['Module_Info']['version'] . '&nbsp;&nbsp;&nbsp;'; }
			if (isset($curr_mod_ini['Module_Info']['version'])) { $return_html .= 'Authors: ' . $curr_mod_ini['Module_Info']['authors']; }


			$return_html .= '</td></tr>';

		} /* End Current Module */

		$return_html .= '</tbody></table>';
		
		return $return_html;	
	}



	###############################################
	# Display Module Settings Page
	###############################################

	public function display_settings($id) {
		$modules = $this->get_modules();

		// If modules settings page is request, display that if it exist
		$mod_settings_file = $this->modules_path . $modules[$id]['svxlinkName'] . '/settings.php';
		if (file_exists($mod_settings_file)) {
			$mod_ini = $this->read_ini($modules[$id]['svxlinkName']);

			if (isset($mod_ini['Module_Info']['display_name'])) {
				$displayName = $mod_ini['Module_Info']['display_name'];
			} else {
			    $displayName = $modules[$id]['svxlinkName'];
			}

			// Modules Includes: CSS & JS (if they exist)
			$mod_css_file = $this->modules_path . $modules[$id]['svxlinkName'] . '/module.css';
			$mod_js_file = $this->modules_path . $modules[$id]['svxlinkName'] . '/module.js';
			if (file_exists($mod_css_file)) { $moduleCSS = '/modules/' . $modules[$id]['svxlinkName'] . '/module.css'; }
			if (file_exists($mod_js_file)) { $moduleJS = '/modules/' . $modules[$id]['svxlinkName'] . '/module.js'; }

			$moduleSettings = $this->get_module_settings($id);

			// Construct Page Title
			$pageTitle = $displayName . " Module Settings";

			// Built Top of Form
			$form_top = '
			<form class="form-inline" role="form" action="' . htmlspecialchars($_SERVER["PHP_SELF"]) . '" method="post" id="moduleSettingsUpdate">

			<div class="row-fluid sortable">
				<div class="box span12">
					<div class="box-header well" data-original-title>
						<h2>' . $displayName . ' Module Settings</h2>
					</div>
					<div class="box-content">
			';

			// Built Bottom of Form
			$form_bottom = '
						<div class="form-actions">
						  <!-- PASS MODULE KEY FOR UPDATE DATABASE AND REDIRECT BACK TO SETTINGS PAGE -->
						  <input type="hidden" name="moduleKey" value="' . $id . '">
						  <input type="hidden" name="updateModuleSettings">		
						  <input type="submit">
						</div>
				
					</div>
				</div><!--/span-->
			</div><!--/row-->
			</form>			
			';

			// ***************************************************************** //
			// Construct Page Content
			ob_start();
			include($this->includes_path . 'header.php');
			echo $form_top;
			include($mod_settings_file);
			echo $form_bottom;
			include($this->includes_path . 'footer.php');
			$moduleHTML = ob_get_clean();
			// ***************************************************************** //

			return $moduleHTML;

		} else {
			// Construct Page Title
			$pageTitle = "Modules";

			// Construct Page Content
			ob_start(); include($this->includes_path . 'header.php'); $moduleHTML = ob_get_clean();
		    $moduleHTML .= "<h2>No Settings Page found.</h2>";
			ob_start(); include($this->includes_path . 'footer.php'); $moduleHTML .= ob_get_clean();

			return $moduleHTML;
		}

	}



	###############################################
	# Display Nav Settings Links
	###############################################

	public function nav_setting_links() {

		$modules = $this->get_modules();
		
		$modulesActive = array();
		foreach($modules as $cur_mod) { 
			if ($cur_mod['moduleEnabled']==1) {
				$curr_mod_ini = $this->read_ini($cur_mod['svxlinkName']);
				if (isset($curr_mod_ini['Module_Info']['display_name'])) {
					$currDisplayName = $curr_mod_ini['Module_Info']['display_name'];
				} else {
				    $currDisplayName = $cur_mod['svxlinkName'];
				}

				$module_settings_file = $this->modules_path . $cur_mod['svxlinkName'] . '/settings.php';
				if (file_exists($module_settings_file)) {
					$modulesActive[$cur_mod['moduleKey']] = $currDisplayName;
				}
			} 
		}

		if (!empty($modulesActive)) {
			// Render Parent and Child menus
			$return_html = '<li><a class="ajax-link" href="modules.php"><i class="icon-align-justify"></i><span class="hidden-tablet"> Modules</span></a>';
			$return_html .= ' <ul class="nav nav-pills nav-stacked">';
			foreach ($modulesActive as $mod_id => $mod_name) {
				$return_html .= '<li><a href="modules.php?settings='.$mod_id.'">&nbsp;&nbsp;&nbsp;<i class="icon-chevron-right"></i><span class="hidden-tablet"> '.$mod_name.'</span></a></li>';
			}
			$return_html .= '  </ul>';
			$return_html .= '</li>';
		} else {
			// Render Parent menu only
			$return_html = '<li><a class="ajax-link" href="modules.php"><i class="icon-align-justify"></i><span class="hidden-tablet"> Modules</span></a></li>';
		}
		
		echo $return_html;
	}



	###############################################
	# Display DTMF Codes
	###############################################

	public function display_dtmf_codes() {
		$modules = $this->get_modules();
		$return_html = '';
		if ($modules) {
			foreach($modules as $cur_mod_loop) {
				$currDisplayName = '';
				if ($cur_mod_loop['moduleEnabled']==1) { 
					$curr_mod_ini = $this->read_ini($cur_mod_loop['svxlinkName']);

					if (isset($curr_mod_ini['Module_Info']['display_name'])) {
						$currDisplayName = $curr_mod_ini['Module_Info']['display_name'];
					} else {
					    $currDisplayName = $cur_mod_loop['svxlinkName'];
					}

					$return_html .= '<a name="' . $cur_mod_loop['svxlinkName'] . '"></a>';			
					$return_html .= '<legend>' . $cur_mod_loop['svxlinkID'] . '# - ' . $currDisplayName . ' Module</legend>
					<p>Pressing ' . $cur_mod_loop['svxlinkID'] . '# will enable the ' . $currDisplayName . ' module.</p>';
			
					$dtmf_help_file = $this->modules_path . $cur_mod_loop['svxlinkName'] . '/dtmf.php';
					include($dtmf_help_file);
					if ($cur_mod_loop['moduleEnabled']==1 && file_exists($dtmf_help_file)) {
						$return_html .= '<h4>Sub Commands:</h4>
						<pre>'.$sub_subcommands.'</pre>
						<br>';
					}
				}
			} /* End Current Module */
		}
		
		return $return_html;
	}



	###############################################
	# Read Module INI
	###############################################

	public function read_ini($svxlink_name) {
		$ini_path = $this->modules_path . $svxlink_name . '/info.ini';
		
		if (file_exists($ini_path)) {
			$mod_ini_array = parse_ini_file($ini_path, true);
			return $mod_ini_array;
		} else {
		    return false;
		}

	}



	###############################################
	# Get Next SVXLink ID Number
	###############################################

	public function find_next_svxlink_id() {
		$maxID = 99;

		$sql = 'SELECT * FROM "modules";';
		$existingIDs = $this->Database->select_key_value($sql, 'svxlinkName', 'svxlinkID');

		$x = 1; 
		while( !isset($nextNumber) && $maxID >= $x ) {
		    if (!in_array($x,$existingIDs)) {
			    $nextNumber = $x;
				return $nextNumber;
		    }
		    $x++;
		}
		
	}



	###############################################
	# Update Module GPIO Pins
	###############################################

	private function update_gpios($gpio_type, $gpio_array) {
		// Purge all GPIO Pins for this TYPE
		$sql = 'DELETE FROM "gpio_pins" WHERE type = "'.$gpio_type.'";';
		$delete_result = $this->Database->delete_row($sql);

		// Loop through provided array and set new GPIO Pins
		foreach($gpio_array as $curr_GPIO) {	
			$sql = 'INSERT INTO "gpio_pins" ("gpio_num","direction","active","description","type") VALUES ("'.$curr_GPIO['gpio_num'].'","'.$curr_GPIO['direction'].'","'.$curr_GPIO['active'].'","'.$curr_GPIO['description'].'","'.$gpio_type.'");';;
			$insert_result = $this->Database->insert($sql);
		}
	}


	private function delete_gpios($gpio_type) {
		// Purge all GPIO Pins for this TYPE
		$sql = 'DELETE FROM "gpio_pins" WHERE type = "'.$gpio_type.'";';
		$delete_result = $this->Database->delete_row($sql);
	}



	###############################################
	# Read Directory and Generate Paths to Files
	###############################################

	const ZIP_MAX_ARCHIVE = 8388608;
	const ZIP_MAX_ENTRIES = 500;
	const ZIP_MAX_ENTRY = 8388608;
	const ZIP_MAX_TOTAL = 33554432;

	private function zipEntrySkipped($name) {
		return $name === '__MACOSX' || (is_string($name) && strpos($name, '__MACOSX/') === 0);
	}

	private function zipEntryAllowed($name, $stat) {
		if (!is_string($name) || $name === '' || strlen($name) > 240) {
			return false;
		}
		if (strpos($name, "\0") !== false || strpos($name, '\\') !== false || strpos($name, ':') !== false) {
			return false;
		}
		if ($name[0] === '/' || $name[0] === '.') {
			return false;
		}
		$trimmed = rtrim($name, '/');
		if ($trimmed === '' || strpos($trimmed, '//') !== false) {
			return false;
		}
		$parts = explode('/', $trimmed);
		if (count($parts) > 8) {
			return false;
		}
		foreach ($parts as $part) {
			if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$/', $part)) {
				return false;
			}
		}
		$attr = isset($stat['external_attributes']) ? (int) $stat['external_attributes'] : 0;
		$mode = ($attr >> 16) & 0170000;
		if ($mode === 0120000) {
			return false;
		}
		$uncompressed = isset($stat['size']) ? (int) $stat['size'] : -1;
		$compressed = isset($stat['comp_size']) ? (int) $stat['comp_size'] : 0;
		if ($uncompressed < 0 || $uncompressed > self::ZIP_MAX_ENTRY) {
			return false;
		}
		if ($compressed < 0 || $compressed > self::ZIP_MAX_ARCHIVE) {
			return false;
		}
		if ($compressed > 0 && $uncompressed > ($compressed * 100)) {
			return false;
		}
		if ($compressed === 0 && $uncompressed > 1048576) {
			return false;
		}
		if (!empty($stat['encryption_method'])) {
			return false;
		}
		return true;
	}

	private function pathIsInside($root, $path) {
		$root = rtrim($root, '/');
		$path = rtrim($path, '/');
		return $path === $root || strpos($path, $root . '/') === 0;
	}

	private function mkdirInside($root, $relative) {
		$relative = trim($relative, '/');
		if ($relative === '' || $relative === '.') {
			return $this->pathIsInside($root, $root);
		}
		$current = $root;
		foreach (explode('/', $relative) as $part) {
			if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$/', $part)) {
				return false;
			}
			$next = $current . '/' . $part;
			if (is_link($next)) {
				return false;
			}
			if (!is_dir($next) && !mkdir($next, 0755) && !is_dir($next)) {
				return false;
			}
			if (is_link($next)) {
				return false;
			}
			$real = realpath($next);
			if ($real === false || !$this->pathIsInside($root, $real)) {
				return false;
			}
			$current = $real;
		}
		return true;
	}

	private function flattenSingleFolder($root) {
		$list = scandir($root);
		if (!is_array($list)) {
			return false;
		}
		$dirs = array();
		$files = 0;
		foreach ($list as $name) {
			if ($name === '.' || $name === '..') {
				continue;
			}
			$path = $root . '/' . $name;
			if (is_link($path)) {
				return false;
			}
			if (is_dir($path)) {
				$dirs[] = $name;
			} else {
				$files++;
			}
		}
		if (count($dirs) !== 1 || $files !== 0) {
			return true;
		}
		$sub = $root . '/' . $dirs[0];
		$children = scandir($sub);
		if (!is_array($children)) {
			return false;
		}
		foreach ($children as $child) {
			if ($child === '.' || $child === '..') {
				continue;
			}
			$from = $sub . '/' . $child;
			$to = $root . '/' . $child;
			if (is_link($from) || file_exists($to) || is_link($to)) {
				return false;
			}
			if (!rename($from, $to)) {
				return false;
			}
		}
		return rmdir($sub);
	}

	private function discardUploadedArchive($path) {
		if (is_string($path) && is_file($path) && !is_link($path)) {
			unlink($path);
		}
	}

	private function discardChildren($dir, $root) {
		if (!is_string($dir) || is_link($dir) || !is_dir($dir)) {
			return;
		}
		$real = realpath($dir);
		if ($real === false || !$this->pathIsInside($root, $real)) {
			return;
		}
		$list = scandir($real);
		if (!is_array($list)) {
			return;
		}
		foreach ($list as $name) {
			if ($name === '.' || $name === '..') {
				continue;
			}
			$path = $real . '/' . $name;
			if (is_link($path)) {
				unlink($path);
				continue;
			}
			if (is_dir($path)) {
				$this->discardChildren($path, $root);
				rmdir($path);
				continue;
			}
			if (is_file($path)) {
				unlink($path);
			}
		}
	}

	private function read_dir($path) {
	
		// Read Files into 1 dimensional array
		if ($handle = opendir($path)) {
				while (false !== ($file = readdir($handle))) {
				if ('.' === $file) continue;
				if ('..' === $file) continue;
				$fileList[] = $file;
			}
			closedir($handle);	
		}
	
		// Build array with full file paths
		foreach($fileList as $fileName) {	
			$filePath = $path . $fileName;
			$filesArray[] = array('fileName' => $fileName, 'filePath' => $filePath);	
		}

		return $filesArray;
	}



	###############################################
	# Non-Core Modules
	###############################################

	public function get_non_core_modules_path() {	
		$mod_folder_list  = glob($this->modules_path."*", GLOB_ONLYDIR);
		foreach($mod_folder_list as $currPath) {
			if (!in_array(basename($currPath), $this->core_modules)) {
				$addon_modules[basename($currPath)] = $currPath;
			}
		}
		
		if(isset($addon_modules)) {
			return $addon_modules;		
		} else {
			return NULL;
		}
	}


}