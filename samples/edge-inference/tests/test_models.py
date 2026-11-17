import tempfile
import unittest
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper, numpy_helper

from models.prepare import adapt_model


class ModelAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def make_model(self, rows=300):
        graph = helper.make_graph(
            [
                helper.make_node("ReduceMean", ["images"], ["mean"], axes=[1, 2, 3], keepdims=0),
                helper.make_node("Expand", ["mean", "shape"], ["output"]),
            ],
            "preprocessing-fixture",
            [helper.make_tensor_value_info("images", TensorProto.FLOAT, [1, 3, 640, 640])],
            [helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, rows, 6])],
            [numpy_helper.from_array(np.array([1, rows, 6], dtype=np.int64), "shape")],
        )
        model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)], ir_version=10)
        source = self.root / "source.onnx"
        onnx.save(model, source)
        return source

    def test_adaptation_preserves_predictions_under_foundry_normalization(self):
        source = self.make_model()
        target = self.root / "adapted.onnx"
        adapt_model(source, target)
        image = np.broadcast_to(
            np.array([0.2, 0.5, 0.8], dtype=np.float32).reshape(1, 3, 1, 1),
            (1, 3, 640, 640),
        ).copy()
        mean = np.array([0.485, 0.456, 0.406], dtype=np.float32).reshape(1, 3, 1, 1)
        std = np.array([0.229, 0.224, 0.225], dtype=np.float32).reshape(1, 3, 1, 1)
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        original = ort.InferenceSession(str(source), options, providers=["CPUExecutionProvider"])
        adapted = ort.InferenceSession(str(target), options, providers=["CPUExecutionProvider"])
        expected = original.run(None, {"images": image})[0]
        actual = adapted.run(None, {"foundry_image": (image - mean) / std})[0]
        np.testing.assert_allclose(actual, expected, rtol=1e-5, atol=1e-6)

    def test_incompatible_row_count_is_rejected_before_packaging(self):
        source = self.make_model(rows=100)
        with self.assertRaisesRegex(ValueError, r"\[1,300,6\]"):
            adapt_model(source, self.root / "adapted.onnx")
        self.assertFalse((self.root / "adapted.onnx").exists())


if __name__ == "__main__":
    unittest.main()
