"""Calls into GEOS and PROJ: an opaque boundary for CrossHair."""

import numpy as np
from pyproj import Transformer
from shapely.geometry import Point


def buffer_metres(x: float, y: float, r: float) -> float:
    """post: __return__ >= 0"""
    return float(Point(x, y).buffer(r).area)


def reproject(x: float, y: float) -> tuple[float, float]:
    t = Transformer.from_crs(4326, 3857, always_xy=True)
    return t.transform(x, y)


def mean_of(values: list[float]) -> float:
    return float(np.mean(values))


def pure(n: int) -> int:
    return n + 1
