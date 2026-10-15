#!/usr/bin/env python3
"""Positive and negative samples for policies/pii/recognizers.yml and the Luhn
filter in scan.py (issue #97). Run with the presidio virtualenv's python."""
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".github", "actions", "presidio"))
sys.dont_write_bytecode = True
from scan import luhn_ok, glob_match  # noqa: E402

from presidio_analyzer import AnalyzerEngine, RecognizerRegistry  # noqa: E402
from presidio_analyzer.nlp_engine import NlpEngineProvider  # noqa: E402

RECOGNIZERS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "policies", "pii", "recognizers.yml")


class Recognizers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        nlp = NlpEngineProvider(nlp_configuration={"nlp_engine_name": "spacy", "models": [{"lang_code": "en", "model_name": "en_core_web_sm"}]}).create_engine()
        reg = RecognizerRegistry()
        reg.load_predefined_recognizers(nlp_engine=nlp, languages=["en"])
        reg.add_recognizers_from_yaml(RECOGNIZERS)
        cls.analyzer = AnalyzerEngine(registry=reg, nlp_engine=nlp, supported_languages=["en"])

    def entities(self, text, threshold=0.4):
        return {(r.entity_type, text[r.start:r.end]) for r in self.analyzer.analyze(text=text, entities=["CA_SIN", "CA_POSTAL_CODE", "PERSON"], language="en", score_threshold=threshold)}

    @staticmethod
    def valid_sin():
        """A Luhn-valid SIN in an issued range (first digit 1-7), built at run time so no SIN is committed."""
        body = "13" + "052947"  # 8 digits plus the check digit
        total = 0
        for i, ch in enumerate(reversed(body)):
            d = int(ch)
            if i % 2 == 0:
                d = d * 2 - 9 if d * 2 > 9 else d * 2
            total += d
        n = body + str((10 - total % 10) % 10)
        return f"{n[:3]} {n[3:6]} {n[6:]}"

    def test_sin_with_context_scores_high(self):
        sin = self.valid_sin()
        self.assertIn(("CA_SIN", sin), self.entities(f"SIN: {sin}", threshold=0.8))

    def test_sin_without_context_is_weak(self):
        sin = self.valid_sin()
        self.assertNotIn(("CA_SIN", sin), self.entities(f"order {sin} shipped", threshold=0.8))

    def test_sin_outside_issued_ranges_is_not_matched(self):
        # first digit 0 or 8 is never issued; the Service Canada example 046 454 286 is one
        self.assertEqual(set(), {e for e in self.entities("SIN: 046 454 286", threshold=0.1) if e[0] == "CA_SIN"})

    def test_sin_luhn(self):
        self.assertTrue(luhn_ok(self.valid_sin().replace(" ", "")))
        self.assertTrue(luhn_ok("046454286"))
        self.assertFalse(luhn_ok("123456789"))
        self.assertFalse(luhn_ok("046454287"))

    def test_postal_code_next_to_address(self):
        self.assertIn(("CA_POSTAL_CODE", "V6B 1A1"), self.entities("Address: 123 Main Street, Vancouver BC V6B 1A1", threshold=0.6))

    def test_postal_code_alone_is_weak(self):
        self.assertNotIn(("CA_POSTAL_CODE", "V6B 1A1"), self.entities("grid cell V6B 1A1", threshold=0.6))

    def test_postal_code_rejects_invalid_letters(self):
        self.assertEqual(set(), self.entities("Address: D1D 1D1 and W2W 2W2", threshold=0.1))

    def test_glob(self):
        self.assertTrue(glob_match("README.md", "**/*.md"))
        self.assertTrue(glob_match("docs/a/b.md", "**/*.md"))
        self.assertTrue(glob_match("tests/fixtures/x/y.csv", "**/fixtures/**"))
        self.assertTrue(glob_match("vendor/NOTICE.txt", "vendor/**"))
        self.assertFalse(glob_match("src/vendor/NOTICE.txt", "vendor/**"))
        self.assertFalse(glob_match("a/b.py", "**/*.md"))


if __name__ == "__main__":
    unittest.main()
