"""Base-branch copy for the diffbehavior fixture."""


def double(x: int) -> int:
    return 2 * x


def total(a: int, b: int) -> int:
    return a + b


def _hidden(x: int) -> int:
    return x
