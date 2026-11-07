<?php
#####################################################################################################
# Backup & Restore Class
#####################################################################################################

class BackupRestore {

	private $dateString;
	private $callsign;
	private $orp_version;
	
	private $backupPath = "/var/www/openrepeater/backup/";
 	private $baseDownloadPath = '/backup/'; // This will get read and rewritten in construct below
	private $archive_base_name;
	private $backup_file_name;
	private $archive_build_dir;
	private $backup_restore_dir;
	private $backup_db_file = 'backup.sql';
	private $db_tables = ['settings','gpio_pins','ports','modules'];
	private $backup_ini_file = 'backup.ini';
	private $alsa_state_file = 'alsamixer.state';
	private $orp_sounds_dir = '/var/www/openrepeater/sounds/';
	
	private $Database;
	private $Modules;


	public function __construct() {
		$this->Database = new Database();
		$this->Modules = new Modules();
		$backupOverride = getenv('ORP_BACKUP_PATH');
		if (is_string($backupOverride) && $backupOverride !== '' && $backupOverride[0] === '/'
			&& strpos($backupOverride, '..') === false && is_dir($backupOverride) && !is_link($backupOverride)) {
			$this->backupPath = rtrim($backupOverride, '/') . '/';
		}
		$soundsOverride = getenv('ORP_SOUNDS_PATH');
		if (is_string($soundsOverride) && $soundsOverride !== '' && $soundsOverride[0] === '/'
			&& strpos($soundsOverride, '..') === false && is_dir($soundsOverride) && !is_link($soundsOverride)) {
			$this->orp_sounds_dir = rtrim($soundsOverride, '/') . '/';
		}

		$this->dateString = date('Y/m/d H:i:s');

		$this->callsign = $this->Database->get_settings('callSign');
		$this->orp_version = $this->Database->get_version();

		$this->archive_build_dir = $this->backupPath . 'build/';
		$this->backup_restore_dir = $this->backupPath . 'restore/';

		$this->archive_base_name = strtolower($this->callsign) . date( "_Y-m-d_H-i-s", strtotime( $this->dateString ) );

		// Construct base download url
		$path = $this->baseDownloadPath; // Read starting path
		$protocol = empty($_SERVER['HTTPS']) ? 'http' : 'https';
		$this->baseDownloadPath = $protocol .'://' . $_SERVER['HTTP_HOST'] . $path; // Rewrite as full url

	}



	###############################################
	# Create Backup
	###############################################

	public function create_backup() {
		// Create build directory if it doesn't exist
		if (!file_exists($this->archive_build_dir)) {
		    mkdir($this->archive_build_dir, 0777, true);
		}

		// Create INI file with basic info
		$this->write_ini( $this->archive_build_dir . $this->backup_ini_file );
		
 		// Dump the sqlite database, specified tables only
		$sql_file = $this->archive_build_dir . $this->backup_db_file;
		if ($this->Database->db_export( $this->db_tables, $sql_file ) !== true) {
			$this->removeDirectory($this->archive_build_dir);
			return array(
				'msgType' => 'error',
				'msgText' => 'The backup was not written. The previous database rows were left unchanged.'
			);
		}

		// Backup of ALSA settings
		exec('sudo orp_helper alsa backup "' . $this->archive_build_dir . $this->alsa_state_file . '"');

		// Add build files to archive, including sounds, then package as ORP file
		$this->build_archive();

		// Clean and remove build folder & contents
		$this->removeDirectory($this->archive_build_dir);

		// Verify Backup File was Created and return results.
		if (file_exists($this->backupPath . $this->backup_file_name)) {
			return array(
				'msgType' => 'success',
				'msgText' => 'Successfully created backup: <strong>' . $this->backup_file_name . '</strong>'
			);	
		} else {
			return array(
				'msgType' => 'error',
				'msgText' => 'There was a problem creating the backup. Please try again. If the problem persists, it may be due to a permissions issue.'
			);				
		}

	}
	
	


	###############################################
	# Restore from Backup
	###############################################

	public function pre_restore_validation($selected_restore_file) {
		if (!is_string($selected_restore_file) || !preg_match('/^[A-Za-z0-9._-]+\.orp$/', $selected_restore_file)) {
			exit('Unable to locate file for restoration');
		}
		$data = [];
		$errorLevel = 0;

		// Check full file path exists before continuing
		if (!file_exists($this->backupPath . $selected_restore_file)) {
			exit('Unable to locate file for restoration');
		}

		// Create Restore directory if it doesn't exist
		if (!file_exists($this->backup_restore_dir)) {
		    mkdir($this->backup_restore_dir, 0777, true);
		} else {
			// OR if it does exist, then remove it recursively and recreate
			$this->removeDirectory($this->backup_restore_dir);
		    mkdir($this->backup_restore_dir, 0777, true);
		}

		// Unpack Backup into Temp Folder
		$this->unpack_archive($this->backupPath . $selected_restore_file);

		// Verify min files exist: DB, INI file
		if (!file_exists($this->backup_restore_dir . $this->backup_ini_file)) { $errorLevel++; }
		if (!file_exists($this->backup_restore_dir . $this->backup_db_file)) { $errorLevel++; }

		if ($errorLevel == 0) {
			$data['status'] = 'ok';

			// Read INI and compare
			$curr_orp_verion = $this->Database->get_version();
			$ini_array = $this->read_ini( $this->backup_restore_dir . $this->backup_ini_file );
			if ($curr_orp_verion == $ini_array['ORP_Backup']['orp_version']) {
				$data['versionMatch'] = true;				
			} else {
				$data['versionMatch'] = false;
			}
			$data['curr_orp_verion'] = $curr_orp_verion;
			$data['backup_orp_verion'] = $ini_array['ORP_Backup']['orp_version'];
			$data['backup_callsign'] = $ini_array['ORP_Backup']['orp_callsign'];
			$data['backup_date'] = date( "F j, Y, g:i a", strtotime( $ini_array['ORP_Backup']['backup_date'] ) );
			
		} else {
	        $data['status'] = 'error';
		}

        $data['errorLevel'] = $errorLevel;

	    //returns data as JSON format
	    echo json_encode($data);		
	}


	public function restore_backup() {
		$sql_file = $this->backup_restore_dir . $this->backup_db_file;
		$rows = $this->Database->load_backup_rows($this->db_tables, $sql_file);
		if ($rows === false) {
			return $this->restore_failed();
		}
		$prior = $this->Database->capture_table_rows($this->db_tables);
		if ($prior === false) {
			return $this->restore_failed();
		}
		$stashes = $this->apply_restore_files();
		if ($stashes === false) {
			return $this->restore_failed();
		}
		if ($this->Database->replace_backup_tables($this->db_tables, $rows) !== true) {
			$this->revert_restore_files($stashes);
			return $this->restore_failed();
		}
		if (!$this->restore_alsa()) {
			$this->Database->replace_backup_tables($this->db_tables, $prior);
			$this->revert_restore_files($stashes);
			return $this->restore_failed();
		}
		$this->discard_restore_stashes($stashes);
		$this->removeDirectory($this->backup_restore_dir);
		$this->Database->set_update_flag(true);
		return array(
			'msgType' => 'success',
			'msgText' => 'Backup was successfully restored.'
		);
	}

	private function restore_failed() {
		return array(
			'msgType' => 'error',
			'msgText' => 'The backup was not restored. The previous database rows were left unchanged.'
		);
	}

	private function apply_restore_files() {
		$stashes = array();
		$trees = array(
			array($this->orp_sounds_dir . 'courtesy_tones', $this->backup_restore_dir . 'courtesy_tones'),
			array($this->orp_sounds_dir . 'identification', $this->backup_restore_dir . 'identification'),
		);
		foreach ($trees as $pair) {
			if (!is_dir($pair[1])) {
				continue;
			}
			$stash = $this->replace_tree($pair[0], $pair[1]);
			if ($stash === false) {
				$this->revert_restore_files($stashes);
				return false;
			}
			$stashes[] = $stash;
		}
		$restore_module_path = $this->backup_restore_dir . 'modules/';
		if (is_dir($restore_module_path)) {
			$existing = $this->Modules->get_non_core_modules_path();
			if (is_array($existing)) {
				foreach ($existing as $mod_name => $mod_path) {
					if (!preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/', $mod_name)) {
						$this->revert_restore_files($stashes);
						return false;
					}
					$held = $this->hold_tree($mod_path);
					if ($held === false) {
						$this->revert_restore_files($stashes);
						return false;
					}
					$stashes[] = $held;
				}
			}
			$incoming = glob($restore_module_path . '*', GLOB_ONLYDIR);
			if ($incoming === false) {
				$this->revert_restore_files($stashes);
				return false;
			}
			foreach ($incoming as $mod_path) {
				$mod_name = basename($mod_path);
				if (!preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/', $mod_name)) {
					$this->revert_restore_files($stashes);
					return false;
				}
				$dest = $this->Modules->modules_path . $mod_name;
				$copied = $this->replace_tree($dest, $mod_path);
				if ($copied === false) {
					$this->revert_restore_files($stashes);
					return false;
				}
				$stashes[] = $copied;
				$linked = $this->Modules->link_module_files($mod_name);
				if ($linked === false) {
					$this->revert_restore_files($stashes);
					return false;
				}
				$stashes[] = array('links' => $linked);
			}
		}
		return $stashes;
	}

	private function replace_tree($live, $incoming) {
		if ($this->tree_has_link($incoming)) {
			return false;
		}
		$held = $this->hold_tree($live);
		if ($held === false) {
			return false;
		}
		if (!$this->copy_tree($incoming, $live)) {
			$this->restore_held($held);
			return false;
		}
		$held['created'] = $live;
		return $held;
	}

	private function hold_tree($live) {
		if (!file_exists($live)) {
			return array('live' => $live, 'stash' => null, 'created' => null);
		}
		if (is_link($live)) {
			return false;
		}
		$stash = dirname($live) . '/.orp-stash-' . bin2hex(random_bytes(6));
		if (!rename($live, $stash)) {
			return false;
		}
		return array('live' => $live, 'stash' => $stash, 'created' => null);
	}

	private function tree_has_link($path) {
		if (is_link($path)) {
			return true;
		}
		if (!is_dir($path)) {
			return false;
		}
		$items = scandir($path);
		if ($items === false) {
			return true;
		}
		foreach ($items as $item) {
			if ($item === '.' || $item === '..') {
				continue;
			}
			if ($this->tree_has_link($path . '/' . $item)) {
				return true;
			}
		}
		return false;
	}

	private function copy_tree($src, $dest) {
		if (!is_dir($src) || is_link($src) || is_link(dirname($dest))) {
			return false;
		}
		exec('cp -a ' . escapeshellarg($src) . ' ' . escapeshellarg($dest), $unused, $rc);
		return $rc === 0 && is_dir($dest) && !is_link($dest);
	}

	private function revert_restore_files($stashes) {
		if (!is_array($stashes)) {
			return;
		}
		for ($i = count($stashes) - 1; $i >= 0; $i--) {
			$item = $stashes[$i];
			if (isset($item['links']) && is_array($item['links'])) {
				$this->Modules->undo_module_links($item['links']);
				continue;
			}
			$this->restore_held($item);
		}
	}

	private function restore_held($held) {
		if (!is_array($held) || !isset($held['live'])) {
			return;
		}
		if (isset($held['created']) && is_string($held['created']) && file_exists($held['created']) && !is_link($held['created'])) {
			exec('rm -R ' . escapeshellarg($held['created']), $unused, $rc);
		}
		if (isset($held['stash']) && is_string($held['stash']) && file_exists($held['stash'])) {
			rename($held['stash'], $held['live']);
		}
	}

	private function discard_restore_stashes($stashes) {
		if (!is_array($stashes)) {
			return;
		}
		foreach ($stashes as $item) {
			if (isset($item['stash']) && is_string($item['stash']) && file_exists($item['stash']) && !is_link($item['stash'])) {
				exec('rm -R ' . escapeshellarg($item['stash']), $unused, $rc);
			}
		}
	}

	private function restore_alsa() {
		$state = $this->backup_restore_dir . $this->alsa_state_file;
		if (!is_file($state) || is_link($state)) {
			return true;
		}
		exec('sudo orp_helper alsa restore ' . escapeshellarg($state), $unused, $rc);
		return $rc === 0;
	}



	###############################################
	# Archive Functions
	###############################################

	public function build_archive() {
		try	{
		    $archive = new PharData($this->archive_build_dir . $this->archive_base_name . '.tar');
		
		    // Add Files/Folders to Archive
		    $archive->addFile($this->archive_build_dir . $this->backup_db_file, $this->backup_db_file); // DB
		    $archive->addFile($this->archive_build_dir . $this->backup_ini_file, $this->backup_ini_file); // INI
			if (file_exists($this->alsa_state_file)) {
				$archive->addFile($this->archive_build_dir . $this->alsa_state_file, $this->alsa_state_file); // alsamixer backup
			}

			$archive->buildFromDirectory($this->orp_sounds_dir); // Sounds


			// Modules (non-core / add-ons)
			$non_core_modules = $this->Modules->get_non_core_modules_path();
			if ( isset($non_core_modules) ) {
				$mod_build_dir = $this->archive_build_dir . 'mod_build/modules';
				if (!file_exists($mod_build_dir)) { mkdir($mod_build_dir, 0777, true); }
	
				foreach($non_core_modules as $mod_name => $mod_path) {
					exec('cp "' . $mod_path . '" "' . $mod_build_dir . '/' . $mod_name . '" -R');			
				}
				$archive->buildFromDirectory($this->archive_build_dir . 'mod_build/');				
			}


		    // Compress Archive
		    $archive->compress(Phar::GZ);
		
			// Remove .tar
		    unlink($this->archive_build_dir . $this->archive_base_name . '.tar');

			// Rename Compressed format with ORP extension
			rename($this->archive_build_dir . $this->archive_base_name . '.tar.gz', $this->backupPath . $this->archive_base_name . '.orp');
			
			// Set file name as variable for verification and display
			$this->backup_file_name = $this->archive_base_name . '.orp';

		} catch (Exception $e) {
		    echo "Exception : " . $e;
		}
	}


	public function unpack_archive($selected_archive) {
		try	{
			// Create restore directory if it doesn't exist
			if (!file_exists($this->backup_restore_dir)) {
			    mkdir($this->backup_restore_dir, 0777, true);
			}

			// Copy ORP package back to .tar.gz extension in restore directory
			copy($selected_archive, $this->backup_restore_dir . $this->archive_base_name . '.tar.gz');

			// Decompress and extract
			$restore = new PharData($this->backup_restore_dir . $this->archive_base_name . '.tar.gz');
			$restore->decompress();

		    $restore = new PharData($this->backup_restore_dir . $this->archive_base_name . '.tar');
		    $restore->extractTo($this->backup_restore_dir); // extract all files

			// Remove .tar.gz and .tar
		    unlink($this->backup_restore_dir . $this->archive_base_name . '.tar.gz');
		    unlink($this->backup_restore_dir . $this->archive_base_name . '.tar');

		} catch (Exception $e) {
		    echo "Exception : " . $e;
		}
	}


	
	###############################################
	# INI File Functions
	###############################################

	public function write_ini($ini_file) {
		$backup_ini_array = [
			'ORP_Backup' => [
				'orp_version' => $this->orp_version,
				'orp_callsign' => $this->callsign,
				'backup_date' => $this->dateString				
			]
		];

		$backup_ini_contents = "; This is the Backup INI file. It provide basic information to OpenRepeater upon restore.\n\n";

		foreach ($backup_ini_array as $section => $properties_array) {
			$backup_ini_contents .= "[" . $section . "]\n";
			foreach ($properties_array as $key => $value) {
				$backup_ini_contents .= $key . " = \"" . $value . "\"\n";
			}
		}
		
		file_put_contents($ini_file,$backup_ini_contents);
	}	


	public function read_ini($ini_file) {
		$backup_ini_array = parse_ini_file($ini_file, true);
		return $backup_ini_array;
	}



	###############################################
	# Upload Backup Files
	###############################################

	public function upload_backup_files($fileNameArray) {

		$maxFileSize = 500000000; // size in bytes
		$allowedExts = array('orp');
	
		//Loop through each file
		for($i=0; $i<count($fileNameArray['name']); $i++) {
			//Get the temp file path
			$tmpFile1 = $fileNameArray['tmp_name'][$i];
			
			$temp_ext = explode(".", $fileNameArray['name'][$i]);
			$extension = end($temp_ext);

			$storedName = str_replace(' ', '_', $fileNameArray['name'][$i]);
			if (!is_string($storedName) || !preg_match('/^[A-Za-z0-9._-]+\.orp$/', $storedName)) {
				return array(
					'msgType' => 'error',
					'msgText' => 'The backup name is not a plain file name. Nothing was written.'
				);
			}
			$currFile = $this->backupPath . $storedName;
			

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
					'msgText' => 'Sorry, but the file you tried to upload is not in a supported format. Files must end with an .orp extension.'
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

			# Check to see if file already exists
			if (file_exists($currFile)) {
				return array(
					'msgType' => 'error',
					'msgText' => 'Sorry but the file already exists.'
				);	
			}


			if ($tmpFile1 != ""){
				move_uploaded_file($tmpFile1, $currFile);

				if (file_exists($currFile)) {
					// SUCCESSFUL
					return array(
						'msgType' => 'success',
						'msgText' => 'Successfully uploaded the backup file to library.'
					);	
					
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
	# Get Local Backed Up Files
	###############################################

	public function get_backup_files() {
	
		$baseURL = (!empty($_SERVER['HTTPS']) ? 'https' : 'http') . '://' . $_SERVER['HTTP_HOST'] . $this->backupPath;
		
		// Read Files into 1 dimensional array
		if ($handle = opendir($this->backupPath)) {
				while (false !== ($file = readdir($handle))) {
				if ('.' === $file) continue;
				if ('..' === $file) continue;
				$fileList[] = $file;
			}
			closedir($handle);	
		}
	
		// Sort and reindex array
		natsort($fileList);
		$fileList = array_values($fileList);
	
		// Write into multidimensional array with clean file labels
		foreach($fileList as $fileName) {	
			$fileLabel = str_replace("_"," ",$fileName); //replace underscores with spaces for file labels
			$fileLabel = preg_replace('/\\.[^.\\s]{2,5}$/', '', $fileLabel); //remove extention
			$downloadURL = $baseURL . $fileName;
// 			$downloadURL = '#';
			$filePath = $this->backupPath . $fileName;
			$fileSize = filesize($filePath);
			$fileDate = filemtime($filePath);
			$filesArray[] = array('fileName' => $fileName, 'fileLabel' => $fileLabel, 'downloadURL' => $downloadURL, 'filePath' => $filePath, 'fileSize' => $fileSize, 'fileDate' => $fileDate);			
		}
	
		return $filesArray;
	}



	###############################################
	# Display Backup Files
	###############################################

	public function display_backup_files() {

		$backupLib = $this->get_backup_files();
		$hidden_array = ['build','restore','.gitignore'];
		$total_dir_size = 0;		
		if ($backupLib) {			
			$displayHTML = '<table class="table table-striped table-condensed bootstrap-datatable">';
			$displayHTML .= '<table class="table table-striped table-condensed bootstrap-datatable">';
			$displayHTML .= '<thead><tr class="audio_row"><th>Name</th><th>Date</th><th>Size</th><th class="button_grp">Actions</th></tr></thead>   
	<tbody>';


			foreach($backupLib as $fileArray) {	
				if (!in_array($fileArray['fileName'], $hidden_array, true)) {
					$total_dir_size = $total_dir_size + $fileArray['fileSize'];
					
					$displayHTML .= '
					<tr id="shortIDsoundRow1" class="audio_row">
						<td><h3>' . $fileArray['fileName'] . '</h3></td>
						
						<td class="center">' . date("F d Y H:i:s",$fileArray['fileDate']) . '</td>
							
						<td class="center">' . $this->formatSize($fileArray['fileSize']) . '</td>

						<td class="button_grp">
						
							<button type="button" class="btn btn-success" data-toggle="modal" data-target="#restoreFile" onclick="restoreFile(\'' . $fileArray['fileName'] . '\'); return false;"><i class="icon-refresh icon-white"></i> Restore</button>
						
							<!-- Button triggered modal -->
							<button class="btn" onclick="location.href=\'' . $this->baseDownloadPath . $fileArray['fileName'] . '\'"><i class="icon-download-alt"></i></button>
			
							<!-- Button triggered modal -->
							<button type="button" class="btn btn-danger" data-toggle="modal" data-target="#deleteFile" onclick="deleteFile(\'' . $fileArray['fileName'] . '\'); return false;"><i class="icon-trash icon-white"></i></button>
						</td>
					</tr>
					';
				}
			}

			$displayHTML .= '</tbody></table>';

			$displayHTML .= 'TOTAL FILE SIZE: ' . $this->formatSize($total_dir_size);
			
			echo $displayHTML;		

		} else {
			echo "no files";
		}

	}



	###############################################
	# Delete Backup
	###############################################

	public function deleteBackup($file) {
		if (!is_string($file) || !preg_match('/^[A-Za-z0-9._-]+\.orp$/', $file)) {
			return array(
				'msgType' => 'error',
				'msgText' => 'The backup name is not a plain file name. Nothing was deleted.'
			);
		}
	    unlink($this->backupPath . $file);

		if (!file_exists($this->backupPath . $file)) {
			return array(
				'msgType' => 'success',
				'msgText' => 'File successfully Deleted.'
			);	
		} else {
			return array(
				'msgType' => 'error',
				'msgText' => 'There was a problem deleting the file. Please try again. If the problem persists, it may be due to a permissions issue.'
			);				
		}
	}



	###############################################
	# Recursively Remove Directory
	###############################################

	// Only removes 2 directories deep
	public function removeDirectory($path) {
/*
		$files = glob($path . '*');
		foreach ($files as $file) {
			if (is_dir($file)) { 
				$subfiles = glob($file . '/*');
				foreach ($subfiles as $subfile) {
					unlink($subfile);
				}
				rmdir($file);
			} else {
				unlink($file);
			}
		}
		rmdir($path);
*/
		exec('rm ' . $path . ' -R');
		return;
	}



	###############################################
	# Delete Backup
	###############################################

	public function is_dir_empty($dir) {
		if (!file_exists($dir)) { return NULL; }
		if (!is_readable($dir)) { return NULL; }
		return (count(scandir($dir)) == 2);
	}



	###############################################
	# Format File Size
	###############################################

	public function formatSize($bytes, $precision = 2) { 
	    $units = array('B', 'KB', 'MB', 'GB', 'TB'); 
	
	    $bytes = max($bytes, 0); 
	    $pow = floor(($bytes ? log($bytes) : 0) / log(1024)); 
	    $pow = min($pow, count($units) - 1); 
	    $bytes /= pow(1024, $pow);
	
	    return round($bytes, $precision) . ' ' . $units[$pow]; 
	}

}