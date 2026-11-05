#!/usr/bin/env python3
"""Render the GitHub release notes (English, then Chinese) for one prepared release.

usage: release-notes.py <metadata.json> <assets-dir>

Reads the metadata written by prepare.py, checks that every build's packaged
AnyKernel3 zip (`asset`) is present, and prints Markdown to stdout. Asset
checksums are left to GitHub, which shows a SHA-256 digest for every asset.
"""

import json
import os
import sys
from pathlib import Path

TEXT = {
    "en": {
        "heading": "English",
        "scope": "Only for devices on the `{kmi}` KMI whose CPU cores are all ARMv9. "
                 "**It will not boot on ARMv8 CPUs.**",
        "build_info": "Build information",
        "item": "Item",
        "value": "Value",
        "kernel_version": "Kernel version",
        "build_time": "Build time",
        "source": "Source",
        "built_by": "Built by",
        "toolchain": "Toolchain",
        "downloads": "Downloads",
        "variant": "Variant",
        "zip": "Flashable zip",
        "download": "Download",
        "manager": "Root manager",
        "vanilla": "Vanilla",
        "no_root": "None / no built-in root",
        "note": "The built-in root uses the latest upstream development build, which may be newer than this "
                "kernel. If the manager reports that the kernel is too old, wait for the next release.",
        "paren": " ({})",
    },
    "zh": {
        "heading": "中文",
        "scope": "仅供 KMI 为 `{kmi}`、且所有 CPU 核心均为 ARMv9 的设备刷入。**本内核无法在 ARMv8 CPU 上启动。**",
        "build_info": "构建信息",
        "item": "项目",
        "value": "值",
        "kernel_version": "内核版本",
        "build_time": "构建时间",
        "source": "源码",
        "built_by": "构建者",
        "toolchain": "工具链",
        "downloads": "下载",
        "variant": "变体",
        "zip": "刷机包",
        "download": "下载",
        "manager": "Root 管理器",
        "vanilla": "原版",
        "no_root": "无 / 不内置 Root",
        "note": "内置 Root 使用上游最新开发版构建，它可能比本内核更新。若管理器提示内核版本过低，请等待下一次发布。",
        "paren": "（{}）",
    },
}


def section(t, meta, download):
    base, variants = meta["base"], meta["variants"]
    time, builder, tc = meta["build"]["time"], meta["build"], meta["toolchain"]
    built = time["iso"].replace("T", " ").replace("Z", " UTC")

    def source(build):
        return f"[*{build['branch']}@{build['sha'][:12]}*]({build['commit_url']})"

    def zip_link(build):
        return f"[{t['download']}]({download}/{build['asset']})"

    rows = [f"| **{t['vanilla']}** | {zip_link(base)} | *{t['no_root']}* | {source(base)} |"]
    rows += [f"| **{v['root']}** | {zip_link(v)} | [{v['root']}]({v['manager_nightly']}) | {source(v)} |"
             for v in variants]
    note = f"\n{t['note']}\n" if variants else ""
    return f"""\
## {t['heading']}

{t['scope'].format(kmi=meta['android_branch'])}

### {t['build_info']}

| {t['item']} | {t['value']} |
| --- | --- |
| {t['kernel_version']} | `{meta['kernel_version']}`{t['paren'].format(f"`{meta['tag']}`")} |
| {t['build_time']} | {built}{t['paren'].format(f"`{time['kbuild']}`")} |
| {t['source']} | [{meta['kernel_repo']}]({meta['kernel_url']}/tree/{base['branch']}) |
| {t['built_by']} | `{builder['user']}@{builder['host']}` |
| {t['toolchain']} | Neutron Clang {tc['clang_version']}{t['paren'].format(f"[`{tc['tag']}`]({tc['url']})")} |

### {t['downloads']}

| {t['variant']} | {t['zip']} | {t['manager']} | {t['source']} |
| --- | --- | --- | --- |
{chr(10).join(rows)}
{note}"""


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip())
    meta = json.loads(Path(sys.argv[1]).read_text())
    assets = Path(sys.argv[2])
    for build in (meta["base"], *meta["variants"]):
        if not (assets / build["asset"]).is_file():
            sys.exit(f"missing release asset {assets / build['asset']}")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    download = f"{server}/{os.environ['GITHUB_REPOSITORY']}/releases/download/{meta['tag']}"

    print(f"# Optimistic GKI `{meta['tag']}`\n")
    print(section(TEXT["en"], meta, download))
    print(section(TEXT["zh"], meta, download), end="")


if __name__ == "__main__":
    main()
