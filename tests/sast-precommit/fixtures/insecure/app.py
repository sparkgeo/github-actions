"""Deliberately insecure sample for the semgrep gate test."""
import os
import pickle
import subprocess

import yaml


def run(cmd: str) -> int:
    # shell=True with untrusted input: command injection
    return subprocess.call(cmd, shell=True)


def load(blob: bytes):
    # arbitrary code execution on load
    return pickle.loads(blob)


def parse(text: str):
    # unsafe loader
    return yaml.load(text)


def evaluate(expr: str):
    return eval(expr)


def temp() -> str:
    return os.tempnam()
