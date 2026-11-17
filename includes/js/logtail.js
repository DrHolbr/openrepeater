/* Copyright (c) 2012: Daniel Richman. License: GNU GPL 3 */
/* Additional features: Priyesh Patel                     */

(function () {

var dataelem = "#data";
var pausetoggle = "#pause";
var scrollelems = ["html", "body"];

var url = "functions/log_stream.php";
var fix_rn = true;
var load = 35 * 35; /* 30KB */
var poll = 1; /* 1ms */

var kill = false;
var loading = false;
var pause = false;
var reverse = false;
var log_data = "";
var log_file_size = 0;

/* :-( https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/parseInt */
function csrf_token() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute('content') : '';
}

function parseInt2(value) {
    if (value === null || value === undefined || !(/^[0-9]+$/.test(value))) {
        error("The log stream did not return an integer length.");
        return 0;
    }
    var v = Number(value);
    if (isNaN(v)) {
        error("The log stream did not return an integer length.");
        return 0;
    }
    return v;
}

function get_log() {
    if (kill | loading) return;
    loading = true;

    var range;
    var first_load;
    var must_get_206;
    if (log_file_size === 0) {
        /* Get the last 'load' bytes */
        range = "-" + load.toString();
        first_load = true;
        must_get_206 = false;
    } else {
        /* Get the (log_file_size - 1)th byte, onwards. */
        range = (log_file_size - 1).toString() + "-";
        first_load = false;
        must_get_206 = log_file_size > 1;
    }

    /* The "log_file_size - 1" deliberately reloads the last byte, which we already
     * have. This is to prevent a 416 "Range unsatisfiable" error: a response
     * of length 1 tells us that the file hasn't changed yet. A 416 shows that
     * the file has been trucnated */

    $.ajax(url, {
        dataType: "text",
        cache: false,
        headers: {
            Range: "bytes=" + range,
            "X-CSRF-Token": csrf_token()
        },
        success: function (data, s, xhr) {
            loading = false;

            var content_size;

            if (xhr.status === 206) {
                var c_r = xhr.getResponseHeader("Content-Range");
                if (!c_r) {
                    error("The log stream did not return Content-Range.");
                    return;
                }

                log_file_size = parseInt2(c_r.split("/")[1]);
                content_size = parseInt2(xhr.getResponseHeader("Content-Length"));
            } else if (xhr.status === 200) {
                if (must_get_206) {
                    error("The log stream did not return partial content.");
                    return;
                }

                content_size = log_file_size =
                        parseInt2(xhr.getResponseHeader("Content-Length"));
            } else {
                error("The log stream returned status " + xhr.status + ".");
                return;
            }
            if (kill) return;

            if (first_load && data.length > load) {
                error("The log stream returned more text than requested.");
                return;
            }

            var added = false;

            if (first_load) {
                /* Clip leading part-line if not the whole file */
                if (content_size < log_file_size) {
                    var start = data.indexOf("\n");
                    log_data = data.substring(start + 1);
                } else {
                    log_data = data;
                }

                added = true;
            } else {
                /* Drop the first byte (see above) */
                log_data += data.substring(1);

                if (log_data.length > load) {
                    var start = log_data.indexOf("\n", log_data.length - load);
                    log_data = log_data.substring(start + 1);
                }

                if (data.length > 1)
                    added = true;
            }

            if (added)
                show_log(added);
            setTimeout(get_log, poll);
        },
        error: function (xhr, s, t) {
            loading = false;

            if (xhr.status === 416) {
                /* The file was truncated or rotated. Read from the start again. */
                log_file_size = 0;
                log_data = "";
                show_log();
                setTimeout(get_log, poll);
                return;
            }
            var detail = (xhr.responseText || "").replace(/\s+$/, "");
            if (!detail) {
                detail = "The log stream failed (status " + xhr.status + ").";
            }
            kill = true;
            $(dataelem).text(detail);
            scroll(0);
        }
    });
}

function scroll(where) {
    for (var i = 0; i < scrollelems.length; i++) {
        var s = $(scrollelems[i]);
        if (where === -1)
            s.scrollTop(s.height());
        else
            s.scrollTop(where);
    }
}

function show_log() {
    if (pause) return;

    var t = log_data;

    if (reverse) {
        var t_a = t.split(/\n/g);
        t_a.reverse();
        if (t_a[0] == "") 
            t_a.shift();
        t = t_a.join("\n");
    }

    if (fix_rn)
        t = t.replace(/\n/g, "\r\n");

    $(dataelem).text(t);
    if (!reverse)
        scroll(-1);
}

function error(what) {
    kill = true;

    $(dataelem).text("An error occured :-(.\r\n" +
                     "Reloading may help; no promises.\r\n" + 
                     what);
    scroll(0);

    return false;
}

$(document).ready(function () {
    window.onerror = error;

    /* If URL is /logtail/?noreverse display in chronological order */
    var hash = location.search.replace(/^\?/, "");
    if (hash == "noreverse")
        reverse = false;

    /* Add pause toggle */
    $(pausetoggle).click(function (e) {
        pause = !pause;
        $(pausetoggle).text(pause ? "Unpause" : "Pause");
        show_log();
        e.preventDefault();
    });

    get_log();
});

})();
