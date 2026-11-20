# 代码风格与改动准则

面向在本仓库工作的 AI Agent。`AGENTS.md` 是硬性运行约束；本文件只回答两件事：代码怎么写、
改动怎么落。优先级：`AGENTS.md` > 本文件与 `docs/` 设计文档 > 周边代码。发现文档与代码冲突时
不要静默选一边，在同一改动里修正文档或代码。

## 1. 总原则

> 用最少的新代码，在正确的一层，完成一件可验证的事；失败时保持原状。

六条要求的判定标准：

| 要求 | 做到 | 不做 |
| --- | --- | --- |
| 简单清晰 | 线性流程、早返回、一个函数一件事、名字自解释 | 通用框架、回调套回调、为一行逻辑建类 |
| 模块化 | 一个文件一个关注点、窄接口、依赖单向 | 循环依赖、跨层直接访问、适配器里写策略 |
| 改动面少 | 改现有 owner、最小 diff、一次一个逻辑变更 | 顺手重构、重命名无关符号、格式化整文件 |
| 稳定 | 原路径优先、精确匹配、幂等、边界检查、失败关闭 | 猜测性 fallback、部分写入、新增 panic |
| 拓扑简单 | 固定启动顺序、一次解析一次发布、复用现有线程/缓存 | 新线程、新队列、新状态机、隐藏重试 |
| 不冗余 | 每个字段/参数/开关都有当前使用者 | 为未来预留的抽象、第二套机制、重复数据表 |

**升级信号**：如果实现需要新增模块、线程、配置项或数据表，先停下来写清理由；如果只需在现有
owner 里加一个分支，就做那个分支。能用一句话说清的改动，不要拆成三个抽象。

**DRY 让位于不变量**：重复不总是坏。`SiteSet::apply` 的扫描/写入/回读分成三段，是为了保证
“单个写入窗口 + 写后回读”；不要为了去重把它们合并成一个带跨阶段状态的循环。

## 2. 模块边界与拓扑

```
NootedRed/                     主 kext：Lilu/内核依赖，只做内核侧补丁与桥接
NootedRedUserPatch/
  Analyzer/                    纯 C++23、freestanding；host 与内核共用
  AnalyzerRuntime.cpp          线程、VFS、文件缓存等内核适配
  KernelFileSource.cpp         vnode -> ByteSource 适配
  SiteSet.cpp                  解析结果的只读发布与写入策略
  ValidationHook.cpp           _cs_validate_page 路由与写锁
test/                          主机测试；直接编译真实 Analyzer/SiteSet
```

依赖方向固定：

```
Plugin -> AnalyzerRuntime / ValidationHook -> Analyzer core
                  |                                |
                  +------ KernelFileSource --------+
```

- `Analyzer/` 不得包含 Lilu 或内核头文件。需要 vnode、IORegistry、分配、睡眠或 Lilu 的代码，
  放到适配层。
- 适配层只做适配；补丁策略放在 `RuleTable.cpp`、`RuleResolver.cpp`、`SiteSet.cpp`。
- 一个文件一个关注点。新文件只在出现新关注点时创建；不要建 `Utils.hpp`、`Helpers.cpp` 这类
  杂物间。
- Core 与外界的交互用注入的函数指针（`ByteSource::ReadFn`、`OpenImageFn`、
  `SiteSet::WriteBeginFn`）。host 测试替换回调，不改 core。
- 单例只给启动期有唯一 owner 的模块（`NRed`、`VCNBridge`、`SiteSet`、`ValidationHook`、
  `AnalyzerRuntime`）。无状态函数放命名空间的自由函数里，不要包一层单例。
- 共享状态“发布后只读”：一次写、acquire/release 原子发布；hook 里不引入新的锁。

**放置决策**：

```
需要 Lilu/kernel/vnode/IORegistry? -> 适配层（主 kext 或卫星 runtime）
能只用 C++23 + 标准 C 头在 host 编译? -> Analyzer core
只是规则数据? -> RuleTable
只是验证? -> test/
```

## 3. 命名

| 对象 | 规则 | 现有例子 |
| --- | --- | --- |
| 类型、类、结构、枚举 | PascalCase | `SiteSet`, `ResolvedSite`, `RuleVariant` |
| 枚举值 | `k` + PascalCase，用 `enum class` | `ImageKind::kSharedCache`, `ApuFamily::kRenoir` |
| 函数、方法 | camelCase，动词开头 | `resolveRule`, `findOrOpen`, `siteFitsChunk` |
| 局部变量、参数 | camelCase | `deviceID`, `vnodeName`, `textBase` |
| 常量 | `k` + PascalCase | `kMaxSites`, `kBlockSize`, `kFamilyVCN2` |
| 公开结构字段 | camelCase | `fileOffset`, `ruleId`, `variantCount` |
| 卫星 private 成员 | camelCase + `_` | `sites_`, `installed_`, `blockOffset_` |
| 主 kext 成员 | camelCase，跟随现有文件 | `rmmioPtr`, `engineAllocated` |

- 布尔量用 `is` / `has` / `should` / 状态词：`isRenoir()`、`hasExternalVideo()`、`ready()`、
  `requested`。不要用 `flag`、`enable` 这类含糊名字。
- 缩写只用仓库已确立的：`ID`、`VCN`、`VDA`、`GPU`、`RMMIO`、`MachO`、`vnode`。同一概念不要
  混用 `deviceId` / `deviceID`。
- 内核侧用 `UInt8`…`UInt64`、`mach_vm_address_t`；freestanding core 用 `uint8_t`…`uint64_t`、
  `size_t`。不要在一个层里混用两套类型。
- 用 `using X = ...`，不用 `typedef`；业务代码不引入运算符重载或新的模板元编程。

## 4. 格式

格式以仓库根目录 `.clang-format`（ChefKiss Coding Style v2.1）为准：120 列、4 空格、指针/引用
靠左、`const` 靠左、自动插入花括号。

- 命名空间、类型、函数的左花括号另起一行；`if`/`for`/`while` 的花括号跟在语句后；`else` 另起
  一行。
- 单行短函数、短分支允许写成一行，例如 `if (x == nullptr) { return false; }`；不要为了“好看”
  把已有单行拆开。
- `#pragma once` 是唯一头文件保护，后面紧跟 include，不留空行。
- 卫星 `.cpp` 的 include 顺序：自身头文件、空行、项目头文件、空行、C/系统头文件。主 kext 旧文件
  保持现有平铺块，不重排。
- 新代码用 trailing return：`auto f() -> T`，`void` 也写成 `-> void`。不要批量改写旧函数的
  写法。
- 成员一律默认初始化（`{nullptr}`、`{0}`、`{}`）；用 `nullptr`，不用 `NULL` 或 `0`。
- 不用 STL、异常、RTTI。容器用固定数组 + 计数（`sites_[kMaxSites]`、`count_`）；规模由常量
  界定。
- 常量用 `static constexpr` 或 `inline auto`，不用宏。宏只保留给位域/ABI 兼容和现有
  PenguinWizardry 设施。
- **不要对已有文件运行 `clang-format -i`**（本地 v23.x 会整体重排）。新文件可以格式化；改旧
  文件时手工匹配周边格式。

一个符合本仓库风格的例子（`RuleResolver.cpp`）：

```cpp
auto ruleEnabled(const Rule& rule, const uint32_t runningFamily, const bool vdaEnabled) -> bool
{
    if ((rule.familyMask & runningFamily) == 0U) { return false; }
    if ((rule.flags & kRuleFlagVDA) != 0U && !vdaEnabled) { return false; }
    return true;
}
```

反例：为一个布尔判断引入策略对象、配置项或动态分配；或为了“复用”把三种失败路径塞进一个带
`switch` 的通用函数。规模只有 19 条规则时，线性扫描比哈希表更符合“简单”。

## 5. 注释与文件头

每个源文件第一行是模块标题，随后是完整的 ChefKiss 许可证头。沿用该文件现有年份；新文件用当前
年份。保留原文，不添加 AI/assistant 署名。

```cpp
// NootedRedUserPatch rule resolver
//
// Copyright (C) 2026  ChefKiss.
// ...（按现有文件逐行复制，不要改写）
```

- 源码注释用英文，与现有代码一致；`docs/` 面向人的文档可以用中文。
- 注释解释“为什么/约束/契约”，不重复代码在做什么。重点写：所有权、边界、空指针、线程上下文、
  失败语义。
- 接口注释放在头文件声明处；实现里只注释不明显的算法或不变量。参考 `MachO.hpp`、
  `ByteSource.hpp`、`SiteSet.hpp`。
- 不提交注释掉的代码、“以前是……”的历史说明、调试打印。历史放 commit 或 `CHANGELOG.md`。
- 新 `TODO` 必须写清移除条件；现有 `// TODO: Remove!` 是上游清理计划的一部分，保留。
- 文档注释不要写“处理一下”这类模糊描述；写具体条件与结果。

## 6. 错误处理与不变量

- 返回 `bool`，失败原因通过 `const char** reason` 返回静态字符串；不抛异常、不分配。
- **失败关闭**：门控不通过、符号缺失、形状未知、字节不匹配时，跳过该规则/该 site，保持原行为。
  未知形状只影响该规则，不拖垮其他规则。
- 校验顺序固定：门控 → 空指针/尺寸/溢出 → 内容匹配 → 写入。
- 边界用减法形式，避免加法溢出：参考 `PatchPolicy::siteFitsChunk`。
- 写入必须完整：`find`/`replace` 的整个区间都在交付 chunk 内才写；绝不部分写入。
- 写入后回读校验；已 `replace` 的跳过，陌生字节不碰；site 独立且幂等。
- 每条退出路径释放资源：Lilu `DeviceInfo` 用 guard 对象，vnode 显式 `close()`。
- 卫星和 hook 不新增 panic。主 kext 只对启动期不可能状态用 `PANIC_COND`（例如 RMMIO 映射
  失败）。
- 外部输入一律当作不可信：Mach-O 计数、路径、chunk 偏移都要有上限和 `ByteSource` 边界检查。

## 7. 日志

- 标签用模块名：`"NRed"`、`"VCN"`、`"HWLibs"`、`"UserPatch"`、`"GFX9DCNDisplay"`。
- `SYSLOG` 记录状态变化和最终摘要；`DBGLOG` 记录细节。卫星同时 `IOLog`，因为早期启动时
  Lilu 日志文件可能还不可用。
- 一行一个事实：规则号、镜像名、偏移、结果。不要写叙事句。
- hook/热路径必须有日志预算（`takeLogBudget()`）；禁止每页、每 site 无条件刷日志。
- 诊断优先用日志；IORegistry 属性只作为人读输出，不作为模块间通道（`NRedVCNBridgeReady` 是
  边界例子：卫星已不读它）。
- 失败路径至少留一条可定位的静态原因；不要把失败静默掉。

## 8. 内核与热路径硬约束

这些是正确性约束，不是风格偏好；完整背景见 `AGENTS.md` 和
`docs/USERSPACE-PATCHING.md`。

- hook 内禁止：分配、睡眠、文件 I/O、IORegistry、vnode/pager 引用。只做已解析名字匹配、
  边界检查、`memcmp`、写入。
- VFS/namei 只在 analyzer 内核线程里做；patcher-load 不做 VFS，`thread_call` 不做 VFS。第一次
  dyld cache 校验只置一次 trigger。
- 原校验器永远先跑且结果不变；只考虑它接受的页。
- 每个 chunk 一个 `setKernelWriting` 窗口，随后回读。
- 不保存页级状态；页被回收后下次校验重新命中并重写。
- `KernelFileSource` 的 16 KiB 块缓存必须保留跨块回退到 `FileIO::readFileData`；改 reader 必须
  跑 `test_block_reader.py`。
- freestanding core 保持 freestanding；内核类型、Lilu、vnode 只出现在适配层。
- 内核里的 function-local static 只用可常量初始化、可平凡销毁的类型；需要资源的对象显式
  `open`/`close`（`KernelFile` 的析构注释说明了原因）。
- 不引入 per-process 补丁通道、进程扫描/watchdog、主动 page-in/image completion。

## 9. 测试与验证

- 行为改动必须在能表达它的最低层加回归测试：Analyzer/SiteSet 逻辑 → host test；内核路由/
  硬件路径 → 真机日志 + 回读。
- 测试直接编译真实源码，不为测试复制实现；fixture 是本地未跟踪数据，不提交二进制或生成物。
- 保持这些 host 测试入口可运行：

```sh
python3 test/test_analyzer.py
python3 test/test_site_set.py
python3 test/test_block_reader.py
python3 test/test_fixture_probe.py
```

- host 测试统一用 `clang++ -std=c++23 -Wall -Wextra -Werror`；不要用 pragma 关闭警告。确有无害
  的未使用参数时用 `(void) param;` 明确标注，其他警告先改代码。缺 fixture 的槽位是保留的，按
  `test_fixture_probe.py` 的规则处理。
- 改 `RuleTable.cpp`：保持 find/replace 等长（`static_assert` 会拦截）；如果由
  `scratch/generate_rules.py` 生成，重新生成后跑全套 analyzer 测试。
- 验证至少跑一次 debug 构建；发布用 release。构建命令见 `AGENTS.md`，不要新增构建系统。
- 涉及启动、GPU、VCN 或 hook 的改动，最终门槛是真机验证：给日志证据，不把“能编译”当成
  “能工作”。

## 10. 改动流程与自检

1. 先读 `AGENTS.md` 和对应的设计文档；找到现有 owner，再决定改哪里。
2. 优先改现有文件/函数；没有新关注点就不建新文件。不要建 worktree，直接在主 checkout 工作。
3. 只做最小 diff：一次一个逻辑变更；不顺手重命名、重排 include、改无关注释。
4. 加/改回归测试；跑相关 host 测试；按需要跑 debug 和 release 构建。
5. 提交前自检：
   - 能用一句 commit message 说清吗？
   - 是否新增了第二条路径、第二个开关或第二份数据？
   - 新字段/参数/常量现在都有使用者吗？
   - 失败时旧行为是否保持不变，且日志能定位？
   - hook 是否仍然无分配、无睡眠、无 I/O？
   - 是否只改了必要文件？有没有把调试代码/临时文件带进来？
   - 证据是什么：测试输出、真机日志、回读结果？
6. 汇报时分开写“已验证”和“未验证”；不要声称做过硬件验证而没有真机日志。

提交信息用仓库现有前缀与祈使句，例如 `analyzer: reject rules without a target image path`、
`VCN: bridge the X5000/X6000 VM context metaclasses`、`docs: ...`、`test: ...`。版本号同时改
`xmake.lua` 和 `CHANGELOG.md`。除非用户明确要求，不 commit、不 push；EFI 写入和重启验证必须
获得当前会话的明确授权，subagent 不得自行部署。

## 11. 禁止清单

- 重新引入 NRPT、profile、`NRedProfiles`、image-completion/warm pass、`NootedRedTool`。
- 在 Analyzer 或 hook 里使用 STL、异常、RTTI、动态分配。
- 为编译期就能决定的事新增 boot-arg/plist 配置。
- 在名字解析失败时退化为无范围匹配。
- 在 hook 或 `thread_call` 里做 VFS。
- 为“以后可能用到”加字段、参数、兼容层或第二套日志/失败机制。
- 对已有文件整体 clang-format、整体重命名、无关重构。
- 在文件或 commit 里添加 AI/assistant 署名。
