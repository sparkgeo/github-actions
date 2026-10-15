"""Quadkey encode and decode for XYZ tiles, with contracts CrossHair can check.

A quadkey is the zoom-length string of digits 0-3 that names a tile; each
digit is one level of the quadtree (Bing Maps convention). The contracts are
the acceptance criteria: a key has exactly `zoom` digits, decode inverts
encode, and every input outside the tile grid is rejected at the boundary.
"""

import icontract


@icontract.require(lambda zoom: 0 <= zoom <= 30, "zoom in 0..30")
@icontract.require(lambda x, zoom: 0 <= x < 2**zoom, "x inside the grid")
@icontract.require(lambda y, zoom: 0 <= y < 2**zoom, "y inside the grid")
@icontract.ensure(lambda result, zoom: len(result) == zoom, "one digit per zoom level")
@icontract.ensure(lambda result: all(c in "0123" for c in result), "digits 0-3 only")
def encode(x: int, y: int, zoom: int) -> str:
    """Return the quadkey of tile (x, y) at `zoom`."""
    digits = []
    for i in range(zoom, 0, -1):
        mask = 1 << (i - 1)
        d = 0
        if x & mask:
            d += 1
        if y & mask:
            d += 2
        digits.append(str(d))
    return "".join(digits)


@icontract.require(lambda key: len(key) <= 30 and all(c in "0123" for c in key), "a quadkey")
@icontract.ensure(lambda result, key: result[2] == len(key), "zoom is the key length")
def decode(key: str) -> tuple[int, int, int]:
    """Return (x, y, zoom) for a quadkey.

    `encode(*decode(key)) == key` is the round-trip criterion; it is a Hypothesis
    property (tests/test_quadkey_properties.py), not a contract, because CrossHair
    cannot follow the string loop and would report "Not confirmed".
    """
    x = y = 0
    zoom = len(key)
    for i, c in enumerate(key):
        mask = 1 << (zoom - i - 1)
        d = int(c)
        if d & 1:
            x |= mask
        if d & 2:
            y |= mask
    return x, y, zoom


def parent(key: str) -> str:
    """The key one zoom level up; the root's parent is the root.

    post: len(__return__) == max(len(key) - 1, 0)
    """
    return key[:-1]


def child(x: int, y: int, zoom: int, quadrant: int) -> tuple[int, int, int]:
    """The tile in `quadrant` (0..3) one level below (x, y, zoom).

    pre: 0 <= quadrant <= 3
    pre: 0 <= zoom < 30
    post: __return__[2] == zoom + 1
    post: __return__[0] in (2 * x, 2 * x + 1)
    post: __return__[1] in (2 * y, 2 * y + 1)
    """
    return 2 * x + (quadrant & 1), 2 * y + (quadrant >> 1), zoom + 1
