#!/usr/bin/env node
"use strict";

const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

function boot() {
  const shown = [];
  const $ = function () {
    return {
      text(value) {
        if (value !== undefined) shown.push(String(value));
        return this;
      },
      click() { return this; },
      scrollTop() { return 0; },
      height() { return 0; },
      ready(fn) { fn(); return this; }
    };
  };
  let ajax = null;
  $.ajax = function (url, opts) { ajax = { url: url, opts: opts }; };
  const document = {
    querySelector() { return { getAttribute() { return "csrf-test-token"; } }; }
  };
  const window = {};
  global.document = document;
  global.window = window;
  global.$ = $;
  global.location = { search: "" };
  global.setTimeout = function () { return 0; };
  eval(src);
  return { shown: shown, ajax: ajax, window: window };
}

function fail(message) {
  console.error("FAIL: " + message);
  process.exit(1);
}

const populated = boot();
if (!populated.ajax || populated.ajax.url !== "functions/log_stream.php") {
  fail("client does not request the log stream");
}
if (populated.ajax.opts.headers.Range !== "bytes=-1225") {
  fail("first request range is " + populated.ajax.opts.headers.Range);
}
if (populated.ajax.opts.headers["X-CSRF-Token"] !== "csrf-test-token") {
  fail("first request omitted the CSRF token");
}
const line = "SvxLink v1.10.2@26.05.2 Event handler script successfully loaded\n";
populated.ajax.opts.success(line, "success", {
  status: 206,
  getResponseHeader(name) {
    if (name === "Content-Range") return "bytes 0-" + (line.length - 1) + "/" + line.length;
    if (name === "Content-Length") return String(line.length);
    return null;
  }
});
if (populated.shown.join("\n").indexOf("Event handler script successfully loaded") < 0) {
  fail("populated response was not rendered");
}
if (populated.shown.join("\n").indexOf("An error occured") >= 0) {
  fail("populated response rendered the error banner");
}
console.log("ok: client renders a populated range response");

const empty = boot();
empty.ajax.opts.success("", "success", {
  status: 200,
  getResponseHeader(name) {
    return name === "Content-Length" ? "0" : null;
  }
});
if (empty.shown.length === 0 || empty.shown[empty.shown.length - 1] !== "") {
  fail("empty log was not rendered as an empty view");
}
if (empty.shown.join("\n").indexOf("An error occured") >= 0) {
  fail("empty log rendered the error banner");
}
console.log("ok: client renders an empty log without throwing");

const bad = boot();
let thrown = false;
try {
  bad.ajax.opts.success("x", "success", {
    status: 200,
    getResponseHeader() { return null; }
  });
} catch (err) {
  thrown = true;
}
if (thrown) fail("null length still throws");
if (bad.shown.join("\n").indexOf("did not return an integer length") < 0) {
  fail("null length did not show a useful error");
}
console.log("ok: a null length is a useful error and does not throw");

const missing = boot();
missing.ajax.opts.error({ status: 404, responseText: "SvxLink log is not present.\n" }, "error", "error");
if (missing.shown.join("\n").indexOf("SvxLink log is not present.") < 0) {
  fail("missing log did not show the stream error");
}
if (missing.shown.join("\n").indexOf("Uncaught") >= 0 || missing.shown.join("\n").indexOf("Invalid integer") >= 0) {
  fail("missing log showed the old uncaught banner");
}
console.log("ok: a missing log shows the stream error");

const denied = boot();
denied.ajax.opts.error({ status: 403, responseText: "forbidden\n" }, "error", "error");
if (denied.shown[denied.shown.length - 1] !== "forbidden") {
  fail("refused stream did not show the refusal");
}
console.log("ok: a refused stream shows the refusal");
console.log("log client checks passed");
