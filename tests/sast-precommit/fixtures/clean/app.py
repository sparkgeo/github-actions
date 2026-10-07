"""Clean sample: same shapes, safe APIs."""
import json
import subprocess
import tempfile


def run(args: list[str]) -> int:
    return subprocess.call(args)


def load(blob: str) -> dict:
    return json.loads(blob)


def temp() -> str:
    return tempfile.mkstemp()[1]
