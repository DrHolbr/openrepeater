<?php
#####################################################################################################
# Database Class
#####################################################################################################

class AudioFiles {

    private $path = "/var/lib/openrepeater/sounds/";
    private $temp_dir = "/tmp/";
    private $sound_dir = '/sounds/';

	public function __construct() {
		$override = getenv('ORP_AUDIO_PATH');
		if (is_string($override) && $override !== '' && $override[0] === '/') {
			$this->path = rtrim($override, '/') . '/';
		}
	}

	private function allowedType($type) {
		return $type === 'identification' || $type === 'courtesy_tones';
	}

	// A library is only the real directory for that type. A missing directory
	// is an empty library. A symlink is not a library, so listing, rename,
	// delete, and upload cannot follow it.
	private function libraryDir($type) {
		if (!$this->allowedType($type)) {
			return null;
		}
		$base = $this->path;
		if ($base === '' || is_link(rtrim($base, '/')) || !is_dir($base)) {
			return null;
		}
		$dir = rtrim($base, '/') . '/' . $type;
		if (is_link($dir) || !is_dir($dir)) {
			return null;
		}
		return $dir;
	}

	private function plainFileName($name) {
		if (!is_string($name) || $name === '' || $name !== basename($name)) {
			return null;
		}
		if (strpos($name, "\0") !== false || strpos($name, '/') !== false || strpos($name, '\\') !== false) {
			return null;
		}
		if (!preg_match('/^[A-Za-z0-9._ -]+$/', $name)) {
			return null;
		}
		return $name;
	}

	private function refusal($text) {
		return array(
			'msgType' => 'error',
			'msgText' => $text
		);
	}


	###############################################
	# Get Audio Files by Type
	###############################################

	public function get_audio_files($type) {
		$fileList = array();
		$filesArray = array();
		$dir = $this->libraryDir($type);
		if ($dir === null) {
			return $filesArray;
		}
		$host = isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : 'localhost';
		$scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
		$url = $scheme . '://' . $host . $this->sound_dir . $type . '/';

		$handle = opendir($dir);
		if ($handle === false) {
			return $filesArray;
		}
		while (false !== ($file = readdir($handle))) {
			if ($file === '.' || $file === '..') {
				continue;
			}
			$full = $dir . '/' . $file;
			if (is_link($full) || !is_file($full)) {
				continue;
			}
			if ($this->plainFileName($file) === null) {
				continue;
			}
			$fileList[] = $file;
		}
		closedir($handle);

		natsort($fileList);
		$fileList = array_values($fileList);

		foreach ($fileList as $fileName) {
			$fileLabel = str_replace("_", " ", $fileName);
			$fileLabel = preg_replace('/\\.[^.\\s]{2,5}$/', '', $fileLabel);
			$filesArray[] = array(
				'fileName' => $fileName,
				'fileLabel' => $fileLabel,
				'fileURL' => $url . rawurlencode($fileName),
				'filePath' => $dir . '/' . $fileName
			);
		}
		return $filesArray;
	}
	


	###############################################
	# Display Audio Table Rows
	###############################################

	public function display_audio_files($type, $selected, $settingName) {

		$audioLib = $this->get_audio_files($type);
		$html_modal = '';

		if ($audioLib) {
			
			switch ($settingName) {
				# Short ID
			    case 'ID_Short_CustomFile':
					$rowID_prefix = 'shortIDsoundRow';
					$modal_label = 'Custom Identification Clip';
					$sub_form_action = 'identification.php';
			        break;
	
				# Long ID
			    case 'ID_Long_CustomFile':
					$rowID_prefix = 'longIDsoundRow';
					$modal_label = 'Custom Identification Clip';
					$sub_form_action = 'identification.php';
			        break;
			        
			    # Courtesy Tones
			    case 'courtesy':
					$rowID_prefix = 'courtesyToneRow';			    	
					$modal_label = 'Courtesy Tone';
					$sub_form_action = 'courtesy_tone.php';
			        break;
			}


			// Start with hidden field for jQuery to copy setting in for AJAX update. 
			$html_table = '<input type="hidden" name="' . $settingName . '" id="' . $settingName . '" value="' . $selected . '">';
			
			$file_counter = 0;
			$html_modal = '';
			$totalFiles = count($audioLib);
			
			if ($totalFiles > 10) {
				$html_table .= '
				<table class="table table-striped table-condensed bootstrap-datatable datatable">
					<thead><tr class="audio_row"><th>Name</th><th>Preview</th><th class="button_grp">Actions</th></tr></thead>   
					<tbody>			
				';
				
			} else {
				$html_table .= '
				<table class="table table-striped table-condensed bootstrap-datatable">
					<thead><tr class="audio_row"><th>Name</th><th>Preview</th><th class="button_grp">Actions</th></tr></thead>   
					<tbody>			
				';
			}
		
			foreach($audioLib as $fileArray) {	
		
				$file_counter++;

				switch ($settingName) {
					# Short ID
					case 'ID_Short_CustomFile':
						$select_btn_html = '<button type="button" class="btn btn-success" name="ID_Short_CustomFile" onclick="setCustomShortID(\''. $fileArray['fileName'] .'\','.$file_counter.','.$totalFiles.'); return false;"><i class="icon-ok icon-white"></i> Select</button>';
				        break;

					# Long ID
				    case 'ID_Long_CustomFile':
						$select_btn_html = '<button type="button" class="btn btn-success" name="ID_Long_CustomFile" onclick="setCustomLongID(\''. $fileArray['fileName'] .'\','.$file_counter.','.$totalFiles.'); return false;"><i class="icon-ok icon-white"></i> Select</button>';
				        break;

					# Courtesy Tones
				    case 'courtesy':
						$select_btn_html = '<button type="button" class="btn btn-success" name="courtesy" onclick="setCourtesyTone(\''. $fileArray['fileName'] .'\','.$file_counter.','.$totalFiles.',\''. $fileArray['fileLabel'] .'\'); return false;"><i class="icon-ok icon-white"></i> Select</button>';
				        break;

				}



			
				// START TABLE ROW
				if ($selected == $fileArray['fileName']) {	
					$html_table .= '<tr id="'.$rowID_prefix.$file_counter.'" class="audio_row active">';
				} else {
					$html_table .= '<tr id="'.$rowID_prefix.$file_counter.'" class="audio_row">';
				}
		
				$html_table .= '
					<td><h2>' . $fileArray['fileLabel'] . '</h2></td>
			
					<td class="center">
					<audio controls>
						<source src="' . $fileArray['fileURL'] . '" type=audio/mpeg>
						Your browser does not support the audio element.
					</audio>
					</td>
				
					<td class="button_grp">
			
						' . $select_btn_html . '
			
						<!-- Button triggered modal -->
						<button class="btn" data-toggle="modal" data-target="#renameFile'.$file_counter.'">
							<i class="icon-pencil"></i> 
							Rename
						</button>
			
						<!-- Button triggered modal -->
						<button class="btn btn-danger" data-toggle="modal" data-target="#deleteFile'.$file_counter.'">
							<i class="icon-trash icon-white"></i> 
							Delete
						</button>
					</td>
				</tr>';

			
				$html_modal .= '
			
				<!-- Modal - RENAME DIALOG -->
				<form action="' . $sub_form_action . '" method="post">
			
				<div class="modal fade" id="renameFile'.$file_counter.'" tabindex="-1" role="dialog" aria-labelledby="myModalLabel" aria-hidden="true">
				  <div class="modal-dialog">
				    <div class="modal-content">
				      <div class="modal-header">
					<h3 class="modal-title" id="myModalLabel">Rename ' . $modal_label . '</h3>
				      </div>
				      <div class="modal-body">
					<input type="hidden" name="action" value="rename_file">
					<input class="input disabled" id="disabledInput" type="text" placeholder="' . $fileArray['fileLabel'] . '" disabled="">
					<input type="hidden" name="oldFileName" value="' . $fileArray['fileName'] . '">
					<span style="margin-right:5px;margin-left:5px;margin-top:-12px;" class="icon32 icon-arrowthick-e"/></span>		
					<input type="text" name="newFileLabel" value="' . $fileArray['fileLabel'] . '">
				      </div>
				      <div class="modal-footer">
					<button type="button" class="btn btn-default" data-dismiss="modal">Cancel</button>
					<button type="submit" class="btn btn-success"><i class="icon-pencil icon-white"></i> Rename</button>
			
				      </div>
				    </div><!-- /.modal-content -->
				  </div><!-- /.modal-dialog -->
				</div>
				</form>									
				<!-- /.modal -->
			
				<!-- Modal - DELETE DIALOG -->
				<form action="' . $sub_form_action . '" method="post">
			
				<div class="modal fade" id="deleteFile'.$file_counter.'" tabindex="-1" role="dialog" aria-labelledby="myModalLabel" aria-hidden="true">
				  <div class="modal-dialog">
				    <div class="modal-content">
				      <div class="modal-header">
					<button type="button" class="close" data-dismiss="modal" aria-hidden="true">&times;</button>
					<h3 class="modal-title" id="myModalLabel">Delete ' . $modal_label . '</h3>
				      </div>
				      <div class="modal-body">
					Are you sure that you want to delete the ' . strtolower($modal_label) . ' <strong>' . $fileArray['fileLabel'] . '</strong>? This cannot be undone!
					<input type="hidden" name="delfile[]" value="' . $fileArray['fileName'] . '">
					<input type="hidden" name="action" value="delete_file">
				      </div>
				      <div class="modal-footer">
					<button type="button" class="btn btn-default" data-dismiss="modal">Cancel</button>
					<button type="submit" class="btn btn-danger"><i class="icon-trash icon-white"></i> Delete</button>
				      </div>
				    </div><!-- /.modal-content -->
				  </div><!-- /.modal-dialog -->
				</div>
				</form>
				<!-- /.modal -->';
		    }
		
			$html_table .= '
			</tbody>
		</table>
		';
			return array('table' => $html_table, 'modals' => $html_modal);
		}

		return array(
			'table' => '<h3>No Audio Files to Display, Please upload some.</h3>',
			'modals' => ''
		);

	}



	###############################################
	# Upload Audio Files by Type
	###############################################

	public function audio_upload_files($type, $fileNameArray) {

		$library = $this->libraryDir($type);
		if ($library === null || !is_array($fileNameArray) || !isset($fileNameArray['name'])) {
			return $this->refusal('The audio library is not available. Nothing was written.');
		}
		$final_file_dir = rtrim($library, '/') . '/';
		$maxFileSize = 45000000; // size in bytes
		$allowedExts = array('wav','mp3','aif','aiff','gsm','ogg','flac');
	
		//Loop through each file
		for($i=0; $i<count($fileNameArray['name']); $i++) {
			//Get the temp file path
			$tmpFile1 = $fileNameArray['tmp_name'][$i];
			$plainName = $this->plainFileName($fileNameArray['name'][$i]);
			if ($plainName === null) {
				return $this->refusal('The audio name is not a plain file name. Nothing was written.');
			}
			$tmpFile2 = tempnam($this->temp_dir, 'orp-audio-');
			if ($tmpFile2 === false) {
				return $this->refusal('The audio library is not available. Nothing was written.');
			}
			
			$temp_ext = explode(".", $plainName);
			$extension = strtolower((string) end($temp_ext));
			$filename_no_ext = pathinfo($plainName, PATHINFO_FILENAME);
			if (!preg_match('/^[A-Za-z0-9._ -]+$/', $filename_no_ext)) {
				return $this->refusal('The audio name is not a plain file name. Nothing was written.');
			}

			$soxOutFile = $final_file_dir . str_replace(" ","_",$filename_no_ext) . ".wav";
			$parent = realpath($final_file_dir);
			if ($parent === false || strpos($soxOutFile, $parent . '/') !== 0) {
				return $this->refusal('The audio name is not a plain file name. Nothing was written.');
			}
			

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
					'msgText' => 'Sorry, but the file you tried to upload is not in a supported format. Supported formats are <strong>WAV</strong> and <strong>MP3</strong>.'
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
			if (file_exists($soxOutFile)) {
				return array(
					'msgType' => 'error',
					'msgText' => 'Sorry but the sound <strong>' .  $this->pretty_filename($fileNameArray['name'][$i]) . '</strong> already exists.'
				);	
			}


			# Process File
			if ($tmpFile1 != ""){
				move_uploaded_file($tmpFile1, $tmpFile2);

				$conversion = $this->convert_audio($tmpFile2, $soxOutFile);
				unlink($tmpFile2);

				if($conversion) {
					// SUCCESSFUL
					return array(
						'msgType' => 'success',
						'msgText' => 'Successfully uploaded <strong>' . $this->pretty_filename($fileNameArray['name'][$i]) . '</strong> and converted into the proper format.'
					);	
					
				} else {
					// Failure
					return array(
						'msgType' => 'error',
						'msgText' => 'There was a problem uploading and converting your file.'
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
	# Pretty File Name
	###############################################

	public function pretty_filename($file) {
		$fileLabel = str_replace("_"," ",$file); //replace underscores with spaces for file labels
		$fileLabel = preg_replace('/\\.[^.\\s]{2,5}$/', '', $fileLabel); //remove extention
		return $fileLabel;
	}



	###############################################
	# Convert Audio File
	###############################################

	private function convert_audio($source, $destination) {
		$soxCommand = 'sox "' . $source . '" -r16000 -b16 -esigned-integer -c1 "' . $destination . '"';
		exec($soxCommand);

		if (file_exists($destination)) {
			return true;
		} else {
			return false;			
		}
	}



	###############################################
	# RENAME Audio Files by Type
	###############################################

	public function audio_rename_file($type, $oldFileName, $newFileLabel) {
		$library = $this->libraryDir($type);
		$oldFileName = $this->plainFileName($oldFileName);
		if ($library === null || $oldFileName === null || !is_string($newFileLabel) || $newFileLabel === '') {
			return $this->refusal('The audio file was not renamed.');
		}
		$renamePath = rtrim($library, '/') . '/';
		
		$oldfile = $renamePath . $oldFileName;
		if (is_link($oldfile) || !is_file($oldfile)) {
			return $this->refusal('The audio file was not renamed.');
		} 
		$ext = pathinfo($oldfile, PATHINFO_EXTENSION);
		
		$safeLabel = str_replace(' ', '_', $newFileLabel);
		if ($this->plainFileName($safeLabel . '.' . $ext) === null) {
			return $this->refusal('The audio file was not renamed.');
		}
		$newFileName = $safeLabel . '.' . $ext;
		$newfile = $renamePath . $newFileName;

		# Don't Rename if there is no change
		if($oldFileName == $newFileName){
			return array(
				'msgType' => 'error',
				'msgText' => 'Umm...You\'re trying to rename file to the same thing. Nothing Done.'
			);	
		}

		# Don't Rename if there is another file with the same name
		if (file_exists($newfile)) {
			return array(
				'msgType' => 'error',
				'msgText' => 'Sorry, there is already a file with that name.'
			);	
		}

		# Rename the File 
		rename($oldfile, $newfile);
	
		if (file_exists($newfile)) {
			return array(
				'msgType' => 'success',
				'msgText' => 'Successfully renamed <strong>' . $this->pretty_filename($oldFileName) . '</strong> to <strong>' . $newFileLabel . '</strong>.'
			);	
		} else {
			return array(
				'msgType' => 'error',
				'msgText' => 'There was a problem renaming your file.'
			);	
		}

	}



	###############################################
	# DELETE Audio Files by Type
	###############################################

	public function audio_delete_files($type, $fileNameArray) {
		$library = $this->libraryDir($type);
		if ($library === null) {
			return $this->refusal('The audio file was not deleted.');
		}
		$deletePath = rtrim($library, '/') . '/';
		
		if (!is_array($fileNameArray)) { $fileNameArray = array($fileNameArray); } // if string is passed, turn into array
		$currentFile = '';

		foreach($fileNameArray as $requested) {
			$currentFile = $this->plainFileName($requested);
			if ($currentFile === null) {
				return $this->refusal('The audio file was not deleted.');
			}
			$target = $deletePath . $currentFile;
			if (is_link($target) || !is_file($target)) {
				return $this->refusal('The audio file was not deleted.');
			}
			unlink($target);
		}
		
		#This alert code does not yet handle multiple file deletes. Just the last file in the loop above. 
		if (!file_exists($deletePath . $currentFile)) {
			return array(
				'msgType' => 'success',
				'msgText' => 'Successfully deleted <strong>' . $this->pretty_filename($fileNameArray[0]) . '</strong>.'
			);	
		} else {
			return array(
				'msgType' => 'error',
				'msgText' => 'There was a problem deleting your file.'
			);	
		}

	}


}
?>