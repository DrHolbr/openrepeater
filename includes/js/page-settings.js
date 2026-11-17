$(function() {

    if($('#repeaterDTMF_disable').val() == 'True') {
        $('#dtmf_disable').show();
    }

    $('#repeaterDTMF_disable').change(function(){
        if($('#repeaterDTMF_disable').val() == 'True') {
            $('#dtmf_disable').show();
        } else {
            $('#dtmf_disable').hide();
        }
    });

    if($('#txTone').val() == '') {
        $('#ctcss_level_section').hide();
    }

    $('#txTone').change(function(){
        if($(this).val() != '') {
            $('#ctcss_level_section').show();
        } else {
            $('#ctcss_level_section').hide();
        }
    });

    if($('#rxTone').val() == '') {
        $('#ctcss_rx_thresholds').hide();
        $('#ctcss_rx_close_threshold').hide();
    }

    $('#rxTone').change(function(){
        if($(this).val() != '') {
            $('#ctcss_rx_thresholds').show();
            $('#ctcss_rx_close_threshold').show();
        } else {
            $('#ctcss_rx_thresholds').hide();
            $('#ctcss_rx_close_threshold').hide();
        }
    });


	$('#settingsUpdate').on('change', function() {
	    //submit changes to db
	    var $form = $("#settingsUpdate");
	    var method = $form.attr("method") ? $form.attr("method").toUpperCase() : "GET";
	    $.ajax({
	        url: $form.attr("action"),
	        data: $form.serialize(),
	        type: method,
	        success: function() {
				$('.server_bar_wrap').show(); 
	        }
	    });
    });


    // ─── TTS "Test Voice" preview ────────────────────────────────────────
    // Posts the CURRENT (unsaved) form values to tts_preview.php, which
    // returns audio/wav, and plays it in the hidden <audio> element.
    // jQuery 1.7 cannot carry responseType=blob: its transport reads
    // responseXML, Chrome throws, and the exception is reported as HTTP 0
    // after the server has already returned 200. Use XMLHttpRequest directly.
    $('#ttsTestBtn').on('click', function(event) {
        event.preventDefault();
        var $btn = $(this), $status = $('#ttsTestStatus'), $audio = $('#ttsTestAudio');
        var previous = $audio.attr('src') || '';
        if (previous.indexOf('blob:') === 0) {
            URL.revokeObjectURL(previous);
        }
        $btn.prop('disabled', true);
        $status.text('Generating sample\u2026');
        $audio.hide().attr('src', '');

        function showFailure(text) {
            var span = document.createElement('span');
            span.style.color = '#b94a48';
            span.textContent = text;
            $status.empty().append(span);
        }
        function messageFromBlob(blob, done) {
            if (!blob) {
                done('');
                return;
            }
            var reader = new FileReader();
            reader.onload = function() {
                var msg = String(reader.result || '');
                try { msg = JSON.parse(msg).message || msg; } catch (e) {}
                done(msg);
            };
            reader.onerror = function() { done(''); };
            reader.readAsText(blob);
        }

        var meta = document.querySelector('meta[name="csrf-token"]');
        var token = meta ? (meta.getAttribute('content') || '') : '';
        var body = [
            'engine=' + encodeURIComponent($('#tts_engine').val() || ''),
            'flite_voice=' + encodeURIComponent($('#tts_flite_voice').val() || ''),
            'pic02wave_voice=' + encodeURIComponent($('#tts_pic02wave_voice').val() || ''),
            'gain_db=' + encodeURIComponent($('#tts_gain_db').val() || ''),
            'espeak_voice=' + encodeURIComponent($('#tts_espeak_voice').val() || '')
        ];
        if (token) {
            body.push('csrf_token=' + encodeURIComponent(token));
        }

        var xhr = new XMLHttpRequest();
        xhr.open('POST', 'functions/tts_preview.php', true);
        xhr.responseType = 'blob';
        xhr.timeout = 120000;
        xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
        if (token) {
            xhr.setRequestHeader('X-CSRF-Token', token);
        }
        xhr.onload = function() {
            var blob = xhr.response;
            var ct = (xhr.getResponseHeader('Content-Type') || '').toLowerCase();
            if (xhr.status !== 200 || ct.indexOf('audio/') !== 0) {
                messageFromBlob(blob, function(msg) {
                    var prefix = 'Preview failed (HTTP ' + xhr.status + ')';
                    showFailure(msg ? prefix + ': ' + msg : prefix + '.');
                });
                return;
            }
            if (!blob || !blob.size) {
                showFailure('Preview returned an empty audio file.');
                return;
            }
            var url = URL.createObjectURL(blob);
            $audio.attr('src', url).show();
            var el = $audio[0];
            if (!el || !el.play) {
                showFailure('This browser cannot play the voice sample.');
                return;
            }
            var played = el.play();
            if (played && typeof played.then === 'function') {
                played.then(function() {
                    $status.text('');
                }, function(err) {
                    var reason = err && err.message ? err.message : 'playback was blocked';
                    showFailure('Preview could not play: ' + reason + '.');
                });
                return;
            }
            $status.text('');
        };
        xhr.onerror = function() {
            showFailure('Preview failed: the browser could not read the response.');
        };
        xhr.ontimeout = function() {
            showFailure('Preview timed out before the voice sample finished.');
        };
        xhr.onabort = function() {
            showFailure('Preview was cancelled.');
        };
        xhr.onloadend = function() {
            $btn.prop('disabled', false);
        };
        xhr.send(body.join('&'));
    });

});
