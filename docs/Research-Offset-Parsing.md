# 实际解析偏移来 patch：可行性研究

- 范围：Big Sur+，目标 macOS 15.8.x
- 目的：不靠整页 semantic 扫描，解析模块/函数/site 偏移，运行时按 pageOffset 精确 patch
- 数据来源：本机 15.8.1 / 24H32

## 1. 解析 GL：已可完全计算

GL 是单独文件：

```text
/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver
```

Mach-O：

```text
__TEXT  vmaddr 0x0  fileoff 0  vmsize 0x14d000
```

本地符号：

```text
_gfx9_HwInfoInitData                 0xdf40
_glrAMD_GFX9_UpdateHwCbDualQuadMode 0x8134
```

当前 PatchData：

```text
A1: page 0xE000, site 0x081 -> file 0xE081
A2: page 0x8000, site 0x160 -> file 0x8160
```

计算：

```text
A1 = _gfx9_HwInfoInitData + 0x141
A2 = _glrAMD_GFX9_UpdateHwCbDualQuadMode + 0x2C
```

所以 GL 不需要扫描整页：

```text
解析 LC_SYMTAB
-> 得到函数 VM
-> 加固定 site displacement
-> 得到 site file offset
-> pageOffset = siteFileOffset & ~0xFFF
-> siteInPage = siteFileOffset & 0xFFF
```

## 2. 解析 dyld cache：符号存在

用 dyld cache 的 mapping 表读取 Mach-O 后，15.8.1 上可解析出：

```text
AMDRadeonX5000MTLDriver  __TEXT 0x7FFB08757000
  symbols 19870
  gfx9_HwInfoInitData 0x7FFB087EF3DC

AMDRadeonVADriver2      __TEXT 0x7FFB08606000
  symbols 3958

AppleGVA                __TEXT 0x7FFA0666E000
  symbols 384
```

MTL HwInfo：

```text
函数 VM        0x7FFB087EF3DC
函数 VM - text 0x983DC
_PData 页偏移  0x98000
site 0x51D
```

验证：

```text
0x7FFB087EF3DC - 0x7FFB08757000 = 0x983DC
0x98000 + 0x51D = 0x9851D
0x9851D - 0x983DC = 0x141
```

即 MTL HwInfo 与 GL A1 一样，是函数起始 + `0x141`。

结论：

```text
cache-only 也不一定是黑盒
只要 cache pager 中能读到 __LINKEDIT/LC_SYMTAB，
就可以像 GL 一样计算函数与 site 偏移。
```

## 3. 运行时 pageOffset 是唯一待确认点

`_cs_validate_page` 会提供：

```text
pager
pageOffset
data
```

当前 backend 没有使用 `pageOffset`。

如果 `pageOffset` 是 pager 文件偏移：

```text
可以直接用 profile 的 pageFileOffset 匹配
不需要比较整页
```

如果是 cache 的 VM 页偏移，则需要：

```text
pageOffset -> cache mapping -> 模块页
```

这一点需要通过一次只读 instrumentation 确认，不能猜。

## 4. 建议的 profile

```text
OffsetProfile
  buildFamily      24H
  driver           GL / MTL / VDA / GVA
  imageTextStart
  pageVMOffset
  pageFileOffset
  sites[]
    functionName
    functionVM
    displacement
    siteVM
    siteInPage
    find
    replace
```

GL 可以只存函数名 + displacement；cache 可以存 VM/文件页偏移 + siteInPage。

## 5. 运行时路径

```text
_cs_validate_page(pageOffset, data)
  -> profile pageFileOffset == pageOffset
  -> data + siteInPage
  -> 校验 find
  -> 写 replace
```

没有：

```text
4 KiB 整页比较
全页 semantic 扫描
页内 shift 搜索
```

## 6. 仍需人工的部分

解析能解决：

```text
模块移动
函数移动
页偏移变化
```

不能自动解决：

```text
函数内部结构变化
site 附近的指令/字段语义变化
```

后者仍需：

```text
反汇编确认
structure offset 更新
新 find/replace
```

即：

```text
小版本：重新解析偏移即可
大版本：解析 + 人工确认 site 语义
```

## 7. 结论

```text
可以实际解析，而且应该优先于 semantic 扫描。
```

目标结构：

```text
离线解析生成 OffsetProfile
运行时按 pageOffset + siteInPage 精确写入
semantic 只作为解析失败时的 fallback
```

下一步应先确认 `_cs_validate_page` 的 pageOffset 语义，再生成第一份 GL/MTL offset profile。
