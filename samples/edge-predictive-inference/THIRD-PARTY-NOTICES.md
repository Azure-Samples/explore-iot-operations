# Third-party notices

## YOLOX-Nano

The sample downloads the pretrained `yolox_nano.onnx` export from
[Megvii-BaseDetection/YOLOX release 0.1.1rc0](https://github.com/Megvii-BaseDetection/YOLOX/releases/tag/0.1.1rc0).
The upstream project uses **Apache-2.0**. Model preparation downloads and verifies
the upstream license and records model provenance. OCI publication includes
`LICENSE-YOLOX` and `provenance.json` alongside the unmodified model.

The weights are not embedded in this repository. Preserve their license and
provenance when redistributing them. The generic COCO model is an integration
baseline, not a qualified industrial, safety, identity, or PPE detector.
Use only authorized camera/video/image inputs; model availability does not grant
rights to third-party images or permission to monitor people.

Rust dependencies are recorded in `wasm/Cargo.lock`; retain applicable dependency
licenses when redistributing compiled artifacts.

## Diagram icons

The Foundry product icon comes from the
[Microsoft Azure architecture icon set](https://learn.microsoft.com/azure/architecture/icons/).
Use it to identify its actual Microsoft product, preserve its appearance, and
follow the linked permitted-use terms.

The camera, application, and database pictograms come from
[Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons).

```text
MIT License

Copyright (c) 2020 Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
