#!/usr/bin/env bash
# Build one branch with build-optimistic.sh (Neutron Clang, host glibc, ccache)
# and stage the files uploaded as its GitHub Actions artifact.
#
# Environment:
#   KERNEL_DIR TOOLCHAIN_DIR OUT_DIR  source checkout, Neutron root, Kbuild output
#   STAGE_DIR                         artifact directory to create
#   BUILD_BRANCH BUILD_BASE           local branch to build, commit named by -g<sha>
#   BUILD_SUFFIX BUILD_RELEASE        CONFIG_LOCALVERSION and the expected uname -r
#   KBUILD_USER KBUILD_HOST KBUILD_TIME  shared build identity (KBUILD_TIME: date -d input)
# ccache honors CCACHE_* as usual.
set -euo pipefail

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

for name in KERNEL_DIR TOOLCHAIN_DIR OUT_DIR STAGE_DIR BUILD_BRANCH BUILD_BASE BUILD_SUFFIX \
	BUILD_RELEASE KBUILD_USER KBUILD_HOST KBUILD_TIME; do
	[[ -n "${!name:-}" ]] || fail "$name is not set"
done
[[ ! -e "$STAGE_DIR" ]] || fail "stage directory already exists: $STAGE_DIR"
[[ ! -e "$OUT_DIR/dist" ]] || fail "output directory already has a dist/: $OUT_DIR"

SCRIPT_DIR=$(dirname -- "$(realpath -e -- "${BASH_SOURCE[0]}")")
ccache --zero-stats >/dev/null
"$SCRIPT_DIR/build-optimistic.sh" \
	--source "$KERNEL_DIR" \
	--clang neutron \
	--toolchain "$TOOLCHAIN_DIR" \
	--host-libc glibc \
	--branch "$BUILD_BRANCH" \
	--base "$BUILD_BASE" \
	--suffix "$BUILD_SUFFIX" \
	--out "$OUT_DIR" \
	--ccache \
	--build-user "$KBUILD_USER" \
	--build-host "$KBUILD_HOST" \
	--build-timestamp "$KBUILD_TIME"
ccache --show-stats

shopt -s nullglob
dists=("$OUT_DIR"/dist/*/)
shopt -u nullglob
((${#dists[@]} == 1)) || fail "expected exactly one dist directory under $OUT_DIR/dist"
DIST=${dists[0]%/}
[[ $(<"$DIST/kernel.release") == "$BUILD_RELEASE" ]] || fail "built $(<"$DIST/kernel.release"), expected $BUILD_RELEASE"

mkdir -p -- "$STAGE_DIR"
for file in Image.gz system_dlkm-modules.tar.gz kernel.release build-info.txt Module.symvers SHA256SUMS; do
	cp -- "$DIST/$file" "$STAGE_DIR/$file"
done
(cd -- "$STAGE_DIR" && sha256sum -c SHA256SUMS)
