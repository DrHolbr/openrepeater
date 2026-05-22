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
    $('#ttsTestBtn').on('click', function() {
        var $btn = $(this), $status = $('#ttsTestStatus'), $audio = $('#ttsTestAudio');
        $btn.prop('disabled', true);
        $status.text('Generating sample\u2026');
        $audio.hide().attr('src', '');

        $.ajax({
            url: 'functions/tts_preview.php',
            type: 'POST',
            data: {
                engine:           $('#tts_engine').val(),
                voice:            $('#tts_piper_voice').val(),
                length_scale:     $('#tts_piper_length_scale').val(),
                noise_scale:      $('#tts_piper_noise_scale').val(),
                noise_w:          $('#tts_piper_noise_w').val(),
                sentence_silence: $('#tts_piper_sentence_silence').val(),
                gain_db:          $('#tts_gain_db').val(),
                espeak_voice:     $('#tts_espeak_voice').val()
            },
            xhrFields: { responseType: 'blob' },
            success: function(blob, status, xhr) {
                var ct = xhr.getResponseHeader('Content-Type') || '';
                if (ct.indexOf('audio') !== 0) {
                    var fr = new FileReader();
                    fr.onload = function() {
                        var msg = fr.result;
                        try { msg = JSON.parse(msg).message || msg; } catch (e) {}
                        $status.html('<span style="color:#b94a48">' + msg + '</span>');
                    };
                    fr.readAsText(blob);
                    return;
                }
                var url = URL.createObjectURL(blob);
                $audio.attr('src', url).show();
                var el = $audio[0];
                if (el && el.play) { el.play().catch(function(){}); }
                $status.text('');
            },
            error: function(xhr) {
                $status.html('<span style="color:#b94a48">Preview failed (HTTP ' + xhr.status + ').</span>');
            },
            complete: function() { $btn.prop('disabled', false); }
        });
    });

});
