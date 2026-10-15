"""One property per acceptance criterion; `pytest -m property` is the Baseline gate."""
import pytest
from hypothesis import given, strategies as st

from tiles.quadkey import child, decode, encode, parent

pytestmark = pytest.mark.property


@st.composite
def tiles(draw):
    zoom = draw(st.integers(0, 30))
    n = 2**zoom
    return draw(st.integers(0, n - 1)), draw(st.integers(0, n - 1)), zoom


@given(tiles())
def test_roundtrip(t):
    x, y, zoom = t
    assert decode(encode(x, y, zoom)) == (x, y, zoom)


@given(tiles())
def test_parent_is_prefix(t):
    key = encode(*t)
    assert key.startswith(parent(key))


@given(tiles(), st.integers(0, 3))
def test_child_is_below_parent(t, quadrant):
    x, y, zoom = t
    if zoom == 30:
        return
    cx, cy, cz = child(x, y, zoom, quadrant)
    assert cz == zoom + 1 and cx // 2 == x and cy // 2 == y
