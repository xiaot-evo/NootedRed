# OffsetProfile / 用户空间 profilegen 落地计划

- 状态：方案 B 已确认
- 目标：用户空间解析一次，生成并缓存 OffsetProfile；kext 只消费 profile
- 范围：macOS 15.8.x（24H**），Big Sur+ 页面验证路径

## 1. 数据流

```text
用户空间 profilegen
  -> 读取 GLDriver / dyld shared cache
  -> 解析 Mach-O / LC_SYMTAB / LC_FUNCTION_STARTS
  -> 生成 OffsetProfile
  -> 原子写入 /var/db/nootedred/offset-profile.bin
  -> 写入 offset-profile.meta

kext
  -> 读 embedded profile 或外部 profile
  -> 校验 build/UUID/hash/checksum
  -> _cs_validate_page(pageOffset, data)
  -> pageOffset 匹配 profile
  -> site find 校验
  -> 固定 siteInPage 写 replace
```

## 2. profile 格式

```text
Header
  magic          "NRPF"
  version        u16
  headerSize     u16
  build          char[16]
  parserVersion  u16
  pageCount      u16
  siteCount      u16
  reserved       u16
  pages          PageRecord[pageCount]
  sites          SiteRecord[siteCount]
  checksum       u64 FNV-1a

PageRecord
  pageFileOffset u64
  firstSite      u16
  siteCount      u16
  reserved       u32

SiteRecord
  siteInPage     u32
  size           u8
  reserved       u8[3]
  find           u8[32]
  replace        u8[32]
```

不包含整页镜像、context 或 semantic 规则。

## 3. meta

```text
meta
  build
  GL/MTL/VDA/GVA UUID
  driver text hash
  parser version
  profile checksum
```

缓存命中条件：

```text
build 相同
+ driver UUID/hash 相同
+ parser version 相同
+ checksum 正确
```

否则重新解析。

## 4. 生命周期

### 正常启动

```text
kext 读到已有 profile
-> 直接使用
-> profilegen 不重新解析
```

### macOS 更新后第一次启动

```text
profile invalid
-> kext fallback:
     embedded 24H profile 可用 -> 尝试
     否则 no-op
-> profilegen 运行一次
-> 写新 profile
-> 下次启动使用
```

### 手动

```text
nootedred-profilegen --force
```

## 5. kext 读取顺序

```text
1. 外部 profile
2. embedded profile
3. no-op
```

校验失败一律 no-op。

## 6. helper

```text
/usr/local/libexec/nootedred-profilegen
/Library/LaunchDaemons/com.chefkiss.nootedred.profilegen.plist
```

LaunchDaemon：

```text
RunAtLoad = true
UserName = root
```

启动逻辑：

```text
if profile valid for current build/UUID/hash
    exit
else
    parse
    write profile atomically
```

## 7. 安全约束

```text
helper 只读系统文件
parser 不修改驱动
profile 原子写
kext 只读 profile
pageOffset 必须匹配
site find 必须匹配
任何失败 -> no-op
```

## 8. 实施顺序

```text
1. OffsetProfile 结构/序列化
2. 用户空间 profilegen
3. kext profile 读取/校验/embedded fallback
4. LaunchDaemon 安装
5. 24H32 profile 生成并验证
6. 24Hxx 新 build 自动重生成验证
```

## 9. 非目标

```text
不做运行时 semantic 扫描
不做全页 page image 比较
不在 kext 内反汇编
不在 validation 回调里读文件
```
