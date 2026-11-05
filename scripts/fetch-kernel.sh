#!/usr/bin/env bash
# Shallow-fetch one pinned kernel commit as a local branch, as build-optimistic.sh
# expects. DEPTH must reach BASE_SHA so the script can prove it is an ancestor.
set -euo pipefail

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

(($# == 6)) || fail "usage: fetch-kernel.sh <repo-url> <branch> <sha> <depth> <base-sha> <dir>"
URL=$1
BRANCH=$2
SHA=$3
DEPTH=$4
BASE_SHA=$5
DIR=$6
[[ "$SHA" =~ ^[0-9a-f]{40}$ && "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "commits must be full SHA-1 hashes"
[[ "$DEPTH" =~ ^[1-9][0-9]*$ ]] || fail "depth must be a positive integer: $DEPTH"
git check-ref-format --branch "$BRANCH" >/dev/null || fail "invalid branch name: $BRANCH"
[[ ! -e "$DIR" ]] || fail "source directory already exists: $DIR"

git init --quiet -- "$DIR"
cd -- "$DIR"
git remote add origin "$URL"
git fetch --no-tags --depth="$DEPTH" origin "$SHA"
git switch --quiet --create "$BRANCH" "$SHA"
[[ $(git rev-parse HEAD) == "$SHA" ]] || fail "checked out $(git rev-parse HEAD), expected $SHA"
git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null || fail "base $BASE_SHA is not within $DEPTH commits of $SHA"
git merge-base --is-ancestor "$BASE_SHA" HEAD || fail "base $BASE_SHA is not an ancestor of $SHA"
git log -1 --format='%H %s'
