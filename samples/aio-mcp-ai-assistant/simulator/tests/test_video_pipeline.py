from __future__ import annotations

import asyncio

from onvif_simulator.config import Settings
from onvif_simulator.image_catalog import ImageCatalog
from onvif_simulator.media.encoder import VideoPipeline
from onvif_simulator.renderer import FrameRenderer
from onvif_simulator.state import CameraState


async def test_pipeline_produces_h264_parameter_sets(settings: Settings) -> None:
    catalog = ImageCatalog(settings.image_dir, settings.initial_image)
    state = CameraState(settings.state_path)
    renderer = FrameRenderer(catalog, state)
    pipeline = VideoPipeline(settings.profiles["standard"], renderer)

    await pipeline.start()
    queue = pipeline.subscribe()
    try:
        access_unit = await asyncio.wait_for(queue.get(), timeout=5)
        assert access_unit.nals
        assert pipeline.sps[0] & 0x1F == 7
        assert pipeline.pps[0] & 0x1F == 8
    finally:
        pipeline.unsubscribe(queue)
        await pipeline.stop()
