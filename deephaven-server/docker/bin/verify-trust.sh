#!/bin/sh
# Verifies that every certificate added under /usr/local/share/ca-certificates/ is trusted by both the OS
# store and the JVM cacerts (D3 §6.2). Runs at image build time; usable in a running container as well.
set -eu
status=0
for crt in /usr/local/share/ca-certificates/*.crt; do
    [ -f "$crt" ] || continue
    alias="$(basename "$crt" .crt)"
    if keytool -list -cacerts -storepass changeit -alias "$alias" >/dev/null 2>&1; then
        echo "JVM cacerts: $alias present"
    else
        echo "JVM cacerts: $alias MISSING" >&2
        status=1
    fi
    # The OS bundle contains the certificate body verbatim once update-ca-certificates has run.
    body="$(sed -n '2p' "$crt")"
    if grep -qF "$body" /etc/ssl/certs/ca-certificates.crt; then
        echo "OS store:    $alias present"
    else
        echo "OS store:    $alias MISSING" >&2
        status=1
    fi
done
exit "$status"
