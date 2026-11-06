from __future__ import annotations

import asyncio
import base64
import contextlib
import logging
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from fractions import Fraction

import av

from onvif_simulator.config import StreamProfile
from onvif_simulator.renderer import FrameRenderer

LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class AccessUnit:
    nals: tuple[bytes, ...]
    timestamp: int
    keyframe: bool


def split_annex_b(payload: bytes) -> tuple[bytes, ...]:
    starts: list[tuple[int, int]] = []
    index = 0
    while index < len(payload) - 3:
        if payload[index : index + 4] == b"\x00\x00\x00\x01":
            starts.append((index, 4))
            index += 4
        elif payload[index : index + 3] == b"\x00\x00\x01":
            starts.append((index, 3))
            index += 3
        else:
            index += 1
    if not starts:
        return (payload,) if payload else ()
    nals: list[bytes] = []
    for current, (start, prefix_length) in enumerate(starts):
        end = starts[current + 1][0] if current + 1 < len(starts) else len(payload)
        nal = payload[start + prefix_length : end]
        if nal:
            nals.append(nal)
    return tuple(nals)


class VideoPipeline:
    def __init__(self, profile: StreamProfile, renderer: FrameRenderer) -> None:
        self.profile = profile
        self._renderer = renderer
        self._codec = av.CodecContext.create("libx264", "w")
        self._codec.width = profile.width
        self._codec.height = profile.height
        self._codec.pix_fmt = "yuv420p"
        self._codec.time_base = Fraction(1, profile.frame_rate)
        self._codec.framerate = Fraction(profile.frame_rate, 1)
        self._codec.bit_rate = profile.bitrate_kbps * 1000
        self._codec.options = {
            "preset": "ultrafast",
            "tune": "zerolatency",
            "x264-params": (
                f"repeat-headers=1:keyint={profile.key_frame_interval}:"
                f"min-keyint={profile.key_frame_interval}:scenecut=0"
            ),
        }
        self._codec.open()
        self._executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix=f"encoder-{profile.path}",
        )
        self._subscribers: set[asyncio.Queue[AccessUnit]] = set()
        self._task: asyncio.Task[None] | None = None
        self._ready = asyncio.Event()
        self._stopping = asyncio.Event()
        self._frame_index = 0
        self._last_revision = -1
        self._sps: bytes | None = None
        self._pps: bytes | None = None
        self._latest: AccessUnit | None = None

    @property
    def sps(self) -> bytes:
        if self._sps is None:
            raise RuntimeError(f"H.264 SPS is not ready for {self.profile.path}")
        return self._sps

    @property
    def pps(self) -> bytes:
        if self._pps is None:
            raise RuntimeError(f"H.264 PPS is not ready for {self.profile.path}")
        return self._pps

    @property
    def profile_level_id(self) -> str:
        return self.sps[1:4].hex() if len(self.sps) >= 4 else "42e01f"

    @property
    def sprop_parameter_sets(self) -> str:
        return ",".join(base64.b64encode(value).decode("ascii") for value in (self.sps, self.pps))

    async def start(self) -> None:
        if self._task is not None:
            return
        self._task = asyncio.create_task(self._run(), name=f"pipeline-{self.profile.path}")
        try:
            await asyncio.wait_for(self._ready.wait(), timeout=15)
        except TimeoutError:
            await self.stop()
            raise RuntimeError(
                f"H.264 encoder did not initialize for profile {self.profile.path}"
            ) from None

    async def stop(self) -> None:
        self._stopping.set()
        if self._task is not None:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
            self._task = None
        self._executor.shutdown(wait=True, cancel_futures=True)

    def subscribe(self) -> asyncio.Queue[AccessUnit]:
        queue: asyncio.Queue[AccessUnit] = asyncio.Queue(maxsize=2)
        self._subscribers.add(queue)
        if self._latest is not None:
            queue.put_nowait(self._latest)
        return queue

    def unsubscribe(self, queue: asyncio.Queue[AccessUnit]) -> None:
        self._subscribers.discard(queue)

    async def _run(self) -> None:
        interval = 1.0 / self.profile.frame_rate
        loop = asyncio.get_running_loop()
        next_frame = loop.time()
        try:
            while not self._stopping.is_set():
                access_units = await loop.run_in_executor(self._executor, self._encode_frame)
                for access_unit in access_units:
                    self._record_parameter_sets(access_unit.nals)
                    self._latest = access_unit
                    self._broadcast(access_unit)
                if self._sps is not None and self._pps is not None:
                    self._ready.set()
                next_frame += interval
                await asyncio.sleep(max(0.0, next_frame - loop.time()))
        except asyncio.CancelledError:
            raise
        except Exception:
            LOGGER.exception("H.264 pipeline failed", extra={"profile": self.profile.path})
            raise

    def _encode_frame(self) -> list[AccessUnit]:
        image = self._renderer.render(self.profile)
        frame = av.VideoFrame.from_image(image)  # type: ignore[no-untyped-call]
        frame.pts = self._frame_index
        frame.time_base = self._codec.time_base
        revision = self._renderer.image_revision
        if revision != self._last_revision:
            frame.pict_type = av.video.frame.PictureType.I
            self._last_revision = revision

        timestamp = int(self._frame_index * 90_000 / self.profile.frame_rate) & 0xFFFFFFFF
        self._frame_index += 1
        result: list[AccessUnit] = []
        for packet in self._codec.encode(frame):
            nals = split_annex_b(bytes(packet))
            if nals:
                result.append(AccessUnit(nals, timestamp, packet.is_keyframe))
        return result

    def _record_parameter_sets(self, nals: tuple[bytes, ...]) -> None:
        for nal in nals:
            nal_type = nal[0] & 0x1F
            if nal_type == 7:
                self._sps = nal
            elif nal_type == 8:
                self._pps = nal

    def _broadcast(self, access_unit: AccessUnit) -> None:
        for queue in tuple(self._subscribers):
            if queue.full():
                with contextlib.suppress(asyncio.QueueEmpty):
                    queue.get_nowait()
            with contextlib.suppress(asyncio.QueueFull):
                queue.put_nowait(access_unit)
