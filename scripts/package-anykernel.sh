#!/usr/bin/env bash
# Package one Image.gz into an AnyKernel3 flashable zip using anykernel/anykernel.sh.
# Every @KEY@ placeholder in the template must be given as KEY=VALUE.
set -euo pipefail

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

(($# >= 3)) || fail "usage: package-anykernel.sh <anykernel3-dir> <Image.gz> <output.zip> [KEY=VALUE...]"
AK3=$(realpath -e -- "$1") || fail "AnyKernel3 directory does not exist: $1"
IMAGE=$(realpath -e -- "$2") || fail "kernel image does not exist: $2"
ZIP=$(realpath -m -- "$3")
shift 3
TEMPLATE="$(dirname -- "$(realpath -e -- "${BASH_SOURCE[0]}")")/../anykernel/anykernel.sh"
[[ -f "$AK3/tools/ak3-core.sh" && -f "$AK3/META-INF/com/google/android/update-binary" ]] || fail "not an AnyKernel3 tree: $AK3"
[[ ! -e "$ZIP" ]] || fail "output already exists: $ZIP"

script=$(<"$TEMPLATE")
for assignment; do
	key=${assignment%%=*}
	value=${assignment#*=}
	[[ "$assignment" == *=* && "$key" =~ ^[A-Z_]+$ ]] || fail "expected KEY=VALUE: $assignment"
	[[ "$script" == *"@$key@"* ]] || fail "template has no @$key@ placeholder"
	[[ "$value" != *[$'\n\r\'']* ]] || fail "$key value cannot contain newlines or single quotes"
	script=${script//"@$key@"/"$value"}
done
[[ ! "$script" =~ @[A-Z_]+@ ]] || fail "unfilled template placeholder: ${BASH_REMATCH[0]}"

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
cp -a -- "$AK3/." "$WORK/"
rm -rf -- "$WORK/.git"
printf '%s\n' "$script" > "$WORK/anykernel.sh"
cp -- "$IMAGE" "$WORK/Image.gz"
mkdir -p -- "$(dirname -- "$ZIP")"
# Upstream packaging command; LICENSE must stay in the zip.
(cd -- "$WORK" && zip -r9 -q "$ZIP" ./* -x README.md '*placeholder')
unzip -l "$ZIP"
