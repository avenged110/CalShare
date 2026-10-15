#!/bin/sh
# Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
#
# Smoke test against a running CalShare: ./Scripts/smoke.sh <account> <password> [host] [port] [setup-port]
# Creates, syncs and deletes one event, trusting only the CalShare authority.
set -eu
USER_NAME=$1; PASS=$2
HOST=${3:-$(scutil --get LocalHostName).local}; PORT=${4:-8443}; SETUP=${5:-8080}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -sf "http://127.0.0.1:$SETUP/ca.cer" -o "$TMP/ca.der"
openssl x509 -inform der -in "$TMP/ca.der" -out "$TMP/ca.pem"
C="curl -sf --cacert $TMP/ca.pem -u $USER_NAME:$PASS"
BASE="https://$HOST:$PORT/dav/calendars/$USER_NAME/calendar"
step() { printf '%-40s' "$1"; }
step "principal discovery";  $C -X PROPFIND -H 'Depth: 0' "https://$HOST:$PORT/dav/" | grep -q "principals/$USER_NAME/" && echo ok
step "create event"; printf 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:smoke\r\nBEGIN:VEVENT\r\nUID:smoke-test\r\nDTSTAMP:20260101T000000Z\r\nDTSTART:20260101T120000Z\r\nSUMMARY:Smoke\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n' | $C -X PUT -H 'Content-Type: text/calendar' --data-binary @- "$BASE/smoke-test.ics" -o /dev/null -w '%{http_code}\n'
step "sync-collection lists it"; $C -X REPORT -H 'Depth: 1' --data '<d:sync-collection xmlns:d="DAV:"><d:sync-token/><d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop></d:sync-collection>' "$BASE/" | grep -q smoke-test.ics && echo ok
step "delete event"; $C -X DELETE "$BASE/smoke-test.ics" -o /dev/null -w '%{http_code}\n'
echo "All checks passed."
