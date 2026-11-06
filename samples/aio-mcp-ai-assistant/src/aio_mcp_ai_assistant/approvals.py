import asyncio
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from .common import JsonObject, SampleError


@dataclass(frozen=True)
class Approval:
    approval_id: str
    arguments: JsonObject
    expires_at: datetime

    def as_json(self) -> JsonObject:
        return {
            "id": self.approval_id,
            "tool": "recommendation-publish",
            "arguments": deepcopy(self.arguments),
            "expiresAt": self.expires_at.isoformat(),
        }


class ApprovalStore:
    def __init__(self, lifetime_seconds: int = 300) -> None:
        self.lifetime = timedelta(seconds=lifetime_seconds)
        self.items: dict[str, Approval] = {}
        self.lock = asyncio.Lock()

    def _remove_expired(self, now: datetime) -> None:
        for key in [key for key, value in self.items.items() if value.expires_at <= now]:
            del self.items[key]

    async def create(self, arguments: JsonObject) -> Approval:
        now = datetime.now(timezone.utc)
        approval = Approval(str(uuid4()), deepcopy(arguments), now + self.lifetime)
        async with self.lock:
            self._remove_expired(now)
            if len(self.items) >= 64:
                raise SampleError("Too many pending recommendations; deny or wait for expiry")
            self.items[approval.approval_id] = approval
        return approval

    async def take(self, approval_id: str) -> Approval:
        async with self.lock:
            self._remove_expired(datetime.now(timezone.utc))
            approval = self.items.pop(approval_id, None)
        if approval is None:
            raise ValueError("Approval was not found or has expired")
        return approval
