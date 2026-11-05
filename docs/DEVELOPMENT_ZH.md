# 开发文档

[返回 README](../README_ZH.md)

## 工作流介绍

"Build and release" 工作流（`.github/workflows/release.yml`）只能在 Actions 页面手动触发，共四个任务：

1. Prepare 把 `optimistic` 和选中的变体分支固定到具体提交。如果某个变体不是基于这个 `optimistic` 提交，或者同名 tag 已存在且没有勾选 `replace_release`，就直接停止。所有构建共用的用户名、主机名和构建时间也在这一步确定。
2. Optimistic 在 `ubuntu-26.04` 上构建原版内核，并把 ccache 存入 Actions 缓存。
3. Variant 读取这份缓存，并行构建各个 Root 变体。变体和原版只差几个文件，绝大部分目标文件可以直接从 ccache 取出。
4. Release 把每个 `Image.gz` 打包成 AnyKernel3 刷机包，并发布带中英文说明的 Release。

Release 的 tag 就是去掉后缀的内核版本，例如 `6.1.177-android14-11-g8ee32a09623b`，其中的哈希来自 `optimistic` 提交。每个构建还会上传一个 Artifact，内含 `Image.gz`、`system_dlkm-modules.tar.gz`、`build-info.txt` 和 `Module.symvers`。`system_dlkm` 模块不随 Release 发布。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `variants` | `all` | `all`、`none`，或 `config/variants.json` 里的 id，用逗号分隔，例如 `ksun,fnsu` |
| `neutron_version` | `06092026` | Neutron Clang 版本号，或 `latest` |
| `build_user` | `evans` | `KBUILD_BUILD_USER` |
| `build_host` | `android-ci` | `KBUILD_BUILD_HOST` |
| `build_timestamp` | 空（即开始构建的时间） | `KBUILD_BUILD_TIMESTAMP`，任何 `date -d` 能解析的格式 |
| `replace_release` | 关 | 删除并重建同 tag 的 Release |

## 如何适配自己的工作流

1. Fork 本仓库，在 Settings → Secrets and variables → Actions → Variables 中添加仓库变量 `KERNEL_REPO`，值为你的内核仓库，例如 `you/android_kernel_common`。工作流用默认 token 通过 GitHub API 读取它，所以内核仓库必须公开。
2. 编辑 `config/variants.json`：`base` 里填基础分支和版本后缀；`variants` 里每一项需要 `id`、基于基础分支的 `branch`、类似 `-Optimistic+KSUN` 的 `suffix`、Release 说明里显示的 `root` 名称，以及 `manager_nightly` 下载链接。基础分支每次更新后都要 rebase 变体分支，落后的变体会在 Prepare 阶段被拒绝。
3. 如果你的源码不是 android14-6.1，先看看 `scripts/build-optimistic.sh`。它要求 ACK 结构的源码树，包含 `build.config.constants`、`build.config.common`、`gki_defconfig`，模块需要签名且不压缩。
4. 刷机脚本在 `anykernel/anykernel.sh` 中修改，AnyKernel3 的版本由 `release.yml` 里的 `AK3_COMMIT` 固定。
5. Release 说明由 `scripts/release-notes.py` 生成。

本地构建可以运行 `scripts/build-optimistic.sh --help` 查看用法。默认路径和 CI 一致：`kernel/`、`toolchain/`、`out/` 都放在仓库根目录。
