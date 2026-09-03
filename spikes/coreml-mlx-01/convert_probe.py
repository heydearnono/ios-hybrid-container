import os
import sys
import numpy as np
import torch
import torch.nn as nn
import coremltools as ct

# 产物目录：默认写当前目录，run.sh 会把 cwd 设成 mktemp 目录。**模型产物不入库。**
WORK = os.environ.get("CTWORK", os.getcwd())
os.makedirs(WORK, exist_ok=True)

print("torch", torch.__version__, "| coremltools", ct.__version__)

# ---------- 1. 最小可用转换：trace -> mlprogram ----------
class Tiny(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(64, 256)
        self.fc2 = nn.Linear(256, 10)

    def forward(self, x):
        return self.fc2(torch.relu(self.fc1(x)))

m = Tiny().eval()
example = torch.rand(1, 64)
traced = torch.jit.trace(m, example)

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="x", shape=(1, 64), dtype=np.float16)],
    outputs=[ct.TensorType(name="logits", dtype=np.float16)],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS18,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.save(f"{WORK}/tiny.mlpackage")
print("[1] OK trace->mlprogram, saved tiny.mlpackage")

# ---------- 2. torch.export 前端 ----------
try:
    ep = torch.export.export(m, (example,))
    mlmodel_ep = ct.convert(ep, minimum_deployment_target=ct.target.iOS18)
    print("[2a] OK torch.export frontend, inputs inferred:",
          [i.name for i in mlmodel_ep.get_spec().description.input])
except Exception as e:
    print("[2a] FAIL torch.export raw:", type(e).__name__, str(e)[:300])
try:
    ep2 = torch.export.export(m, (example,)).run_decompositions({})
    mlmodel_ep2 = ct.convert(ep2, minimum_deployment_target=ct.target.iOS18)
    print("[2b] OK torch.export + run_decompositions, inputs inferred:",
          [i.name for i in mlmodel_ep2.get_spec().description.input])
except Exception as e:
    print("[2b] FAIL torch.export + run_decompositions:", type(e).__name__, str(e)[:300])

# ---------- 3. 数据相关控制流：trace 会静默烧死分支 ----------
class Branchy(nn.Module):
    def forward(self, x):
        if x.sum() > 0:          # 数据相关分支
            return x * 2
        return x - 100

b = Branchy().eval()
tb = torch.jit.trace(b, torch.ones(1, 4))     # 走 then 分支
ml_b = ct.convert(tb, inputs=[ct.TensorType(name="x", shape=(1, 4))],
                  minimum_deployment_target=ct.target.iOS18)
neg = ml_b.predict({"x": -np.ones((1, 4), np.float32)})
print("[3] traced branch on input -1: torch =", b(-torch.ones(1, 4)).flatten().tolist(),
      "| coreml =", list(neg.values())[0].flatten().tolist())

# ---------- 4. 不支持的算子 ----------
class Weird(nn.Module):
    def forward(self, x):
        return torch.linalg.matrix_exp(x)

w = Weird().eval()
try:
    tw = torch.jit.trace(w, torch.rand(4, 4))
    ct.convert(tw, inputs=[ct.TensorType(shape=(4, 4))],
               minimum_deployment_target=ct.target.iOS18)
    print("[4] matrix_exp converted (unexpected)")
except Exception as e:
    print("[4] unsupported op ->", type(e).__name__, ":", str(e)[:300])

# ---------- 5. 灵活输入：RangeDim 不封顶 ----------
try:
    tr = torch.jit.trace(m, example)
    ct.convert(tr, inputs=[ct.TensorType(shape=(ct.RangeDim(1, -1), 64))],
               convert_to="mlprogram",
               minimum_deployment_target=ct.target.iOS18)
    print("[5] unbounded RangeDim accepted for mlprogram")
except Exception as e:
    print("[5] unbounded RangeDim ->", type(e).__name__, ":", str(e)[:300])

# ---------- 6. EnumeratedShapes ----------
try:
    ml_enum = ct.convert(
        torch.jit.trace(m, example),
        inputs=[ct.TensorType(shape=ct.EnumeratedShapes(shapes=[(1, 64), (4, 64)],
                                                        default=(1, 64)))],
        convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18)
    print("[6] OK EnumeratedShapes")
except Exception as e:
    print("[6] EnumeratedShapes ->", type(e).__name__, ":", str(e)[:300])

# ---------- 7. 有状态模型 StateType ----------
class Acc(nn.Module):
    def __init__(self):
        super().__init__()
        self.register_buffer("acc", torch.zeros(4))

    def forward(self, x):
        self.acc.add_(x)
        return self.acc * 1.0

a = Acc().eval()
try:
    ta = torch.jit.trace(a, torch.ones(4))
    ml_s = ct.convert(
        ta,
        inputs=[ct.TensorType(name="x", shape=(4,))],
        outputs=[ct.TensorType(name="y")],
        states=[ct.StateType(wrapped_type=ct.TensorType(shape=(4,)), name="acc")],
        minimum_deployment_target=ct.target.iOS18,
    )
    ml_s.save(f"{WORK}/stateful.mlpackage")
    st = ml_s.make_state()
    r1 = ml_s.predict({"x": np.ones(4, np.float32)}, state=st)
    r2 = ml_s.predict({"x": np.ones(4, np.float32)}, state=st)
    print("[7] OK StateType: 1st=", list(r1.values())[0].tolist(),
          "2nd=", list(r2.values())[0].tolist())
except Exception as e:
    print("[7] StateType ->", type(e).__name__, ":", str(e)[:400])

# ---------- 8. iOS26 target ----------
try:
    ml26 = ct.convert(torch.jit.trace(m, example),
                      inputs=[ct.TensorType(shape=(1, 64))],
                      minimum_deployment_target=ct.target.iOS26)
    print("[8] OK ct.target.iOS26, spec version =", ml26.get_spec().specificationVersion)
except Exception as e:
    print("[8] iOS26 ->", type(e).__name__, ":", str(e)[:300])
