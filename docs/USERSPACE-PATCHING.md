# 用户态驱动补丁架构

状态：2026-11-07。替代 NRPT v3 / NRPT v4 / `NRedProfiles` / image-completion 方案。
范围：`NootedRedUserPatch.kext` 如何定位并写入用户态 AMD 驱动的补丁。主 kext 的内核补丁不变。

## 1. 目标与非目标

### 目标

- 在 **AMFI + SIP 全开**、系统卷密封（SSV）的条件下工作，不要求任何降低系统安全性的 boot-arg。
- **跨 macOS 版本**：同一份 satellite 二进制通过运行期解析当前镜像来定位站点，不维护按 build 的
  profile，也不维护按版本增长的字节表。
- **少写**：每个 site 在每次页驻留期间只写一次；不做 per-process 写入，不做无意义的预热 page-in。
- **简单**：satellite 只保留 hook、镜像解析、站点解析、写入四件事。没有 build/APU/device 选择、
  没有 profile 注入、没有 identity 重试、没有 image-completion 线程、没有 IORegistry 诊断。
- **可验证**：主机侧可以用干净 fixture 跑同一套解析逻辑；硬件侧用 Lilu 日志和页回读验证。

### 非目标

- 不替换 Apple 的 AMD 内核驱动或用户态驱动。
- 不改主 kext 的内核补丁、VCN bridge、VDA 内核侧逻辑。
- 不引入 per-process patch 通道（`vm_map_write_user`、进程遍历、watchdog）。
- 不做完整的反编译器。运行期只做 Mach-O 结构解析和函数级/指令级定位。

## 2. 不可变的核心

Apple 的 GL/Metal/VDA 用户态驱动位于 dyld shared cache（GL driver 是独立 bundle）；AppleGVA 在
v1 退役，不参与解析。
系统卷密封，AMFI 在页 fault 时校验签名，因此：

1. 不能改磁盘上的二进制。
2. 不能在用户态注入未签名代码，也不能写已校验的代码页。
3. 唯一可行写点是内核的 code-signing validation 路径：

```
页面 fault
  -> _cs_validate_page(vnode, pager, page_offset, data, ...)
       -> 原校验器先运行，结果不变
       -> 校验通过后，在 UBC 页里原位写 replace 字节
  -> 内核把该页标记为 validated
  -> 所有映射该页的进程看到补丁后的代码
```

这个机制是整套架构唯一需要信任的内核写路径，约两百行。其余问题只有一个：**怎样在当前系统版本
的镜像里找到这些 site 的精确偏移**。旧架构 80% 的复杂度都在这个问题上。

## 3. 为什么不用 profile，也不用按版本的字节表

| 方案 | 版本适配 | 数据增长 | 主要问题 |
|------|----------|----------|----------|
| NRPT v3/v4 profile | 每个 build 生成新 profile | 每个 build 一份 | 偏移是 build 精确值；需要 fixture 流水线、注入、identity 门控、image completion |
| 带掩码的字节表 | pattern 可跨若干 build | 每适配一个版本累积 variant | 同 subcache 误匹配；数据随版本增长；仍需人工维护 |
| **运行期解析（本方案）** | 解析当前镜像的符号/函数结构 | **固定 19 条规则（5 default + 14 VDA），不随版本增长** | 代码量比字节扫描大；解析器必须在内核里安全、可失败 |

本方案的判断是：**版本差异是结构差异，不是数据差异**。Apple 改代码时会移动偏移、改变寄存器分配、
增删指令，但驱动仍保留 Mach-O 符号表、`LC_FUNCTION_STARTS` 和可识别的函数级结构。把“定位”写成
代码，比把每个版本的偏移写成数据更省维护。

## 4. 架构总览

```
NootedRedUserPatch.kext
 ├── RuleTable            19 条规则：镜像 + familyMask + 锚点 + variants[] + find/replace
 ├── ImageAnalyzer        启动时一次：解析目标镜像的 Mach-O / 符号 / 函数边界
 │   └── RuleResolver     把规则解析成 {vnode, fileOffset, find, replace}
 ├── SiteSet              解析结果，只读；hook 只读它
 └── ValidationHook       _cs_validate_page：原校验器优先，然后原位写命中的 site

启动顺序：
  plugin load
    -> 安装 _cs_validate_page route（先装，避免校验窗口）
    -> 创建 analyzer kernel thread（kernel_thread_start），线程只睡眠，不做 VFS
    -> 第一次 dyld shared cache 页校验（用户态已启动、Cryptex 已挂载）
         -> hook 设置一次性的 trigger（单次 atomic store，不做 VFS）
         -> worker 唤醒，执行完整的 VFS/namei 解析
         -> 解析规则表、目标镜像、每条规则 -> SiteSet ready
    -> WindowServer 加载 GPU 用户态驱动
         -> 页面 fault -> hook -> 命中已解析的 site -> 写入
```

关键点：**hook 里不做解析**。不做文件 I/O、不分配、不睡眠、不扫描模式。hook 只做
vnode 名字匹配 + 偏移区间匹配 + 字节比对 + 写入，和当前 `applyChunk` 的热路径相同。

**VFS 时序是硬约束**：patcher-load 时卷命名空间还没就绪，namei 在早期线程（无论 thread_call
还是普通 kernel thread）里都会 panic（`Taking non-sleepable RW lock with preemption enabled`）。
所以 worker 在 patcher-load 只启动并睡眠；第一次 dyld shared cache 页校验证明用户态已起来、
Cryptex 已挂载，才是安全的 VFS 起点。

## 5. 镜像解析

### 5.1 目标镜像的类型

| 类型 | 例子 | 定位方式 |
|------|------|----------|
| standalone | `AMDRadeonX5000GLDriver` | 直接打开文件，Mach-O 的 `__TEXT` / `__LINKEDIT` 都在同一文件 |
| dyld shared cache | `AMDRadeonX5000MTLDriver`、`AMDRadeonVADriver2` | 从主 cache 的 `imagesText` 表取 `loadAddress`/`textSegmentSize`，再用 subcache 的 mapping 表换算成 `(subcache 文件, fileOffset)` |

### 5.2 shared cache 的解析步骤

运行时读取（不是 fixture）：

1. 主 cache：`/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64h`
   - `dyld_cache_header.imagesTextOffset/imagesTextCount`（偏移 `0x88` / `0x90`）
   - 每条 `dyld_cache_image_text_info { uuid, loadAddress, textSegmentSize, pathOffset }`
   - 按路径匹配目标镜像，得到 `(loadAddress, textSegmentSize)`。
2. 每个 subcache 文件头：
   - `dyld_cache_mapping_info { address, size, fileOffset, maxProt, initProt }`
   - 判断镜像地址落在哪个 mapping，得到 `__TEXT` 在 subcache 里的 file offset。
3. 镜像 Mach-O 头（位于 `__TEXT` 起始）：
   - `LC_SEGMENT_64(__TEXT / __LINKEDIT)`：`__LINKEDIT` 的 `fileoff` 是符号表所在 subcache 文件偏移。
   - `LC_SYMTAB`：`symoff/nsyms/stroff/strsize`，同样是 subcache 文件偏移。
   - `LC_FUNCTION_STARTS`：ULEB128 增量，展开成函数起始地址数组。

注意：`__LINKEDIT` 可能和 `__TEXT` 不在同一个 subcache；实现时按各自的 file offset 分别读取，
不能假设同一文件。字符串表（`stroff`）很大（数十 MB），只在需要时按 `strx` 读取单个字符串，
不要整表读入。

**内核读取约束**：vnode `ByteSource` 的 16 KiB 块缓存必须处理跨块请求，回退到直接
`FileIO::readFileData`。24H232 实测，旧实现让跨块的 nlist/path 读取返回 false，符号扫描和镜像
路径匹配整体失败，日志表现为 `symbol not found` / `image not located`；修复后 19/19 解析成功。
主机回归见 `test/test_block_reader.py`；analyzer fixture 测试用普通文件源，不经过该缓存，两者都要跑。

### 5.3 符号索引

对每个目标镜像：

- 读 `nlist_64` 数组（`nsyms × 16` 字节）。
- 只保留 `n_value` 落在镜像 `[loadAddress, loadAddress + textSegmentSize)` 的符号。
- 只对“函数起始地址”或“规则需要的符号”读取字符串，避免遍历整个字符串表。
- 建立 `name -> n_value` 的查找（目标符号只有 19 个，可以线性比对；不需要哈希表）。

函数边界用 `LC_FUNCTION_STARTS` 给出，不用“最近的前一个符号”猜。符号地址是函数入口时，两者应
一致；不一致时以 `LC_FUNCTION_STARTS` 为准，符号名仍作为锚点。

### 5.4 解析预算

- 目标镜像总量约 7 MB（GL 1.8 MB + MTL 4.5 MB + VADriver 0.75 MB）。
- nlist 总量约 3.2 万条（VADriver 3,958 + MTL 19,870 + GL 8,384）。
- 函数起始约 1 万条。
- 一次启动解析预计 < 100 ms，在专用可睡眠内核线程（`kernel_thread_start`）里完成；不占 hook
  热路径。worker 在 patcher-load 只睡眠，第一次 dyld shared cache 页校验后才开始 VFS。
  **不能用 `thread_call`，也不能在 patcher-load 直接做 VFS**：早期 namei 会 panic。

## 6. 站点规则

### 6.1 规则字段

```
Rule {
    image       目标镜像路径（standalone 或 cache 内路径）
    familyMask  运行 iGPU 家族掩码（发布集为 0x28 = VCN2 Renoir/Cezanne/Green Sardine）
    flags       kVDA（仅在 -NRedUserPatchVDA 时启用）
    anchor      符号名（首选）| 函数指纹 | 镜像内唯一模式
    variants[]  每个 variant: { local, find, replace }，按当前函数形状选择
    policy      unique | all | nth(n)
}
```

`find`/`replace` 和规则语义是代码的一部分；`anchor`/`variants[].local` 描述“在当前镜像里怎么找”，
由 analyzer 每次启动重新求值。规则不是按 build 的 profile：一条规则通常只有一个 variant；只有函数
控制流或寄存器分配发生变化时，才增加一个**按函数形状**的 variant。

15.8.2 的实际发布集是 **19 条规则**：default 5 条（GL + MTL），VDA 14 条（VADriver2）。
`-NRedUserPatchVDA` 打开 VDA 集；AppleGVA 不在发布集，v1 不实现。

规则表里每个 `find`/`replace` 数组的长度由编译期 `static_assert` 校验；写入路径按 `patchSize`
从两个数组拷贝。生成器曾把规则 13 的 replace 截成 12 字节（find 是 13 字节），第 13 字节越界读到
相邻静态数组的 `0x55`，实测写入 `90*12 + 55`；已修正为 13 个 NOP。

### 6.2 锚点类型

1. **symbol（首选）**
   - 在符号表里精确匹配 mangled name，得到函数入口 `n_value`。
   - 用 `LC_FUNCTION_STARTS` 求 `[funcStart, funcEnd)`。
   - 15.8.2 发布集的 19 个 site 全部能锚定到函数起始符号；这 19 个符号名在 26.7.2 中全部存在。
     GL 的两个符号是 local symbol，走 nlist 扫描；VADriver 的多数符号可直接从 export trie 取。

2. **function fingerprint（符号被 strip 时的回退）**
   - 枚举函数起始，比较函数开头 N 字节的掩码指纹（例如 24–32 字节，wildcard 掉 RIP 位移）。
   - 要求全镜像唯一。
   - 只对少数失去符号的函数使用。

3. **image-unique pattern（最后的回退）**
   - 在镜像 `__TEXT` 内搜索掩码模式，要求恰好一个匹配。
   - 作为符号和函数指纹都失效时的最后一级；v1 的 19 条规则都有符号锚点，不依赖这一级。
   - AppleGVA 的 site（唯一需要这一级的样本）不在发布集，v1 不实现。

### 6.3 局部规则

在已知函数范围内定位 site：

1. **offset + find**
   - `site = funcStart + offset`，直接验证 `find` 字节。
   - 适合函数很小、指令序列稳定的 site（例如 `VAFactory::createDitheringVP` 偏移 `0x7`）。
2. **masked local pattern**
   - 在函数范围内搜索短掩码模式；`??` wildcard 掉立即数、RIP 位移等会随版本变化的字节。
   - `policy=unique` 要求恰好一个匹配；`policy=nth(n)` 指定第 n 个；`policy=all` 用于确实需要
     同时打多个副本的 site。
   - 适合函数内偏移会移动、但局部指令序列稳定的 site。
3. **shape variant（按函数版本适配）**
   - 同一条规则可以有多个 variant；analyzer 按函数当前的字节形状（掩码模式）选择第一个唯一匹配，
     并使用该 variant 的 `replace`。
   - 这是对“函数控制流/寄存器分配变了，但语义站点不变”的处理方式；variant 是代码形状数据，
     不是按 build 生成的 profile。
   - 已确认的两个例子（发布集的 MTL site）：
     - gate：15.8.2 形状 `F6 80 A0 00 00 00 02 75 0B`，替换 `75 0B -> EB 0B`；
       26.7.2 形状 `F6 81 A0 00 00 00 02 74 28`，替换 `74 28 -> EB 00`（按 26 的函数版本直通）。
     - allow：15.8.2 `0F 94 C0 -> 31 C0 90`；26.7.2 `0F 94 C1 -> 31 C9 90`（同一寄存器，al/cl）。
   - 不做通用 rewriter 或反汇编器；variant 只覆盖已经分析清楚的函数形状。遇到未知形状 fail closed。
     如果未来某条规则需要重算相对跳转目标（AppleGVA 类），再单独引入 branch-target 规则，不在 v1。

### 6.4 解析算法

```
for rule in rules:
    if (rule.familyMask & runningFamily) == 0: skip          // VCN2 门控
    if rule.flags.kVDA && !vdaEnabled: skip                  // -NRedUserPatchVDA
    image = resolve_image(rule.image)                        // 失败 -> rule unresolved
    macho = parse_macho(image)                               // 失败 -> rule unresolved
    func  = resolve_anchor(macho, rule.anchor)               // symbol/fingerprint/image-unique
    if func == null: rule unresolved; log; continue

    for variant in rule.variants:
        site = resolve_local(macho, func, variant.local)
        if site == null: continue
        if matchCount(macho, func, variant) != expected(policy): continue
        if read(image, site, len(variant.find)) != variant.find: continue
        sites.add({vnode_name(image), fileOffset(image, site),
                   variant.find, variant.replace})
        break
    else:
        rule unresolved; log once
```

每条规则独立解析、独立失败。任何一条失败只影响它自己，绝不影响其他 site，也绝不退化成“全镜像
随便扫”。variant 按表顺序尝试；匹配数不符合 policy 的 variant 只被跳过并记录，不产生写入。

### 6.5 失败闭合矩阵

| 条件 | 行为 |
|------|------|
| 规则表缺失/格式错误 | 不解析任何规则；satellite 保持 loaded 但不写 |
| cache 路径暂不可用 | analyzer kernel thread 用 `IOSleep` 重试；期间 hook 不写 |
| 镜像路径不匹配 | 该规则 unresolved；日志一次 |
| 符号不存在 | 依次尝试 fingerprint、image-unique；都失败则 unresolved |
| 函数范围内匹配数不符合 policy | 该 variant 跳过；尝试下一个 variant |
| 所有 variant 都不匹配 | 该规则 unresolved；不写 |
| 解析出的偏移处 find 不匹配 | 该 variant 跳过；尝试下一个 variant |
| hook 收到的 chunk 里 find 不匹配 | 跳过该 site；计数 + 有界日志 |
| 写入失败/回读不一致 | 计数 + 有界日志；不重试到死循环 |

## 7. 写入路径

### 7.1 Hook 契约

`_cs_validate_page`（7 参数，macOS 11+ 实测 ABI）：

- 先调用原校验器；原结果原样返回，hook 不改变 `validated` 的语义。
- 只有原校验器接受后，才检查 `data` 里的 site。
- vnode 名字解析仍用 `vnode_getname`，回退 `vn_getpath`；两者都没有时 fail closed。
- 站点按 `vnode name + fileOffset` 匹配；每个 site 只有在完整 `find`/`replace` 字节都落在交付的
  chunk 内时才处理。
- 一个 chunk 内所有命中的 site 在一次 `MachInfo::setKernelWriting` 窗口里写完，然后回读验证。
- 已是 `replace` -> 跳过（幂等）；是 `find` -> 写；其他 -> 跳过并计数（fail closed）。
- 不做页级状态；UBC 回收后页重新 fault，重新看到 `find`，hook 自然重写。

### 7.2 为什么不再需要 image completion

旧架构的 warm pass 是为了补两类窗口：

1. profile 还没激活（build/APU/device 身份未就绪）时，页已经被校验，结果被内核缓存；
2. 某些页没有被任何 workload fault 到。

新架构下：

- hook 在任何目标页之前安装；analyzer worker 等到第一次 dyld shared cache 页校验（用户态已起来）
  才做 VFS 并解析规则。不存在“profile 未激活”的窗口。
- 第一次 dyld cache 校验通常是无关 dylib 的页；目标 GPU 驱动由 WindowServer / 视频服务更晚加载，
  所以 SiteSet 通常在目标页之前 ready。
- 没有被 fault 的页不需要补丁；它第一次被使用时 fault 会同步进入 hook，补丁在指令执行前完成。
- 因此不再有主动 page-in / `vm_page_validate_cs` 预热，也不需要 `thread_call` 驱动的逐页完成。

**24H232 硬件结论（2026-11-07）**：第一次 dyld cache 页校验触发后，analyzer 解析出 19/19；随后
`.03` 的 MTL/VDA 页在各自校验时被 hook 写入，GL 页在 SiteSet ready 后的首次 fault 被写入；私有
只读映射回读 19/19 为 `replace`。没有观察到目标驱动页先于 SiteSet 校验；当前不需要 pending 修复。
如果未来系统出现这个窗口，再加上述**有界 pending 修复**，不恢复整镜像 completion。

### 7.3 诊断与开关

- `-NRedUserPatchOff`：satellite 不安装 hook，不解析，不写。
- `-NRedUserPatchVDA`：启用 14 条 VADriver2 规则；默认只打 GL/Metal 5 条（保持当前发布行为）。
- `-NRedUserPatchDebug`：详细日志（与 `-NRedDebug` 分开，便于隔离）。
- 日志内容：解析到的镜像范围、每条规则的 anchor/函数/偏移/匹配数、resolved/unresolved 汇总、
  hook 调用数、写入数、已存在数、foreign 数、回读失败数。
- 不再发布 IORegistry 诊断属性；以 Lilu debug 日志为准。

## 8. 版本适配

### 8.1 已获得的证据（主机侧，非硬件）

用 `version-fixtures/15.8.2` 和 `version-fixtures/26.7.2` 的干净镜像做 Mach-O 解析：

- 发布集 19 条规则（default 5 + VDA 14）的语义位置都能在 26.7.2 中找到；19 条都有函数符号，
  且 19 个符号名在 26.7.2 全部存在。GL 的符号是 local symbol（nlist 扫描），VADriver 的多数
  符号可从 export trie 直接取。
- **17/19 的 `find`/`replace` 字节在 15.8.2 与 26.7.2 完全一致**；剩下 2 条 MTL site 需要按函数
  形状的 variant：
  - gate：15.8.2 `F6 80 A0 00 00 00 02 75 0B` -> `EB 0B`；26.7.2
    `F6 81 A0 00 00 00 02 74 28` -> `EB 00`。
  - allow：15.8.2 `0F 94 C0` -> `31 C0 90`；26.7.2 `0F 94 C1` -> `31 C9 90`。
- 函数内偏移会移动（例如 VADriver 的 `identify` 内偏移移动约 12 字节），但函数名和局部指令形状
  不变；variant 按形状匹配，不按 build 选择。
- 18/19 的 ±12 字节局部模式在各自镜像内唯一；剩余的是同一函数内相邻的两个 site
  （`Vcn2Encoder::setEncodeParams`），由 `nth`/函数范围规则区分。
- AppleGVA 不在发布集，v1 不实现。它是唯一没有函数符号且需要重算相对跳转目标的样本；
  相关 branch-target 规则留到 v2。

**修正**：上一版文档的“20/20 都能在 26.7.2 定位”指的是语义位置/符号锚点，不是“15 的 find 字节
在 26 也能匹配”。MTL 的两条 site 证明固定字节替换不能无脑跨版本；按函数形状的 variant 是这里的
取舍。

### 8.2 新系统版本的维护流程

1. 用干净 fixture 跑主机侧 analyzer 测试（`test/test_fixture_probe.py` 先报告 13–26 各槽位的
   resolved/unresolved，再用 `test_analyzer.py` 做严格断言）。
2. 若有规则 unresolved：查看日志里的 anchor/函数/匹配数，只改那一条规则的 anchor 或局部规则。
3. 如果函数控制流/寄存器分配变化，增加一个按函数形状的 variant；不是每个 build 生成 profile。
4. 不需要生成 profile，不需要注入，不需要按 build 选择。
5. 只有当 Apple 彻底移除符号且函数指纹也失效时，才需要新增一个 fingerprint/image-unique 规则。

### 8.3 符号被 strip 的未来风险

如果某个版本把 local symbols 全部 strip：

- `LC_FUNCTION_STARTS` 仍在，函数边界仍可用。
- 锚点退化为 function fingerprint（函数开头字节）或 image-unique pattern。
- 这两级仍然是版本无关的“结构定位”，不是按版本的数据表。
- 最坏情况：某条规则无法定位 -> 该 site 不补丁，驱动可能功能受限；日志明确指出是哪一条。

## 9. 性能

- **解析**：每次启动一次，目标镜像约 7 MB、符号约 3 万条；预计 < 100 ms，在可睡眠线程里。
- **hook 热路径**：vnode 名字匹配 + 最多 19 条 site 的区间比较；没有扫描、没有文件 I/O、没有分配。
- **写入次数**：每个 site 每次页驻留写一次；典型一次启动 5 次（默认）或 19 次（VDA）写。UBC 回收后的页在下次 fault
  时重写，这是机制固有的，不是额外开销。
- **没有**：per-process 写入、主动 page-in、watchdog、定时器、image completion 线程。

## 10. 安全

### 10.1 威胁模型

- 不要求关闭 SIP、不要求关闭 AMFI、不要求 `amfi_get_out_of_my_way`、不要求 root patch。
- 补丁字节来自 satellite 自身（规则表 + 代码），不来自 IORegistry、NVRAM、boot-arg 或任何
  运行期可写通道。旧架构的 `NRedProfiles` 注入面被删除。
- hook 只在原校验器接受后写；它不改变校验结果，不扩大“哪些页被视为有效”的集合，只改变已接受
  页的内容。这是本机制作为“受信任补丁器”的固有属性，必须明确记录。
- 写入长度不变、位置由解析器验证、find 字节精确匹配；不会写入未解析的区域，也不会写入未交付的
  chunk。
- 没有 per-process 通道：不需要 task port、不需要 `vm_map_write_user`、不需要进程遍历。

### 10.2 信任边界

- satellite 自身是信任根：能被替换 kext 的人已经能执行内核代码，本架构不新增这类能力。
- 规则表如果编译进 kext，与 kext 同一信任边界。
- 如果将来把规则表外置为数据文件，必须明确：能写该文件的人可以改变站点定位（但不能注入任意
  replace 字节，replace 仍由代码按 rule ID 固定）。默认方案是编译进 kext；外置只作为运维选项，
  并放在 root-only 路径。

## 11. 验证

### 11.1 主机侧测试

主机的 `test/test_analyzer.py`、`test/test_site_set.py`、`test/test_block_reader.py` 和
`test/test_fixture_probe.py`：

1. 对 `version-fixtures/15.8.2` 和 `version-fixtures/26.7.2` 运行同一套 Mach-O 解析 + 规则解析。
2. 断言 default 5 条、VDA 打开后 19 条全部 resolved；每条解析出的 `find` 字节与 fixture 一致。
3. 断言 MTL gate/allow 在两个 fixture 上选中正确的 shape variant（`EB 0B`/`EB 00`、
   `31 C0 90`/`31 C9 90`）。
4. 断言 familyMask 不匹配时规则被跳过。
5. 负例：删除一个符号、改一个函数指纹、制造一个双匹配，断言该规则 fail closed 且其他规则不受影响。

这组测试不需要硬件，也不依赖 UBC 状态，是跨版本适配的主要回归手段。`test_block_reader.py` 用内存
源覆盖块缓存的跨块/命中/越界；`test_fixture_probe.py` 按 `13.*`/`14.*`/`15.*`/`26.*` 槽位探测
fixture，13/14 目前预留，加入对应目录后自动运行并报告每条规则的 resolved/unresolved。

### 11.2 硬件验证

2026-11-07 / 24H232 / Renoir `0x1638` / SIP + AMFI 全开：

- 主 kext 0.9.1 `E1F3247A`，卫星 debug `2D1498AC`，Lilu 1.7.3 debug；boot-args
  `-NRedUserPatchVDA -NRedUserPatchDebug -liludbgall liludump=60`。
- hook 安装；name resolver `vnode_getname`/`vnode_putname`/`vn_getpath` 全部可用；第一次 dyld
  shared-cache 页校验触发 worker，日志 `analyzer: 19/19 rules resolved (family 0x28, VDA 1)`。
- `.03` 的 MTL/VDA 页和 GL 页由 hook 写入；私有只读映射回读 19/19 `PATCHED`（含规则 13 的
  13 字节 NOP）；无 panic，SIP/AMFI 未关闭。
- 调试通道：该机 Lilu 1.7.2 debug 的 `liludump` 未落盘，1.7.3 debug 正常；硬件验证用 1.7.3。

待验证：`-NRedUserPatchOff`、UBC 回收后的重写、GL/Metal/VDA 功能负载、
26.7.2 实机启动。

## 12. 决策与取舍

| 决策 | 选择 | 代价 |
|------|------|------|
| 定位方式 | 运行期 Mach-O 解析 + 符号/函数锚点 + 局部规则/variant | 代码量比字节表大；内核里要写安全解析器 |
| 数据 | 19 条规则（5 default + 14 VDA），不按 build 增长；函数形状变化时加 variant | 少数 site 需要按函数形状的 variant；不是每 build 生成 profile |
| 替换适配 | 固定的 find/replace + 少量 shape variant；不做通用 rewriter | MTL gate/allow 需要两个 variant；未来 AppleGVA 类需要 branch-target 规则 |
| profile | 删除 | 失去“不改 kext 只换 profile”的能力；但也不再需要每 build 生成 profile |
| identity | 保留最小 device-id `familyMask` 门控，删除 build/profile 选择 | 卫星仍有少量 IOKit 探测；但不再依赖 kern.osversion |
| VDA 默认 | 默认关闭，`-NRedUserPatchVDA` 打开 14 条 VADriver 规则 | 保持当前发布行为；用户需要显式开启 VDA |
| AppleGVA | v1 丢弃 | 少一个 site；它是唯一需要重算相对跳转目标的样本 |
| image completion | 删除 | 24H232 实测 19/19 在目标页校验时写入；若未来出现 analyzer 与目标页的窗口，再加有界 pending 修复 |
| range hook | 暂不安装 | 如果未来版本走 range 路径，需要再加 |
| kext 边界 | satellite 独立 | 两个安装物；但主 kext 的版本门不拖住用户态解析 |

## 附录 A：15.8.2 → 26.7.2 站点解析证据

以下符号名来自 15.8.2 fixture 的 `LC_SYMTAB`；`26 符号` 表示同名符号在 26.7.2 的符号表中存在。
函数内偏移是 15.8.2 的解析结果，不是规则常量；运行时由 analyzer 重新求值。
发布集是 0–18 共 19 条（5 default + 14 VDA）；site 19 AppleGVA 退役，不在 v1。

| # | 镜像 | 锚点符号（mangled） | 15 函数内偏移 | 26 符号 |
|---|------|---------------------|---------------|---------|
| 0 | GL | `_glrAMD_GFX9_UpdateHwCbDualQuadMode` | `0x2c` | 有 |
| 1 | GL | `_gfx9_HwInfoInitData` | `0x141` | 有 |
| 2 | MTL | `-[GFX9_MtlRenderPipelineState initWithDevice:pipelineStateDescriptor:...]` | `0x11c4` | 有（2 个 shape variant） |
| 3 | MTL | 同上 | `0x11f8` | 有（2 个 shape variant） |
| 4 | MTL | `__Z19gfx9_HwInfoInitDataP14GFX9_HwInfoRecP24_sAMD_GET_HW_INFO_VALUESj` | `0x141` | 有 |
| 5 | VADriver2 | `__ZN17VAAcceleratorInfo8identifyEjj` | `0x1b6` | 有 |
| 6 | VADriver2 | `__ZN18VAAddrLibInterface4initEP11VAIOConnectP13sHardwareInfo` | `0x8b` | 有 |
| 7 | VADriver2 | `__ZN9VAFactory29createColourFormatConverterVPEi` | `0x7` | 有 |
| 8 | VADriver2 | `__ZN9VAFactory17createDitheringVPEi` | `0x7` | 有 |
| 9 | VADriver2 | `__ZN9VAFactory17createDeblockerVPEi` | `0x7` | 有 |
| 10 | VADriver2 | `__ZN9VAFactory20createGraphicsEngineEP9VAContext` | `0xa` | 有 |
| 11 | VADriver2 | `__ZN9VAFactory14createImageBltEP9VAContextj` | `0xb` | 有 |
| 12 | VADriver2 | `__ZN11Vcn2Encoder15setEncodeParamsEPvP15VAVendorTexture` | `0x31` | 有 |
| 13 | VADriver2 | 同上 | `0x3d` | 有 |
| 14 | VADriver2 | `__ZN14Vcn2EncCommand15getFeedbackSizeEv` | `0x4` | 有 |
| 15 | VADriver2 | `__ZN26AVDVcn2AvcEncDataProcessor19ProcessEncodeStatusEP19_VAEncodeStatus` | `0x2a` | 有 |
| 16 | VADriver2 | `__ZN27AVDVcn2HevcEncDataProcessor19ProcessEncodeStatusEP19_VAEncodeStatus` | `0x2a` | 有 |
| 17 | VADriver2 | `__ZN4Addr3Lib6CreateEPK18_ADDR_CREATE_INPUTP19_ADDR_CREATE_OUTPUT` | `0xb5` | 有 |
| 18 | VADriver2 | `__ZN4Addr2V27Gfx9Lib20HwlConvertChipFamilyEjj` | `0x0` | 有 |
| 19 | AppleGVA | 无（image-unique pattern） | — | n/a（v1 退役） |

补充：sites 12/13 在同一函数内，镜像范围内各有 2 个匹配（两个相邻 site 的局部模式互相覆盖），
规则用函数范围 + `nth` 或更长的局部上下文区分。sites 2/3 在 15.8.2 的镜像范围内各有 2 个匹配，
函数锚点把范围缩小到同一函数后由局部规则区分。

sites 2/3 的 **替换字节** 在两个 fixture 上不同（gate `75 0B`/`74 28`，allow `0F 94 C0`/`0F 94 C1`），
所以每条规则有两个 shape variant；符号锚点和局部定位不变，只是 variant 的 `find`/`replace` 不同。
这是“按函数版本适配”的取舍，不是按 build 的 profile。

## 附录 B：为什么不直接反编译

完整的反编译器（Ghidra 级）不适合放进 kext：

- 体积和复杂度远超本问题；内核里没有动态分配、异常、STL 的余量。
- 目标站点只有 19 个，且都有明确的语义（设备 ID 比较、固件 size、VP 创建、编码参数、分支）。
- 结构解析（Mach-O/符号/函数）已经能把“版本差异”吃掉；局部规则只需要识别少量指令类别。
- 如果某个 site 的编码跨版本变化，再为它增加一条指令级规则，而不是引入通用反编译器。
