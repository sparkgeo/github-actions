"""Consumer test: the Python service uses the Dafny-compiled quadkey core.

Not generated (the drift check allows extra files); run from this directory
with `python3 -m unittest test_quadkey`.
"""

import unittest

import _dafny
import Quadkey


def text(seq):
    return "".join(str(c) for c in seq)


class QuadkeyCore(unittest.TestCase):
    def test_encode(self):
        self.assertEqual(text(Quadkey.default__.EncodeChecked(3, 5, 3)), "213")

    def test_round_trip(self):
        for zoom in range(0, 6):
            for x in range(0, 2 ** zoom):
                for y in range(0, 2 ** zoom, 3):
                    key = Quadkey.default__.EncodeChecked(x, y, zoom)
                    self.assertEqual(tuple(Quadkey.default__.Decode(key)), (x, y, zoom))

    def test_parent(self):
        key = _dafny.Seq(_dafny.CodePoint(c) for c in "0213")
        self.assertEqual(text(Quadkey.default__.Parent(key)), "021")


if __name__ == "__main__":
    unittest.main()
