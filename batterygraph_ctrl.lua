local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local PowerD = require("device"):getPowerDevice()
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")

local BatteryGraph = WidgetContainer:extend{
    name = "batterygraph",
    title = _("电量图表"),
    settings_file = DataStorage:getSettingsDir() .. "/battery_graph.lua",
    min_sample_interval = 300,    -- 基础采样间隔5分钟
    min_new_point_interval = 3600, -- 最少1小时新增1个采样点（保证曲线连续）
    capacity_change_threshold = 1, -- 电量变化阈值1%
    record_count_since_flush = 0,
    flush_every_records = 5,       -- 每5次记录落盘一次（平衡性能与安全）
}

function BatteryGraph:init()


    -- 事件接收说明：本插件作为 UI 子 widget 注册（ui:registerModule），
    -- Suspend/Resume/Charging 事件由 UIManager 事件分发自动送达 onSuspend 等回调。
    -- 旧代码的 UIManager:addEventReceiver / registerReceiver 在本版 KOReader 中
    -- 并不存在（属死代码，每次启动误报 warn），故已删除，无需也无法额外注册。
    logger.info("BatteryGraph: initialized",
        "min_sample_interval=", tostring(self.min_sample_interval),
        "min_new_point_interval=", tostring(self.min_new_point_interval),
        "settings=", tostring(self.settings_file))

    self.settings = LuaSettings:open(self.settings_file)
    self.history = self.settings:readSetting("history") or {ts={}, capacity={}, is_charging={}}

    -- 兼容旧数据格式：尽量迁移旧数组记录，而不是直接清空。
    self.history = self:convertLegacyHistory(self.history)
    self.history = self:normalizeHistory(self.history)
    self:saveHistory(true)





    self:cleanHistory()
    self:recordPoint()
    self:scheduleNextRecord()
end

-- 获取合法电量值（带校验）
function BatteryGraph:getValidCapacity()
    if not PowerD then
        logger.warn("BatteryGraph: PowerD unavailable")
        return nil
    end
    local ok, cap = pcall(function()
        -- 优先 getCapacity（返回 0-100 百分比，语义稳定）；
        -- 仅当其不可用时才回退 getCapacityHW（某些设备返回原始值，>100 会被下方范围检查拒绝）。
        if PowerD.getCapacity then
            return PowerD:getCapacity()
        elseif PowerD.getCapacityHW then
            return PowerD:getCapacityHW()
        end
    end)
    cap = ok and tonumber(cap) or nil
    if type(cap) ~= "number" then
        logger.warn("BatteryGraph: Invalid battery capacity value")
        return nil
    end
    -- Kindle 等设备刚唤醒时偶尔返回 0 或非法值；不要写入历史。
    if cap <= 0 or cap > 100 then
        logger.warn("BatteryGraph: Out-of-range battery capacity:", tostring(cap))
        return nil
    end
    return cap
end

-- 获取合法充电状态
function BatteryGraph:getValidChargingState()
    if not PowerD or not PowerD.isCharging then return false end
    local ok, charging = pcall(function() return PowerD:isCharging() end)
    return ok and charging == true or false
end

function BatteryGraph:convertLegacyHistory(history)
    if not history or not history[1] then
        return history or {ts={}, capacity={}, is_charging={}}
    end
    local out = {ts={}, capacity={}, is_charging={}}
    for _, item in ipairs(history) do
        if type(item) == "table" then
            local ts = tonumber(item.ts or item.timestamp or item.time or item[1])
            local cap = tonumber(item.capacity or item.cap or item.battery or item.level or item[2])
            local charging = item.is_charging
            if charging == nil then charging = item.charging end
            if charging == nil then charging = item[3] end
            if ts and cap then
                out.ts[#out.ts + 1] = ts
                out.capacity[#out.capacity + 1] = cap
                out.is_charging[#out.is_charging + 1] = charging == true
            end
        end
    end
    return out
end

-- 规范化历史数据：
-- 1. 删除非法点；
-- 2. 按时间排序；
-- 3. 合并重复时间；
-- 4. 未充电且连续放电段内，抑制电量正向跳变，避免老设备电量回弹被画成“未充电却上升”。
function BatteryGraph:normalizeHistory(history)
    history = history or {ts={}, capacity={}, is_charging={}}
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
        if a.ts == b.ts then return (a.is_charging and 1 or 0) < (b.is_charging and 1 or 0) end
        return a.ts < b.ts
    end)

    local out = {ts={}, capacity={}, is_charging={}}
    local function push(point)
        local n = #out.ts
        if n > 0 and out.ts[n] == point.ts then
            out.capacity[n] = point.capacity
            out.is_charging[n] = point.is_charging
            return
        end
        if n > 0 and (not point.is_charging) and (out.is_charging[n] == false) and point.capacity > out.capacity[n] then
            logger.dbg("BatteryGraph: Clamped non-charging battery rebound", point.capacity, "to", out.capacity[n])
            point.capacity = out.capacity[n]
        end
        out.ts[#out.ts + 1] = point.ts
        out.capacity[#out.capacity + 1] = point.capacity
        out.is_charging[#out.is_charging + 1] = point.is_charging
    end
    for _, point in ipairs(temp) do push(point) end
    return out
end

function BatteryGraph:appendPoint(ts, capacity, is_charging)
    local history = self.history
    history.ts[#history.ts + 1] = ts
    history.capacity[#history.capacity + 1] = capacity
    history.is_charging[#history.is_charging + 1] = is_charging == true
    self.history = self:normalizeHistory(history)
end

-- 双实例保护（v1.0.2 P1）：把「内存历史 a」与「磁盘历史 b」合并，按 ts 去重。
-- 先并入磁盘历史(b)，再并入内存历史(a)，使本实例尚未落盘的最新点优先胜出。
-- 这样既拾取另一实例（FileManager/Reader）已落盘的点，又不丢失本实例未落盘的点。
function BatteryGraph:mergeHistory(a, b)
    a = self:normalizeHistory(a)
    b = self:normalizeHistory(b)
    local out = {ts = {}, capacity = {}, is_charging = {}}
    for i = 1, #b.ts do
        out.ts[#out.ts + 1] = b.ts[i]
        out.capacity[#out.capacity + 1] = b.capacity[i]
        out.is_charging[#out.is_charging + 1] = b.is_charging[i]
    end
    for i = 1, #a.ts do
        out.ts[#out.ts + 1] = a.ts[i]
        out.capacity[#out.capacity + 1] = a.capacity[i]
        out.is_charging[#out.is_charging + 1] = a.is_charging[i]
    end
    return self:normalizeHistory(out)
end

-- 清理365天前的过期数据（每次记录前轻量检查，每天最多执行一次）
function BatteryGraph:cleanHistory()
    local history = self.history
    if not history.ts or #history.ts == 0 then return end
    
    local last_clean = self.settings:readSetting("last_clean_ts") or 0
    local now = os.time()
    if now - last_clean < 86400 then return end -- 一天最多清理一次

    local cut_off = now - 365 * 24 * 60 * 60
    local new_ts, new_cap, new_charge = {}, {}, {}
    for i = 1, #history.ts do
        if history.ts[i] >= cut_off then
            table.insert(new_ts, history.ts[i])
            table.insert(new_cap, history.capacity[i])
            table.insert(new_charge, history.is_charging[i])
        end
    end

    if #new_ts < #history.ts then
        self.history = {ts = new_ts, capacity = new_cap, is_charging = new_charge}
        self.settings:saveSetting("last_clean_ts", now)
        self:saveHistory(true)
        logger.dbg("BatteryGraph: Cleaned", #history.ts - #new_ts, "expired records")
    else
        self.history = self:normalizeHistory(self.history)
        self.settings:saveSetting("last_clean_ts", now)
        self.settings:saveSetting("history", self.history)
        self.settings:flush()
    end
end

-- 优化后的采样逻辑：1%变化阈值 + 最低1小时1点，保证曲线连续
-- merge_disk：是否先把磁盘历史并入内存（双实例保护）。边界事件传 true；
-- 周期采样传 false，避免每 5 分钟都全量重读+排序（降低 e-ink 自耗电）。
function BatteryGraph:recordPoint(merge_disk)
    merge_disk = (merge_disk ~= false)
    local ts = os.time()
    local capacity = self:getValidCapacity()
    local is_charging = self:getValidChargingState()
    
    if not capacity then
        logger.warn("BatteryGraph: Skip record due to invalid capacity")
        return
    end

    -- 双实例保护（v1.0.2 P1）：FileManager 与 Reader 各自持有独立内存 history，直接 append 写回会
    -- 覆盖对方已落盘的点。仅在边界事件把磁盘历史并入内存（按 ts 合并），再 append；
    -- 周期采样跳过此步（内存 history 已含上次边界合并结果），仅追加本实例新点。
    if merge_disk then
        local tmp = LuaSettings:open(self.settings_file)
        self.history = self:mergeHistory(self.history, tmp:readSetting("history") or {ts = {}, capacity = {}, is_charging = {}})
    end
    local history = self.history
    local count = history.ts and #history.ts or 0

    -- 第一条记录直接插入
    if count == 0 then
        self:appendPoint(ts, capacity, is_charging)
        self:saveHistory(true)
        return
    end

    local last_ts = history.ts[count]
    local last_cap = history.capacity[count]
    local last_charge = history.is_charging[count]

    -- 时间回拨：允许记录，但必须通过 normalizeHistory 排序，不能直接追加到末尾后再按末尾当最大时间绘图。
    if ts < last_ts then
        logger.warn("BatteryGraph: Time went backwards; record will be sorted into history")
    end

    -- 未充电且上一点也未充电时，电量上升通常是电量计回弹/唤醒刷新滞后，不应画成充电上升。
    if (not is_charging) and (last_charge == false) and capacity > last_cap then
        logger.dbg("BatteryGraph: Suppressed non-charging capacity rebound", capacity, "->", last_cap)
        capacity = last_cap
    end

    local cap_changed = math.abs(capacity - last_cap) >= self.capacity_change_threshold
    local state_changed = last_charge ~= is_charging
    local time_elapsed = ts - last_ts
    local need_new_point = time_elapsed >= self.min_new_point_interval

    -- 状态变化必须立即记录
    if state_changed then
        self:appendPoint(ts, capacity, is_charging)
        self:saveHistory(true) -- 状态变化立即落盘，保证数据安全
        logger.dbg("BatteryGraph: New record (state changed) at", os.date("%H:%M:%S", ts))
    -- 电量变化超阈值，新增记录
    elseif cap_changed then
        self:appendPoint(ts, capacity, is_charging)
        self:saveHistory(false)
        logger.dbg("BatteryGraph: New record (capacity changed) at", os.date("%H:%M:%S", ts))
    -- 超过1小时电量没变，新增采样点保证曲线连续
    elseif need_new_point then
        self:appendPoint(ts, capacity, is_charging)
        self:saveHistory(false)
        logger.dbg("BatteryGraph: New record (time interval) at", os.date("%H:%M:%S", ts))
    -- 否则不改写最后一条时间戳。
    -- 原逻辑每 5 分钟刷新最后时间戳，会导致“超过 1 小时新增采样点”永远触发不了。
    else
        logger.dbg("BatteryGraph: Skip record (no meaningful change)")
    end

    -- 定期清理过期数据
    self:cleanHistory()
end

function BatteryGraph:saveHistory(hard_flush)
    self.history = self:normalizeHistory(self.history)
    self.settings:saveSetting("history", self.history)
    self.record_count_since_flush = self.record_count_since_flush + 1

    if hard_flush or self.record_count_since_flush >= self.flush_every_records then
        self.settings:flush()
        self.record_count_since_flush = 0
    end
end

function BatteryGraph:scheduleNextRecord()
    if self.record_task then
        UIManager:unschedule(self.record_task)
    end
    self.record_task = UIManager:scheduleIn(self.min_sample_interval, function()
        self:recordPoint(false) -- 周期采样不合并（降自耗电）
        self:scheduleNextRecord()
    end)
end

function BatteryGraph:onShowBatteryGraph()
    self:recordPoint()
    local view_mode = self.settings:readSetting("view_mode") or "30d"
    local GraphWidget = require("graphwidget")
    UIManager:show(GraphWidget:new{
        history        = self.history,
        view_mode      = view_mode,
        _monitor       = self._monitor,
        on_mode_change = function(mode, period)
            self.settings:saveSetting("view_mode", mode)
            self.settings:flush()
        end,
    })
    return true
end

-- 休眠时强制记录并落盘
function BatteryGraph:onSuspend()
    self:recordPoint()
    self:saveHistory(true)
end

-- 唤醒时立即记录并重启采样；延迟补采样可避开老 Kindle 电量/充电状态刷新滞后。
function BatteryGraph:onResume()
    self:recordPoint()
    UIManager:scheduleIn(5, function() self:recordPoint() end)
    UIManager:scheduleIn(15, function() self:recordPoint() end)
    self:scheduleNextRecord()
end

-- 充电状态变化立即记录（兜底：即使事件收不到，定时采样也能检测到）
function BatteryGraph:onCharging()
    self:recordPoint()
end

function BatteryGraph:onNotCharging()
    self:recordPoint()
end

-- 修改：关闭书籍时清理本实例的循环定时器与全局引用，防止回调持有已销毁实例。
-- Reader 侧实例随书销毁；FileManager 常驻实例不受影响（其数据采样连续性保持不变）。
function BatteryGraph:onCloseDocument()
	if self.record_task then
		UIManager:unschedule(self.record_task)
		self.record_task = nil
	end
	-- 关闭书籍前合并落盘，保住本实例尚未落盘的电量采样点（避免阅读实例被销毁时丢点）
	self:recordPoint(true)
	self:saveHistory(true)
	logger.info("BatteryGraph: cleaned up on close document")
end

return BatteryGraph