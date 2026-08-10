# 电量监测 (BatteryMonitor)

KOReader 插件，**由「电量图表」(batterygraph) 与「休眠/唤醒追踪器」(sleepwaketracker) 合并而成**。

一个插件同时提供：

- **电量曲线**：连续电量历史折线图，支持「当前放电周期 / 当前充电周期 / 按天数(30/90/180/365)」多种视图，放电段黑色、充电段灰色。
- **休眠/唤醒记录**：追踪设备休眠(SLEEP)与唤醒(WAKE)时间戳，统计每段的电量消耗、活跃时长与待机时长，并支持 CSV 导入/导出。
- **关于**：合并说明。

## 安装

将 `batterymonitor.koplugin/` 目录放入 KOReader 的 `plugins/` 目录（或 `kd/plugins/`、`koreader/plugins/` 等用户插件路径），重启 KOReader。

> 本插件为**目录形态**的 `.koplugin`，同时兼容 zip 形态打包分发（不再依赖跨插件 `dofile` 加载，消除了旧版在 zip 分发下失效的雷）。

## 使用

主菜单「更多工具 ▸ 电量监测」下：

- **电量曲线**：查看电量折线图（图内左上菜单可切换视图模式、并跳转到休眠/唤醒记录）。
- **休眠/唤醒记录**：今日 / 昨日事件、浏览历史、数据管理（CSV 导出/导入、清除）、关于。

## 数据位置

- 电量曲线历史：`koreader/settings/battery_graph.lua`
- 休眠/唤醒事件日志：`koreader/<data_dir>/sleepwaketracker/all_events.log`（`SLEEP|时间戳|电量` / `WAKE|时间戳|电量`，电量为 `-1` 表示硬件未就绪占位）

## 合并说明（相对于原两插件的变化）

1. **单一插件、单一主菜单**：原两个独立插件各自的 `addToMainMenu` 与全局实例（`_G.BatteryGraphInstance` / `_G.SleepWakeTrackerInstance`）已移除，统一由 `main.lua` 注册「电量监测」菜单并暴露 `_G.BatteryMonitorInstance`。
2. **消除 `dofile` 跨插件雷**：原 sleepwaketracker 用 `dofile(插件目录/graphwidget.lua)` 硬编码路径加载电量图表，在 zip 形态下会失效；现改为进程内 `self._monitor:onShowBatteryGraph()` 委派。
3. **生命周期统一接收**：`onSuspend/onResume/onCharging/onNotCharging/onEnterStandby/onLeaveStandby` 由主插件接收后委派给对应子控制器，逻辑与原插件一致。
4. **模块划分**：
   - `batterygraph_ctrl.lua`：电量采样能力（原 batterygraph 主体，去菜单/全局/Dispatcher 注册）。
   - `sleepwake_ctrl.lua`：休眠/唤醒追踪能力（原 sleepwaketracker 主体，去菜单/全局/Dispatcher 注册，`getMenuSubItems()` 向主插件提供子项）。
   - `graphwidget.lua`：折线图视图（原 graphwidget，跨插件引用改为 `_G.BatteryMonitorInstance`）。
   - `main.lua`：编排器（菜单、生命周期委派、全局实例、Dispatcher 动作）。

## 兼容与回滚

- 合并前原两插件已完整备份至 `Backup/plugins/`。
- 卸载本插件：删除 `batterymonitor.koplugin/` 目录，原两插件数据文件（`settings/battery_graph.lua` 与 `sleepwaketracker/` 日志）可保留或一并清理。
