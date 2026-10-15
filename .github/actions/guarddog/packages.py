"""List the exact package versions a repository's lockfiles pin, optionally
only those added or changed against a base commit, and write one GuardDog
verify input per ecosystem (issue #229).

Standard library only, so it runs on the runner's python3 before GuardDog is
installed; when nothing changed the install is skipped.

Usage: packages.py --root DIR --out DIR [--base SHA] [--ecosystems pypi,npm,go]
Writes <out>/requirements.txt, <out>/package.json, <out>/go.mod (only for
ecosystems with packages), <out>/sources.json mapping "eco:name@version" to
the lockfile path that pinned it, and prints count=N for GITHUB_OUTPUT.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import tomllib

LOCKFILES = {
    "pypi": [r"(^|/)requirements[^/]*\.txt$", r"(^|/)poetry\.lock$", r"(^|/)uv\.lock$"],
    "npm": [r"(^|/)package-lock\.json$", r"(^|/)pnpm-lock\.yaml$", r"(^|/)yarn\.lock$"],
    "go": [r"(^|/)go\.mod$"],
}
REQ_PIN = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*===?\s*([^\s;\\#]+)")
GO_REQ = re.compile(r"^\s*(?:require\s+)?([^\s()]+)\s+(v[^\s]+)")


def parse_requirements(text):
    return {(m.group(1).lower(), m.group(3)) for m in map(REQ_PIN.match, text.splitlines()) if m}


def parse_toml_lock(text):
    # poetry.lock and uv.lock: [[package]] name/version; skip the project itself
    # and path, git or URL sources, which no registry serves.
    out = set()
    for pkg in tomllib.loads(text).get("package", []):
        source = pkg.get("source", {})
        if isinstance(source, dict) and (set(source) & {"editable", "virtual", "directory", "path", "git", "url"}
                                         or source.get("type") in {"directory", "file", "git", "url"}):
            continue
        if "name" in pkg and "version" in pkg:
            out.add((pkg["name"].lower(), pkg["version"]))
    return out


def parse_package_lock(text):
    out = set()
    for key, pkg in json.loads(text).get("packages", {}).items():
        if not key or pkg.get("link") or "version" not in pkg:
            continue
        out.add((pkg.get("name") or key.rsplit("node_modules/", 1)[-1], pkg["version"]))
    return out


def split_name_version(spec):
    name, _, version = spec.rpartition("@")
    return name, version


def parse_pnpm_lock(text):
    # v6 keys are "/name@1.2.3", v9 keys "name@1.2.3"; a "(peer@x)" suffix is dropped.
    out, section = set(), None
    for line in text.splitlines():
        if not line.startswith(" ") and line.endswith(":"):
            section = line[:-1]
            continue
        m = re.match(r"^  ['\"]?/?((?:@[^/@\s]+/)?[^@\s'\"]+@[^(\s'\":]+)", line)
        if section == "packages" and m:
            name, version = split_name_version(m.group(1))
            if name and re.match(r"^\d", version):
                out.add((name, version))
    return out


def parse_yarn_lock(text):
    # Classic (v1) and Berry: an unindented key line names the package, the
    # indented version line under it pins it.
    out, name = set(), None
    for line in text.splitlines():
        if line and not line.startswith((" ", "#")) and line.endswith(":"):
            first = line[:-1].split(",")[0].strip().strip('"')
            name = first[: first.index("@", 1)] if "@" in first[1:] else None
        m = re.match(r'^\s+version:?\s+"?([^"\s]+)"?', line)
        if m and name and name != "__metadata":
            out.add((name, m.group(1)))
            name = None
    return out


def parse_go_mod(text):
    out, in_block = set(), False
    for line in text.splitlines():
        stripped = line.split("//")[0].strip()
        if stripped.startswith("require ("):
            in_block = True
            continue
        if in_block and stripped == ")":
            in_block = False
            continue
        m = GO_REQ.match(stripped) if in_block or stripped.startswith("require ") else None
        if m:
            out.add((m.group(1), m.group(2)))
    return out


PARSERS = {
    "requirements": parse_requirements, "poetry.lock": parse_toml_lock, "uv.lock": parse_toml_lock,
    "package-lock.json": parse_package_lock, "pnpm-lock.yaml": parse_pnpm_lock, "yarn.lock": parse_yarn_lock,
    "go.mod": parse_go_mod,
}


def parser_for(path):
    name = Path(path).name
    return PARSERS["requirements"] if name.startswith("requirements") else PARSERS[name]


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False)


def collect(root, ecosystems, base):
    files = git("-C", str(root), "ls-files", "--full-name").stdout.splitlines()
    top = Path(git("-C", str(root), "rev-parse", "--show-toplevel").stdout.strip())
    found = {}
    for eco in ecosystems:
        for path in files:
            if not any(re.search(p, path) for p in LOCKFILES[eco]):
                continue
            text = (top / path).read_text()
            pins = parser_for(path)(text)
            if base:
                old = git("-C", str(root), "show", f"{base}:{path}")
                pins -= parser_for(path)(old.stdout) if old.returncode == 0 else set()
            for name, version in pins:
                found.setdefault(f"{eco}:{name}@{version}", path)
    return found


def write_inputs(found, out):
    by_eco = {}
    for key in sorted(found):
        eco, spec = key.split(":", 1)
        by_eco.setdefault(eco, []).append(split_name_version(spec))
    if "pypi" in by_eco:
        (out / "requirements.txt").write_text("".join(f"{n}=={v}\n" for n, v in by_eco["pypi"]))
    if "npm" in by_eco:
        # npm verify reads package.json; one entry per name, so a second version
        # of the same package goes in its own file.
        files, seen = [{}], {}
        for n, v in by_eco["npm"]:
            i = seen[n] = seen.get(n, -1) + 1
            files.extend({} for _ in range(i + 1 - len(files)))
            files[i][n] = v
        for i, deps in enumerate(files):
            target = out / "package.json" if i == 0 else out / f"npm-{i}" / "package.json"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps({"name": "guarddog-verify", "version": "0.0.0", "dependencies": deps}, indent=2))
    if "go" in by_eco:
        body = "".join(f"\t{n} {v}\n" for n, v in by_eco["go"])
        (out / "go.mod").write_text(f"module guarddog.verify\n\ngo 1.22\n\nrequire (\n{body})\n")
    (out / "sources.json").write_text(json.dumps(found, indent=2, sort_keys=True))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--out", required=True)
    ap.add_argument("--base", default="")
    ap.add_argument("--ecosystems", default="pypi,npm,go")
    args = ap.parse_args()
    ecosystems = [e.strip() for e in args.ecosystems.split(",") if e.strip()]
    unknown = set(ecosystems) - set(LOCKFILES)
    if unknown:
        sys.exit(f"::error title=malicious-package-check::unsupported ecosystems: {', '.join(sorted(unknown))} (supported: pypi, npm, go)")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    found = collect(Path(args.root), ecosystems, args.base)
    write_inputs(found, out)
    print(f"count={len(found)}")


if __name__ == "__main__":
    main()
