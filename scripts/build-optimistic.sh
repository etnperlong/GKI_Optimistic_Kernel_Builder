#!/usr/bin/env bash
# Build the selected local kernel branch and collect Image.gz plus signed GKI modules.
set -euo pipefail

SCRIPT_DIR=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")")
# Defaults follow this repository's GitHub Actions layout (build-kernel.yml):
# kernel/, toolchain/ and out/ under the repository root ($GITHUB_WORKSPACE).
WORKSPACE=$(realpath -e -- "$SCRIPT_DIR/..")
SOURCE="$WORKSPACE/kernel"
GOOGLE_TOOLCHAIN="$WORKSPACE/toolchain-google"
NEUTRON_TOOLCHAIN="$WORKSPACE/toolchain"
CLANG=neutron
TOOLCHAIN=
HOST_BUILD_TOOLS="$WORKSPACE/build-tools"
HOST_LIBC=
BRANCH=optimistic
BASE=
SUFFIX=-Optimistic
OUT=
USE_CCACHE=1
CCACHE_BIN=
JOBS=$(nproc)
if (( JOBS > 8 )); then JOBS=8; fi
BUILD_USER=${KBUILD_BUILD_USER-}
[[ ${KBUILD_BUILD_USER+x} ]] || BUILD_USER=evans
BUILD_HOST=${KBUILD_BUILD_HOST-}
[[ ${KBUILD_BUILD_HOST+x} ]] || BUILD_HOST=github-actions
BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP-}
[[ ${KBUILD_BUILD_TIMESTAMP+x} ]] || BUILD_TIMESTAMP=now

usage() {
	cat <<'EOF'
Usage: build-optimistic.sh [options]

Build Image.gz and signed, stripped in-tree GKI modules; this does not create
an AnyKernel3 flash ZIP or a system_dlkm.img. The modules archive still needs
partition-image packaging before it can be used by AnyKernel3.

Options (default paths are relative to the repository root, i.e. $GITHUB_WORKSPACE):
  --source PATH    Kernel source (default: kernel/)
  --clang google|neutron   Toolchain preset (default: neutron). It only supplies
                          defaults; explicit --toolchain, --host-libc and --out win:
                            neutron  toolchain/ (installed by setup-neutron.sh),
                                     --host-libc glibc, --out out/
                            google   toolchain-google/,
                                     --host-libc musl, --out out-google/
                          Neutron ships only the x86_64-unknown-linux-gnu compiler-rt,
                          so it cannot link musl host tools.
  --toolchain PATH Clang toolchain root containing bin/ (default: from --clang)
  --host-build-tools PATH  Android host bundle with sysroots/ and linux_musl-x86/
                          (default: build-tools/; used only with --host-libc musl)
  --host-libc musl|glibc   Libc for host tools such as fixdep and resolve_btfids
                          (default: from --clang). musl uses the Android bundle;
                          glibc uses the system headers/libraries and the toolchain's
                          x86_64-unknown-linux-gnu runtime
  --branch NAME    Local git branch to build (default: optimistic)
  --base REF       Commit whose 12-character hash goes into the kernel release
                   (-g<sha>); must be an ancestor of --branch (default: --branch).
                   Use it to build a derived branch such as optimistic+ksu while
                   naming the release after its baseline.
  --suffix VALUE   Kernel suffix (default: -Optimistic; --suffix= disables it)
  --out PATH       Persistent Kbuild output directory (default: from --clang)
  --jobs N, -j N   Parallel make jobs (default: min(nproc, 8))
  --ccache         Cache kernel/module compilation with ccache from PATH (default)
  --no-ccache      Compile without ccache (last switch wins)
  --build-user NAME       Kernel build identity (default: KBUILD_BUILD_USER or evans)
  --build-host NAME       Kernel build host (default: KBUILD_BUILD_HOST or github-actions)
  --build-timestamp VALUE Kernel build time (default: KBUILD_BUILD_TIMESTAMP or now)
                          Dates without a zone are interpreted as UTC and normalized
                          to English UTC; identities allow only letters, digits,
                          '.', '_', '+', and '-'.
                          Empty values are rejected. VALUE also accepts @Unix-seconds.
                          CLI values override KBUILD_BUILD_* environment values,
                          which override evans/github-actions/current time. Chosen values
                          are recorded in build-info.txt. Fixed metadata alone does
                          not guarantee reproducible artifacts.
                          Example: --build-timestamp "$CI_BUILD_TIMESTAMP"
                          or:
                            KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=ci-node \
                              KBUILD_BUILD_TIMESTAMP=2026-11-05T12:00:00Z ./build-optimistic.sh
  --help           Show this help

Each successful run publishes a new timestamped directory under OUT/dist/:
  Image.gz, system_dlkm/lib/modules/ (flat .ko files and metadata),
  system_dlkm-modules.tar.gz, kernel.release, build-info.txt, .config,
  Module.symvers, and SHA256SUMS.

Object files are reused. Changing the compiler or host bundle invalidates the
host BPF tool cache; use a separate --out for independent build configurations.

ccache must be installed unless --no-ccache is given. Its normal configuration and CCACHE_*
environment variables (for example CCACHE_DIR and CCACHE_MAXSIZE) are honored.
The cache is shared across output directories by default; host tools and linking
are not cached. Cache hits still depend on matching compiler inputs/options.
Example:
  CCACHE_DIR="$HOME/.cache/ccache" CCACHE_MAXSIZE=20G ./build-optimistic.sh
EOF
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

while (($#)); do
	case "$1" in
		--source)
			(($# >= 2)) || fail "--source requires a path"
			SOURCE=$2; shift 2 ;;
		--source=*) SOURCE=${1#*=}; shift ;;
		--clang)
			(($# >= 2)) || fail "--clang requires google or neutron"
			CLANG=$2; shift 2 ;;
		--clang=*) CLANG=${1#*=}; shift ;;
		--toolchain)
			(($# >= 2)) || fail "--toolchain requires a path"
			TOOLCHAIN=$2; shift 2 ;;
		--toolchain=*) TOOLCHAIN=${1#*=}; shift ;;
		--host-build-tools)
			(($# >= 2)) || fail "--host-build-tools requires a path"
			HOST_BUILD_TOOLS=$2; shift 2 ;;
		--host-build-tools=*) HOST_BUILD_TOOLS=${1#*=}; shift ;;
		--host-libc)
			(($# >= 2)) || fail "--host-libc requires musl or glibc"
			HOST_LIBC=$2; shift 2 ;;
		--host-libc=*) HOST_LIBC=${1#*=}; shift ;;
		--branch)
			(($# >= 2)) || fail "--branch requires a name"
			BRANCH=$2; shift 2 ;;
		--branch=*) BRANCH=${1#*=}; shift ;;
		--base)
			(($# >= 2)) || fail "--base requires a git revision"
			BASE=$2; shift 2 ;;
		--base=*) BASE=${1#*=}; shift ;;
		--suffix)
			(($# >= 2)) || fail "--suffix requires a value"
			SUFFIX=$2; shift 2 ;;
		--suffix=*) SUFFIX=${1#*=}; shift ;;
		--out)
			(($# >= 2)) || fail "--out requires a path"
			OUT=$2; shift 2 ;;
		--out=*) OUT=${1#*=}; shift ;;
		--jobs|-j)
			(($# >= 2)) || fail "$1 requires a positive integer"
			JOBS=$2; shift 2 ;;
		--jobs=*|-j=*) JOBS=${1#*=}; shift ;;
		--ccache) USE_CCACHE=1; shift ;;
		--no-ccache) USE_CCACHE=0; shift ;;
		--build-user)
			(($# >= 2)) || fail "--build-user requires a name"
			BUILD_USER=$2; shift 2 ;;
		--build-user=*) BUILD_USER=${1#*=}; shift ;;
		--build-host)
			(($# >= 2)) || fail "--build-host requires a name"
			BUILD_HOST=$2; shift 2 ;;
		--build-host=*) BUILD_HOST=${1#*=}; shift ;;
		--build-timestamp)
			(($# >= 2)) || fail "--build-timestamp requires a value"
			BUILD_TIMESTAMP=$2; shift 2 ;;
		--build-timestamp=*) BUILD_TIMESTAMP=${1#*=}; shift ;;
		--help|-h) usage; exit 0 ;;
		*) fail "unknown option: $1 (use --help)" ;;
	esac
done

[[ -n "$BUILD_USER" && "$BUILD_USER" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "build user must be nonempty and contain only letters, digits, '.', '_', '+', or '-'"
[[ -n "$BUILD_HOST" && "$BUILD_HOST" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "build host must be nonempty and contain only letters, digits, '.', '_', '+', or '-'"
[[ -n "$BUILD_TIMESTAMP" ]] || fail "build timestamp must be nonempty"
NORMALIZED_BUILD_TIMESTAMP=$(LC_ALL=C TZ=UTC date -u -d "$BUILD_TIMESTAMP" '+%a %b %e %T UTC %Y') || fail "invalid build timestamp: $BUILD_TIMESTAMP"
BUILD_TIMESTAMP=$NORMALIZED_BUILD_TIMESTAMP


[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "jobs must be a positive integer"
if (( USE_CCACHE )); then
	CCACHE_BIN=$(type -P ccache) || fail "--ccache requires ccache in PATH"
	CCACHE_BIN=$(realpath -e -- "$CCACHE_BIN") || fail "cannot resolve ccache executable"
	[[ "$CCACHE_BIN" != *[$' \t\r\n:']* ]] || fail "ccache executable path cannot contain whitespace or ':' (Kbuild path limitation): $CCACHE_BIN"
fi
case "$CLANG" in
	google) DEFAULT_TOOLCHAIN=$GOOGLE_TOOLCHAIN; DEFAULT_HOST_LIBC=musl; DEFAULT_OUT="$WORKSPACE/out-google" ;;
	neutron) DEFAULT_TOOLCHAIN=$NEUTRON_TOOLCHAIN; DEFAULT_HOST_LIBC=glibc; DEFAULT_OUT="$WORKSPACE/out" ;;
	*) fail "clang preset must be google or neutron: $CLANG" ;;
esac
TOOLCHAIN=${TOOLCHAIN:-$DEFAULT_TOOLCHAIN}
HOST_LIBC=${HOST_LIBC:-$DEFAULT_HOST_LIBC}
OUT=${OUT:-$DEFAULT_OUT}
[[ "$HOST_LIBC" == musl || "$HOST_LIBC" == glibc ]] || fail "host libc must be musl or glibc: $HOST_LIBC"
[[ -z "$SUFFIX" || "$SUFFIX" =~ ^-[A-Za-z0-9._+-]+$ ]] || fail "suffix must be empty or start with '-' and contain only letters, digits, '.', '_', '+', or '-'"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE GIT_CEILING_DIRECTORIES
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || fail "invalid local branch name: $BRANCH"
[[ -n "$BASE" ]] || BASE=$BRANCH
[[ "$BASE" != -* && "$BASE" != *[$' \t\r\n']* ]] || fail "invalid base revision: $BASE"

# Resolve the path held in variable $1 in place; report the unresolved path on failure.
resolve_existing() {
	local resolved
	resolved=$(realpath -e -- "${!1}" 2>/dev/null) || fail "$2 does not exist: ${!1}"
	printf -v "$1" '%s' "$resolved"
}
resolve_existing SOURCE "source directory"
resolve_existing TOOLCHAIN "toolchain directory"
if [[ "$HOST_LIBC" == musl ]]; then
	resolve_existing HOST_BUILD_TOOLS "host build-tools bundle"
else
	HOST_BUILD_TOOLS=
fi
OUT=$(realpath -m -- "$OUT") || fail "cannot resolve output path"
for path in "$SOURCE" "$TOOLCHAIN" ${HOST_BUILD_TOOLS:+"$HOST_BUILD_TOOLS"} "$OUT"; do
	[[ "$path" != *[$' \t\r\n:']* ]] || fail "source, toolchain, and output paths cannot contain whitespace or ':' (Kbuild path limitation): $path"
done

path_is_within() {
	local path=$1 parent=$2
	[[ "$path" == "$parent" || "$path" == "$parent/"* ]]
}
path_is_within "$OUT" "$SOURCE" && fail "output directory must be outside the source tree: $OUT"
path_is_within "$SOURCE" "$OUT" && fail "output directory cannot contain the source tree: $OUT"
[[ "$OUT" != "$WORKSPACE" ]] || fail "output directory cannot be the repository root"

for command_name in git make nproc realpath flock sha256sum tee awk grep sed cp mv mkdir mktemp date tar gzip depmod modinfo rm; do
	command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
for tool in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip; do
	[[ -x "$TOOLCHAIN/bin/$tool" ]] || fail "missing executable in toolchain: $TOOLCHAIN/bin/$tool"
done
if [[ "$HOST_LIBC" == musl ]]; then
	HOST_SYSROOT="$HOST_BUILD_TOOLS/sysroots/x86_64-unknown-linux-musl"
	HOST_PREBUILTS="$HOST_BUILD_TOOLS/linux_musl-x86"
	for required in "$HOST_SYSROOT/include/stdio.h" "$HOST_SYSROOT/lib/libc_musl.so" \
		"$HOST_PREBUILTS/include/libelf.h" "$HOST_PREBUILTS/include/openssl/crypto.h" \
		"$HOST_PREBUILTS/lib64/libelf.so" "$HOST_PREBUILTS/lib64/libcrypto.so"; do
		[[ -f "$required" ]] || fail "incomplete Android host build-tools bundle: missing $required"
	done
fi

[[ -d "$SOURCE" ]] || fail "source directory does not exist: $SOURCE"
[[ -f "$SOURCE/build.config.constants" && -f "$SOURCE/build.config.common" ]] || fail "Android build configuration files are missing from $SOURCE"
[[ -x "$SOURCE/scripts/config" ]] || fail "kernel scripts/config is not executable"
mkdir -p -- "$OUT"
OUT=$(realpath -e -- "$OUT")
path_is_within "$OUT" "$SOURCE" && fail "output directory resolves inside the source tree: $OUT"
path_is_within "$SOURCE" "$OUT" && fail "output directory resolves to an ancestor of the source tree: $OUT"
[[ "$OUT" != "$WORKSPACE" ]] || fail "output directory cannot be the repository root"
[[ "$OUT" != *%* ]] || fail "output directory cannot contain '%' (Kbuild modules_install path limitation)"

cd -- "$SOURCE"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || fail "source is not a git worktree: $SOURCE"
REPO_ROOT=$(realpath -e -- "$REPO_ROOT")
[[ "$REPO_ROOT" == "$SOURCE" ]] || fail "source path must be the git worktree root: $SOURCE"
GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
[[ "$GIT_COMMON_DIR" == /* ]] || GIT_COMMON_DIR="$SOURCE/$GIT_COMMON_DIR"
GIT_COMMON_DIR=$(realpath -e -- "$GIT_COMMON_DIR")
path_is_within "$OUT" "$GIT_COMMON_DIR" && fail "output directory cannot be inside git metadata: $OUT"
path_is_within "$GIT_COMMON_DIR" "$OUT" && fail "output directory cannot contain git metadata: $OUT"
[[ ! -L "$OUT/.build-optimistic.lock" ]] || fail "refusing symlinked output lock: $OUT/.build-optimistic.lock"
[[ ! -L "$GIT_COMMON_DIR/build-optimistic.lock" ]] || fail "refusing symlinked source lock: $GIT_COMMON_DIR/build-optimistic.lock"
exec 8>>"$OUT/.build-optimistic.lock"
flock -n 8 || fail "another build script is already using this output directory"
exec 9>>"$GIT_COMMON_DIR/build-optimistic.lock"
flock -n 9 || fail "another build script is already using this source repository"

assert_tracked_clean() {
	local status
	status=$(git --no-optional-locks status --porcelain --untracked-files=no)
	[[ -z "$status" ]] || fail $'tracked source changes are present; refusing to switch/build:\n'"$status"
}
git show-ref --verify --quiet "refs/heads/$BRANCH" || fail "local branch does not exist: $BRANCH"
assert_tracked_clean
if [[ $(git branch --show-current) != "$BRANCH" ]]; then
	git switch --quiet "$BRANCH"
fi
[[ $(git branch --show-current) == "$BRANCH" ]] || fail "failed to select local branch $BRANCH"
assert_tracked_clean
SOURCE_COMMIT=$(git rev-parse --verify HEAD)
BASE_COMMIT=$(git rev-parse --verify --quiet "$BASE^{commit}") || fail "base revision does not name a commit: $BASE"
git merge-base --is-ancestor "$BASE_COMMIT" "$SOURCE_COMMIT" || fail "base $BASE ($BASE_COMMIT) is not an ancestor of $BRANCH ($SOURCE_COMMIT)"
BASE_SHA12=${BASE_COMMIT:0:12}
[[ "$BASE_SHA12" =~ ^[0-9a-f]{12}$ ]] || fail "could not determine the 12-character base commit"

ANDROID_BRANCH=$(awk -F= '$1 == "BRANCH" { sub(/^[^=]*=/, ""); print }' "$SOURCE/build.config.constants")
KMI_GENERATION=$(awk -F= '$1 == "KMI_GENERATION" { sub(/^[^=]*=/, ""); print }' "$SOURCE/build.config.common")
[[ "$ANDROID_BRANCH" =~ ^android[0-9]{2,}(-[A-Za-z0-9._+-]+)?$ ]] || fail "unexpected Android BRANCH in build.config.constants: $ANDROID_BRANCH"
ANDROID_RELEASE=${ANDROID_BRANCH%%-*}
[[ "$KMI_GENERATION" =~ ^[0-9]+$ ]] || fail "unexpected KMI_GENERATION in build.config.common: $KMI_GENERATION"

# Keep inherited build/config knobs from silently changing the requested build.
unset BUILD_NUMBER LOCALVERSION KBUILD_EXTMOD KBUILD_OUTPUT KBUILD_SRC KERNELRELEASE \
	KBUILD_BUILD_USER KBUILD_BUILD_HOST KBUILD_BUILD_TIMESTAMP KBUILD_BUILD_VERSION \
	KCFLAGS KCFLAGS_MODULE KAFLAGS KCPPFLAGS CFLAGS CFLAGS_MODULE CXXFLAGS CPPFLAGS \
	LDFLAGS HOSTCFLAGS HOSTCXXFLAGS HOSTLDFLAGS HOSTLDLIBS KBUILD_CFLAGS KBUILD_AFLAGS \
	KBUILD_LDFLAGS KBUILD_EXTRA_SYMBOLS KBUILD_MODPOST_WARN KBUILD_SIGN_PIN \
	CROSS_COMPILE CROSS_COMPILE_COMPAT CROSS_COMPILE_ARM32 CLANG_TRIPLE \
	CC LD AR NM OBJCOPY OBJDUMP READELF STRIP HOSTCC HOSTCXX HOSTLD HOSTAR \
	ARCH SUBARCH LLVM LLVM_IAS MAKE MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEOVERRIDES \
	KCONFIG_CONFIG KCONFIG_ALLCONFIG KCONFIG_AUTOCONFIG KCONFIG_AUTOHEADER KCONFIG_TRISTATE \
	KCONFIG_SPLITCONFIG KCONFIG_OVERWRITECONFIG KCONFIG_WARN_UNKNOWN_SYMBOLS KCONFIG_NOSILENTUPDATE \
	KCONFIG_SEED KCONFIG_PROBABILITY KCONFIG_WERROR CONFIG_ W CCACHE DTC INSTALL_MOD_PATH INSTALL_MOD_STRIP DEPMOD \
	CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH LD_LIBRARY_PATH


shopt -s nullglob
for path in "$SOURCE"/localversion*; do
	fail "source-tree localversion file would alter the required release: $path"
done
for path in "$OUT"/localversion*; do
	[[ "$path" == "$OUT/localversion" ]] || fail "unexpected output localversion file would alter the release: $path"
done
shopt -u nullglob
[[ ! -L "$OUT/localversion" ]] || fail "refusing to write through a symlink at $OUT/localversion"

TOOLBIN="$TOOLCHAIN/bin"
export PATH="$TOOLBIN${PATH:+:$PATH}"
# Wrap only target compilation; host tools retain their explicit libc setup.
TARGET_CC="$TOOLBIN/clang"
if (( USE_CCACHE )); then
	TARGET_CC="$CCACHE_BIN $TARGET_CC"
fi
if [[ "$HOST_LIBC" == musl ]]; then
	# Android's musl host sysroot keeps host tools independent of the system glibc.
	# Without ACK 586fda832cd6 (libbpf: Fix -Wdiscarded-qualifiers under C23), libbpf
	# fails against glibc >= 2.42, whose _GNU_SOURCE C23 strchr() returns const char *.
	HOST_CFLAGS="--target=x86_64-unknown-linux-musl --sysroot=$HOST_SYSROOT -I$HOST_PREBUILTS/include"
	HOST_LDFLAGS="--target=x86_64-unknown-linux-musl --sysroot=$HOST_SYSROOT --rtlib=compiler-rt --unwindlib=none -fuse-ld=lld"
	HOST_LDFLAGS+=" -L$HOST_PREBUILTS/lib64 -Wl,-rpath,$HOST_PREBUILTS/lib64"
	HOST_LDFLAGS+=" -Wl,--dynamic-linker,$HOST_SYSROOT/lib/libc_musl.so"
else
	# System glibc, headers, libelf, and libcrypto; for toolchains that ship only
	# the x86_64-unknown-linux-gnu runtime (for example Neutron clang).
	HOST_CFLAGS=
	HOST_LDFLAGS="-fuse-ld=lld"
fi
MAKE_BASE=(make -C "$SOURCE" ARCH=arm64 LLVM=1 LLVM_IAS=1
	CC="$TARGET_CC" LD="$TOOLBIN/ld.lld" AR="$TOOLBIN/llvm-ar" NM="$TOOLBIN/llvm-nm"
	OBJCOPY="$TOOLBIN/llvm-objcopy" OBJDUMP="$TOOLBIN/llvm-objdump" READELF="$TOOLBIN/llvm-readelf"
	STRIP="$TOOLBIN/llvm-strip" HOSTCC="$TOOLBIN/clang" HOSTCXX="$TOOLBIN/clang++"
	HOSTLD="$TOOLBIN/ld.lld" HOSTAR="$TOOLBIN/llvm-ar"
	"HOSTCFLAGS=$HOST_CFLAGS" "HOSTCXXFLAGS=$HOST_CFLAGS" "HOSTLDFLAGS=$HOST_LDFLAGS"
	"KBUILD_BUILD_USER=$BUILD_USER" "KBUILD_BUILD_HOST=$BUILD_HOST" "KBUILD_BUILD_TIMESTAMP=$BUILD_TIMESTAMP"
	"O=$OUT" "BRANCH=$ANDROID_BRANCH" "KMI_GENERATION=$KMI_GENERATION" LOCALVERSION= BUILD_NUMBER=)

mkdir -p -- "$OUT"
LOG="$OUT/build.log"
: > "$LOG"
printf 'Build started: %s\nSource: %s\nBranch: %s\nCommit: %s\nBase: %s (%s)\n' \
	"$(date -u +%FT%TZ)" "$SOURCE" "$BRANCH" "$SOURCE_COMMIT" "$BASE" "$BASE_COMMIT" | tee -a "$LOG"
printf 'Kernel build user: %s\nKernel build host: %s\nKernel build timestamp: %s\n' \
	"$BUILD_USER" "$BUILD_HOST" "$BUILD_TIMESTAMP" | tee -a "$LOG"
printf 'Compiler cache: %s\n' "${CCACHE_BIN:-disabled}" | tee -a "$LOG"
run_logged() {
	local command_line
	printf -v command_line '%q ' "$@"
	printf '+ %s\n' "$command_line" | tee -a "$LOG"
	"$@" 2>&1 | tee -a "$LOG"
}
CLANG_VERSION=$("$TOOLBIN/clang" --version)
# libbpf's outer archive rule tracks source timestamps, not compiler flags.
# Invalidate only this generated host-tool subtree when its environment changes.
HOST_ENV=$(printf '%s\n' "$TOOLCHAIN" "$CLANG_VERSION" "$HOST_CFLAGS" "$HOST_LDFLAGS" | sha256sum)
[[ ! -L "$OUT/.host-build-env" ]] || fail "refusing symlinked host environment marker"
if [[ ! -f "$OUT/.host-build-env" || $(<"$OUT/.host-build-env") != "$HOST_ENV" ]]; then
	rm -rf -- "$OUT/tools/bpf/resolve_btfids"
	printf '%s\n' "$HOST_ENV" > "$OUT/.host-build-env"
fi

run_logged "${MAKE_BASE[@]}" gki_defconfig
[[ -f "$OUT/.config" ]] || fail "gki_defconfig did not create $OUT/.config"
bash "$SOURCE/scripts/config" --file "$OUT/.config" --set-str LOCALVERSION "$SUFFIX" --disable LOCALVERSION_AUTO
printf '%s\n' "-android${ANDROID_RELEASE#android}-${KMI_GENERATION}-g${BASE_SHA12}" > "$OUT/localversion"
run_logged "${MAKE_BASE[@]}" olddefconfig
run_logged "${MAKE_BASE[@]}" syncconfig

for setting in CONFIG_MODULE_SIG=y CONFIG_MODULE_SIG_ALL=y CONFIG_MODULE_SIG_PROTECT=y; do
	grep -Fxq "$setting" "$OUT/.config" || fail "GKI module signing/protection is not enabled: expected $setting"
done
grep -Fxq 'CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"' "$OUT/.config" || fail "module signing must use the build-generated certs/signing_key.pem"
if grep -Eq '^CONFIG_MODULE_COMPRESS_(GZIP|XZ|ZSTD)=y$' "$OUT/.config"; then
	fail "compressed modules are enabled; system_dlkm output requires plain .ko files"
fi

KERNEL_VERSION=$("${MAKE_BASE[@]}" -s kernelversion)
[[ "$KERNEL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unexpected kernel version: $KERNEL_VERSION"
EXPECTED_RELEASE="${KERNEL_VERSION}-${ANDROID_RELEASE}-${KMI_GENERATION}-g${BASE_SHA12}${SUFFIX}"
ACTUAL_RELEASE=$("${MAKE_BASE[@]}" -s kernelrelease)
[[ "$ACTUAL_RELEASE" == "$EXPECTED_RELEASE" ]] || fail "kernelrelease mismatch: expected $EXPECTED_RELEASE, got $ACTUAL_RELEASE"
(( ${#EXPECTED_RELEASE} <= 64 )) || fail "kernelrelease exceeds the 64-character limit: $EXPECTED_RELEASE"

run_logged "${MAKE_BASE[@]}" "-j$JOBS" Image.gz modules
[[ -s "$OUT/arch/arm64/boot/Image.gz" ]] || fail "build did not produce a non-empty Image.gz"
[[ -s "$OUT/modules.order" ]] || fail "build did not produce modules.order"
[[ -s "$OUT/System.map" ]] || fail "build did not produce System.map for module dependency verification"
[[ -s "$OUT/Module.symvers" ]] || fail "build did not produce Module.symvers"

MODULE_STAGE=
DIST_STAGE=
cleanup() {
	if [[ -n "$MODULE_STAGE" && -d "$MODULE_STAGE" ]]; then rm -rf -- "$MODULE_STAGE"; fi
	if [[ -n "$DIST_STAGE" && -d "$DIST_STAGE" ]]; then rm -rf -- "$DIST_STAGE"; fi
}
trap cleanup EXIT
MODULE_STAGE=$(mktemp -d "$OUT/.system-dlkm.XXXXXX")
DIST_ROOT="$OUT/dist"
mkdir -p -- "$DIST_ROOT"
DIST_STAGE=$(mktemp -d "$DIST_ROOT/.${EXPECTED_RELEASE}.tmp.XXXXXX")
INSTALL_ROOT="$MODULE_STAGE/install"
FLAT_ROOT="$MODULE_STAGE/tree"
INSTALL_MODULES="$INSTALL_ROOT/lib/modules/$EXPECTED_RELEASE"
FLAT_MODULES="$FLAT_ROOT/lib/modules/$EXPECTED_RELEASE"
FINAL_SYSTEM_DLKM="$DIST_STAGE/system_dlkm"
FINAL_MODULES="$FINAL_SYSTEM_DLKM/lib/modules"
mkdir -p -- "$FLAT_MODULES" "$FINAL_MODULES"
run_logged "${MAKE_BASE[@]}" "-j$JOBS" modules_install "INSTALL_MOD_PATH=$INSTALL_ROOT" INSTALL_MOD_STRIP=1 DEPMOD=true

: > "$FLAT_MODULES/modules.order"
: > "$FLAT_MODULES/modules.load"
declare -A seen_modules=()
module_count=0
while IFS= read -r module_path || [[ -n "$module_path" ]]; do
	[[ -n "$module_path" ]] || continue
	[[ "$module_path" == *.ko && "$module_path" != /* && "$module_path" != *[$' \t\r\n:']* ]] || fail "invalid module path in modules.order: $module_path"
	case "/$module_path/" in */../*) fail "unsafe module path in modules.order: $module_path" ;; esac
	module_name=${module_path##*/}
	[[ -z "${seen_modules[$module_name]+present}" ]] || fail "duplicate module basename in modules.order: $module_name"
	seen_modules[$module_name]=1
	installed_module="$INSTALL_MODULES/kernel/$module_path"
	[[ -f "$installed_module" && ! -L "$installed_module" ]] || fail "modules_install did not produce expected module: $installed_module"
	vermagic=$(modinfo -F vermagic "$installed_module") || fail "cannot read vermagic from $installed_module"
	[[ "${vermagic%% *}" == "$EXPECTED_RELEASE" ]] || fail "module vermagic mismatch for $module_name: $vermagic"
	signer=$(modinfo -F signer "$installed_module") || fail "cannot read signer from $installed_module"
	[[ -n "$signer" ]] || fail "module was not signed: $module_name"
	cp -- "$installed_module" "$FLAT_MODULES/$module_name"
	printf '%s\n' "$module_name" >> "$FLAT_MODULES/modules.order"
	printf '%s\n' "$module_name" >> "$FLAT_MODULES/modules.load"
	((module_count += 1))
done < "$OUT/modules.order"
(( module_count > 0 )) || fail "modules.order did not list any loadable modules"
for metadata in modules.builtin modules.builtin.modinfo; do
	[[ -f "$INSTALL_MODULES/$metadata" ]] || fail "modules_install omitted $metadata"
	cp -- "$INSTALL_MODULES/$metadata" "$FLAT_MODULES/$metadata"
done

run_depmod() {
	local output rc=0 command_line
	printf -v command_line '%q ' "$@"
	printf '+ %s\n' "$command_line" | tee -a "$LOG"
	output=$("$@" 2>&1) || rc=$?
	if [[ -n "$output" ]]; then printf '%s\n' "$output" | tee -a "$LOG"; fi
	if (( rc != 0 )); then return "$rc"; fi
	if grep -Eqi 'unknown symbol|unresolved symbol' <<< "$output"; then
		fail "depmod reported unresolved module symbols; see $LOG"
	fi
}
run_depmod depmod -e -F "$OUT/System.map" -b "$FLAT_ROOT" "$EXPECTED_RELEASE"
[[ -s "$FLAT_MODULES/modules.dep" ]] || fail "depmod did not produce modules.dep"
sed -E -i 's@([^[:space:]:]+\.ko)@/system_dlkm/lib/modules/\1@g' "$FLAT_MODULES/modules.dep"
rm -f -- "$FLAT_MODULES/modules.dep.bin"
grep -Eq '^/system_dlkm/lib/modules/[^:]+\.ko:' "$FLAT_MODULES/modules.dep" || fail "flattened modules.dep paths were not rewritten for system_dlkm"
cp -a -- "$FLAT_MODULES/." "$FINAL_MODULES/"

cp -- "$OUT/arch/arm64/boot/Image.gz" "$DIST_STAGE/Image.gz"
cp -- "$OUT/.config" "$DIST_STAGE/.config"
cp -- "$OUT/Module.symvers" "$DIST_STAGE/Module.symvers"
printf '%s\n' "$EXPECTED_RELEASE" > "$DIST_STAGE/kernel.release"
CLANG_VERSION=${CLANG_VERSION%%$'\n'*}
cat > "$DIST_STAGE/build-info.txt" <<EOF
Kernel release: $EXPECTED_RELEASE
Source branch: $BRANCH
Source commit: $SOURCE_COMMIT
Release base: $BASE
Release base commit: $BASE_COMMIT
Android BRANCH: $ANDROID_BRANCH
KMI generation: $KMI_GENERATION
Kernel suffix: $SUFFIX
Toolchain preset: $CLANG ($TOOLCHAIN)
Toolchain clang: $CLANG_VERSION
Host libc: $HOST_LIBC${HOST_BUILD_TOOLS:+ ($HOST_BUILD_TOOLS)}
Compiler cache: ${CCACHE_BIN:-disabled}
Build jobs: $JOBS
Kernel build user: $BUILD_USER
Kernel build host: $BUILD_HOST
Kernel build timestamp: $BUILD_TIMESTAMP
Build time UTC: $(date -u +%FT%TZ)
Modules: $module_count
EOF
tar -C "$FINAL_SYSTEM_DLKM" -czf "$DIST_STAGE/system_dlkm-modules.tar.gz" lib/modules
(
	cd -- "$DIST_STAGE"
	sha256sum Image.gz system_dlkm-modules.tar.gz > SHA256SUMS
)

# Refuse to publish artifacts under a label that no longer matches the checkout.
[[ $(git branch --show-current) == "$BRANCH" ]] || fail "source branch changed during build; refusing to publish"
[[ $(git rev-parse --verify HEAD) == "$SOURCE_COMMIT" ]] || fail "source HEAD changed during build; refusing to publish"
assert_tracked_clean
[[ $(<"$OUT/include/config/kernel.release") == "$EXPECTED_RELEASE" ]] || fail "built kernel.release does not match $EXPECTED_RELEASE"

RUN_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
PUBLISH_DIR="$DIST_ROOT/$EXPECTED_RELEASE-$RUN_TIMESTAMP"
run_number=0
while [[ -e "$PUBLISH_DIR" || -L "$PUBLISH_DIR" ]]; do
	((run_number += 1))
	PUBLISH_DIR="$DIST_ROOT/$EXPECTED_RELEASE-$RUN_TIMESTAMP-$run_number"
done
mv -- "$DIST_STAGE" "$PUBLISH_DIR"
DIST_STAGE=

printf 'Built kernel release: %s\nArtifacts: %s\n' "$EXPECTED_RELEASE" "$PUBLISH_DIR"
