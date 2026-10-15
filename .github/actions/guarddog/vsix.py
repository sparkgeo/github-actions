"""Scan local .vsix files with GuardDog's full analyzer (issue #229).

`guarddog extension scan <file>.vsix` runs only the source-code rules on a
local file and returns no risk score, so the gate would have no label to
compare with fail-on. This unpacks each file and runs the same analyzer the
marketplace path uses, then writes the verify-shaped list gate.py reads.

Usage: vsix.py OUT.json FILE.vsix [FILE.vsix ...]
"""

import json
import sys
import tempfile
import zipfile

from guarddog.scanners.extension_scanner import ExtensionScanner

scanner = ExtensionScanner()
out = []
for path in sys.argv[2:]:
    with tempfile.TemporaryDirectory() as tmp:
        # zipfile.extractall drops absolute paths and ".." components.
        zipfile.ZipFile(path).extractall(tmp)
        out.append({"dependency": path, "version": "", "result": scanner.analyzer.analyze(tmp)})
with open(sys.argv[1], "w") as handle:
    json.dump(out, handle)
