# zig-wind

Wind 量化接口的 Zig 封装，同一套 API 同时支持 Windows 和 Linux。

## 前提

- Zig 0.16.0；
- Wind 终端已安装并登录，且账号具有相应数据权限。

两个平台的传输层不同，但公开 API 完全一致：

| | Windows | Linux |
|---|---|---|
| 传输 | 终端注册的 `WindDataCOM` Automation 组件 | 终端安装的 `com.wind.api` C 接口动态库 |
| 依赖 | `src/wind_com_helpers.c` + `ole32` / `oleaut32` | 无，运行时 `dlopen` |
| 位置 | 注册表 | `/opt/apps/com.wind.wft/files/com.wind.api/lib` |

Linux 上库是运行时加载的，所以构建机不需要装 Wind，产物也不含对 Wind 的动态依赖 —— 拷到任何装了 Wind 终端的机器上直接能跑。安装路径非默认时用 `WIND_API_LIB_DIR` 覆盖。

## 已实现接口

### 会话与请求管理

- `Wind.init` / `deinit`
- `start` / `stop` / `isConnected`
- `cancelRequest` / `cancelAllRequests`

### 同步数据接口

- 行情：`wsd`、`wss`、`wsi`、`wst`、`wsq`、`tdq`、`bbq`
- 数据与新闻：`wset`、`wgel`、`wnd`、`wnq`、`wnc`、`edb`、`htocode`
- WSEE：`wsee`、`wses`
- 交易日：`tdays`、`tdaysOffset`、`tdaysCount`

组合、筛选、组合上传、交易、回测和 App 鉴权接口不在当前范围内。

### 实时订阅

- `subscribeWsq`
- `subscribeTdq`
- `subscribeBbq`
- `subscribeWnq`
- `poll`
- `Subscription.cancel` / `deinit`

两个平台都不在 Wind 的回调线程里执行 Zig 用户代码。回调只把 `(state, request_id, error_code)` 放进队列；调用者反复调用 `poll(allocator)`，由它读取数据并返回所有权明确的 `SubscriptionEvent`。Windows 下 `poll` 还负责泵送 STA 消息，因此必须在创建 `Wind` 的同一线程调用；Linux 下没有这个限制。

`SubscriptionEvent.data` 为可选值；收到时由事件持有，必须调用 `event.deinit()`。实时接口返回 Wind 推送的**增量数据**，不会自动维护原 C++ wrapper 中可选的 `updateAllFields` 本地快照。

### 平台差异

以下接口只有 COM 才有，Linux 的动态库没有导出，调用会返回 `error.UnsupportedOnThisPlatform`，而不是编译不过 —— 这样上层代码保持可移植：

- `tdq` / `subscribeTdq`
- `bbq` / `subscribeBbq`
- `wgel`

`start` 的 `options2` 参数同理只在 COM 生效，Linux 下被忽略。

## 使用

```bash
zig build test
zig build run-wsd
zig build run-wsq
```

`examples/wsd.zig` 是同步日线查询示例。`examples/wsq.zig` 建立 `000001.SZ` 的 `rt_last` 订阅并最长轮询 10 秒；无报价变动时它会正常提示没有收到事件，长驻应用应持续轮询。

```zig
var api = try wind.Wind.init();
defer api.deinit();

const start_code = try api.start(null, null, 5000);
if (start_code != 0) return;
defer _ = api.stop() catch {};

var data = try api.wsi(
    allocator,
    "000001.SZ",
    "close",
    "2024-01-02 09:30:00",
    "2024-01-02 15:00:00",
    "BarSize=30",
);
defer data.deinit();
```

实时订阅的最小模式：

```zig
const started = try api.subscribeWsq("000001.SZ", "rt_last", "");
var subscription = started.subscription orelse return;
defer subscription.deinit();

while (true) {
    if (try api.poll(allocator)) |event_value| {
        var event = event_value;
        defer event.deinit();
        if (event.data) |data| {
            // 使用 data，再由 event.deinit() 释放它。
            _ = data;
        }
    }
    // 在你的主循环、事件循环或定时器中继续调用 poll。
}
```

## 返回值、所有权与数据布局

Wind 业务请求是否成功由 `Data.error_code` 或 `SubscriptionStart.error_code` 表示，`0` 为成功。传输层失败（COM 创建、方法解析、封送；Linux 下动态库缺失或符号缺失）作为 Zig `Error` 返回。

出错时 Wind 会把原因当成数据返回（`codes = {"ErrorReport"}`、`fields = {"OUTMESSAGE"}`），`Data.errorMessage()` 直接把它取出来：

```zig
if (result.error_code != 0) {
    std.debug.print("Wind API error {d}: {s}\n", .{
        result.error_code,
        result.errorMessage() orelse "(no message)",
    });
    return;
}
// Wind API error -40522018: CWSDService: multi-codes with multi-indicators is not supported.
```

返回的切片属于该 `Data`，随 `deinit` 一起失效。

`Data.codes`、`Data.fields` 是 UTF-8 字符串数组；`Data.times` 保存 OLE Automation 日期（自 1899-12-30 起的天数，`f64`）；`Data.values` 按 `time × code × field` 排列。推荐使用：

```zig
const value = try data.valueAt(time_index, code_index, field_index);
```

`Data` 必须由调用者执行 `deinit()`。`Value.string` 的内存也随其所属 `Data` 一同释放，不应在 `Data.deinit()` 后继续持有。

## 实现说明

### 源码组织

- `src/wind.zig` —— 门面，按 `builtin.os.tag` 分派后端。
- `src/wind_types.zig` —— 两端共用的 `Error` / `Value` / `Data` / `SubscriptionEvent`。
- `src/wind_windows.zig` + `src/wind_com_helpers.c` —— COM 后端。
- `src/wind_linux.zig` —— 动态库后端。

`build.zig` 只在目标为 Windows 时编译 C 文件并链接 OLE 库。

### Linux 后端的几个关键点

绑定的是 `libWind.QuantData.so` 导出的 C 接口，也就是 WindPy 通过 ctypes 调用的那一层，所以不需要任何 C/C++ 中间层。另有 `libWAPIWrapperCpp.so` 提供 C++ 类接口，但它导出的是 C++ mangled 符号且参数为 `std::vector<std::string>`，必须写 shim，故未采用。

三个不明显但必须的细节：

1. **`setLongValue(6433, product_type)` 必须在 `start` 之前调用**，否则 `start` 既不返回也不报错，直接卡死。
2. **两个库必须以 `RTLD_LOCAL` 加载**。`libWind.QuantData.so` 和 `libWind.Cosmos.QuantData.so` 导出了同名符号（`start`、`stop`、`free_data`、`isConnectionOK` 等）；用 `RTLD_GLOBAL` 时先加载的会把后者的内部调用符号插入掉，表现为 `wsi` / `wst` 返回 `-103`、实时订阅完全收不到推送，而同步请求看上去一切正常。
3. **不能假设 Wind 返回缓冲区的对齐**。`SafeArray.pvData` 指向的数组未必按元素自然对齐，所有读取都走 `align(1)`。

`wsi` 和 `wst` 由 `libWind.Cosmos.QuantData.so` 提供，并且必须用它自己的 `free_data` 释放。

### COM 后端读数组的方式

数组元素直接按 `SAFEARRAY::pvData` 平铺下标取，`pos = 时间 × 代码数 × 字段数 + 代码 × 字段数 + 字段`，与 Linux 后端同一套布局 —— 这也是 Wind 随包 `WAPIWrapperCpp` 里 `WindDataParser::GetVarFromArray` 的做法。不用 `SafeArrayGetElement`：Wind 的结果是三维的，而它要求每个维度一个下标，传单个 `LONG` 会读越界并取错元素。数据块同样不保证对齐，所有读取走 `align(1)`。

`times` 要减 693960 天：COM 的时间轴数的是自 0001-01-01 起的天数，OLE Automation 日期从 1899-12-30 起算。Wind 自己的 wrapper 就在 `WindData::GetTimeByIndex`（`WAPIWrapperCpp.cpp:58`）这一处做这个换算。

注意这个不对称是 Wind 的：数据单元格里的 `VT_DATE`（比如 `tdaysoffset` 的返回值）本来就是 OLE 日期，wrapper 走 `GetVarFromArray` 读它时不减，所以 `copyValue` 不能碰它。Linux 的 C 接口又是另一回事，它的时间轴本来就是 OLE 日期。三处约定各不相同，都照 Wind 自己的来。

### 使用上的两个坑

- `wsd` 不支持“多代码 + 多字段”同时提取，会返回 `-40522018`
  `CWSDService: multi-codes with multi-indicators is not supported.`。多代码时只取
  一个字段，或多字段时只取一个代码 —— WindPy 走同一个接口，行为完全一样。
- `start` 的 `timeout_ms` 别给太小。WindPy 默认等 120 秒，冷启动的终端确实可能要
  这么久；等待期间失败会报 `-40520008`（超时），容易被误认成权限问题。

### 已知构建问题

Zig 0.16 自带的 ELF 链接器无法处理 gcc 16 的 `crt1.o` 里的 `.sframe` 重定位（`unhandled relocation type R_X86_64_PC64`）。如果本机原生构建报这个错，用 Zig 自带的 glibc 即可：

```bash
zig build -Dtarget=x86_64-linux-gnu.2.39
```
