# zig-wind

一个面向 Windows x64 的 Zig Wind COM 封装。它直接调用 Wind 终端注册的 `WindDataCOM` Automation 服务

## 前提

- Windows x64；
- Zig 0.16.0；
- Wind 终端及其 `WindDataCOM` COM 组件已在运行机器正确安装、注册，并具有相应数据权限。

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

订阅不在 COM 回调线程中直接执行 Zig 用户回调。COM event sink 只记录 `(state, request_id, error_code)`；调用者在创建 `Wind` 的同一线程反复调用 `poll(allocator)`，由它泵送 STA 消息、读取 `readdata` 并返回 Zig 所有权明确的 `SubscriptionEvent`。这避免了回调重入、线程切换和临时 `VARIANT` 跨边界持有问题。

`SubscriptionEvent.data` 为可选值；收到时由事件持有，必须调用 `event.deinit()`。实时接口目前返回 Wind 推送的**增量数据**，不会自动维护原 C++ wrapper 中可选的 `updateAllFields` 本地快照。

## 使用

```powershell
cd C:\code\zig\zig_wind
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

Wind 业务请求是否成功由 `Data.error_code` 或 `SubscriptionStart.error_code` 表示，`0` 为成功。COM 创建、方法解析、参数封送和 Automation 调用失败会作为 Zig `Error` 返回。

`Data.codes`、`Data.fields` 是 UTF-8 字符串数组；`Data.times` 保存 OLE Automation 日期（`f64`）；`Data.values` 按 `time × code × field` 排列。推荐使用：

```zig
const value = try data.valueAt(time_index, code_index, field_index);
```

`Data` 必须由调用者执行 `deinit()`。`Value.string` 的内存也随其所属 `Data` 一同释放，不应在 `Data.deinit()` 后继续持有。
