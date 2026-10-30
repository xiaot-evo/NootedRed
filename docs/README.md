# 文档索引

文档分两类：**介绍与使用**（本目录）给使用者和贡献者；**研究记录**放在仓库根目录的 `research/`
（本地保留，不进 git），记录设计取舍、验证证据和已被取代的方案。

## 介绍与使用

| 文档 | 内容 |
| --- | --- |
| [INSTALLATION.md](INSTALLATION.md) | 安装两个 kext、注入 profile、boot-args、验证、回滚、常见现象 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 三个组件的边界、profile 数据流、页面身份、不变量、非目标 |
| [COMPATIBILITY.md](COMPATIBILITY.md) | 状态词表、逐 build / 逐 APU 矩阵、新增 build 的流程、已知问题 |
| [MODULES-AND-SUPPORT.md](MODULES-AND-SUPPORT.md) | 模块职责与禁区、DeviceProfile 硬件档位、启动顺序、全部启动参数 |
| [Build-Artifacts.md](Build-Artifacts.md) | 按分支隔离的构建产物布局，以及为什么卫星产物是同级目录 |
| [VDA-TESTING.md](VDA-TESTING.md) | 硬解/硬编的真机验证流程、期望日志、失败处理 |
| [FIREFOX-HW-DECODE.md](FIREFOX-HW-DECODE.md) | Firefox/Zen 硬解启动器与 prefs |
| [PatchProfile-Spec.md](PatchProfile-Spec.md) | NRPT v3 profile 的规范（英文）：格式、选择器、匹配算法、错误码 |

代码邻近的文档不搬进 `docs/`，就近维护：

| 文档 | 内容 |
| --- | --- |
| [`NootedRedUserPatch/README.md`](../NootedRedUserPatch/README.md) | 卫星的运行模型、bundle 键、诊断属性（与代码最接近的一份） |
| [`NootedRedTool/README.md`](../NootedRedTool/README.md) | 工具 GUI/CLI 用法与已知缺口 |
| [`NootedRedTool/Docs/PatchAnalyzer.md`](../NootedRedTool/Docs/PatchAnalyzer.md) | 13 条语义规则与 profile 生成器内部结构 |
| [`test/README.md`](../test/README.md) | 校验器、注入器与 golden 测试的用法 |
| [`tools/README.md`](../tools/README.md) | 工具索引（采集、诊断、VDA、生成） |
| [`PatchData/README.md`](../PatchData/README.md) | 旧数据面（已停用）的来源与再生成方式 |

## 研究记录

`research/` 不进版本库，用 `research/README.md` 做索引。内容包括：profile 引擎的验证证据、卫星
拆分决策与失败史、被取代的格式与方案（NRPD v1、offset 身份、root patch）。想查某段历史设计
为什么被放弃，先看那里的 `legacy/`。
