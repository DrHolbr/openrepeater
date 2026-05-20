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

});