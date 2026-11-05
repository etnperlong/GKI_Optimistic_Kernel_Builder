### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=@KERNEL_STRING@
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
# Generic @ANDROID_BRANCH@ GKI kernel-only package: no device check, because any
# device on this KMI can boot it. Only the kernel inside boot is replaced;
# system_dlkm, vendor_dlkm, vendor_boot and init_boot are not flashed.
# Kernel release: @KERNEL_RELEASE@
# Source: @SOURCE_URL@
# Built: @BUILD_TIME@ with @TOOLCHAIN@

## boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
NO_MAGISK_CHECK=1;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install: keep the current boot header and ramdisk (if any), replace the kernel
split_boot;
flash_boot;

## end boot install
