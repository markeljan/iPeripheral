"""Pairing: Tony speaks a 6-digit code, the phone sends it back, and gets a token. Only token hashes are stored."""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import time
from pathlib import Path

TOKENS = Path(os.environ.get("TONYPI_PHONE_TOKENS", Path.home() / ".config/tonypi-phone/tokens.json"))
CODE_TTL_S = 120
TRIES = 3


def _digest(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class TokenStore:
    def __init__(self, path: Path = TOKENS) -> None:
        self.path = Path(path)

    def _load(self) -> dict:
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {"tokens": []}

    def check(self, token: str) -> bool:
        d = _digest(token)
        return any(secrets.compare_digest(d, t["sha256"]) for t in self._load()["tokens"])

    def issue(self, device: str) -> str:
        token = secrets.token_urlsafe(32)
        data = self._load()
        data["tokens"].append({"sha256": _digest(token), "device": device, "issued": int(time.time())})
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2))
        os.chmod(tmp, 0o600)
        tmp.replace(self.path)
        return token


class PairingAttempt:
    def __init__(self, now: float | None = None) -> None:
        self.code = f"{secrets.randbelow(10**6):06d}"
        self.expires = (now if now is not None else time.monotonic()) + CODE_TTL_S
        self.tries_left = TRIES

    def confirm(self, code: str, now: float | None = None) -> bool:
        """True on the right code. Wrong codes use up tries; an expired attempt never succeeds."""
        if self.expired(now) or self.tries_left <= 0:
            return False
        if secrets.compare_digest(str(code), self.code):
            return True
        self.tries_left -= 1
        return False

    def expired(self, now: float | None = None) -> bool:
        return (now if now is not None else time.monotonic()) > self.expires

    @property
    def spoken(self) -> str:
        digits = " ".join(self.code)
        return f"My pairing code is {digits}. Again, {digits}."
