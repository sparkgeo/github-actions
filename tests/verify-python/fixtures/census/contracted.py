"""Every contract spelling the census recognises."""

import deal
import icontract


@icontract.require(lambda n: n >= 0)
@icontract.ensure(lambda result, n: result >= n)
def with_icontract(n: int) -> int:
    return n + 1


@deal.pre(lambda n: n >= 0)
@deal.post(lambda r: r >= 0)
def with_deal(n: int) -> int:
    return n * 2


def with_pep316(n: int) -> int:
    """Double it.

    pre: n >= 0
    post: __return__ >= n
    """
    return n * 2


def with_assert(n: int) -> int:
    r = n * 2
    assert r >= n
    return r


def _private(n: int) -> int:
    return n
