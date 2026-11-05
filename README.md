<div align="center">

# Optimistic GKI Kernel Builder

Builds and releases the Optimistic kernel, a performance-tuned kernel based on `android14-6.1`, with GitHub Actions.

[![Build](https://img.shields.io/github/actions/workflow/status/etnperlong/GKI_Optimistic_Kernel_Builder/release.yml?label=build)](https://github.com/etnperlong/GKI_Optimistic_Kernel_Builder/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/etnperlong/GKI_Optimistic_Kernel_Builder?display_name=tag&label=release)](https://github.com/etnperlong/GKI_Optimistic_Kernel_Builder/releases/latest)
[![Built](https://img.shields.io/github/release-date/etnperlong/GKI_Optimistic_Kernel_Builder?label=built)](https://github.com/etnperlong/GKI_Optimistic_Kernel_Builder/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

English | [简体中文](README_ZH.md)

</div>

## About the kernel

Optimistic Kernel is built from the `android14-6.1` sources of the Android Common Kernel (ACK) and keeps up with upstream ACK. It stays compatible with the GKI KMI while pulling in performance work and useful new features.

Optimistic accepts a bit more risk in exchange for speed and features. It is compiled with the bleeding-edge Neutron Clang, uses ThinLTO, generates code for ARMv9 directly, and picks up scheduler and I/O tweaks from community projects such as XanMod. **It is aimed at experienced users who like trying new things and tuning for performance.**

Compared with ACK, the main changes are:

- Clang ThinLTO: optimizes the kernel and its modules across files at link time for better runtime performance
- Native ARMv9 build: compiled with `-march=armv9-a` and tuned for Cortex-A715. **It will not boot on ARMv8 CPUs**, so make sure every core in your SoC is ARMv9 before flashing
- Built with [Neutron Clang](https://github.com/Neutron-Toolchains/clang-build-catalogue): a compiler for kernel builds that follows LLVM main every week. The default build is `06092026` (Clang 24)
- Scheduling and I/O: copy prefetching, `clear_page()` alignment, a revised idle CPU scan order, shorter alarmtimer wakeups, and lower VFS cache pressure
- Networking: TCP BBR by default, plus ipset, CAKE and additional netfilter targets
- NTSync: provides `/dev/ntsync` so Wine-based emulators such as Winlator can run Windows games faster
- [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS): enables the kernel options needed to run lightweight Linux containers on Android
- [Re:Kernel](https://github.com/Sakion-Team/Re-Kernel): tells userspace to thaw a frozen app when it receives a Binder transaction, a signal or network data; meant to be used with app-freezing ("tombstone") modules
- [Baseband-guard](https://github.com/vc-teahouse/Baseband-guard) LSM: stops root processes from writing to partitions outside an allowlist (such as preloader, lk and seccfg), so a bad flash cannot brick the device

Each release ships the variants below. Vanilla is built straight from the `optimistic` branch, and each root variant adds a few commits on top of `optimistic`:

| Variant | Upstream |
| --- | --- |
| Vanilla | [ACK `android14-6.1`](https://android.googlesource.com/kernel/common/+/refs/heads/android14-6.1) |
| KernelSU | [`tiann/KernelSU` `main`](https://github.com/tiann/KernelSU/tree/main) |
| KernelSU Next | [`KernelSU-Next/KernelSU-Next` `dev`](https://github.com/KernelSU-Next/KernelSU-Next/tree/dev) |
| BakaSU | [`Baka-SU/BakaSU` `main`](https://github.com/Baka-SU/BakaSU/tree/main) |
| SukiSU-Ultra | [`SukiSU-Ultra/SukiSU-Ultra` `builtin`](https://github.com/SukiSU-Ultra/SukiSU-Ultra/tree/builtin) |
| FinaSU | [`LyraVoid/FinaSU` `master`](https://github.com/LyraVoid/FinaSU/tree/master) |

All root variants except KernelSU Next have [SusFS](https://gitlab.com/simonpunk/susfs4ksu) v2.3.0 built in. KernelSU Next keeps SusFS out of the kernel and loads it dynamically after boot.

## Building and adapting

See the [development guide](docs/DEVELOPMENT.md) for how the workflow runs, the inputs you can set when starting it, and how to build your own kernel with it.

## License

The scripts and workflows in this repository are released under the [MIT License](LICENSE). The kernel, AnyKernel3, Neutron Clang and the root implementations are covered by their own licenses.
