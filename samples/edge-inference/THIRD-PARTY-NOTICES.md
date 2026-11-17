# Third-party notices

The sample code is covered by this repository's license. **Downloaded models and
media have separate terms.** They are not included in the repository, and this
sample does not relicense them. Review the upstream terms and your intended use
before downloading, deploying, modifying, distributing, or offering a service
using them.

## PCB quality model

| Item | Source |
| --- | --- |
| Model | [betty0/pcb-defect-detection](https://huggingface.co/betty0/pcb-defect-detection) |
| Revision | `08f7ff096054f6ad3e1f37dfdf5cfc63d04dabaa` |
| File | `best.onnx` |
| SHA-256 | `057c61dbd2745f59bd246effebf47a31686e95b0e2263610b0600664e5210fc5` |
| Upstream license declaration | AGPL-3.0 for code and trained weights |
| Training/source project | [tun0000/pcb-defect-detection](https://github.com/tun0000/pcb-defect-detection) |

This is a community YOLO26 end-to-end detector, not an official Microsoft model.
It predicts `missing_hole`, `mouse_bite`, `open_circuit`, `short`, `spur`, and
`spurious_copper`. The model card describes training on HRIPCB/PKU-Market-PCB,
synthetically introduced defects, few template boards, and limited generalization.
It is an evaluation baseline, not a qualified production inspection system.

The model's license declaration does not establish commercial rights to its
training data. The commonly used Kaggle mirror of HRIPCB lists its data license
as **Unknown**. [DeepPCB](https://github.com/tangsanli5201/DeepPCB) explicitly
restricts its dataset to research use. This sample therefore does **not** download
or redistribute PCB dataset images. Supply a photograph or frame you are
authorized to use, and review training-data provenance before commercial adoption.
Do not interpret downloadable weights as commercial clearance.

## Equipment-area model

| Item | Source |
| --- | --- |
| Model | [onnx-community/yolov10n](https://huggingface.co/onnx-community/yolov10n) |
| Revision | `57657320425ee34056408a57ad9d29c4d4815bd8` |
| File | `onnx/model.onnx` |
| SHA-256 | `a77dd863933f184a19e84361c64b788228a7c7dacc2c78939239a96ad3efca3b` |
| Upstream license declaration | AGPL-3.0 |
| Original project | [THU-MIG/yolov10](https://github.com/THU-MIG/yolov10) |

This is a community ONNX conversion of YOLOv10n with COCO labels. The sample uses
the `person` class, not identity, face recognition, demographics, PPE compliance,
or health classification. Dataset and individual source-image terms are not
automatically replaced by the model's license.

## Model modifications and distribution

`models/prepare.py` downloads immutable revisions and verifies checksums. It
adds two ONNX operations that undo the documented Foundry Local ImageNet
normalization, and gives the existing detection output the name `detections`.
It does not train, fine-tune, or change the detection classes.

Each generated archive includes the adapted ONNX file, `id2label` configuration,
upstream AGPL license text, source/provenance information, and the modification
script. Keep these files with the model. They do not replace any obligations to
provide corresponding source or notices under the applicable licenses. Review
AGPL requirements, including network-service and modified-work obligations, with
your organization; do not assume that a model served behind an API is exempt.

## Factory replay photograph

- **Title:** Employees working at Edison Price Lighting
- **Author:** Mizzvizz9
- **Source:** [Wikimedia Commons file page](https://commons.wikimedia.org/wiki/File:Employees_working_at_Edison_Price_Lighting.jpg)
- **Original file:** [JPEG](https://upload.wikimedia.org/wikipedia/commons/5/5c/Employees_working_at_Edison_Price_Lighting.jpg)
- **License:** [Creative Commons Attribution-ShareAlike 3.0](https://creativecommons.org/licenses/by-sa/3.0/)
- **Original SHA-256:** `fbda4b9ab58d03e13885f66f807a21795edb7a8d845179abd3b3af97b750c234`
- **Sample modifications:** RGB conversion, resizing and gray padding to 640 x 640,
  JPEG re-encoding, and looping as an RTSP stream.

Retain this attribution, the source and license links, and a description of
modifications when sharing the replay image or derived media. Share-alike
conditions apply to adaptations. The photograph documents a real workplace:
neither the author nor the people shown endorse this sample. A configured image
region is a software demonstration, not an assertion that anyone in the
photograph behaved unsafely.

For live cameras, obtain appropriate permission, minimize collection, restrict
access to imagery and observations, and set an appropriate retention period.

## Diagram icons

The architecture SVG includes Microsoft Azure IoT Operations and Foundry product
icons from the [Azure architecture icon set](https://learn.microsoft.com/azure/architecture/icons/).
Microsoft permits their use in architectural diagrams, training materials, and
documentation; all other rights are reserved. The icons identify the Microsoft
components, not this sample as a separate product. Keep their shapes, colors, and
proportions unchanged.

The camera, application, and database pictograms come from
[Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons).
Their license is reproduced below:

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

## Other dependencies

The observer uses Eclipse Paho MQTT (EPL-2.0 / EDL-1.0). Model preparation uses
NumPy (BSD-3-Clause), ONNX (Apache-2.0), ONNX Runtime (MIT), and Pillow
(HPND-style license). Replay uses MediaMTX (MIT) and its FFmpeg-enabled image;
FFmpeg and bundled codecs have their own LGPL/GPL and potentially patent-related
conditions. Container base images also contain separately licensed software.
Consult the exact versions' upstream license files and image inventories.

Configuration rendering uses jsonschema (MIT). Development checks additionally
use PyYAML (MIT) and Ruff (MIT). These tools are not included in the observer image.
