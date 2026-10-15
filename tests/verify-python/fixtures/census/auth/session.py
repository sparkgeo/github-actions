"""A high-risk path (matches **/auth/**) with no contract."""


def issue(user: str) -> str:
    return user + ":session"


def revoke(token: str) -> bool:
    return bool(token)
