#!/usr/bin/env python3
"""Model scan gate and CycloneDX ML-BOM (issue #104).

Usage: report.py --root DIR --scan modelscan.json[,more.json] [--paths DIR,FILE] [--manifest models.json]
                 [--fail-on-severity critical|high|medium|low]
                 [--verify none|sigstore|key --identity I --identity-provider P --public-key K
                  --signature-suffix .sig --model-signing-cmd CMD] [--require-signature]
                 [--inventory docs/ai-agents.md] [--lock .mcp-scan.lock]
                 [--mlbom sbom/mlbom.cdx.json] [--output report.json]

1. Model files under --paths (default: all of --root; extensions in EXTENSIONS, plus every directory
   holding saved_model.pb) are listed with their sha256. A directory model
   is hashed over its sorted relative paths and file hashes.
2. modelscan issues at or above --fail-on-severity are errors; a modelscan
   error (unreadable file, missing extra such as tensorflow) is an error.
3. --manifest lists models the code loads at runtime or expects in the tree:
   {"models": [{"name", "path" | "url", "source", "version", "sha256",
   "license"}]}. Every entry needs a sha256 (the pin); a "path" entry's
   sha256 must equal the file's. That is the policy: a model loaded at
   runtime is pinned by hash and listed in the ML-BOM.
4. With --verify, a model with a sibling <path><suffix> signature is
   verified through `model_signing verify sigstore|key`; a failed
   verification is an error, an unsigned model is reported and is an error
   with --require-signature.
5. The ML-BOM (CycloneDX 1.6) lists every model (type machine-learning-model),
   plus the MCP servers and skills from --lock and the agent rows from the
   --inventory table (issue #102), so one document covers models, tools and
   servers. Standard library only; run with python3 -I.
"""

import argparse
import glob
import hashlib
import json
import os
import subprocess
import sys
import uuid
from datetime import datetime, timezone

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ai-inventory"))
from check import parse_inventory  # noqa: E402  (issue #102 inventory table parser)

EXTENSIONS = (".pkl", ".pickle", ".pt", ".pth", ".h5", ".hdf5", ".keras", ".bin", ".safetensors", ".onnx", ".ckpt", ".joblib", ".npy", ".npz", ".gguf")
SEVERITIES = ["low", "medium", "high", "critical"]
EXCLUDE = (".git", "node_modules", ".sparkgeo-github-actions", ".sparkgeo-policies")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_dir(path):
    h = hashlib.sha256()
    for dirpath, _, files in sorted(os.walk(path)):
        for f in sorted(files):
            full = os.path.join(dirpath, f)
            h.update(os.path.relpath(full, path).encode() + b"\0" + sha256_file(full).encode() + b"\n")
    return h.hexdigest()


def discover(root, paths):
    """{relative path: sha256} for model files and SavedModel directories under paths."""
    found = {}
    for start in paths or ["."]:
        start_abs = os.path.join(root, start)
        if os.path.isfile(start_abs):
            rel = os.path.relpath(start_abs, root).replace(os.sep, "/")
            if rel.lower().endswith(EXTENSIONS):
                found[rel] = sha256_file(start_abs)
            continue
        for dirpath, dirs, files in os.walk(start_abs):
            dirs[:] = sorted(d for d in dirs if d not in EXCLUDE)
            rel_dir = os.path.relpath(dirpath, root).replace(os.sep, "/")
            if "saved_model.pb" in files:
                found[rel_dir] = sha256_dir(dirpath)
                dirs[:] = []
                continue
            for f in sorted(files):
                if f.lower().endswith(EXTENSIONS):
                    rel = f if rel_dir == "." else f"{rel_dir}/{f}"
                    found[rel] = sha256_file(os.path.join(dirpath, f))
    return found


def verify(cmd, mode, root, rel, sig, args):
    argv = cmd.split() + ["verify", mode, rel, "--signature", sig]
    if mode == "sigstore":
        argv += ["--identity", args.identity, "--identity_provider", args.identity_provider]
    else:
        argv += ["--public_key", args.public_key]
    try:
        p = subprocess.run(argv, cwd=root, capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)
    out = (p.stdout + p.stderr).strip()
    return p.returncode == 0 and "Verification succeeded" in out, out.splitlines()[-1] if out else f"exit {p.returncode}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--scan", default="")
    ap.add_argument("--paths", default="", help="comma-separated scan roots; discovery is limited to them")
    ap.add_argument("--manifest", default="models.json")
    ap.add_argument("--fail-on-severity", default="high", choices=SEVERITIES)
    ap.add_argument("--verify", default="none", choices=["none", "sigstore", "key"])
    ap.add_argument("--identity", default="")
    ap.add_argument("--identity-provider", default="")
    ap.add_argument("--public-key", default="")
    ap.add_argument("--signature-suffix", default=".sig")
    ap.add_argument("--model-signing-cmd", default="model_signing")
    ap.add_argument("--require-signature", action="store_true")
    ap.add_argument("--inventory", default="docs/ai-agents.md")
    ap.add_argument("--lock", default=".mcp-scan.lock")
    ap.add_argument("--mlbom", default="")
    ap.add_argument("--output")
    args = ap.parse_args()

    errors, warnings = [], []
    models = {rel: {"sha256": h, "severity": None, "issues": [], "signed": False, "verified": None} for rel, h in discover(args.root, [p.strip() for p in args.paths.split(",") if p.strip()]).items()}

    # modelscan reports
    threshold = SEVERITIES.index(args.fail_on_severity)
    for path in [p for p in args.scan.split(",") if p.strip()]:
        with open(path) as fh:
            rep = json.load(fh)
        base = os.path.relpath(rep["summary"]["absolute_path"], os.path.abspath(args.root)).replace(os.sep, "/")
        base = "" if base == "." else base + "/"
        for issue in rep.get("issues", []):
            src = issue.get("source") or ""
            rel = src if src.startswith(base) and base else f"{base}{src}"
            if os.path.isfile(os.path.join(args.root, rel)) or rel in models:
                pass
            elif base and os.path.isfile(os.path.join(args.root, base.rstrip("/"))):
                rel = base.rstrip("/")  # -p pointed at a single file
            sev = issue.get("severity", "").lower()
            entry = models.setdefault(rel, {"sha256": None, "severity": None, "issues": [], "signed": False, "verified": None})
            entry["issues"].append(f"{sev.upper()}: {issue.get('description')}")
            if entry["severity"] is None or SEVERITIES.index(sev) > SEVERITIES.index(entry["severity"]):
                entry["severity"] = sev
            if SEVERITIES.index(sev) >= threshold:
                errors.append(f"{rel}: {sev.upper()}: {issue.get('description')} ({issue.get('scanner', '').rsplit('.', 1)[-1]})")
        for err in rep.get("errors", []):
            src = err.get("source") or ""
            errors.append(f"{base}{src}: modelscan {err.get('category', 'ERROR').lower()}: {err.get('description')}")

    # manifest: runtime models pinned by hash
    manifest_path = os.path.join(args.root, args.manifest)
    manifest = []
    if os.path.exists(manifest_path):
        with open(manifest_path) as fh:
            manifest = json.load(fh).get("models", [])
    for i, m in enumerate(manifest):
        label = f"{args.manifest}: {m.get('name') or m.get('path') or m.get('url') or f'entry {i + 1}'}"
        if not m.get("sha256"):
            errors.append(f"{label}: no sha256; a model loaded at runtime is pinned by hash")
        if not m.get("source"):
            errors.append(f"{label}: no source")
        if m.get("path"):
            rel = m["path"].strip("/")
            if rel not in models:
                errors.append(f"{label}: path {rel} is not in the repository")
            else:
                models[rel]["manifest"] = m
                if m.get("sha256") and m["sha256"].removeprefix("sha256:") != models[rel]["sha256"]:
                    errors.append(f"{label}: sha256 {m['sha256']} does not match the file ({models[rel]['sha256']})")

    # signatures
    for rel, entry in models.items():
        sig = rel + args.signature_suffix
        if os.path.exists(os.path.join(args.root, sig)):
            entry["signed"] = True
            if args.verify != "none":
                ok, msg = verify(args.model_signing_cmd, args.verify, args.root, rel, sig, args)
                entry["verified"] = ok
                if not ok:
                    errors.append(f"{rel}: signature {sig} did not verify: {msg}")
        elif args.require_signature:
            errors.append(f"{rel}: unsigned (no {sig}); require-signature is on")
        else:
            warnings.append(f"{rel}: unsigned (no {sig})")

    # ML-BOM
    components = []
    for rel, entry in sorted(models.items()):
        m = entry.get("manifest") or {}
        c = {"type": "machine-learning-model", "bom-ref": f"model:{rel}", "name": m.get("name") or os.path.basename(rel),
             "version": str(m.get("version") or entry["sha256"] or "unknown")[:64],
             "properties": [{"name": "sparkgeo:path", "value": rel},
                            {"name": "sparkgeo:signed", "value": str(entry["signed"]).lower()},
                            {"name": "sparkgeo:modelscan", "value": entry["severity"] or "clean"}]}
        if entry["sha256"]:
            c["hashes"] = [{"alg": "SHA-256", "content": entry["sha256"]}]
        if m.get("source"):
            c["externalReferences"] = [{"type": "distribution", "url": m["source"]}]
        if m.get("license"):
            c["licenses"] = [{"license": {"id": m["license"]}}]
        if entry["verified"] is not None:
            c["properties"].append({"name": "sparkgeo:signature-verified", "value": str(entry["verified"]).lower()})
        components.append(c)
    for m in manifest:
        if m.get("url"):
            c = {"type": "machine-learning-model", "bom-ref": f"model:{m['url']}", "name": m.get("name") or m["url"],
                 "version": str(m.get("version") or "unknown"), "externalReferences": [{"type": "distribution", "url": m["url"]}],
                 "properties": [{"name": "sparkgeo:loaded-at-runtime", "value": "true"}]}
            if m.get("sha256"):
                c["hashes"] = [{"alg": "SHA-256", "content": m["sha256"].removeprefix("sha256:")}]
            if m.get("source"):
                c["externalReferences"].append({"type": "website", "url": m["source"]})
            components.append(c)
    lock_path = os.path.join(args.root, args.lock)
    lock = {}
    if os.path.exists(lock_path):
        with open(lock_path) as fh:
            lock = json.load(fh)
    for key, h in sorted(lock.get("servers", {}).items()):
        cfg, name = key.split("::", 1)
        components.append({"type": "application", "bom-ref": f"mcp:{key}", "name": name, "version": h.removeprefix("sha256:")[:12],
                           "hashes": [{"alg": "SHA-256", "content": h.removeprefix("sha256:")}],
                           "properties": [{"name": "sparkgeo:mcp-config", "value": cfg}, {"name": "sparkgeo:kind", "value": "mcp-server"}]})
    for path, h in sorted(lock.get("skills", {}).items()):
        components.append({"type": "file", "bom-ref": f"skill:{path}", "name": path, "version": h.removeprefix("sha256:")[:12],
                           "hashes": [{"alg": "SHA-256", "content": h.removeprefix("sha256:")}],
                           "properties": [{"name": "sparkgeo:kind", "value": "skill"}]})
    rows, inv_errors = parse_inventory(os.path.join(args.root, args.inventory)) if os.path.exists(os.path.join(args.root, args.inventory)) else ([], [])
    warnings += [f"{args.inventory}: {e}" for e in inv_errors]
    for r in rows:
        if (r.get("lifecycle state") or "").lower() == "retired":
            continue
        components.append({"type": "application", "bom-ref": f"agent:{r.get('name')}", "name": r.get("name", ""),
                           "version": r.get("lifecycle state", ""), "supplier": {"name": r.get("provider", "")},
                           "properties": [{"name": f"sparkgeo:{k.replace(' ', '-')}", "value": r.get(k, "")}
                                          for k in ("config path", "class", "risk tier", "owner", "kill switch")]})
    bom = {"bomFormat": "CycloneDX", "specVersion": "1.6", "serialNumber": f"urn:uuid:{uuid.uuid4()}", "version": 1,
           "metadata": {"timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                        "tools": {"components": [{"type": "application", "name": "sparkgeo/github-actions modelscan", "version": "1"}]},
                        "component": {"type": "application", "name": os.environ.get("GITHUB_REPOSITORY", os.path.basename(os.path.abspath(args.root))),
                                      "version": os.environ.get("GITHUB_SHA", "local")}},
           "components": components}
    if args.mlbom:
        os.makedirs(os.path.dirname(os.path.join(args.root, args.mlbom)) or ".", exist_ok=True)
        with open(os.path.join(args.root, args.mlbom), "w") as fh:
            json.dump(bom, fh, indent=1)
            fh.write("\n")

    for e in errors:
        print(f"::error title=model-scan::{e}")
    for w in warnings:
        print(f"::warning title=model-scan::{w}")
    n_models = sum(1 for e in models.values() if e["sha256"])
    summary = [f"## Model scan: {n_models} model(s), {len(manifest)} manifest entr{'y' if len(manifest) == 1 else 'ies'}, {len(components)} ML-BOM component(s), {len(errors)} error(s), {len(warnings)} warning(s)", ""]
    if models:
        summary += ["| Model | SHA-256 | modelscan | Signature |", "|---|---|---|---|"]
        for rel, e in sorted(models.items()):
            sig = "verified" if e["verified"] else "failed" if e["verified"] is False else "signed" if e["signed"] else "unsigned"
            summary.append(f"| `{rel}` | `{(e['sha256'] or '')[:12]}` | {(e['severity'] or 'clean').upper()} | {sig} |")
    if errors:
        summary += ["", "### Errors", ""] + [f"- {e}" for e in errors]
    if warnings:
        summary += ["", "### Warnings", ""] + [f"- {w}" for w in warnings]
    text = "\n".join(summary) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"model-count={n_models}\nerror-count={len(errors)}\ncomponent-count={len(components)}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"models": models, "errors": errors, "warnings": warnings, "components": len(components)}, fh, indent=1)
            fh.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
