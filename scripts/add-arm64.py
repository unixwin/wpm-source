#!/usr/bin/env python3
"""Fill `windows-arm64` artifacts for packages whose upstream GitHub release
already publishes an arm64/aarch64 Windows asset.

Dry-run by default: resolves candidates and prints a match table without
downloading payloads or touching index.json. `--apply` downloads each matched
asset, records sha256+size, verifies the package's `files` mappings resolve
inside the downloaded archive, then writes index.json (LF, trailing blank
line, same as the existing file convention).

Non-GitHub sources are reported as SKIP and left for manual handling.

Resumable: packages that already have a windows-arm64 artifact are skipped,
and every package decision is logged to .arm64-report.json next to the index.
"""

import argparse
import difflib
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX_PATH = os.path.join(HERE, "..", "index.json")
REPORT_PATH = os.path.join(HERE, "..", ".arm64-report.json")

GH_RE = re.compile(r"https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/(.+)")
ARM64_RE = re.compile(r"(?<![a-z0-9])(arm64|aarch64)(?![a-z0-9])", re.I)
WIN_RE = re.compile(r"(win(dows)?|pc-windows|\.exe$|\.zip$)", re.I)
X64_TOKENS = re.compile(r"(x86_64|amd64|x64|win64|64bit|x86-64)", re.I)
NOT_WIN_RE = re.compile(r"(?<![a-z0-9])(darwin|mac(os)?|osx|linux|freebsd|openbsd|netbsd|android|ios)(?![a-z0-9])", re.I)


def gh_api(path):
    out = subprocess.run(
        ["gh", "api", path], capture_output=True, text=True, timeout=60
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:200])
    return json.loads(out.stdout)


def arm64_score(name, x64_name):
    """True if name looks like a Windows arm64 asset; plus similarity to the
    x64 asset name for ranking."""
    if not ARM64_RE.search(name):
        return None
    # reject other-OS arm64 assets (aarch64-mac, linux-arm64, ...)
    if NOT_WIN_RE.search(name):
        return None
    if not WIN_RE.search(name):
        return None
    # rank by similarity after normalizing the arch token out of both names
    norm = lambda s: ARM64_RE.sub("@", X64_TOKENS.sub("@", s.lower()))
    return difflib.SequenceMatcher(None, norm(x64_name), norm(name)).ratio()


def resolve_candidate(pkg):
    """Return (status, info). status in OK/NOCAND/SKIP/ERR."""
    art = pkg.get("artifacts", {}).get("windows-x64")
    if not art:
        return "SKIP", "no windows-x64 artifact"
    url = (art.get("urls") or [""])[0]
    m = GH_RE.match(url)
    if not m:
        return "SKIP", f"non-github source: {url.split('/')[2] if '/' in url else url}"
    repo, tag, x64_asset = m.group(1), m.group(2), m.group(3)
    try:
        rel = gh_api(f"repos/{repo}/releases/tags/{tag}")
    except RuntimeError:
        try:
            rel = gh_api(f"repos/{repo}/releases/latest")
        except RuntimeError as e:
            return "ERR", str(e)
    best, best_score = None, 0.0
    for a in rel.get("assets", []):
        s = arm64_score(a["name"], x64_asset)
        if s is not None and s > best_score:
            best, best_score = a, s
    if not best:
        return "NOCAND", f"{repo}@{tag}"
    return "OK", {
        "repo": repo,
        "tag": rel.get("tag_name", tag),
        "asset": best["name"],
        "url": best["browser_download_url"],
        "score": round(best_score, 3),
    }


def download(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "wpm-arm64-fill"})
    with urllib.request.urlopen(req, timeout=180) as r, open(dest, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    h = hashlib.sha256()
    size = 0
    with open(dest, "rb") as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size


def archive_names(path, atype):
    if atype == "zip":
        with zipfile.ZipFile(path) as z:
            return set(z.namelist())
    if atype in ("tar.gz", "tar.xz", "tgz"):
        with tarfile.open(path) as t:
            return set(t.getnames())
    return None  # exe/unknown: nothing to verify


def infer_type(asset_name):
    """Artifact type from the arm64 asset's own extension -- it can differ
    from the x64 artifact (e.g. crane ships zip for x64, tar.gz for arm64)."""
    n = asset_name.lower()
    if n.endswith(".zip"):
        return "zip"
    if n.endswith((".tar.gz", ".tgz")):
        return "tar.gz"
    if n.endswith(".tar.xz"):
        return "tar.xz"
    if n.endswith(".exe"):
        return "exe"
    return None


def arch_rewrite(from_path):
    """Candidate `from` paths with x64 arch tokens swapped for arm64 ones.
    Handles archives whose internal directory embeds the arch
    (e.g. clang+llvm-22.1.8-aarch64-pc-windows-msvc/)."""
    swaps = [
        ("x86_64", "aarch64"), ("amd64", "arm64"), ("x64", "arm64"),
        ("win64", "win-arm64"),
    ]
    out = [from_path]
    for old, new in swaps:
        if old in from_path.lower():
            idx = from_path.lower().index(old)
            out.append(from_path[:idx] + new + from_path[idx + len(old):])
    return out


def resolve_from(from_path, names):
    """Mirror wpm's find_artifact_path (exact path, else recursive basename),
    trying arch-rewritten variants. Returns the resolved `from` or None."""
    for src in arch_rewrite(from_path.replace("\\", "/")):
        if src in names:
            return src
        base = src.rsplit("/", 1)[-1].lower()
        if any(n.rsplit("/", 1)[-1].lower() == base for n in names):
            return src
        # directory mappings: match any member under the directory
        if any(n.startswith(src.rstrip("/") + "/") for n in names):
            return src
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--packages", default="")
    args = ap.parse_args()

    index = json.load(open(INDEX_PATH, newline=""))
    only = set(filter(None, args.packages.split(",")))
    todo = [
        p for p in index["packages"]
        if "windows-arm64" not in p.get("artifacts", {})
        and (not only or p["name"] in only)
    ]
    print(f"{len(todo)} packages missing windows-arm64")

    with ThreadPoolExecutor(args.workers) as ex:
        results = dict(zip([p["name"] for p in todo], ex.map(resolve_candidate, todo)))

    report = {}
    if os.path.exists(REPORT_PATH):
        report = json.load(open(REPORT_PATH))
    ok = [(p["name"], i) for p in todo for s, i in [results[p["name"]]] if s == "OK"]
    print(f"resolved: {len(ok)} with arm64 asset")
    for name in [p["name"] for p in todo]:
        s, i = results[name]
        if s != "OK":
            print(f"  {s:7} {name:24} {i}")

    if not args.apply:
        for name, i in ok:
            print(f"  OK      {name:24} {i['asset']}  ({i['score']})")
        return

    failures = {}
    for name, info in ok:
        pkg = next(p for p in index["packages"] if p["name"] == name)
        x64 = pkg["artifacts"]["windows-x64"]
        atype = infer_type(info["asset"]) or x64.get("type", "exe")
        try:
            with tempfile.TemporaryDirectory() as td:
                dest = os.path.join(td, info["asset"])
                sha, size = download(info["url"], dest)
                files = None
                names = archive_names(dest, atype)
                if names is not None:
                    files = []
                    for f in x64.get("files", []):
                        resolved = resolve_from(f["from"], names)
                        if resolved is None:
                            failures[name] = f"files missing in arm64 archive: {[f['from']]}"
                            files = None
                            break
                        nf = dict(f)
                        nf["from"] = resolved
                        files.append(nf)
                elif x64.get("files"):
                    files = x64["files"]
                if names is not None and files is None:
                    continue
            entry = {
                "type": atype,
                "sha256": sha,
                "urls": [info["url"]],
            }
            if files:
                entry["files"] = files
            entry["size"] = size
            if "layout" in x64:
                entry["layout"] = x64["layout"]
            pkg["artifacts"]["windows-arm64"] = entry
            report[name] = {"status": "ok", "asset": info["asset"], "sha256": sha}
            print(f"  added   {name:24} {info['asset']} ({size} bytes)")
        except Exception as e:
            failures[name] = str(e)[:200]
            report[name] = {"status": "fail", "error": str(e)[:200]}

    for name, why in failures.items():
        print(f"  FAILED  {name:24} {why}")

    with open(INDEX_PATH, "w", newline="\n") as f:
        json.dump(index, f, indent=2, ensure_ascii=False)
        f.write("\n\n")
    json.dump(report, open(REPORT_PATH, "w"), indent=1)
    print(f"applied {sum(1 for n,_ in ok if n not in failures)} arm64 artifacts; "
          f"{len(failures)} failed")


if __name__ == "__main__":
    main()
