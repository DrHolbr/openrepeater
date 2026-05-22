<?php
// --------------------------------------------------------
// SESSION CHECK TO SEE IF USER IS LOGGED IN.
session_start();
if ((!isset($_SESSION['username'])) || (!isset($_SESSION['userID']))){
	header('location: login.php'); // If they aren't logged in, send them to login page.
} elseif (!isset($_SESSION['callsign'])) {
	header('location: wizard/index.php'); // If they are logged in, but they haven't set a callsign then send them to setup wizard.
} else { // If they are logged in and have set a callsign, show the page.
// --------------------------------------------------------
?>

<?php
$pageTitle = "General Settings"; 

$customJS = "page-settings.js"; // "file1.js, file2.js, ... "

// include_once("includes/get_ctcss.php");

include('includes/header.php');
$ctcss = $Database->get_ctcss();

// TTS settings (bootstraps tts_* rows if missing) + available Piper voices.
require_once(rtrim($_SERVER['DOCUMENT_ROOT'], '/') . '/includes/classes/TTS.php');
$tts        = TTS::get_settings();
$tts_voices = TTS::list_voices();
$tts_status = TTS::status_summary();

?>

			<?php if (isset($alert)) { echo $alert; } ?>

			<form class="form-horizontal" role="form" action="functions/ajax_db_update.php" method="post" id="settingsUpdate" name="settingsUpdate" >
			<div class="row-fluid sortable">
				<div class="box span12">
					<div class="box-header well" data-original-title>
						<h2><i class="icon-wrench"></i> General Repeater Settings</h2>
					</div>
					<div class="box-content">

						  <fieldset>
							<legend>Basic Settings</legend>

							  <div class="control-group">
								<label class="control-label" for="callSign">Call Sign</label>
								<div class="controls">
								  <input class="input-xlarge" style="text-transform: uppercase" id="callSign" type="text" name="callSign" value="<?php echo $settings['callSign']; ?>" required>
								  <span class="help-inline">This call sign will be used for identification.</span>
								</div>
							  </div>


							  <div class="control-group">
								<label class="control-label" for="txTailValueSec">TX Tail</label>
								<div class="controls">
								  <div class="input-append">
									<input id="txTailValueSec" name="txTailValueSec" size="16" type="text" value="<?php echo $settings['txTailValueSec']; ?>" required><span class="add-on">secs</span>
								  </div>
								  <span class="help-inline">The amount of time before the transmitter drops</span>
								</div>
							  </div>
							  

							<legend>Timeout Settings</legend>

							  <div class="control-group">
								<label class="control-label" for="repeaterTimeoutSec">Repeater Timeout</label>
								<div class="controls">
								  <div class="input-append">
									<input id="repeaterTimeoutSec" name="repeaterTimeoutSec" size="16" type="text" value="<?php echo $settings['repeaterTimeoutSec']; ?>"><span class="add-on">secs</span>
								  </div>
								  <span class="help-inline">(i.e. 4 minutes would equal 240 seconds)</span>
								</div>
							  </div>

							<legend>DTMF Remote Disable</legend>

							  <div class="control-group">
								<label class="control-label" for="repeaterDTMF_disable">Use Remote Disable?</label>
								<div class="controls">
								  <select id="repeaterDTMF_disable" name="repeaterDTMF_disable">
								  	<option value="False"<?php if ($settings['repeaterDTMF_disable'] == 'False') { echo ' selected'; } ?>>Disable Function</option>
								  	<option value="True"<?php if ($settings['repeaterDTMF_disable'] == 'True') { echo ' selected'; } ?>>Enable Function</option>
								  </select>
								  <span class="help-inline">Enable this to be able to disable the transmitter by entering DTMF command.</span>
								</div>
							  </div>
 
							  <div id="dtmf_disable" style="display: none;"> <!-- Expand Setting -->
 
							  <div class="control-group">
								<label class="control-label" for="repeaterDTMF_disable_pin">Pin Code</label>
								<div class="controls">
								  <input class="input-xlarge" id="repeaterDTMF_disable_pin" type="text" name="repeaterDTMF_disable_pin" value="<?php echo $settings['repeaterDTMF_disable_pin']; ?>" maxlength="10" required>
								  <span class="help-inline">The pin will be used at part of DTMF command. This should be unique and the longer the better.</span>
								</div>
							  </div>
							  
							  <p>For command detials, visit the <a href="dtmf.php#remoteDisable">Remote DMTF Disable</a> section on the DTMF Reference page.</p>
							  
							  </div> <!-- END Expand Setting -->

							<legend>CTCSS Settings</legend>
							<p>These are settings experimental. It is recommend that you leave these set to none and set your CTCSS tones in your radios.<br></p>

							  <div class="control-group">
								<label class="control-label" for="rxTone">RX Tone (Hz)</label>
								<div class="controls">
								  <select id="rxTone" name="rxTone" data-rel="chosen">
									<?php 
										$option_string = '<option value=""';
										if ($settings['rxTone'] == '') { 
											$option_string .= ' selected';
										}
										$option_string .= '>(none)</option>';
										echo $option_string;

										foreach($ctcss as $freq => $code) {
											$option_string = '<option value="'.$freq.'"';
											if ($settings['rxTone'] == $freq) { 
												$option_string .= ' selected';
											}
											$option_string .= '>'.$freq.'</option>';
											echo $option_string;
										}
									?>
								  </select>
								  <span class="help-inline">The CTCSS tone you have to transmit to "open" the repeater.</span>
								</div>
							  </div>

							  <div class="control-group" id="ctcss_rx_thresholds">
								<label class="control-label" for="rxCtcssOpenThresh">RX CTCSS Open Threshold</label>
								<div class="controls">
								  <input type="number" id="rxCtcssOpenThresh" name="rxCtcssOpenThresh" min="1" max="50" value="<?php echo $settings['rxCtcssOpenThresh'] ? $settings['rxCtcssOpenThresh'] : '10'; ?>">
								  <span class="help-inline">Sensitivity to open squelch on CTCSS (1–50). Higher = more sensitive. Default: 10.</span>
								</div>
							  </div>

							  <div class="control-group" id="ctcss_rx_close_threshold">
								<label class="control-label" for="rxCtcssCloseThresh">RX CTCSS Close Threshold</label>
								<div class="controls">
								  <input type="number" id="rxCtcssCloseThresh" name="rxCtcssCloseThresh" min="1" max="50" value="<?php echo $settings['rxCtcssCloseThresh'] ? $settings['rxCtcssCloseThresh'] : '5'; ?>">
								  <span class="help-inline">Sensitivity to close squelch when CTCSS lost (1–50). Higher = more sensitive. Default: 5.</span>
								</div>
							  </div>

							  <div class="control-group">
								<label class="control-label" for="txTone">TX Tone (Hz)</label>
								<div class="controls">
								  <select id="txTone" name="txTone" data-rel="chosen">
									<?php 
										$option_string = '<option value=""';
										if ($settings['txTone'] == '') { 
											$option_string .= ' selected';
										}
										$option_string .= '>(none)</option>';
										echo $option_string;

										foreach($ctcss as $freq => $code) {
											$option_string = '<option value="'.$freq.'"';
											if ($settings['txTone'] == $freq) { 
												$option_string .= ' selected';
											}
											$option_string .= '>'.$freq.'</option>';
											echo $option_string;
										}
									?>
								  </select>
								  <span class="help-inline">The CTCSS tone you need to hear the repeater.</span>
									</div>
								  </div>

								  <div class="control-group" id="ctcss_level_section">
									<label class="control-label" for="txCtcssLevel">TX CTCSS Level</label>
									<div class="controls">
									  <input type="number" id="txCtcssLevel" name="txCtcssLevel" min="1" max="20" value="<?php echo $settings['txCtcssLevel'] ? $settings['txCtcssLevel'] : '9'; ?>">
									  <span class="help-inline">Level of the TX CTCSS tone relative to audio (1&ndash;20). Lower = quieter tone. Default: 9.</span>
									</div>
								  </div>


							<legend>Text-to-Speech (Voice Announcements)</legend>

							  <div class="control-group">
								<label class="control-label">Status</label>
								<div class="controls">
								  <span class="help-inline" style="display:inline-block;padding-top:5px"><?php echo htmlspecialchars($tts_status); ?></span>
								</div>
							  </div>

							  <div class="control-group">
								<label class="control-label" for="tts_engine">Engine</label>
								<div class="controls">
								  <select id="tts_engine" name="tts_engine">
									<option value="piper"  <?php echo ($tts['tts_engine']==='piper')  ? 'selected' : ''; ?>>Piper (neural, recommended)</option>
									<option value="espeak" <?php echo ($tts['tts_engine']==='espeak') ? 'selected' : ''; ?>>eSpeak (robotic, lightweight)</option>
								  </select>
								  <span class="help-inline">Piper produces far more natural speech. eSpeak is used automatically as a fallback if Piper or the selected voice isn't available.</span>
								</div>
							  </div>

							  <div class="control-group">
								<label class="control-label" for="tts_piper_voice">Piper Voice</label>
								<div class="controls">
								  <?php if (count($tts_voices) > 0): ?>
								  <select id="tts_piper_voice" name="tts_piper_voice">
									<?php foreach ($tts_voices as $v):
										$sel = ($tts['tts_piper_voice'] === $v['rel'] || $tts['tts_piper_voice'] === $v['name']) ? 'selected' : ''; ?>
									  <option value="<?php echo htmlspecialchars($v['rel']); ?>" <?php echo $sel; ?>><?php echo htmlspecialchars($v['name']); ?></option>
									<?php endforeach; ?>
								  </select>
								  <span class="help-inline">Voices found in <code>/var/lib/openrepeater/piper/voices/</code>.</span>
								  <?php else: ?>
								  <input type="text" id="tts_piper_voice" name="tts_piper_voice" class="input-xlarge" value="<?php echo htmlspecialchars($tts['tts_piper_voice']); ?>" placeholder="(no voices installed)">
								  <span class="help-inline" style="color:#b94a48">No Piper voices found in <code>/var/lib/openrepeater/piper/voices/</code>. Download a <code>.onnx</code> + <code>.onnx.json</code> pair from <a href="https://huggingface.co/rhasspy/piper-voices" target="_blank">huggingface.co/rhasspy/piper-voices</a> and place both files there, then reload this page.</span>
								  <?php endif; ?>
								</div>
							  </div>

							  <div class="control-group">
								<label class="control-label" for="tts_piper_length_scale">Speed</label>
								<div class="controls">
								  <input id="tts_piper_length_scale" name="tts_piper_length_scale" type="number" step="0.05" min="0.3" max="3.0" value="<?php echo htmlspecialchars($tts['tts_piper_length_scale']); ?>">
								  <span class="help-inline">Piper <code>length_scale</code>. 1.0 = normal. Lower = faster, higher = slower (0.9 is a clear choice for IDs).</span>
								</div>
							  </div>

							  <div class="control-group">
								<label class="control-label" for="tts_piper_noise_scale">Expressiveness</label>
								<div class="controls">
								  <input id="tts_piper_noise_scale" name="tts_piper_noise_scale" type="number" step="0.05" min="0" max="1.5" value="<?php echo htmlspecialchars($tts['tts_piper_noise_scale']); ?>">
								  <span class="help-inline">Piper <code>noise_scale</code>. Default 0.667. Lower = flatter, higher = more variation.</span>
								</div>
							  </div>

							  <div class="control-group">
								<label class="control-label" for="tts_piper_sentence_silence">Sentence Pause</label>
								<div class="controls">
								  <div class="input-append">
									<input id="tts_piper_sentence_silence" name="tts_piper_sentence_silence" type="number" step="0.05" min="0" max="2" value="<?php echo htmlspecialchars($tts['tts_piper_sentence_silence']); ?>"><span class="add-on">sec</span>
								  </div>
								  <span class="help-inline">Piper <code>sentence_silence</code>. Pause between sentences. Default 0.2.</span>
								</div>
							  </div>

							  <input type="hidden" id="tts_piper_noise_w" name="tts_piper_noise_w" value="<?php echo htmlspecialchars($tts['tts_piper_noise_w']); ?>">
							  <input type="hidden" id="tts_espeak_voice" name="tts_espeak_voice" value="<?php echo htmlspecialchars($tts['tts_espeak_voice']); ?>">

							  <div class="control-group">
								<label class="control-label" for="tts_gain_db">Volume Gain</label>
								<div class="controls">
								  <div class="input-append">
									<input id="tts_gain_db" name="tts_gain_db" type="number" step="0.5" min="-20" max="20" value="<?php echo htmlspecialchars($tts['tts_gain_db']); ?>"><span class="add-on">dB</span>
								  </div>
								  <span class="help-inline">Applied by sox after synthesis. 0 = no change.</span>
								</div>
							  </div>

							  <div class="control-group">
								<label class="control-label">&nbsp;</label>
								<div class="controls">
								  <button type="button" id="ttsTestBtn" class="btn"><i class="icon-volume-up"></i> Test Voice</button>
								  <span id="ttsTestStatus" style="margin-left:8px"></span>
								  <audio id="ttsTestAudio" style="display:none;margin-top:8px;width:100%" controls></audio>
								  <div class="help-block" style="margin-top:6px">Plays a short sample with the values shown above (no save needed). Module announcements update on the next Rebuild &amp; Restart.</div>
								</div>
							  </div>

							  </fieldset>

					</div>
				</div><!--/span-->			
			</div><!--/row-->
			</form>   

    
<?php include('includes/footer.php'); ?>

<?php
// --------------------------------------------------------
// SESSION CHECK TO SEE IF USER IS LOGGED IN.
 } // close ELSE to end login check from top of page
// --------------------------------------------------------
?>