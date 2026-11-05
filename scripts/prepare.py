#!/usr/bin/env python3
"""Resolve everything one release run must agree on before any kernel is built.

Pins `optimistic` and every selected root variant to a commit, proves each
variant is based on that exact `optimistic` commit, derives the release tag from
the kernel sources at that commit, fixes the Neutron Clang build and the
KBUILD identity, and refuses to start when the release tag is already taken.

Inputs come from the environment (see the prepare job in release.yml). The
result is written to $GITHUB_OUTPUT as `metadata` (everything) and `variants`
(the build matrix); without $GITHUB_OUTPUT it is printed instead.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CONFIG = Path(__file__).resolve().parent.parent / "config" / "variants.json"
CATALOGUE = "https://raw.githubusercontent.com/Neutron-Toolchains/clang-build-catalogue/main"
CATALOGUE_RELEASES = "https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/tag"
# Same character sets build-optimistic.sh accepts.
IDENTITY = re.compile(r"[A-Za-z0-9._+-]+")
SUFFIX = re.compile(r"-[A-Za-z0-9._+-]+")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
ID = re.compile(r"[a-z0-9][a-z0-9_-]*")
MAX_RELEASE = 64  # UTS release field size


def fail(message):
    print(f"::error::{message}")
    sys.exit(1)


API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
SERVER = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
TOKEN = os.environ.get("GH_TOKEN", "")


def http_get(url, accept, auth):
    headers = {"Accept": accept, "User-Agent": "gki-optimistic-kernel-builder"}
    if auth and TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
            return response.read().decode()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        fail(f"GET {url}: HTTP {error.code}: {error.read()[:300].decode(errors='replace')}")
    except urllib.error.URLError as error:
        fail(f"GET {url}: {error.reason}")


def api(path):
    body = http_get(f"{API}/{path}", "application/vnd.github+json", auth=True)
    return None if body is None else json.loads(body)


def api_raw(path):
    return http_get(f"{API}/{path}", "application/vnd.github.raw", auth=True)


def quote(value):
    return urllib.parse.quote(value, safe="")


def branch_sha(repo, branch):
    ref = api(f"repos/{repo}/git/ref/{urllib.parse.quote('heads/' + branch, safe='/')}")
    # GitHub answers a non-existent ref that prefixes others with a list.
    if not isinstance(ref, dict) or ref.get("ref") != f"refs/heads/{branch}":
        fail(f"branch {branch} does not exist in {repo}")
    if ref["object"]["type"] != "commit":
        fail(f"refs/heads/{branch} in {repo} does not point to a commit")
    return ref["object"]["sha"]


def assignment(text, key, path):
    """Value of the first KEY=VALUE line, read the way build-optimistic.sh reads it."""
    for line in text.splitlines():
        name, sep, value = line.partition("=")
        if sep and name == key:
            return value
    fail(f"{key} is missing from {path}")


def kernel_identity(repo, sha):
    def source(path):
        text = api_raw(f"repos/{repo}/contents/{path}?ref={sha}")
        if text is None:
            fail(f"{path} is missing from {repo} at {sha}")
        return text

    makefile = source("Makefile")
    fields = {}
    for name in ("VERSION", "PATCHLEVEL", "SUBLEVEL", "EXTRAVERSION"):
        match = re.search(rf"^{name}\s*=[ \t]*(\S*)[ \t]*$", makefile, re.M)
        if not match:
            fail(f"{name} is missing from Makefile")
        fields[name] = match.group(1)
    if fields["EXTRAVERSION"]:
        fail(f"Makefile EXTRAVERSION must be empty, got {fields['EXTRAVERSION']}")
    version = "{VERSION}.{PATCHLEVEL}.{SUBLEVEL}".format(**fields)
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        fail(f"unexpected kernel version {version}")

    android_branch = assignment(source("build.config.constants"), "BRANCH", "build.config.constants")
    if not re.fullmatch(r"android\d{2,}(-[A-Za-z0-9._+-]+)?", android_branch):
        fail(f"unexpected Android BRANCH {android_branch}")
    kmi = assignment(source("build.config.common"), "KMI_GENERATION", "build.config.common")
    if not re.fullmatch(r"\d+", kmi):
        fail(f"unexpected KMI_GENERATION {kmi}")
    return version, android_branch, kmi


def catalogue_sections(text):
    sections, key = {}, None
    for line in text.splitlines():
        line = line.strip()
        header = re.fullmatch(r"\[(.+)\]", line)
        if header:
            key = header.group(1)
        elif key and line and key not in sections:
            sections[key] = line
    return sections


def neutron(requested):
    tag = requested.strip()
    if tag == "latest":
        latest = http_get(f"{CATALOGUE}/latest.txt", "text/plain", auth=False)
        tag = catalogue_sections(latest or "").get("tag", "")
    if not re.fullmatch(r"\d{8}", tag):
        fail(f"Neutron Clang build tag must be 'latest' or DDMMYYYY, got {requested!r} -> {tag!r}")
    info = http_get(f"{CATALOGUE}/{tag}-info.txt", "text/plain", auth=False)
    if info is None:
        fail(f"Neutron Clang build {tag} is not in the clang-build-catalogue")
    sections = catalogue_sections(info)
    return {
        "tag": tag,
        "clang_version": sections.get("clang-ver", ""),
        "llvm_commit": sections.get("llvm-commit", ""),
        "host_glibc": sections.get("host-glibc", ""),
        "url": f"{CATALOGUE_RELEASES}/{tag}",
    }


def build_time(value):
    def date(*args):
        result = subprocess.run(["date", "-u", *args], capture_output=True, text=True,
                                env={**os.environ, "LC_ALL": "C", "TZ": "UTC"})
        if result.returncode != 0:
            fail(f"invalid build timestamp {value!r}: {result.stderr.strip()}")
        return result.stdout.strip()

    epoch = date("-d", value.strip() or "now", "+%s")
    return {
        # build-optimistic.sh normalizes @epoch to the same KBUILD form shown below.
        "kbuild_arg": f"@{epoch}",
        "kbuild": date("-d", f"@{epoch}", "+%a %b %e %T UTC %Y"),
        "iso": date("-d", f"@{epoch}", "+%Y-%m-%dT%H:%M:%SZ"),
    }


def load_config():
    config = json.loads(CONFIG.read_text())
    entries = [config["base"], *config["variants"]]
    ids, branches = set(), set()
    for entry in entries:
        for key in ("id", "branch", "suffix"):
            if not isinstance(entry.get(key), str) or not entry[key]:
                fail(f"{CONFIG.name}: every build needs a non-empty {key}")
        if not ID.fullmatch(entry["id"]) or entry["id"] in ids:
            fail(f"{CONFIG.name}: invalid or duplicate id {entry['id']}")
        if entry["branch"] in branches:
            fail(f"{CONFIG.name}: duplicate branch {entry['branch']}")
        if not SUFFIX.fullmatch(entry["suffix"]):
            fail(f"{CONFIG.name}: suffix {entry['suffix']} must start with '-' and use [A-Za-z0-9._+-]")
        ids.add(entry["id"])
        branches.add(entry["branch"])
    for variant in config["variants"]:
        for key in ("root", "manager_nightly"):
            if not isinstance(variant.get(key), str) or not variant[key]:
                fail(f"{CONFIG.name}: variant {variant['id']} needs {key}")
        if not variant["manager_nightly"].startswith("https://"):
            fail(f"{CONFIG.name}: variant {variant['id']} manager_nightly must be an https URL")
    return config


def select(variants, spec):
    spec = spec.strip()
    if spec == "all":
        return variants
    if spec == "none":
        return []
    wanted = [item.strip() for item in spec.split(",") if item.strip()]
    if not wanted:
        fail("variants must be 'all', 'none', or a comma-separated list of ids")
    known = {variant["id"] for variant in variants}
    unknown = sorted(set(wanted) - known)
    if unknown:
        fail(f"unknown variant ids {', '.join(unknown)}; known: {', '.join(sorted(known))}")
    return [variant for variant in variants if variant["id"] in wanted]


def tag_taken(repo, tag):
    return (api(f"repos/{repo}/releases/tags/{quote(tag)}") is not None
            or api(f"repos/{repo}/git/ref/tags/{quote(tag)}") is not None)


def main():
    kernel_repo = os.environ.get("KERNEL_REPO", "").strip()
    if not REPO.fullmatch(kernel_repo):
        fail("set the KERNEL_REPO repository variable to the kernel source repository (owner/name)")
    self_repo = os.environ["GITHUB_REPOSITORY"]
    replace = os.environ.get("INPUT_REPLACE_RELEASE", "false") == "true"

    config = load_config()
    selected = select(config["variants"], os.environ.get("INPUT_VARIANTS", "all"))

    build_user = os.environ.get("INPUT_BUILD_USER", "").strip() or os.environ["GITHUB_REPOSITORY_OWNER"]
    build_host = os.environ.get("INPUT_BUILD_HOST", "").strip() or "android-ci"
    for label, value in (("build user", build_user), ("build host", build_host)):
        if not IDENTITY.fullmatch(value):
            fail(f"{label} {value!r} may only contain letters, digits, '.', '_', '+', and '-'")

    kernel_url = f"{SERVER}/{kernel_repo}"
    base_cfg = config["base"]
    base_sha = branch_sha(kernel_repo, base_cfg["branch"])
    version, android_branch, kmi = kernel_identity(kernel_repo, base_sha)
    tag = f"{version}-{android_branch.split('-', 1)[0]}-{kmi}-g{base_sha[:12]}"

    def build_entry(entry, sha, depth):
        name = entry["suffix"][1:]
        release = f"{tag}{entry['suffix']}"
        if len(release) > MAX_RELEASE:
            fail(f"kernel release {release} exceeds {MAX_RELEASE} characters")
        return {
            **entry,
            "sha": sha,
            "depth": depth,
            "name": name,
            "release": release,
            "commit_url": f"{kernel_url}/commit/{sha}",
            "asset": f"AnyKernel3_{name.replace('+', '-')}_{tag}.zip",
        }

    base = build_entry(base_cfg, base_sha, 1)

    variants = []
    for variant in selected:
        sha = branch_sha(kernel_repo, variant["branch"])
        compare = api(f"repos/{kernel_repo}/compare/{base_sha}...{sha}?per_page=1")
        if compare is None or compare["status"] not in ("ahead", "identical"):
            status = "unknown" if compare is None else compare["status"]
            fail(f"{variant['branch']} ({sha[:12]}) is not based on {base_cfg['branch']} "
                 f"({base_sha[:12]}): compare status {status}; rebase it before releasing")
        # Enough history for the base commit to be present in a shallow fetch.
        variants.append(build_entry(variant, sha, compare["ahead_by"] + 1))

    if tag_taken(self_repo, tag) and not replace:
        fail(f"release tag {tag} already exists in {self_repo}; rerun with replace_release to rebuild it")

    toolchain = neutron(os.environ.get("INPUT_NEUTRON_VERSION", "latest"))
    cache_prefix = f"ccache-neutron-{toolchain['tag']}-{base_cfg['id']}-"
    metadata = {
        "kernel_repo": kernel_repo,
        "kernel_url": kernel_url,
        "tag": tag,
        "kernel_version": version,
        "android_branch": android_branch,
        "kmi_generation": kmi,
        "base": base,
        "variants": variants,
        "build": {"user": build_user, "host": build_host, "time": build_time(os.environ.get("INPUT_BUILD_TIMESTAMP", ""))},
        "toolchain": toolchain,
        "ccache": {
            "prefix": cache_prefix,
            "key": f"{cache_prefix}{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}",
        },
        "replace_release": replace,
    }

    outputs = {"metadata": json.dumps(metadata, separators=(",", ":")),
               "variants": json.dumps(variants, separators=(",", ":"))}
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a") as handle:
            for key, value in outputs.items():
                handle.write(f"{key}={value}\n")
    print(json.dumps(metadata, indent=2, ensure_ascii=False))

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        rows = "\n".join(f"| `{b['branch']}` | [`{b['sha'][:12]}`]({b['commit_url']}) | `{b['release']}` |"
                         for b in (base, *variants))
        with open(summary_path, "a") as handle:
            handle.write(f"### Release `{tag}`\n\n| Branch | Commit | Kernel release |\n| --- | --- | --- |\n{rows}\n\n"
                         f"Build: `{build_user}@{build_host}`, `{metadata['build']['time']['kbuild']}`, "
                         f"Neutron Clang {toolchain['clang_version']} (`{toolchain['tag']}`)\n")


if __name__ == "__main__":
    main()
