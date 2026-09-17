# Crab · iOS 容器

三端 WebView 容器（Android / iOS / HarmonyOS NEXT）的 iOS 那一份。应用名 `Crab`，中文「螃蟹」，
标识 `net.xiaoluzhu.crab`，三端同一个字符串。

**规划不在这里。** 要做什么、怎么算过、取值取什么，都在 `pro`
（`~/Desktop/github/Prospect`）的 README 与 `plan/` 五份里程碑文件。本仓只出实现、验收脚本与运行记录。

## 跑起来

```bash
brew install xcodegen         # 没装过才要
./scripts/verify.sh           # 生成工程 + 构建 + 装进模拟器 + 起一次 + 对齐取值
```

**clone 之后先 `xcodegen generate`。** 仓库里没有 `.xcodeproj`，它是生成物、不入库；
直接用 Xcode 打开这个目录会报「Failed to open a document」，那不是仓库坏了。
`verify.sh` 自己会先生成，所以从任何子目录调用都行。

卡住了看 [`docs/工程事实.md`](docs/工程事实.md)：工具链门槛、五条自检命令、报错速查表都在那里。

## 现在做到哪

M1「装到模拟器」已过：构建通过、装得上、屏幕上有一个原生页面，取值与 `pro` 的取值表逐项对齐。
**这一步不碰 WebView** —— 承载、注入、导航、降级分别是 M2 到 M4 的事。

- 本端任务与逐条结果：[`docs/M1-任务清单.md`](docs/M1-任务清单.md)
- 运行记录：[`docs/运行记录/`](docs/运行记录/)
- 探针页十六条断言的入口是 `scripts/probe.sh`，M2 起才有东西跑；现在跑它会明确告诉你一条也没实现

## 目录

| 路径 | 是什么 |
| --- | --- |
| `project.yml` | xcodegen 工程定义。工程结构改这个，不改 `.xcodeproj` |
| `App/` | 薄 SwiftUI 外壳。`App/Resources/zh-Hans.lproj` 是中文显示名 |
| `scripts/verify.sh` | 验证入口，AI 与 CI 都只调这个 |
| `scripts/probe.sh` | 探针页断言入口，三仓同名、输出形状三端一字不差 |
| `docs/` | 工程事实、每个里程碑的任务清单、运行记录 |

协作约定与三条纪律见 [`CLAUDE.md`](CLAUDE.md)。
