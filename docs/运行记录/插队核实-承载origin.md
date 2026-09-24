# 运行记录 · 插队核实（承载 origin 形态 / `data:` iframe）

命令：`./scripts/spike-origin.sh` · 2026-09-17 23:39（iPhone 17 Pro，iOS 26.2 模拟器）
一次性验证代码在 `Spikes/OriginProbe/`，不是 M2 的承载实现。

## 判读（要回 `pro` 的就是这几条）

| 问题 | 答案 |
| --- | --- |
| 自定义 scheme 的 `location.origin` 是否 opaque | **不是**。两种形状都拿到可用的 tuple origin，不是 `null` |
| 带 host `crab://app/index.html` | `origin === "crab://app"`，形状规整 |
| 不带 host `crab:///index.html` | `origin === "crab://"`，host 为空，形状怪 |
| `isSecureContext` | 两种形状都 **`true`** |
| localStorage | 两种形状都能写能读回（`storage: "ok"`） |
| 相对路径子资源 | 两种形状都走到 `WKURLSchemeHandler`、加载成功（`subresource: "loaded"`） |
| `data:text/html` iframe | **加载得起来，脚本能执行**（它自己 `postMessage` 回来了），origin 为 `null`（opaque） |
| `sandbox="allow-scripts"` + `srcdoc` 退路 | 同样起得来，origin 也是 `null` —— iOS 上不需要用这条退路 |
| 命令行回读 App 日志（M4 关心） | **三条路都通**：落盘文件、`simctl launch --console-pty` 的 stdout、`simctl spawn log show --predicate 'subsystem == "net.xiaoluzhu.crab"'` |

两个子帧里 `typeof window.__CRAB__ === "undefined"`，是因为这次注入按 `forMainFrameOnly: true` 挂的，
**不构成「注入到不了子帧」的结论** —— 注入范围是 M3 的 `inject-scope`，那时再单独试。

没试的（别当成已知）：两种形状之间的 storage 是否互相隔离、跨会话是否留存、
`crab://` 空 host 形状在 `WKWebsiteDataStore` 带 identifier 时的行为。

选形状的倾向：**带 host**。`crab://app` 是规整的 scheme+host 二元组，和后面要拼的 UA、
要判的同源导航、要落的 storage 分区都对得上；`crab://` 这种空 host 的 origin 形状，
三端对账时更容易各家理解不一致。定不定由 `pro` 的 M2 拍。

## 补测 · 2026-09-24：第三种形状 `crab://ios.crab.invalid`

`pro` 选型时加了第三个候选：host 带点、与另两端的 `and.crab.invalid` / `hm.crab.invalid` 对齐。
`Spikes/OriginProbe` 加了这一组，并加了 `storageMarks`：每种形状写一个 `mark:<host>` 再列出看得见的
全部 `mark:*`。命令同上，iPhone 17 Pro · iOS 26.2 模拟器。

| 问题 | `crab://ios.crab.invalid/index.html` |
| --- | --- |
| `location.origin` | `crab://ios.crab.invalid`，tuple，不是 `null` |
| `isSecureContext` | `true` |
| localStorage | 能写能读回 |
| 相对路径子资源 | 走到 `WKURLSchemeHandler`、加载成功 |
| 注入 | `injected: 1`，`injectedOrigin` 与 `location.origin` 一致 |
| 两个 opaque 子帧 | 与另两种形状相同：起得来、`origin` 为 `null`、没有 `__CRAB__` |
| **storage 分不分区** | **按 host 分。** 三种形状同一进程、同一个默认 data store，各自只看得见自己的标记（`mark:app` / `mark:(empty)` / `mark:ios.crab.invalid`）。OSLog 里有两轮启动，第二轮时第一轮的标记还在 store 里，仍然只看得见自己的 |

**`pro` 已拍板取这一种**，理由与被否的方案都记在 `pro` 的 M2「备案 · iOS 承载 origin 选型」。

仍然没试的：跨会话留存（这次每种形状每轮都重写自己的标记，证明不了留存）、带 identifier 的
`WKWebsiteDataStore` 下的行为（M3 的事）。

原始输出（落盘文件，判据取这一条；console 与 OSLog 两条路内容一致，这次也都取回来了）：

```
# 插队核实 · 承载 origin 形态
# 2026-09-24T09:06:04Z

with-host crab://app/index.html
{"origin":"crab://app","href":"crab://app/index.html","baseURI":"crab://app/index.html","isSecureContext":true,"storage":"ok","storageMarks":["mark:app"],"subresource":"loaded","injected":1,"injectedOrigin":"crab://app","frames":{"srcdoc":{"from":"srcdoc","crab":"undefined","origin":"null"},"data":{"from":"data","crab":"undefined","origin":"null"}}}

no-host crab:///index.html
{"origin":"crab://","href":"crab:///index.html","baseURI":"crab:///index.html","isSecureContext":true,"storage":"ok","storageMarks":["mark:(empty)"],"subresource":"loaded","injected":1,"injectedOrigin":"crab://","frames":{"srcdoc":{"from":"srcdoc","crab":"undefined","origin":"null"},"data":{"from":"data","crab":"undefined","origin":"null"}}}

dotted-host crab://ios.crab.invalid/index.html
{"origin":"crab://ios.crab.invalid","href":"crab://ios.crab.invalid/index.html","baseURI":"crab://ios.crab.invalid/index.html","isSecureContext":true,"storage":"ok","storageMarks":["mark:ios.crab.invalid"],"subresource":"loaded","injected":1,"injectedOrigin":"crab://ios.crab.invalid","frames":{"srcdoc":{"from":"srcdoc","crab":"undefined","origin":"null"},"data":{"from":"data","crab":"undefined","origin":"null"}}}
```

## 原始输出（2026-09-17 那一遍）

### ① 落盘文件（判据取这一条）

```
# 插队核实 · 承载 origin 形态
# 2026-09-17T15:39:53Z

with-host crab://app/index.html
{"origin":"crab://app","href":"crab://app/index.html","baseURI":"crab://app/index.html","isSecureContext":true,"storage":"ok","subresource":"loaded","injected":1,"injectedOrigin":"crab://app","frames":{"srcdoc":{"from":"srcdoc","crab":"undefined","origin":"null"},"data":{"from":"data","crab":"undefined","origin":"null"}}}

no-host crab:///index.html
{"origin":"crab://","href":"crab:///index.html","baseURI":"crab:///index.html","isSecureContext":true,"storage":"ok","subresource":"loaded","injected":1,"injectedOrigin":"crab://","frames":{"srcdoc":{"from":"srcdoc","crab":"undefined","origin":"null"},"data":{"from":"data","crab":"undefined","origin":"null"}}}
```

### ② console（`simctl launch --console-pty`）

```
CRAB-SPIKE no-host {"origin":"crab://","href":"crab:///index.html",...}
CRAB-SPIKE with-host {"origin":"crab://app","href":"crab://app/index.html",...}
CRAB-SPIKE no-host {...}      # 第二次收，给子帧留回话时间
CRAB-SPIKE with-host {...}
```

### ③ OSLog（`simctl spawn <device> log show --predicate 'subsystem == "net.xiaoluzhu.crab"'`）

```
2026-09-17 23:39:51.797 Df Crab[61213:9036e] [net.xiaoluzhu.crab:spike] CRAB-SPIKE no-host {...}
2026-09-17 23:39:51.799 Df Crab[61213:9036e] [net.xiaoluzhu.crab:spike] CRAB-SPIKE with-host {...}
2026-09-17 23:39:53.437 Df Crab[61213:9036e] [net.xiaoluzhu.crab:spike] CRAB-SPIKE no-host {...}
2026-09-17 23:39:53.440 Df Crab[61213:9036e] [net.xiaoluzhu.crab:spike] CRAB-SPIKE with-host {...}
```

`Logger` 那条要 `privacy: .public` 才看得到内容，否则回读到的是 `<private>`。

### 截屏

`.probe/spike-origin.png`（不入库）：两个 WebView 各显示 `origin probe`，
下方文本区把两条结果都打出来，和落盘文件一致。

## 工程事实（本仓自留）

- `WKWebViewConfiguration` 在 `WKWebView(frame:configuration:)` 时被拷贝，
  所以 `setURLSchemeHandler` 与 `addUserScript` 必须在创建实例之前挂完 —— 实测顺序错了就不生效
- 子帧的 `postMessage` 是异步的：`didFinish` 里只收一次会拿到空的 `frames`。
  这次收两次（400ms / 2s），两次都进落盘文件
- `simctl launch --console-pty` 会跟着进程不退出，脚本里必须后台跑 + 定时收摊
