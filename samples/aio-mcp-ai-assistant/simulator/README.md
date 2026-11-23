# ONVIF camera simulator

This component supplies the optional simulated camera for the
[MCP assistant tutorial](../docs/camera-actions.md). It implements ONVIF device,
media, and PTZ services, HTTP snapshots, and H.264 RTSP streams. A bounded pan
changes the crop of a static panorama and its reported PTZ position; it does not
move physical equipment.

The image build generates a clearly labeled synthetic calibration scene. There
are no real people, camera recordings, or vision-model results in this scene.
The AIO connector for ONVIF and the MQTT command/response path are real components.

## Use the published simulator

Follow the [camera setup](../docs/camera-actions.md) to create the Kubernetes
workload using the simulator image from the same
[coordinated release](../../../docs/edge-ai-samples-release.md) as the assistant.
Register its Device and control Asset and use the assistant's
`camera-pan` tool. No public Service or unauthenticated broker listener is needed.
The deployment generates per-instance camera credentials and an administrative
token in Kubernetes Secrets. No default password is built into the image.

The configured ONVIF endpoint is `/onvif/device_service` on port 2020.
`profile_high` advertises 1920x1080 at 15 fps (`stream1`);
`profile_standard` advertises 640x360 at 10 fps (`stream2`). Both share one PTZ
state. The Kubernetes Service exposes RTSP port 554 to container port 8554.
Use RTSP over TCP for in-cluster streaming.

For a different simulated scene, mount an image directory read-only and set
`ONVIF_SIMULATOR_IMAGE_DIR` and `ONVIF_SIMULATOR_INITIAL_IMAGE`. Supply only images
you have permission to use. The camera username, password, and administrative
token are supplied through `ONVIF_SIMULATOR_CAMERA_USERNAME`,
`ONVIF_SIMULATOR_CAMERA_PASSWORD`, and `ONVIF_SIMULATOR_ADMIN_TOKEN`.
Do not expose the HTTP/RTSP simulator to an untrusted network.

## Authentication and movement behavior

HTTP SOAP and RTSP Digest use separate server nonces and replay state. Each
nonce expires after five minutes. Clients must use `qop=auth`, a nonempty
`cnonce`, and a positive eight-hex-digit `nc` that strictly increases for that
username/client nonce. Reused or lower counts, expired nonces, and legacy
Digest without `qop` are rejected. After expiry, obtain the new challenge.
Concurrent duplicates admit at most one request; a request that later fails
SOAP parsing still consumes its authenticated count.

Replay state is bounded to 1,024 client-nonce contexts per server nonce.
Existing records are not evicted to admit new clients; new contexts fail
closed until nonce expiry if the limit is reached. Clients must not send
lower-count requests after higher-count requests have already been accepted.

Replaying a previously accepted header with a changed SOAP body cannot issue a
second command. However, `qop=auth` does **not** authenticate the body itself;
this is not protection against tampering before the first accepted request.
RTSP Basic and the separate ONVIF UsernameToken path are not converted into
Digest. Use an isolated, trusted evaluation network; this simulator is not a
replacement for protected camera transport.

Selective `Stop` affects only the requested PanTilt and/or Zoom axes. Any axes
still moving retain the original remaining `ContinuousMove` timeout; a
Zoom-only Stop cannot make a timed pan run indefinitely.

## Customize the image

From the parent sample directory, use your own repository and a new version:

```bash
docker build --target test --tag aio-onvif-simulator-test ./simulator
docker build --platform linux/amd64 --tag YOUR_REGISTRY/azure-samples/onvif-simulator:0.1.1 ./simulator
docker push YOUR_REGISTRY/azure-samples/onvif-simulator:0.1.1
```

The test target includes protocol/state regressions, lint, formatting, and
strict source type checks. Official GHCR builds use the release workflow.

## Limits

This is a software camera, not an ONVIF-certified hardware product. PTZ state
uses an `emptyDir` volume in the tutorial and resets when its Pod is replaced.
Its device-side movement timeout and the caller's explicit `Stop` are both used.
The simulator does not establish physical travel limits, collision avoidance,
or safe behavior for a real motorized camera.

To use real equipment, follow the hardware replacement steps in the
[camera tutorial](../docs/camera-actions.md); do not reuse simulator credentials.
