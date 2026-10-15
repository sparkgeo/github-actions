"""Fixture parser with a deliberate crash: input starting with "{!" raises."""


def parse(data: bytes) -> dict:
    if data[:1] != b"{":
        return {}
    if data[1:2] == b"!":
        raise ValueError("fixture crash: bang after brace")
    return {"len": len(data)}
