import os, shutil, subprocess, time
import numpy as np, torch, torch.nn as nn
import coremltools as ct
import coremltools.optimize.coreml as cto

# 产物目录：默认写当前目录，run.sh 会把 cwd 设成 mktemp 目录。**模型产物不入库。**
WORK = os.environ.get("CTWORK", os.getcwd())
os.makedirs(WORK, exist_ok=True)

W = 2048
DEPTH = 6          # ~ 6 * 2048^2 = 25.2M params


class Stack(nn.Module):
    def __init__(self):
        super().__init__()
        self.layers = nn.ModuleList([nn.Linear(W, W) for _ in range(DEPTH)])

    def forward(self, x):
        for l in self.layers:
            x = torch.relu(l(x))
        return x


def du(path):
    out = subprocess.run(["du", "-sk", path], capture_output=True, text=True).stdout
    return int(out.split()[0]) / 1024.0     # MiB


m = Stack().eval()
n_params = sum(p.numel() for p in m.parameters())
print(f"params = {n_params/1e6:.1f}M  (fp32 = {n_params*4/2**20:.0f} MiB)")

traced = torch.jit.trace(m, torch.rand(1, W))
base = ct.convert(traced, inputs=[ct.TensorType(name="x", shape=(1, W))],
                  convert_to="mlprogram",
                  minimum_deployment_target=ct.target.iOS18,
                  compute_precision=ct.precision.FLOAT16)
base.save(f"{WORK}/base.mlpackage")
print(f"fp16 mlpackage            = {du(f'{WORK}/base.mlpackage'):7.1f} MiB")

variants = {}

cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
    mode="linear_symmetric", dtype="int8", granularity="per_channel"))
variants["int8 per_channel"] = cto.linear_quantize_weights(base, cfg)

cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
    mode="linear_symmetric", dtype="int4", granularity="per_block", block_size=32))
variants["int4 per_block(32)"] = cto.linear_quantize_weights(base, cfg)

for nbits in (6, 4, 3, 2):
    cfg = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(
        nbits=nbits, mode="kmeans",
        granularity="per_grouped_channel", group_size=16))
    variants[f"palettize {nbits}bit group16"] = cto.palettize_weights(base, cfg)

cfg = cto.OptimizationConfig(global_config=cto.OpMagnitudePrunerConfig(target_sparsity=0.5))
variants["prune 50%"] = cto.prune_weights(base, cfg)

for name, mdl in variants.items():
    p = f"{WORK}/v.mlpackage"
    shutil.rmtree(p, ignore_errors=True)
    mdl.save(p)
    print(f"{name:26s} = {du(p):7.1f} MiB")

# ---- mlpackage -> mlmodelc 编译耗时（宿主 macOS，非设备） ----
shutil.rmtree(f"{WORK}/out", ignore_errors=True)
os.makedirs(f"{WORK}/out", exist_ok=True)
t0 = time.time()
r = subprocess.run(["xcrun", "coremlcompiler", "compile",
                    f"{WORK}/base.mlpackage", f"{WORK}/out"],
                   capture_output=True, text=True)
t1 = time.time()
print("coremlcompiler rc =", r.returncode, r.stderr[:200])
print(f"compile time (host M4) = {t1-t0:.2f}s -> "
      f"{du(f'{WORK}/out/base.mlmodelc'):.1f} MiB .mlmodelc")
