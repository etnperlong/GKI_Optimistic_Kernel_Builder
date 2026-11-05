<div align="center">

# Optimistic GKI Kernel Builder

用 GitHub Actions 构建并发布 Optimistic 内核：一个基于 `android14-6.1` 的优化内核

[![Build](https://img.shields.io/github/actions/workflow/status/etnperlong/GKI_Optimistic_Kernel_Builder/release.yml?label=build)](https://github.com/etnperlong/GKI_Optimistic_Kernel_Builder/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/etnperlong/GKI_Optimistic_Kernel_Builder?display_name=tag&label=release)](https://github.com/etnperlong/GKI_Optimistic_Kernel_Builder/releases/latest)
[![Built](https://img.shields.io/github/release-date/etnperlong/GKI_Optimistic_Kernel_Builder?label=built)](https://github.com/etnperlong/GKI_Optimistic_Kernel_Builder/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) | 简体中文

</div>

## 内核介绍

Optimistic Kernel（乐观内核）基于 Android 通用内核（ACK）`android14-6.1` 的源代码，跟随 ACK 上游持续更新，在保持 GKI KMI 兼容的前提下，积极引入性能优化和实用的新功能。

乐观内核愿意为性能和功能多承担一些风险：用前沿的 Neutron Clang 编译，开启 ThinLTO 并直接面向 ARMv9 生成代码，同时吸收 XanMod 等社区项目的调度与 I/O 调整。它**适合愿意尝鲜，追求性能调优的高级用户**。

和 ACK 相比，主要改动如下：

- Clang ThinLTO：链接时跨文件优化内核与模块，提升运行时性能
- 原生 ARMv9 编译：以 `-march=armv9-a` 编译并针对 Cortex-A715 调优。**无法在 ARMv8 CPU 上启动**，刷入前请确认 SoC 的所有核心都是 ARMv9
- [Neutron Clang](https://github.com/Neutron-Toolchains/clang-build-catalogue) 构建：每周跟随 LLVM 主线更新的内核专用编译器，默认版本 `06092026`（Clang 24）
- 调度与 I/O：拷贝预取、`clear_page()` 对齐、调整空闲 CPU 扫描顺序、缩短 alarmtimer 唤醒等待，并降低 VFS 缓存回收压力
- 网络：默认 TCP BBR，加入 ipset、CAKE 和更多 netfilter 目标
- NTSync：提供 `/dev/ntsync`，供 Winlator 等基于 Wine 的模拟器加速 Windows 游戏
- [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)：开启在 Android 上运行轻量 Linux 容器所需的内核选项
- [Re:Kernel](https://github.com/Sakion-Team/Re-Kernel)：冻结的应用收到 Binder、信号或网络数据时通知用户态解冻，配合墓碑类模块使用
- [Baseband-guard](https://github.com/vc-teahouse/Baseband-guard) LSM：阻止 Root 进程写入白名单以外的分区（如 preloader、lk、seccfg），避免设备被误刷变砖

每次发布包含以下变体。原版直接由 `optimistic` 分支构建，各 Root 变体都是在 `optimistic` 之上的几个提交：

| 变体 | 上游来源 |
| --- | --- |
| 原版（Vanilla） | [ACK `android14-6.1`](https://android.googlesource.com/kernel/common/+/refs/heads/android14-6.1) |
| KernelSU | [`tiann/KernelSU` `main`](https://github.com/tiann/KernelSU/tree/main) |
| KernelSU Next | [`KernelSU-Next/KernelSU-Next` `dev`](https://github.com/KernelSU-Next/KernelSU-Next/tree/dev) |
| BakaSU | [`Baka-SU/BakaSU` `main`](https://github.com/Baka-SU/BakaSU/tree/main) |
| SukiSU-Ultra | [`SukiSU-Ultra/SukiSU-Ultra` `builtin`](https://github.com/SukiSU-Ultra/SukiSU-Ultra/tree/builtin) |
| FinaSU | [`LyraVoid/FinaSU` `master`](https://github.com/LyraVoid/FinaSU/tree/master) |

除 KernelSU Next 外，所有内置 Root 的变体都内建 [SusFS](https://gitlab.com/simonpunk/susfs4ksu) v2.3.0；KernelSU Next 的 SusFS 不编入内核，由 KernelSU Next 在开机后动态加载。

## 构建与适配

工作流的运行方式、手动触发参数，以及如何改成构建自己的内核，见[开发文档](docs/DEVELOPMENT_ZH.md)。

## 开源协议

本仓库的脚本和工作流以 [MIT 协议](LICENSE) 开源。内核、AnyKernel3、Neutron Clang 以及各 Root 实现遵循各自的协议。
