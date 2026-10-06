#!/usr/bin/env bash
# Proves the leak rules in .gitleaks.toml catch Meshy and ElevenLabs keys, and
# that the repository's history is clean. The test keys are made at run time,
# so no key-shaped string is ever committed.
set -euo pipefail
cd "$(dirname "$0")/.."

config=.gitleaks.toml
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A random key: the prefix, then 2 x bytes hex characters.
fake() { printf '%s%s' "$1" "$(openssl rand -hex "$2")"; }

scan() { gitleaks dir "$1" --config "$config" --no-banner --redact >/dev/null 2>&1; }

# A broken config also exits non-zero, which would let expect_leak pass by
# accident, so a clean scan has to succeed first.
mkdir -p "$tmp/clean"
printf 'nothing secret here\n' > "$tmp/clean/notes.txt"
if ! scan "$tmp/clean"; then
	echo "FAIL: a clean folder did not scan clean (is $config valid?)"
	exit 1
fi
echo "ok: clean folder scans clean"

expect_leak() { # name, line
	mkdir -p "$tmp/$1"
	printf '%s\n' "$2" > "$tmp/$1/key.txt"
	if scan "$tmp/$1"; then
		echo "FAIL: $1 key was not flagged"
		exit 1
	fi
	echo "ok: $1 key flagged"
}

expect_leak meshy "MESHY_API_KEY=$(fake msy_ 16)"
expect_leak elevenlabs "ELEVENLABS_API_KEY=$(fake sk_ 24)"

if ! gitleaks git . --config "$config" --no-banner --redact >/dev/null 2>&1; then
	echo "FAIL: the history contains a leak (run: gitleaks git . --config $config -v)"
	exit 1
fi
echo "ok: history clean"
