<?php
#####################################################################################################
# Database Class
#####################################################################################################

class Database {

    private $db_loc;


	public function databasePath() {
		return $this->db_loc;
	}

	public function __construct() {
		$override = getenv('ORP_DB_PATH');
		if (is_string($override) && $override !== '') {
			$this->db_loc = $override;
		} else {
			$this->db_loc = '/var/lib/openrepeater/db/openrepeater.db';
		}
	}


	###############################################
	# Run SQL Statements
	###############################################

	// SELECT ALL - Return all values of table as nested array. Optional custom SQL.
	public function select_all($table_name, $custom_sql = null) {
		$db = new SQLite3($this->db_loc) or die('Unable to open database');

		if (isset($custom_sql)) {
			$sql = $custom_sql;			
		} else {
			$sql = 'SELECT * FROM "' . $table_name . '";';
		}

		// Get column names for table. 	
		$column_results = $db->query('PRAGMA table_info("' . $table_name . '")');
		$columns = array();
		$primary_key = null;
		$nested_array = array();
		while ($colArray = $column_results->fetchArray()) {
			// Set Primary Key for parent array
			if ($colArray['pk'] == 1) { $primary_key =  $colArray['name']; }
			$columns[] = $colArray['name'];
		}

		if ($primary_key === null) {
			return $nested_array;
		}

		$result = $db->query($sql) or die('Query failed');
	
		// Return all data as nested associative array
		while ($rowArray = $result->fetchArray()) {
			$row_pk = $rowArray[$primary_key];
			foreach($columns as $key => $value) {
				$nested_array[$row_pk][$value] = $rowArray[$value];
			}
		}
		return $nested_array;	
	}

	// SELECT KEY/VALUE PAIR - Return table as key/value associative array
	public function select_key_value($sql, $keyCol = NULL, $valueCol = NULL) {
		$db = new SQLite3($this->db_loc) or die('Unable to open database');
		$result = $db->query($sql) or die('Unable to select key/value pair.');
		$select_array = array();
		
		// Return key/value pairs as associative array
		while ($rowArray = $result->fetchArray()) {
			$key = $rowArray[$keyCol];
			$select_array[$key] = $rowArray[$valueCol];
		}
		return $select_array;
	}

	// SELECT SINGLE - Return single 
	public function select_single($sql) {
		$db = new SQLite3($this->db_loc) or die('Unable to open database');
		$results = $db->querySingle($sql, true);
		if ($results === false || $results === null) {
			return array();
		}
		return $results;
	}

	// VALUE EXISTS - Return True/False
	public function exists($table, $column, $value) {
		$db = new SQLite3($this->db_loc) or die('Unable to open database');
		$sql = 'SELECT COUNT(*) FROM "'.$table.'" WHERE "'.$column.'" = "'.$value.'";';
		$result = $db->querySingle($sql, true) or die('Unable to locate value in database');
		if ( $result['COUNT(*)'] > 0 ) { return true; } else { return false; }
	}

	// INSERT ROW - Return True/False
	public function insert($sql) {
		$db = new SQLite3($this->db_loc) or die('Unable to open database');
		$results = $db->query($sql) or die('Unable to insert record into database.');
		if ( $db->changes() > 0 ) { 
			$this->set_update_flag(true);
			return true;
		} else {
			return false;
		}
	}

	// UPDATE - Return True/False
	public function update($sql) {
		$db = new SQLite3($this->db_loc) or die('Unable to open database');
		$results = $db->query($sql) or die('Unable to update database.');
		if ( $db->changes() > 0 ) { 
			$this->set_update_flag(true);
			return true;
		} else {
			return false;
		}
	}

	// DELETE ROW - Return True/False
	public function delete_row($sql) {
		$db = new SQLite3($this->db_loc) or die('Unable to open database');
		$results = $db->query($sql) or die('Unable to delete from database.');
		if ( $db->changes() > 0 ) { return true; } else { return false; }
	}



	###############################################
	# Settings Table
	###############################################

	public function get_settings($returnSetting = 'all') {
		if ($returnSetting == 'all') {
			// Return ALL settings as associative array
			$sql = "SELECT * FROM settings";
			$results = $this->select_key_value($sql, 'keyID', 'value');
			return $results;
		} else {
			// Return requested setting value as string
			$sql = "SELECT * FROM settings WHERE keyID = '".$returnSetting."'";
			$results = $this->select_single($sql);
			return $results['value'];
		}
	}


	// ENSURE SETTING EXISTS - Insert a default value only if the key is missing.
	// Used so settings added in newer ORP versions are seeded into databases
	// from older installs without overwriting any value the user has set.
	public function has_setting($key) {
		if (!is_string($key) || !preg_match('/^[A-Za-z][A-Za-z0-9_]{0,63}$/', $key)) {
			return false;
		}
		$db = new SQLite3($this->db_loc);
		$stmt = $db->prepare('SELECT 1 FROM settings WHERE keyID = :key');
		$stmt->bindValue(':key', $key, SQLITE3_TEXT);
		$result = $stmt->execute();
		$exists = $result !== false && $result->fetchArray() !== false;
		$db->close();
		return $exists;
	}

	public function update_existing_setting($key, $value) {
		if (!is_string($key)) {
			return false;
		}
		return $this->update_existing_settings(array($key => $value));
	}

	public function update_existing_settings($pairs) {
		if (!is_array($pairs)) {
			return false;
		}
		foreach ($pairs as $key => $value) {
			if (!is_string($key) || !preg_match('/^[A-Za-z][A-Za-z0-9_]{0,63}$/', $key)) {
				return false;
			}
			if (!is_string($value) || strlen($value) > 4000 || strpos($value, "\0") !== false) {
				return false;
			}
			if (!$this->has_setting($key)) {
				return false;
			}
		}
		if ($pairs === array()) {
			return true;
		}
		$db = $this->open_writer();
		if ($db === null || !$this->exec_ok($db, 'BEGIN IMMEDIATE')) {
			$this->close_quietly($db);
			return false;
		}
		$stmt = $db->prepare('UPDATE settings SET value = :value WHERE keyID = :key');
		if ($stmt === false) {
			return $this->abort_write($db);
		}
		foreach ($pairs as $key => $value) {
			$stmt->bindValue(':value', $value, SQLITE3_TEXT);
			$stmt->bindValue(':key', $key, SQLITE3_TEXT);
			if (!$this->ran($db, $stmt->execute())) {
				return $this->abort_write($db);
			}
			$stmt->reset();
		}
		if (!$this->write_flag_in_transaction($db, true)) {
			return $this->abort_write($db);
		}
		return $this->finish_write($db);
	}

	public function replace_port_form($rows) {
		if (!is_array($rows) || $rows === array()) {
			return false;
		}
		$db = $this->open_writer();
		if ($db === null || !$this->exec_ok($db, 'BEGIN IMMEDIATE')) {
			$this->close_quietly($db);
			return false;
		}
		if (!$this->exec_ok($db, 'DELETE FROM ports') || !$this->exec_ok($db, "DELETE FROM gpio_pins WHERE type = 'Port'")) {
			return $this->abort_write($db);
		}
		$portStmt = $db->prepare('INSERT INTO ports (portNum, portLabel, rxMode, rxGPIO, txGPIO, rxAudioDev, txAudioDev, rxGPIO_active, txGPIO_active) VALUES (:portNum, :portLabel, :rxMode, :rxGPIO, :txGPIO, :rxAudioDev, :txAudioDev, :rxGPIO_active, :txGPIO_active)');
		$gpioStmt = $db->prepare('INSERT INTO gpio_pins (gpio_num, direction, active, description, type) VALUES (:gpio_num, :direction, :active, :description, :type)');
		if ($portStmt === false || $gpioStmt === false) {
			return $this->abort_write($db);
		}
		$n = 1;
		foreach ($rows as $row) {
			$portStmt->bindValue(':portNum', $n, SQLITE3_INTEGER);
			$portStmt->bindValue(':portLabel', $row['portLabel'], SQLITE3_TEXT);
			$portStmt->bindValue(':rxMode', $row['rxMode'], SQLITE3_TEXT);
			$portStmt->bindValue(':rxGPIO', $row['rxGPIO'], SQLITE3_TEXT);
			$portStmt->bindValue(':txGPIO', $row['txGPIO'], SQLITE3_TEXT);
			$portStmt->bindValue(':rxAudioDev', $row['rxAudioDev'], SQLITE3_TEXT);
			$portStmt->bindValue(':txAudioDev', $row['txAudioDev'], SQLITE3_TEXT);
			$portStmt->bindValue(':rxGPIO_active', $row['rxGPIO_active'], SQLITE3_TEXT);
			$portStmt->bindValue(':txGPIO_active', $row['txGPIO_active'], SQLITE3_TEXT);
			if (!$this->ran($db, $portStmt->execute())) {
				return $this->abort_write($db);
			}
			$portStmt->reset();
			foreach (array(
				array($row['rxGPIO'], 'in', $row['rxGPIO_active'], 'PORT ' . $n . ' RX: ' . $row['portLabel']),
				array($row['txGPIO'], 'out', $row['txGPIO_active'], 'PORT ' . $n . ' TX: ' . $row['portLabel']),
			) as $gpio) {
				$gpioStmt->bindValue(':gpio_num', $gpio[0], SQLITE3_TEXT);
				$gpioStmt->bindValue(':direction', $gpio[1], SQLITE3_TEXT);
				$gpioStmt->bindValue(':active', $gpio[2], SQLITE3_TEXT);
				$gpioStmt->bindValue(':description', $gpio[3], SQLITE3_TEXT);
				$gpioStmt->bindValue(':type', 'Port', SQLITE3_TEXT);
				if (!$this->ran($db, $gpioStmt->execute())) {
					return $this->abort_write($db);
				}
				$gpioStmt->reset();
			}
			$n++;
		}
		if (!$this->write_flag_in_transaction($db, true)) {
			return $this->abort_write($db);
		}
		return $this->finish_write($db);
	}

	public function write_advanced_rows($pairs) {
		if (!is_array($pairs) || $pairs === array()) {
			return false;
		}
		foreach ($pairs as $key => $value) {
			if (!is_string($key) || !preg_match('/^[A-Za-z][A-Za-z0-9_]{0,63}$/', $key)) {
				return false;
			}
			if (!is_string($value)) {
				return false;
			}
		}
		$db = $this->open_writer();
		if ($db === null || !$this->exec_ok($db, 'BEGIN IMMEDIATE')) {
			$this->close_quietly($db);
			return false;
		}
		if (!$this->exec_ok($db, 'CREATE TABLE IF NOT EXISTS advanced (keyID TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)')) {
			return $this->abort_write($db);
		}
		$stmt = $db->prepare('INSERT OR REPLACE INTO advanced (keyID, value) VALUES (:key, :value)');
		if ($stmt === false) {
			return $this->abort_write($db);
		}
		foreach ($pairs as $key => $value) {
			$stmt->bindValue(':key', $key, SQLITE3_TEXT);
			$stmt->bindValue(':value', $value, SQLITE3_TEXT);
			if (!$this->ran($db, $stmt->execute())) {
				return $this->abort_write($db);
			}
			$stmt->reset();
		}
		return $this->finish_write($db);
	}

	public function ensure_advanced_table() {
		$db = $this->open_writer();
		if ($db === null) {
			return false;
		}
		$ok = $this->exec_ok($db, 'CREATE TABLE IF NOT EXISTS advanced (keyID TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)');
		$db->close();
		return $ok;
	}

	public function set_module_enabled($moduleKey, $enabled) {
		$moduleKey = $this->module_key($moduleKey);
		if ($moduleKey === null || ($enabled !== 0 && $enabled !== 1 && $enabled !== '0' && $enabled !== '1' && $enabled !== true && $enabled !== false)) {
			return false;
		}
		$bit = ($enabled === 1 || $enabled === '1' || $enabled === true) ? 1 : 0;
		$db = $this->open_writer();
		if ($db === null || !$this->exec_ok($db, 'BEGIN IMMEDIATE')) {
			$this->close_quietly($db);
			return false;
		}
		if (!$this->module_row_exists($db, $moduleKey)) {
			return $this->abort_write($db);
		}
		$stmt = $db->prepare('UPDATE modules SET moduleEnabled = :enabled WHERE moduleKey = :key');
		if ($stmt === false) {
			return $this->abort_write($db);
		}
		$stmt->bindValue(':enabled', $bit, SQLITE3_INTEGER);
		$stmt->bindValue(':key', (int) $moduleKey, SQLITE3_INTEGER);
		if (!$this->ran($db, $stmt->execute())) {
			return $this->abort_write($db);
		}
		if (!$this->write_flag_in_transaction($db, true)) {
			return $this->abort_write($db);
		}
		return $this->finish_write($db);
	}

	public function write_module_options($moduleKey, $serialized) {
		$moduleKey = $this->module_key($moduleKey);
		if ($moduleKey === null || !is_string($serialized)) {
			return false;
		}
		$db = $this->open_writer();
		if ($db === null || !$this->exec_ok($db, 'BEGIN IMMEDIATE')) {
			$this->close_quietly($db);
			return false;
		}
		if (!$this->module_row_exists($db, $moduleKey)) {
			return $this->abort_write($db);
		}
		$stmt = $db->prepare('UPDATE modules SET moduleOptions = :options WHERE moduleKey = :key');
		if ($stmt === false) {
			return $this->abort_write($db);
		}
		$stmt->bindValue(':options', $serialized, SQLITE3_TEXT);
		$stmt->bindValue(':key', (int) $moduleKey, SQLITE3_INTEGER);
		if (!$this->ran($db, $stmt->execute())) {
			return $this->abort_write($db);
		}
		if (!$this->write_flag_in_transaction($db, true)) {
			return $this->abort_write($db);
		}
		return $this->finish_write($db);
	}

	public function insert_module_row($name, $enabled, $svxlinkId) {
		if (!is_string($name) || !preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/', $name)) {
			return false;
		}
		if ($enabled !== 0 && $enabled !== 1 && $enabled !== '0' && $enabled !== '1') {
			return false;
		}
		if (is_int($svxlinkId)) {
			$svxlinkId = (string) $svxlinkId;
		}
		if (!is_string($svxlinkId) || !preg_match('/^[1-9][0-9]{0,8}$/', $svxlinkId)) {
			return false;
		}
		$db = $this->open_writer();
		if ($db === null || !$this->exec_ok($db, 'BEGIN IMMEDIATE')) {
			$this->close_quietly($db);
			return false;
		}
		$exists = $db->prepare('SELECT moduleKey FROM modules WHERE svxlinkName = :name');
		if ($exists === false) {
			return $this->abort_write($db);
		}
		$exists->bindValue(':name', $name, SQLITE3_TEXT);
		$found = $exists->execute();
		if (!$this->ran($db, $found)) {
			return $this->abort_write($db);
		}
		if ($found->fetchArray() !== false) {
			return $this->commit_write($db);
		}
		$stmt = $db->prepare('INSERT INTO modules (moduleEnabled, svxlinkName, svxlinkID) VALUES (:enabled, :name, :id)');
		if ($stmt === false) {
			return $this->abort_write($db);
		}
		$stmt->bindValue(':enabled', (int) $enabled, SQLITE3_INTEGER);
		$stmt->bindValue(':name', $name, SQLITE3_TEXT);
		$stmt->bindValue(':id', (int) $svxlinkId, SQLITE3_INTEGER);
		if (!$this->ran($db, $stmt->execute())) {
			return $this->abort_write($db);
		}
		if (!$this->write_flag_in_transaction($db, true)) {
			return $this->abort_write($db);
		}
		return $this->finish_write($db);
	}

	private function open_writer() {
		try {
			$db = new SQLite3($this->db_loc);
		} catch (Exception $e) {
			return null;
		}
		$db->busyTimeout(0);
		return $db;
	}

	private function exec_ok($db, $sql) {
		if (!$db instanceof SQLite3) {
			return false;
		}
		return $db->exec($sql) !== false && $db->lastErrorCode() === 0;
	}

	private function ran($db, $result) {
		return $result !== false && $db->lastErrorCode() === 0;
	}

	private function write_flag_in_transaction($db, $flag) {
		if ($this->useMemcached()) {
			return true;
		}
		$stmt = $db->prepare('INSERT OR REPLACE INTO system_flags (keyID, value) VALUES (:keyID, :value)');
		if ($stmt === false) {
			return false;
		}
		$stmt->bindValue(':keyID', 'update_settings_flag', SQLITE3_TEXT);
		$stmt->bindValue(':value', $flag ? '1' : '0', SQLITE3_TEXT);
		return $this->ran($db, $stmt->execute());
	}

	private function commit_write($db) {
		if (!$this->exec_ok($db, 'COMMIT')) {
			$db->exec('ROLLBACK');
			$db->close();
			return false;
		}
		$db->close();
		return true;
	}

	private function finish_write($db) {
		if (!$this->commit_write($db)) {
			return false;
		}
		if ($this->useMemcached()) {
			$this->set_update_flag(true);
		}
		return true;
	}

	private function module_key($moduleKey) {
		if (is_int($moduleKey)) {
			$moduleKey = (string) $moduleKey;
		}
		if (!is_string($moduleKey) || !preg_match('/^[1-9][0-9]{0,8}$/', $moduleKey)) {
			return null;
		}
		return $moduleKey;
	}

	private function module_row_exists($db, $moduleKey) {
		$stmt = $db->prepare('SELECT moduleKey FROM modules WHERE moduleKey = :key');
		if ($stmt === false) {
			return false;
		}
		$stmt->bindValue(':key', (int) $moduleKey, SQLITE3_INTEGER);
		$result = $stmt->execute();
		if (!$this->ran($db, $result)) {
			return false;
		}
		return $result->fetchArray() !== false;
	}

	private function abort_write($db) {
		if ($db instanceof SQLite3) {
			$db->exec('ROLLBACK');
			$db->close();
		}
		return false;
	}

	private function close_quietly($db) {
		if ($db instanceof SQLite3) {
			$db->close();
		}
	}

	public function ensure_setting($keyID, $defaultValue) {
		$db = new SQLite3($this->db_loc) or die('Unable to open database');
		$stmt = $db->prepare('INSERT OR IGNORE INTO settings (keyID, value) VALUES (:keyID, :value)');
		$stmt->bindValue(':keyID', $keyID, SQLITE3_TEXT);
		$stmt->bindValue(':value', $defaultValue, SQLITE3_TEXT);
		$stmt->execute();
		$db->close();
	}
	
	

	###############################################
	# Ports Table
	###############################################

	public function get_ports() {
		$sql = 'SELECT * FROM "ports" ORDER BY "portNum" ASC';
		$ports = $this->select_all('ports', $sql);
		return $ports;	
	}


	public function clear_ports_table() {
		$sql = 'DELETE FROM ports;';
		$delete_result = $this->delete_row($sql);
		return $delete_result;
	}


	public function update_ports_table( $input_array = array() ) {
		foreach($input_array as $portArr){  
			$column_names = [];
			$column_values = [];
			$columns = implode(",",array_keys($portArr));
			$escaped_values = array_values($portArr);
			$values  = "'" . implode("','", $escaped_values) . "'";
			$sql = "INSERT INTO ports(".$columns.") VALUES(".$values.");";
			$results = $this->insert($sql);
		}
	}



	###############################################
	# GPIO Table
	###############################################

	public function get_gpios() {
		$sql = 'SELECT * FROM "gpio_pins" ORDER BY "gpio_num" ASC';
		$gpios = $this->select_all('gpio_pins', $sql);
		return $gpios;	
	}


	public function clear_gpio_table() {
		$sql = 'DELETE FROM gpio_pins;';
		$delete_result = $this->delete_row($sql);
		return $delete_result;
	}


	public function update_gpio_table( $input_array = array() ) {
		foreach($input_array as $gpioArr){  
			$column_names = [];
			$column_values = [];
			$columns = implode(",",array_keys($gpioArr));
			$escaped_values = array_values($gpioArr);
			$values  = "'" . implode("','", $escaped_values) . "'";
			$sql = "INSERT INTO gpio_pins(".$columns.") VALUES(".$values.");";
			$results = $this->insert($sql);
		}
	}



	###############################################
	# Module Table
	###############################################

	public function get_modules() {
		$sql = 'SELECT * FROM "modules" ORDER BY "svxlinkID" ASC';
		$modules = $this->select_all('modules', $sql);
		return $modules;	
	}


	public function active_module($id = NULL) {
		if(isset($id)) {
			// Target Module
			$sql = "UPDATE modules SET moduleEnabled='1' WHERE moduleKey='$id'";
		} else {
			// Deactivate ALL Modules
			$sql = "UPDATE modules SET moduleEnabled='1'";
		}
		$results = $this->insert($sql);
		return $results;
	}


	public function deactive_module($id = NULL) {
		if(isset($id)) {
			// Target Module
			$sql = "UPDATE modules SET moduleEnabled='0' WHERE moduleKey='$id'";
		} else {
			// Deactivate ALL Modules
			$sql = "UPDATE modules SET moduleEnabled='0'";
		}
		$results = $this->insert($sql);
		return $results;
	}


	public function update_preset_modules( $input_array = array() ) {
		foreach($input_array as $moduleArray){  
			$sql = "UPDATE modules SET moduleEnabled='1', moduleOptions='".$moduleArray['moduleOptions']."' WHERE moduleKey='".$moduleArray['moduleKey']."';";
			$results = $this->insert($sql);
		}
	}



	###############################################
	# CTCSS Table
	###############################################

	// Read all the CTCSS Tones from SQLite into a PHP array
	public function get_ctcss() {
		$sql = 'SELECT * FROM ctcss';
		$ctcss = $this->select_key_value($sql, 'toneFreqHz', 'toneFreqHz');
		return $ctcss;	
	}



	###############################################
	# Version Table
	###############################################

	public function get_version() {
		$sql = 'SELECT * FROM version_info';
		$result = $this->select_single($sql);
		return $result['version_num'];		
	}



	###############################################
	# Export
	###############################################

	public function db_export($db_tables, $sql_file) {
		if (!is_string($sql_file) || $sql_file === '' || !is_array($db_tables) || $db_tables === array()) {
			return false;
		}
		$orp_version = $this->get_version();
		$sql_file_header = str_repeat('-',80) . "\n-- OpenRepeater Backup (ver $orp_version)\n" . str_repeat('-',80) . "\n";
		exec('printf %s ' . escapeshellarg($sql_file_header) . ' > ' . escapeshellarg($sql_file), $unused, $rc);
		if ($rc !== 0) {
			return false;
		}
		foreach ($db_tables as $cur_table) {
			if (!is_string($cur_table) || !preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', $cur_table)) {
				return false;
			}
			$sql_section_header = "\n\n" . str_repeat('-',80) . "\n-- Table: $cur_table\n" . str_repeat('-',80) . "\n";
			exec('printf %s ' . escapeshellarg($sql_section_header) . ' >> ' . escapeshellarg($sql_file), $unused, $rc);
			if ($rc !== 0) {
				return false;
			}
			exec('sqlite3 ' . escapeshellarg($this->db_loc) . ' ' . escapeshellarg('.dump ' . $cur_table) . ' >> ' . escapeshellarg($sql_file), $unused, $rc);
			if ($rc !== 0) {
				return false;
			}
		}
		return true;
	}



	###############################################
	# Import
	###############################################

	public function db_import($db_tables, $sql_file) {
		$rows = $this->load_backup_rows($db_tables, $sql_file);
		if ($rows === false) {
			return false;
		}
		return $this->replace_backup_tables($db_tables, $rows);
	}

	public function load_backup_rows($db_tables, $sql_file) {
		if (!is_string($sql_file) || !is_file($sql_file) || !is_readable($sql_file)) {
			return false;
		}
		$sql = file_get_contents($sql_file);
		if (!is_string($sql)) {
			return false;
		}
		require_once __DIR__ . '/BackupSql.php';
		return BackupSql::parse($sql, $db_tables);
	}

	public function capture_table_rows($db_tables) {
		if (!$this->backup_tables_ok($db_tables)) {
			return false;
		}
		$db = $this->open_reader();
		if ($db === null) {
			return false;
		}
		$rows = array();
		foreach ($db_tables as $table) {
			$captured = $this->capture_one_table($db, $table);
			if ($captured === false) {
				$db->close();
				return false;
			}
			$rows[$table] = $captured;
		}
		$db->close();
		return $rows;
	}

	// The installed database is root-owned inside a sticky directory. The web
	// user can write that inode and cannot rename another file over it.
	public function replace_backup_tables($db_tables, $rows) {
		if (!$this->backup_tables_ok($db_tables) || !is_array($rows)) {
			return false;
		}
		foreach ($db_tables as $table) {
			if (!isset($rows[$table]) || !is_array($rows[$table])) {
				return false;
			}
		}
		$db = $this->open_writer();
		if ($db === null) {
			return false;
		}
		$allowed = array();
		foreach ($db_tables as $table) {
			$allowed[$table] = true;
		}
		$columns = array();
		foreach ($db_tables as $table) {
			$info = $db->query('PRAGMA table_info("' . $table . '")');
			if ($info === false) {
				$this->close_quietly($db);
				return false;
			}
			$names = array();
			while ($col = $info->fetchArray(SQLITE3_ASSOC)) {
				$names[] = $col['name'];
			}
			if ($names === array()) {
				$this->close_quietly($db);
				return false;
			}
			$columns[$table] = $names;
		}
		if (!method_exists($db, 'setAuthorizer')) {
			$this->close_quietly($db);
			return false;
		}
		$db->setAuthorizer(function ($action, $arg1 = null, $arg2 = null, $arg3 = null, $arg4 = null) use ($allowed) {
			if ($action === SQLite3::TRANSACTION) {
				return SQLite3::OK;
			}
			$internal = ($arg1 === 'sqlite_sequence' || $arg1 === 'sqlite_master' || $arg1 === 'sqlite_schema' || $arg1 === 'sqlite_temp_master' || $arg1 === 'sqlite_temp_schema');
			if ($action === SQLite3::READ && ($internal || (is_string($arg1) && isset($allowed[$arg1])))) {
				return SQLite3::OK;
			}
			if (($action === SQLite3::INSERT || $action === SQLite3::DELETE || $action === SQLite3::UPDATE)
				&& ($arg1 === 'sqlite_sequence' || (is_string($arg1) && isset($allowed[$arg1])))) {
				return SQLite3::OK;
			}
			return SQLite3::DENY;
		});
		if (!$this->exec_ok($db, 'BEGIN IMMEDIATE')) {
			$this->close_quietly($db);
			return false;
		}
		foreach ($db_tables as $table) {
			if (!$this->exec_ok($db, 'DELETE FROM "' . $table . '"')) {
				return $this->abort_write($db);
			}
			foreach ($rows[$table] as $row) {
				if (!is_array($row) || !isset($row['values']) || !is_array($row['values'])) {
					return $this->abort_write($db);
				}
				$names = $row['columns'] === null ? $columns[$table] : $row['columns'];
				if (!is_array($names) || count($names) !== count($row['values'])) {
					return $this->abort_write($db);
				}
				foreach ($names as $name) {
					if (!is_string($name) || !in_array($name, $columns[$table], true)) {
						return $this->abort_write($db);
					}
				}
				$holders = array();
				foreach ($names as $index => $name) {
					$holders[] = ':' . $index;
				}
				$stmt = $db->prepare('INSERT INTO "' . $table . '" ("' . implode('","', $names) . '") VALUES (' . implode(',', $holders) . ')');
				if ($stmt === false) {
					return $this->abort_write($db);
				}
				foreach ($row['values'] as $index => $value) {
					if (!$this->bind_backup_value($stmt, ':' . $index, $value)) {
						return $this->abort_write($db);
					}
				}
				if (!$this->ran($db, $stmt->execute())) {
					return $this->abort_write($db);
				}
			}
		}
		return $this->commit_write($db);
	}

	private function backup_tables_ok($db_tables) {
		if (!is_array($db_tables) || $db_tables === array()) {
			return false;
		}
		$seen = array();
		foreach ($db_tables as $table) {
			if (!is_string($table) || !preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', $table) || isset($seen[$table])) {
				return false;
			}
			$seen[$table] = true;
		}
		return true;
	}

	private function open_reader() {
		try {
			$db = new SQLite3($this->db_loc, SQLITE3_OPEN_READONLY);
		} catch (Exception $e) {
			return null;
		}
		$db->busyTimeout(0);
		return $db;
	}

	private function capture_one_table($db, $table) {
		$info = $db->query('PRAGMA table_info("' . $table . '")');
		if ($info === false) {
			return false;
		}
		$names = array();
		while ($col = $info->fetchArray(SQLITE3_ASSOC)) {
			$names[] = $col['name'];
		}
		if ($names === array()) {
			return false;
		}
		$result = $db->query('SELECT "' . implode('","', $names) . '" FROM "' . $table . '"');
		if ($result === false) {
			return false;
		}
		$rows = array();
		while ($row = $result->fetchArray(SQLITE3_NUM)) {
			$values = array();
			foreach ($row as $value) {
				if ($value === null) {
					$values[] = array('null', null);
				} elseif (is_int($value)) {
					$values[] = array('number', (string) $value);
				} elseif (is_float($value)) {
					$values[] = array('number', (string) $value);
				} elseif (is_string($value) && strpos($value, "\0") !== false) {
					$values[] = array('blob', $value);
				} else {
					$values[] = array('string', (string) $value);
				}
			}
			$rows[] = array('columns' => $names, 'values' => $values);
		}
		return $rows;
	}

	private function bind_backup_value($stmt, $name, $value) {
		if (!is_array($value) || !isset($value[0])) {
			return false;
		}
		if ($value[0] === 'null') {
			$stmt->bindValue($name, null, SQLITE3_NULL);
			return true;
		}
		if ($value[0] === 'string') {
			$stmt->bindValue($name, $value[1], SQLITE3_TEXT);
			return true;
		}
		if ($value[0] === 'blob') {
			$stmt->bindValue($name, $value[1], SQLITE3_BLOB);
			return true;
		}
		if ($value[0] === 'number' && is_string($value[1]) && preg_match('/^-?[0-9]+$/', $value[1])) {
			$stmt->bindValue($name, (int) $value[1], SQLITE3_INTEGER);
			return true;
		}
		if ($value[0] === 'number' && is_string($value[1]) && is_numeric($value[1])) {
			$stmt->bindValue($name, (float) $value[1], SQLITE3_FLOAT);
			return true;
		}
		return false;
	}



	###############################################
	# Memcache Flag
	###############################################

	private function useMemcached() {
		$force = getenv('ORP_FLAG_STORE');
		if ($force === 'sqlite') {
			return false;
		}
		// extension_loaded does not ask the autoloader to invent
		// includes/classes/Memcached.php. The class check is also
		// non-autoloading, so a missing extension uses system_flags.
		return extension_loaded('memcached') && class_exists('Memcached', false);
	}

	public function set_update_flag($flag) {
		/* SET FLAG TO LET THE UI KNOW A REBUILD WAS REQUESTED */
		if ($this->useMemcached()) {
			$memcached_obj = new Memcached;
			$memcached_obj->addServer('localhost', 11211);
			if($flag == true) {
				$memcached_obj->set('update_settings_flag', 1); // Set Flag
			} else {
				$memcached_obj->set('update_settings_flag', 0); // Clear Flag			
			}
			return;
		}
		$db = new SQLite3($this->db_loc);
		$stmt = $db->prepare('INSERT OR REPLACE INTO system_flags (keyID, value) VALUES (:keyID, :value)');
		if ($stmt === false) {
			return;
		}
		$stmt->bindValue(':keyID', 'update_settings_flag', SQLITE3_TEXT);
		$stmt->bindValue(':value', $flag ? '1' : '0', SQLITE3_TEXT);
		$stmt->execute();
		$db->close();
	}

	public function get_update_flag() {
		if ($this->useMemcached()) {
			$memcached_obj = new Memcached;
			$memcached_obj->addServer('localhost', 11211);
			$state = $memcached_obj->get('update_settings_flag');
			return $state == 1;
		}
		$db = new SQLite3($this->db_loc);
		$stmt = $db->prepare('SELECT value FROM system_flags WHERE keyID = :keyID');
		if ($stmt === false) {
			return false;
		}
		$stmt->bindValue(':keyID', 'update_settings_flag', SQLITE3_TEXT);
		$result = $stmt->execute();
		if ($result === false) {
			return false;
		}
		$row = $result->fetchArray(SQLITE3_ASSOC);
		$db->close();
		return is_array($row) && isset($row['value']) && $row['value'] === '1';
	}

}
?>