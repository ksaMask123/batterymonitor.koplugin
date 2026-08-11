-- batterymonitor.koplugin/util.lua
-- 合并插件公共工具库：抽取自 batterygraph_ctrl / sleepwake_ctrl / graphwidget 的重复实现，
-- 供三模块共享 require，杜绝重复加载与逻辑漂移（整改 1.2①②）。
local Device = require("device")
local PowerD = Device:getPowerDevice()
local DataStorage = require("datastorage")
local logger = require("logger")

local util = {}

-- 合并插件统一设置文件（整改 4.2：配置 + 容量历史集中到单个 LuaSettings 文件）。
-- 休眠/唤醒事件日志因体量（append-only，单文件可达 1MB）保留原生 io 单文件，
-- 不并入 LuaSettings —— 否则每次落盘整文件重写会违背「严禁拖慢 KOReader」的硬要求。
util.SETTINGS_FILE = DataStorage:getSettingsDir() .. "/batterymonitor_settings.lua"

-- 合法电量获取（去重自 BatteryGraph:getValidCapacity / SleepWakeTracker:getBatteryLevel）。
-- 纯逻辑、不打印日志：优先 getCapacity（0-100%），不可用时回退 getCapacityHW；
-- 范围外 / 非法 / 硬件未就绪一律返回 nil（调用方负责上下文日志）。
function util.getValidCapacity()
    if not PowerD then return nil end
    local ok, cap = pcall(function()
        if PowerD.getCapacity then
            return PowerD:getCapacity()
        elseif PowerD.getCapacityHW then
            return PowerD:getCapacityHW()
        end
    end)
    cap = ok and tonumber(cap) or nil
    if type(cap) ~= "number" then return nil end
    if cap <= 0 or cap > 100 then return nil end
    return cap
end

-- 历史规范化（去重自 BatteryGraph:normalizeHistory；原 graphwidget 的
-- normalizeHistoryForGraph 行为一致并修正同 ts 排序：充电点优先）。
-- 1) 过滤非法点；2) 按时间排序；3) 合并重复时间；4) 未充电连续放电段抑制电量正向跳变。
function util.normalizeHistory(history)
    history = history or {ts = {}, capacity = {}, is_charging = {}}
    history.ts = history.ts or {}
    history.capacity = history.capacity or {}
    history.is_charging = history.is_charging or {}
    local temp = {}
    for i = 1, #(history.ts or {}) do
        local ts = tonumber(history.ts[i])
        local cap = tonumber(history.capacity and history.capacity[i])
        local charging = history.is_charging and history.is_charging[i] == true or false
        if ts and cap and cap > 0 and cap <= 100 then
            temp[#temp + 1] = {ts = ts, capacity = cap, is_charging = charging}
        end
    end
    table.sort(temp, function(a, b)
        if a.ts == b.ts then
            return (a.is_charging and 1 or 0) < (b.is_charging and 1 or 0)
        end
        return a.ts < b.ts
    end)

    local out = {ts = {}, capacity = {}, is_charging = {}}
    local function push(point)
        local n = #out.ts
        if n > 0 and out.ts[n] == point.ts then
            out.capacity[n] = point.capacity
            out.is_charging[n] = point.is_charging
            return
        end
        if n > 0 and (not point.is_charging) and (out.is_charging[n] == false) and point.capacity > out.capacity[n] then
            logger.dbg("BatteryMonitor: Clamped non-charging battery rebound", point.capacity, "to", out.capacity[n])
            point.capacity = out.capacity[n]
        end
        out.ts[#out.ts + 1] = point.ts
        out.capacity[#out.capacity + 1] = point.capacity
        out.is_charging[#out.is_charging + 1] = point.is_charging
    end
    for _, point in ipairs(temp) do push(point) end
    return out
end

return util
