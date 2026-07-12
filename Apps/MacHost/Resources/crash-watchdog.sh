#!/bin/sh
set -eu

parent_pid="$1"
app_bundle="$2"
armed_marker="$3"

while kill -0 "$parent_pid" 2>/dev/null; do
  sleep 1
done

test -f "$armed_marker" || exit 0
sleep 1
test -d "$app_bundle" || exit 0
/usr/bin/open "$app_bundle"
