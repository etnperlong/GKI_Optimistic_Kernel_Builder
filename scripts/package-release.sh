#!/usr/bin/env bash
# Package every build of one prepared release into its AnyKernel3 zip.
# KERNELS holds one downloaded artifact directory per kernel release.
set -euo pipefail

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

(($# == 4)) || fail "usage: package-release.sh <metadata.json> <kernels-dir> <anykernel3-dir> <assets-dir>"
METADATA=$1
KERNELS=$2
AK3=$3
ASSETS=$4
SCRIPT_DIR=$(dirname -- "$(realpath -e -- "${BASH_SOURCE[0]}")")

tag=$(jq -r .tag "$METADATA")
android_branch=$(jq -r .android_branch "$METADATA")
build_time=$(jq -r .build.time.iso "$METADATA")
toolchain=$(jq -r '"Neutron Clang \(.toolchain.clang_version) (\(.toolchain.tag))"' "$METADATA")
builds=$(jq -r '(.base, .variants[]) | [.name, .release, .asset, .commit_url] | @tsv' "$METADATA")

while IFS=$'\t' read -r name release asset commit_url; do
	[[ -f "$KERNELS/$release/kernel.release" && $(<"$KERNELS/$release/kernel.release") == "$release" ]] ||
		fail "$KERNELS/$release does not hold kernel release $release"
	"$SCRIPT_DIR/package-anykernel.sh" "$AK3" "$KERNELS/$release/Image.gz" "$ASSETS/$asset" \
		"KERNEL_STRING=$name $tag GKI" \
		"KERNEL_RELEASE=$release" \
		"ANDROID_BRANCH=$android_branch" \
		"SOURCE_URL=$commit_url" \
		"BUILD_TIME=$build_time" \
		"TOOLCHAIN=$toolchain"
done <<< "$builds"
