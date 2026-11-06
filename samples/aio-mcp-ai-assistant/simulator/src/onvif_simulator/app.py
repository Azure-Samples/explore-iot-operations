from __future__ import annotations

import asyncio
import contextlib
import hmac
import io
import logging
import re
import secrets
from typing import Final

from aiohttp import web

from onvif_simulator.authentication import (
    digest_challenge,
    is_basic_authorized,
    is_digest_authorized,
)
from onvif_simulator.config import Settings
from onvif_simulator.discovery import DiscoveryServer
from onvif_simulator.image_catalog import (
    CorruptImageError,
    ImageCatalog,
    ImageCatalogError,
    ImageNotFoundError,
    InvalidImageNameError,
    UnsupportedImageError,
)
from onvif_simulator.media.encoder import VideoPipeline
from onvif_simulator.onvif.dispatcher import OnvifDispatcher
from onvif_simulator.renderer import FrameRenderer
from onvif_simulator.rtsp import RtspServer
from onvif_simulator.state import CameraState

LOGGER = logging.getLogger(__name__)
MAX_SOAP_BODY: Final = 1_048_576
ACTION_PARAMETER = re.compile(r'action=(?:"([^"]+)"|([^;\s]+))', re.IGNORECASE)


class Simulator:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.catalog = ImageCatalog(settings.image_dir, settings.initial_image)
        self.state = CameraState(settings.state_path)
        self.state.load()
        self.renderer = FrameRenderer(
            self.catalog,
            self.state,
            settings.diagnostic_overlay,
        )
        self.dispatcher = OnvifDispatcher(
            settings,
            self.state,
            self._log_camera_viewport,
        )
        self.pipelines = {
            profile.path: VideoPipeline(profile, self.renderer)
            for profile in settings.profiles.values()
        }
        self.rtsp = RtspServer(settings, self.pipelines)
        self.discovery = DiscoveryServer(settings) if settings.discovery_enabled else None
        self._http_digest_nonce = secrets.token_hex(16)
        self.web_app = self._create_web_app()
        self._runner: web.AppRunner | None = None
        self._motion_task: asyncio.Task[None] | None = None
        self._ready = False

    async def start(self) -> None:
        LOGGER.info(
            "starting ONVIF simulator",
            extra={
                "image": self.catalog.active_name,
                "http_port": self.settings.http_port,
                "rtsp_port": self.settings.rtsp_port,
            },
        )
        for pipeline in self.pipelines.values():
            await pipeline.start()
        await self.rtsp.start()
        if self.discovery is not None:
            await self.discovery.start()
        self._runner = web.AppRunner(self.web_app, access_log=LOGGER)
        await self._runner.setup()
        site = web.TCPSite(
            self._runner,
            self.settings.bind_host,
            self.settings.http_port,
        )
        await site.start()
        self._motion_task = asyncio.create_task(self._motion_loop(), name="ptz-motion")
        self._ready = True
        LOGGER.info("ONVIF simulator is ready")
        self._log_camera_viewport("startup")

    async def stop(self) -> None:
        self._ready = False
        if self._motion_task is not None:
            self._motion_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._motion_task
            self._motion_task = None
        if self._runner is not None:
            await self._runner.cleanup()
            self._runner = None
        if self.discovery is not None:
            await self.discovery.stop()
        await self.rtsp.stop()
        for pipeline in self.pipelines.values():
            await pipeline.stop()
        LOGGER.info("ONVIF simulator stopped")

    def _create_web_app(self) -> web.Application:
        app = web.Application(client_max_size=MAX_SOAP_BODY)
        for path in (
            "/onvif/device_service",
            "/onvif/media_service",
            "/onvif/media2_service",
            "/onvif/ptz_service",
            "/onvif/imaging_service",
            "/onvif/events_service",
            "/onvif/deviceio_service",
        ):
            app.router.add_post(path, self._soap)
        app.router.add_get("/onvif/snapshot/{profile_token}.jpg", self._snapshot)
        app.router.add_get("/switch_image", self._switch_image)
        app.router.add_get("/healthz", self._health)
        app.router.add_get("/readyz", self._readiness)
        return app

    async def _soap(self, request: web.Request) -> web.Response:
        if request.content_length is not None and request.content_length > MAX_SOAP_BODY:
            raise web.HTTPRequestEntityTooLarge(
                max_size=MAX_SOAP_BODY,
                actual_size=request.content_length,
            )
        payload = await request.read()
        action = request.headers.get("SOAPAction")
        if action is None:
            match = ACTION_PARAMETER.search(request.headers.get("Content-Type", ""))
            action = (match.group(1) or match.group(2)) if match else None
        transport_authenticated = is_digest_authorized(
            request.headers.get("Authorization", ""),
            method=request.method,
            uri=request.path_qs,
            nonce=self._http_digest_nonce,
            username=self.settings.camera_username,
            password=self.settings.camera_password.get_secret_value(),
        )
        result = self.dispatcher.dispatch(
            request.path,
            payload,
            action,
            transport_authenticated=transport_authenticated,
        )
        headers = (
            {"WWW-Authenticate": digest_challenge(self._http_digest_nonce)}
            if result.status == 401 and not transport_authenticated
            else None
        )
        return web.Response(
            body=result.payload,
            status=result.status,
            content_type="application/soap+xml",
            charset="utf-8",
            headers=headers,
        )

    async def _snapshot(self, request: web.Request) -> web.Response:
        self._require_camera_basic_auth(request)
        token = request.match_info["profile_token"]
        try:
            profile = self.settings.profile_by_token(token)
        except KeyError as exc:
            raise web.HTTPNotFound(text="unknown media profile") from exc
        image = await asyncio.to_thread(self.renderer.render, profile)
        output = io.BytesIO()
        await asyncio.to_thread(image.save, output, "JPEG", quality=90)
        return web.Response(
            body=output.getvalue(),
            content_type="image/jpeg",
            headers={"Cache-Control": "no-store"},
        )

    async def _switch_image(self, request: web.Request) -> web.Response:
        self._require_admin_auth(request)
        name = request.query.get("name")
        if name is None:
            raise web.HTTPBadRequest(
                text='{"error":"the name query parameter is required"}',
                content_type="application/json",
            )
        try:
            snapshot = await asyncio.to_thread(self.catalog.switch, name)
        except InvalidImageNameError as exc:
            raise self._json_error(web.HTTPBadRequest, str(exc)) from exc
        except ImageNotFoundError as exc:
            raise self._json_error(web.HTTPNotFound, str(exc)) from exc
        except UnsupportedImageError as exc:
            raise self._json_error(web.HTTPUnsupportedMediaType, str(exc)) from exc
        except CorruptImageError as exc:
            raise self._json_error(web.HTTPUnprocessableEntity, str(exc)) from exc
        except ImageCatalogError as exc:
            LOGGER.exception("image switch failed", extra={"requested_image": name})
            raise self._json_error(web.HTTPInternalServerError, str(exc)) from exc
        LOGGER.info(
            "active simulator image changed",
            extra={"active_image": snapshot.name, "revision": snapshot.revision},
        )
        self._log_camera_viewport("image_switched")
        return web.json_response(
            {"active_image": snapshot.name, "revision": snapshot.revision},
            headers={"Cache-Control": "no-store"},
        )

    async def _health(self, request: web.Request) -> web.Response:
        return web.json_response({"status": "healthy"})

    async def _readiness(self, request: web.Request) -> web.Response:
        if not self._ready:
            return web.json_response({"status": "not ready"}, status=503)
        return web.json_response(
            {
                "status": "ready",
                "active_image": self.catalog.active_name,
                "profiles": [profile.path for profile in self.settings.profiles.values()],
            }
        )

    def _require_admin_auth(self, request: web.Request) -> None:
        configured = self.settings.admin_token
        if configured is None:
            raise web.HTTPNotFound()
        authorization = request.headers.get("Authorization", "")
        scheme, _, supplied = authorization.partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(
            supplied,
            configured.get_secret_value(),
        ):
            raise web.HTTPUnauthorized(
                text='{"error":"valid administrative bearer token required"}',
                content_type="application/json",
                headers={"WWW-Authenticate": "Bearer"},
            )

    def _require_camera_basic_auth(self, request: web.Request) -> None:
        if is_basic_authorized(
            request.headers.get("Authorization", ""),
            self.settings.camera_username,
            self.settings.camera_password.get_secret_value(),
        ):
            return
        raise web.HTTPUnauthorized(
            text="camera authentication required",
            headers={"WWW-Authenticate": 'Basic realm="ONVIF Simulator"'},
        )

    async def _motion_loop(self) -> None:
        loop = asyncio.get_running_loop()
        last_update = loop.time()
        last_report = last_update
        while True:
            await asyncio.sleep(0.05)
            now = loop.time()
            self.state.update_motion(now - last_update)
            last_update = now
            if self.state.snapshot().velocity.moving and now - last_report >= 0.5:
                self._log_camera_viewport("continuous_move")
                last_report = now

    def _log_camera_viewport(self, event: str) -> None:
        profile = max(
            self.settings.profiles.values(),
            key=lambda candidate: candidate.width * candidate.height,
        )
        viewport = self.renderer.viewport_status(profile)
        LOGGER.info(
            "camera viewport event=%s image=%s pan=%.3f tilt=%.3f zoom=%.3f "
            "source=%dx%d crop=%d,%d,%dx%d %s",
            event,
            viewport.image_name,
            viewport.pan,
            viewport.tilt,
            viewport.zoom,
            viewport.source_width,
            viewport.source_height,
            viewport.left,
            viewport.top,
            viewport.width,
            viewport.height,
            viewport.indicator,
        )

    @staticmethod
    def _json_error(
        error_type: type[web.HTTPException],
        message: str,
    ) -> web.HTTPException:
        safe_message = message.replace("\\", "\\\\").replace('"', '\\"')
        return error_type(
            text=f'{{"error":"{safe_message}"}}',
            content_type="application/json",
            headers={"Cache-Control": "no-store"},
        )
