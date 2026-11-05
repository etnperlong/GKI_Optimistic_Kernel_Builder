#!/usr/bin/env bash
# Install one Neutron Clang build with antman; patch it to a bundled glibc when
# the host glibc is older than the build requires (build.info host-glibc).
set -euo pipefail

# antman v3.1
ANTMAN_URL=https://raw.githubusercontent.com/Neutron-Toolchains/antman/0b32c45e3ad83a953b4bc3fd2feb4ad3cc87c1e8/antman

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

(($# == 2)) || fail "usage: setup-neutron.sh <build-tag> <install-dir>"
TAG=$1
DIR=$2
[[ "$TAG" =~ ^[0-9]{8}$ ]] || fail "Neutron build tag must be DDMMYYYY: $TAG"
[[ ! -e "$DIR" ]] || fail "install directory already exists: $DIR"

mkdir -p -- "$DIR"
cd -- "$DIR"
curl -fsSL --retry 3 -o antman "$ANTMAN_URL"
chmod +x antman
./antman --sync="$TAG" --noprogress

required=$(awk '/^\[host-glibc\]$/ { getline; print; exit }' build.info)
host=$(getconf GNU_LIBC_VERSION | awk '{ print $2 }')
[[ "$required" =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "build.info has no usable host-glibc entry"
if [[ $(printf '%s\n' "$required" "$host" | sort -V | head -n1) != "$required" ]]; then
	printf 'Host glibc %s is older than the required %s; patching the toolchain\n' "$host" "$required"
	./antman --patch=glibc --noprogress
fi
./bin/clang --version
