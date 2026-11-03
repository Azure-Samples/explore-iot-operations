# ONVIF camera simulator

This component supplies the optional simulated camera for the
[MCP assistant tutorial](../docs/camera-actions.md). It implements ONVIF device,
media, and PTZ services, HTTP snapshots, and H.264 RTSP streams. A bounded pan
changes the crop of a static panorama and its reported PTZ position; it does not
move physical equipment.

The image build generates a clearly labeled synthetic calibration scene. There
are no real people, camera recordings, or vision-model results in this scene.
The AIO ONVIF connector and the MQTT command/response path are real components.

## Build and use

From the parent sample directory:

```bash
docker build --target test --tag aio-onvif-simulator-test ./simulator
docker build --tag YOUR_REGISTRY/azure-samples/onvif-simulator:0.1.0 ./simulator
docker push YOUR_REGISTRY/azure-samples/onvif-simulator:0.1.0
```

Follow the [camera setup](../docs/camera-actions.md) to create the Kubernetes
workload, register its Device and control Asset, and use the assistant's
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

## Limits

This is a software camera, not an ONVIF-certified hardware product. PTZ state
uses an `emptyDir` volume in the tutorial and resets when its Pod is replaced.
Its device-side movement timeout and the caller's explicit `Stop` are both used.
The simulator does not establish physical travel limits, collision avoidance,
or safe behavior for a real motorized camera.

To use real equipment, follow the hardware replacement steps in the
[camera tutorial](../docs/camera-actions.md); do not reuse simulator credentials.
