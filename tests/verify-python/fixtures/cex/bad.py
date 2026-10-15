"""A false postcondition: inc(-1) returns 0, not > 0."""


def inc(x: int) -> int:
    """post: __return__ > 0"""
    return x + 1


def clamp(x: int) -> int:
    """post: 0 <= __return__ <= 10"""
    return min(max(x, 0), 10)
