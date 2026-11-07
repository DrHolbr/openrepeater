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
		// One SQLite commit is atomic for the four tables. Directory replacement
		// is a separate rename. The mixer is applied only after both succeed and
		// is not undone. The recovery note lists destination and stash paths for
		// a person. This program does not replay that note.
		if ($this->marker_path() === false) {
			return $this->restore_unchanged();
		}
		if ($this->marker_occupied()) {
			return $this->restore_needs_recovery('A recovery note is already present and was not replaced.');
		}
		$sql_file = $this->backup_restore_dir . $this->backup_db_file;
		$rows = $this->Database->load_backup_rows($this->db_tables, $sql_file);
		if ($rows === false) {
			return $this->restore_unchanged();
		}
		$staged = $this->stage_restore_files();
		if ($staged === false) {
			return $this->restore_unchanged();
		}
		if (!$this->write_recovery_manifest($staged['moves'])) {
			$this->remove_private_stages($staged['stages']);
			return $this->restore_unchanged();
		}
		$published = $this->publish_staged_trees($staged['moves']);
		if ($published['ok'] !== true) {
			$this->remove_private_stages($staged['stages']);
			if ($published['rolled_back'] === true) {
				$this->clear_recovery_manifest();
				return $this->restore_unchanged();
			}
			return $this->restore_needs_recovery('A file tree could not be put back after a failed publish.');
		}
		if (!$this->update_recovery_phase($staged['moves'], 'files-published')) {
			return $this->restore_needs_recovery('The recovery note could not be updated after the file publish. It still lists each destination and stash.');
		}
		if ($this->Database->replace_backup_tables($this->db_tables, $rows) !== true) {
			if ($this->undo_published($published['done']) === true) {
				$this->remove_private_stages($staged['stages']);
				$this->clear_recovery_manifest();
				return $this->restore_unchanged();
			}
			return $this->restore_needs_recovery('The database transaction rolled back, but a file tree could not be put back.');
		}
		$this->discard_published_stashes($published['done']);
		$this->remove_private_stages($staged['stages']);
		$this->clear_recovery_manifest();
		$this->Database->set_update_flag(true);
		if (!$this->restore_alsa()) {
			return array(
				'msgType' => 'error',
				'msgText' => 'The backup database and files were restored. The mixer state was not applied and is not part of that restore.'
			);
		}
		$this->removeDirectory($this->backup_restore_dir);
		return array(
			'msgType' => 'success',
			'msgText' => 'Backup was successfully restored.'
		);
	}

	private function recovery_manifest() {
		$path = $this->marker_path();
		return is_string($path) ? $path : $this->backupPath . 'restore-recovery.json';
	}

	private function marker_path() {
		$anchor = $this->real_anchor(rtrim($this->backupPath, '/'));
		if ($anchor === false) {
			return false;
		}
		return $anchor . '/restore-recovery.json';
	}

	private function marker_occupied() {
		$path = $this->marker_path();
		if ($path === false) {
			return true;
		}
		return @lstat($path) !== false;
	}

	private function restore_unchanged() {
		return array(
			'msgType' => 'error',
			'msgText' => 'The backup was not restored. The previous database rows and files were left unchanged.'
		);
	}

	private function restore_needs_recovery($reason) {
		$path = $this->marker_path();
		$where = is_string($path) ? ' Recovery notes were kept at ' . $path . '.' : '';
		return array(
			'msgType' => 'error',
			'msgText' => 'The backup restore needs recovery. ' . $reason . $where . ' The backup archive was not deleted. These notes are not an automated recovery.'
		);
	}

	private function write_recovery_manifest($moves) {
		return $this->exclusive_marker_create($this->marker_note($moves, 'ready'));
	}

	private function update_recovery_phase($moves, $phase) {
		if (getenv('ORP_RESTORE_FAULT') === 'marker-update') {
			return false;
		}
		$encoded = $this->marker_note($moves, $phase);
		if ($encoded === false) {
			return false;
		}
		return $this->replace_regular_marker($encoded);
	}

	private function marker_note($moves, $phase) {
		$encoded = json_encode(array(
			'phase' => $phase,
			'automated_recovery' => false,
			'crash_atomic' => false,
			'moves' => $moves,
		));
		return is_string($encoded) ? $encoded : false;
	}

	private function exclusive_marker_create($bytes) {
		$path = $this->marker_path();
		if ($path === false || !is_string($bytes) || $this->marker_occupied()) {
			return false;
		}
		return $this->exclusive_nofollow_write($path, $bytes);
	}

	private function replace_regular_marker($bytes) {
		$path = $this->marker_path();
		if ($path === false || !is_string($bytes)) {
			return false;
		}
		$current = @lstat($path);
		if ($current === false || !$this->is_regular_mode($current['mode'])) {
			return false;
		}
		$tmp = dirname($path) . '/.restore-recovery-' . bin2hex(random_bytes(6)) . '.tmp';
		if (!$this->exclusive_nofollow_write($tmp, $bytes)) {
			return false;
		}
		if (@lstat($path) === false || !$this->is_regular_mode(lstat($path)['mode']) || !rename($tmp, $path)) {
			$this->unlink_regular($tmp);
			return false;
		}
		$after = @lstat($path);
		return $after !== false && $this->is_regular_mode($after['mode']) && (int) $after['size'] === strlen($bytes);
	}

	private function exclusive_nofollow_write($path, $bytes) {
		if (@lstat($path) !== false) {
			return false;
		}
		// PHP fopen mode x follows a dangling symlink and creates the target.
		// Python os.open with O_NOFOLLOW|O_EXCL does not. The web SAPI disables FFI.
		$script = <<<'PY'
import os, sys
path = sys.stdin.buffer.readline()[:-1].decode()
data = sys.stdin.buffer.read()
flags = os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_WRONLY | getattr(os, "O_CLOEXEC", 0)
fd = os.open(path, flags, 0o600)
try:
    view = memoryview(data)
    off = 0
    while off < len(view):
        wrote = os.write(fd, view[off:])
        if wrote <= 0:
            raise OSError("short write")
        off += wrote
    os.fsync(fd)
    os.fchmod(fd, 0o600)
finally:
    os.close(fd)
PY;
		$script = implode("\n", array_map(function ($line) {
			return ltrim($line, "\t");
		}, explode("\n", $script)));
		$proc = proc_open('python3 -c ' . escapeshellarg($script), array(0 => array('pipe', 'r'), 1 => array('pipe', 'w'), 2 => array('pipe', 'w')), $pipes);
		if (!is_resource($proc)) {
			return false;
		}
		fwrite($pipes[0], $path . "\n" . $bytes);
		fclose($pipes[0]);
		fclose($pipes[1]);
		fclose($pipes[2]);
		$rc = proc_close($proc);
		$st = @lstat($path);
		if ($rc !== 0 || $st === false || !$this->is_regular_mode($st['mode']) || (int) $st['size'] !== strlen($bytes)) {
			$this->unlink_regular($path);
			return false;
		}
		return true;
	}

	private function is_regular_mode($mode) {
		return ((int) $mode & 0170000) === 0100000;
	}

	private function unlink_regular($path) {
		$st = @lstat($path);
		if ($st !== false && $this->is_regular_mode($st['mode'])) {
			unlink($path);
		}
	}

	private function clear_recovery_manifest() {
		$path = $this->marker_path();
		if (is_string($path)) {
			$this->unlink_regular($path);
		}
	}

	private function stage_restore_files() {
		$sounds = $this->real_anchor(rtrim($this->orp_sounds_dir, '/'));
		$modules = $this->real_anchor(rtrim($this->Modules->modules_path, '/'));
		$restore = $this->real_anchor(rtrim($this->backup_restore_dir, '/'));
		if ($sounds === false || $modules === false || $restore === false) {
			return false;
		}
		$stageId = bin2hex(random_bytes(6));
		$soundsStage = $sounds . '/.orp-stage-' . $stageId;
		$modulesStage = $modules . '/.orp-stage-' . $stageId;
		$stages = array();
		$moves = array();
		foreach (array('courtesy_tones', 'identification') as $name) {
			$incoming = $restore . '/' . $name;
			if (!file_exists($incoming)) {
				continue;
			}
			$live = $this->anchored_child($sounds, $name);
			if ($live === false || !$this->stage_one_tree($incoming, $soundsStage, $name, $stages)) {
				$this->remove_private_stages($stages);
				return false;
			}
			$stash = $this->plan_stash($live);
			if ($stash === false) {
				$this->remove_private_stages($stages);
				return false;
			}
			$moves[] = array('destination' => $live, 'live' => $live, 'staged' => $soundsStage . '/' . $name, 'stash' => $stash, 'links' => null);
		}
		$moduleRoot = $restore . '/modules';
		if (is_dir($moduleRoot) && !is_link($moduleRoot)) {
			$existing = $this->Modules->get_non_core_modules_path();
			if (is_array($existing)) {
				foreach ($existing as $mod_name => $mod_path) {
					$live = $this->anchored_child($modules, $mod_name);
					if ($live === false) {
						$this->remove_private_stages($stages);
						return false;
					}
					$stash = $this->plan_stash($live);
					if ($stash === false) {
						$this->remove_private_stages($stages);
						return false;
					}
					$moves[] = array('destination' => $live, 'live' => $live, 'staged' => null, 'stash' => $stash, 'links' => null);
				}
			}
			$incoming = glob($moduleRoot . '/*', GLOB_ONLYDIR);
			if ($incoming === false) {
				$this->remove_private_stages($stages);
				return false;
			}
			foreach ($incoming as $mod_path) {
				$mod_name = basename($mod_path);
				$live = $this->anchored_child($modules, $mod_name);
				if ($live === false || is_link($mod_path) || !$this->stage_one_tree($mod_path, $modulesStage, $mod_name, $stages)) {
					$this->remove_private_stages($stages);
					return false;
				}
				$stash = $this->plan_stash($live);
				if ($stash === false) {
					$this->remove_private_stages($stages);
					return false;
				}
				$moves[] = array('destination' => $live, 'live' => $live, 'staged' => $modulesStage . '/' . $mod_name, 'stash' => $stash, 'links' => $mod_name);
			}
		}
		return array('moves' => $moves, 'stages' => $stages);
	}

	private function stage_one_tree($incoming, $stageRoot, $name, &$stages) {
		if (!is_dir($incoming) || is_link($incoming) || $this->tree_has_link($incoming)) {
			return false;
		}
		if (!in_array($stageRoot, $stages, true)) {
			if (!mkdir($stageRoot, 0700) || is_link($stageRoot)) {
				return false;
			}
			$stages[] = $stageRoot;
		}
		$dest = $stageRoot . '/' . $name;
		exec('cp -a ' . escapeshellarg($incoming) . ' ' . escapeshellarg($dest), $unused, $rc);
		if ($rc !== 0 || !is_dir($dest) || is_link($dest) || $this->tree_has_link($dest)) {
			return false;
		}
		return true;
	}

	private function publish_staged_trees($moves) {
		$done = array();
		foreach ($moves as $move) {
			$live = $move['destination'];
			$stash = $move['stash'];
			if (file_exists($live)) {
				if (!is_string($stash) || is_link($live) || @lstat($stash) !== false || !rename($live, $stash)) {
					return array('ok' => false, 'rolled_back' => $this->undo_published($done), 'done' => $done);
				}
				if (getenv('ORP_RESTORE_FAULT') === 'publish-collision' && count($done) === 0) {
					mkdir($live, 0755);
					file_put_contents($live . '/collision', 'occupied');
				}
			}
			if (is_string($move['staged'])) {
				if (!rename($move['staged'], $live)) {
					$rolled = $this->undo_published($done) && $this->restore_unmoved($live, $stash);
					return array('ok' => false, 'rolled_back' => $rolled, 'done' => $done);
				}
			}
			$links = null;
			if (is_string($move['links'])) {
				$links = $this->Modules->link_module_files($move['links']);
				if ($links === false) {
					$done[] = array('live' => $live, 'stash' => $stash, 'links' => null);
					return array('ok' => false, 'rolled_back' => $this->undo_published($done), 'done' => $done);
				}
			}
			$done[] = array('live' => $live, 'stash' => $stash, 'links' => $links);
		}
		return array('ok' => true, 'rolled_back' => true, 'done' => $done);
	}

	private function plan_stash($live) {
		if (!file_exists($live)) {
			return null;
		}
		if (is_link($live)) {
			return false;
		}
		for ($i = 0; $i < 5; $i++) {
			$stash = dirname($live) . '/.orp-stash-' . bin2hex(random_bytes(6));
			if (@lstat($stash) === false) {
				return $stash;
			}
		}
		return false;
	}

	private function restore_unmoved($live, $stash) {
		if (!is_string($stash) || !file_exists($stash)) {
			return !file_exists($live);
		}
		if (file_exists($live)) {
			return false;
		}
		return rename($stash, $live);
	}

	private function undo_published($done) {
		if (!is_array($done)) {
			return false;
		}
		for ($i = count($done) - 1; $i >= 0; $i--) {
			$item = $done[$i];
			if (isset($item['links']) && is_array($item['links'])) {
				$this->Modules->undo_module_links($item['links']);
			}
			if (file_exists($item['live'])) {
				$discard = $item['live'] . '.orp-discard-' . bin2hex(random_bytes(4));
				if (!rename($item['live'], $discard)) {
					return false;
				}
				if (is_dir($discard) && !is_link($discard)) {
					exec('rm -R ' . escapeshellarg($discard), $unused, $rc);
				}
			}
			if (is_string($item['stash']) && file_exists($item['stash'])) {
				if (!rename($item['stash'], $item['live'])) {
					return false;
				}
			}
		}
		return true;
	}

	private function discard_published_stashes($done) {
		if (!is_array($done)) {
			return;
		}
		foreach ($done as $item) {
			if (isset($item['stash']) && is_string($item['stash']) && file_exists($item['stash']) && !is_link($item['stash'])) {
				exec('rm -R ' . escapeshellarg($item['stash']), $unused, $rc);
			}
		}
	}

	private function remove_private_stages($stages) {
		if (!is_array($stages)) {
			return;
		}
		foreach ($stages as $stage) {
			if (is_string($stage) && is_dir($stage) && !is_link($stage)) {
				exec('rm -R ' . escapeshellarg($stage), $unused, $rc);
			}
		}
	}

	private function real_anchor($path) {
		if (!is_string($path) || $path === '' || $path[0] !== '/' || strpos($path, '..') !== false) {
			return false;
		}
		$path = rtrim($path, '/');
		$built = '';
		foreach (explode('/', $path) as $part) {
			if ($part === '') {
				continue;
			}
			$built .= '/' . $part;
			if (is_link($built) || !is_dir($built)) {
				return false;
			}
		}
		$real = realpath($path);
		if ($real === false || $real !== $path) {
			return false;
		}
		return $real;
	}

	private function anchored_child($anchor, $name) {
		if (!is_string($name) || !preg_match('/^[A-Za-z0-9][A-Za-z0-9_.-]{0,64}$/', $name)) {
			return false;
		}
		$live = $anchor . '/' . $name;
		if (is_link($live)) {
			return false;
		}
		if (file_exists($live)) {
			$real = realpath($live);
			if ($real !== $live) {
				return false;
			}
		}
		return $live;
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

	private function restore_alsa() {
		if (getenv('ORP_RESTORE_FAULT') === 'alsa-fail') {
			return false;
		}
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