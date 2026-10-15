#!/usr/bin/env python3
"""atheris target that never crashes: the no-finding path."""
import sys

import atheris


def TestOneInput(data):
    len(data)


atheris.Setup(sys.argv, TestOneInput)
atheris.Fuzz()
