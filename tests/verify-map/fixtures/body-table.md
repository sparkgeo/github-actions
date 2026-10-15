## Summary

Quadkey encode now handles zoom 0.

## Verification

Each acceptance criterion cites the contract, property, model or proof that covers it.

| Acceptance criterion | Covered by | Where |
|---|---|---|
| zoom 0 encodes to the empty key | contract `encode.__post__` and Hypothesis property `test_roundtrip` | `src/tiles/quadkey.py:12` |
