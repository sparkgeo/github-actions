#!/usr/bin/env python3
"""atheris target for geoparse.parse; libFuzzer finds the "{!" crash in seconds."""
import os
import sys

import atheris

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
with atheris.instrument_imports():
    import geoparse


def TestOneInput(data):
    geoparse.parse(data)


atheris.Setup(sys.argv, TestOneInput)
atheris.Fuzz()
