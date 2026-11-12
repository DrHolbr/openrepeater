#!/bin/bash
# Read the CSRF token rendered into a login or authenticated page.

http_token() {
	local html=$1 token
	token=$(printf '%s' "$html" | sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' | head -n 1)
	if [ -z "$token" ]; then
		token=$(printf '%s' "$html" | sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p' | head -n 1)
	fi
	printf '%s' "$token"
}
