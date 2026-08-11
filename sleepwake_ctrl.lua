local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template
local util = require("batterymonitor_util")
local Screen = Device.screen
local PowerD = Device:getPowerDevice()

-- 电量采样误差阈值：单段变化小于此值视为硬件波动，不计入分段充放电统计
local BATTERY_EPSILON = 0.5

-- 电量未知占位值：当硬件后端返回非法值时使用，仅记录时间戳，不参与电量统计
local BATTERY_UNKNOWN = -1

local SleepWakeTracker = WidgetContainer:extend{
    name = "sleepwaketracker",
    is_doc_only = false,
    data_dir = DataStorage:getDataDir() .. "/sleepwaketracker",
    log_file = "all_events.log",
    last_event_type = nil,
    last_event_ts = nil,
    max_log_size = 1024 * 1024,  -- 单文件1MB
    max_backup_count = 3,         -- 保留3份备份
    max_history_days = 365,       -- 最多保留365天数据
    cached_events = nil,          -- 内存缓存，避免频繁读文件
}

function SleepWakeTracker:init()
    logger.dbg("SleepWakeTracker: init")

    
    local success, err = pcall(function()
        self:ensureDataDir()
    end)
    if not success then
        logger.err("SleepWakeTracker: Failed to initialize data directory:", err)
    end
    local ok, err = pcall(function() self:migrateOldLogs() end)
    if not ok then
        logger.err("SleepWakeTracker: Failed to migrate old logs, continuing with new log:", err)
    end
    -- 恢复最后一条事件状态
    local last = self:getLastEvent()
    if last then
        self.last_event_type = last.type
        self.last_event_ts = last.timestamp
    end
    

    

    -- 启动时清理过期数据
    self:cleanOldEvents()
end

function SleepWakeTracker:migrateOldLogs()
    local new_log_path = self:getLogFilePath()
    if lfs.attributes(new_log_path) then
        return
    end
    local old_files = {}
    for entry in lfs.dir(self.data_dir) do
        if entry:match("^%d%d%d%d%-%d%d%-%d%d%.txt$") then
            table.insert(old_files, self.data_dir .. "/" .. entry)
        end
    end
    if #old_files == 0 then return end
    logger.dbg("SleepWakeTracker: Migrating old log files...")
    local all_events = {}
    for _, old_path in ipairs(old_files) do
        local file = io.open(old_path, "r")
        if file then
            local fname = old_path:match("([^/]+)$")
            local date_str = fname:sub(1, 10)
            local year, month, day = date_str:match("(%d+)-(%d+)-(%d+)")
            for line in file:lines() do
                local parts = {}
                for part in line:gmatch("[^|]+") do table.insert(parts, part) end
                if #parts >= 2 then
                    local event_type = parts[1]
                    local time_str = parts[2]
                    local battery = tonumber(parts[3])
                    if not battery or battery <= 0 or battery > 100 then
                        battery = BATTERY_UNKNOWN
                    end
                    local h, m, s = time_str:match("(%d+):(%d+):(%d+)")
                    if h and m and s then
                        local ts = os.time{
                            year = tonumber(year),
                            month = tonumber(month),
                            day = tonumber(day),
                            hour = tonumber(h),
                            min = tonumber(m),
                            sec = tonumber(s)
                        }
                        if ts then
                            table.insert(all_events, {type=event_type, timestamp=ts, battery=battery})
                        end
                    end
                end
            end
            file:close()
            local ok, err = os.rename(old_path, old_path .. ".bak")
            if not ok then
                logger.warn("SleepWakeTracker: Failed to backup old log:", old_path, err)
            end
        end
    end
    if #all_events > 0 then
        table.sort(all_events, function(a,b) return a.timestamp < b.timestamp end)
        local new_file = io.open(new_log_path, "w")
        if new_file then
            for _, ev in ipairs(all_events) do
                new_file:write(ev.type .. "|" .. ev.timestamp .. "|" .. string.format("%.1f", ev.battery) .. "\n")
            end
            new_file:close()
            logger.dbg("SleepWakeTracker: Migrated", #all_events, "events to", new_log_path)
            -- 整改 4.1：迁移成功后删除旧备份文件，避免存储浪费
            for _, old_path in ipairs(old_files) do
                os.remove(old_path .. ".bak")
            end
        end
    end
    -- 整改 2.4：旧日志整读产生的大块临时表，用毕显式释放并主动回收
    all_events = nil
    collectgarbage("collect")
end

function SleepWakeTracker:ensureDataDir()
    local ok, err = lfs.mkdir(self.data_dir)
    if not ok and err ~= "File exists" then
        logger.warn("SleepWakeTracker: Failed to create data directory:", err)
        local attr = lfs.attributes(self.data_dir)
        if not attr then
            error("Cannot create or access data directory: " .. self.data_dir)
        end
    end
end

-- 清理超过最大保留天数的历史数据
function SleepWakeTracker:cleanOldEvents()
    local all = self:readAllEvents()
    if #all == 0 then return end
    local cutoff = os.time() - self.max_history_days * 24 * 3600
    local new_events = {}
    for _, ev in ipairs(all) do
        if ev.timestamp >= cutoff then
            table.insert(new_events, ev)
        end
    end
    if #new_events < #all then
        self:writeAllEvents(new_events)
        logger.dbg("SleepWakeTracker: Cleaned", #all - #new_events, "old events")
    end
    -- 整改 2.4：cleanOldEvents 仅在启动/低频触发，整读的大块 events 表用毕主动回收
    all = nil
    collectgarbage("collect")
end

function SleepWakeTracker:getLogFilePath()
    return self.data_dir .. "/" .. self.log_file
end

-- 获取电量并做合法性校验（去重自 util.getValidCapacity，整改 1.2②）
-- 注意：读不到电量时返回 nil，而不是 0。
-- 0 往往是电源后端尚未就绪/读取失败的占位值，写入日志会造成巨大异常或把真实掉电抵消。
function SleepWakeTracker:getBatteryLevel()
    if not PowerD then
        if not self._battery_warned then
            logger.warn("SleepWakeTracker: PowerD not available, battery level unavailable")
            self._battery_warned = true
        end
        return nil
    end
    local cap = util.getValidCapacity()
    -- KOReader/设备刚唤醒时偶尔会返回 0 或非法值；不要把它当作真实电量落盘。
    if cap == nil then
        logger.warn("SleepWakeTracker: Invalid battery reading:", tostring(cap))
        return nil
    end
    return cap
end

-- 日志轮转：保留多份备份
function SleepWakeTracker:rotateLogIfNeeded()
    local filepath = self:getLogFilePath()
    local attr = lfs.attributes(filepath)
    if not attr or attr.size <= self.max_log_size then
        return
    end
    logger.dbg("SleepWakeTracker: Log file size exceeds limit, rotating...")
    
    for i = self.max_backup_count, 1, -1 do
        local bak_path = filepath .. ".bak." .. i
        if i == self.max_backup_count then
            os.remove(bak_path)
        else
            local next_path = filepath .. ".bak." .. (i + 1)
            if lfs.attributes(bak_path) then
                os.rename(bak_path, next_path)
            end
        end
    end
    os.rename(filepath, filepath .. ".bak.1")
    local new_file = io.open(filepath, "w")
    if new_file then
        new_file:close()
        logger.dbg("SleepWakeTracker: Log rotated successfully")
    else
        logger.err("SleepWakeTracker: Failed to create new log file after rotation")
    end
end

-- 更新最后一条事件的电量（优化版：仅读写文件尾部，不全量解析）
function SleepWakeTracker:updateLastEventBattery(event_type, battery)
    if not battery then return false end
    -- 置空缓存，确保多实例场景下从文件读取最新数据
    self.cached_events = nil

    local filepath = self:getLogFilePath()
    if not lfs.attributes(filepath) then return false end

    local file = io.open(filepath, "r")
    if not file then return false end
    local content = file:read("*a")
    file:close()
    if not content or #content == 0 then return false end

    -- 去掉末尾换行，找到最后一个换行符以定位最后一行
    local trimmed = content:gsub("\n+$", "")
    if #trimmed == 0 then return false end
    local last_nl = trimmed:reverse():find("\n", 1, true)
    local prefix, last_line
    if last_nl then
        local cut = #trimmed - last_nl
        prefix = trimmed:sub(1, cut)
        last_line = trimmed:sub(cut + 1)
    else
        prefix = ""
        last_line = trimmed
    end

    local parts = {}
    for part in last_line:gmatch("[^|]+") do table.insert(parts, part) end
    if #parts < 3 then return false end
    if parts[1] ~= event_type then return false end
    local old_bat = tonumber(parts[3])
    if old_bat and old_bat ~= BATTERY_UNKNOWN and math.abs(old_bat - battery) < 0.05 then
        return false
    end

    -- 仅替换最后一行，保留其余内容不变
    local new_line = event_type .. "|" .. parts[2] .. "|" .. string.format("%.1f", battery) .. "\n"
    local out = io.open(filepath, "w")
    if not out then return false end
    if #prefix > 0 then
        out:write(prefix)
        out:write("\n")
    end
    out:write(new_line)
    out:close()

    self.cached_events = nil
    logger.dbg("SleepWakeTracker: Updated last", event_type, "battery from", tostring(old_bat), "to", battery)
    return true
end

-- 记录事件：即使电量不可用也记录时间戳（电量用 BATTERY_UNKNOWN 占位）
function SleepWakeTracker:logEvent(event_type)
    self:rotateLogIfNeeded()
    local ts = os.time()
    local battery = self:getBatteryLevel()
    local filepath = self:getLogFilePath()

    -- 连续相同事件不再简单丢弃：如果后一次采样电量更准确，就更新最后一条事件的电量。
    local last = self:getLastEvent()
    if last and last.type == event_type then
        logger.dbg("SleepWakeTracker: Consecutive " .. event_type .. " event, updating last battery if changed")
        if battery then
            self:updateLastEventBattery(event_type, battery)
        end
        return true
    end
    -- 时间回拨防护
    if last and ts < last.timestamp then
        logger.warn("SleepWakeTracker: Time went backwards, last:", last.timestamp, "current:", ts)
    end

    -- 电量不可用时使用占位值，确保时间戳不丢失
    local bat_value = battery or BATTERY_UNKNOWN

    local file, err = io.open(filepath, "a")
    if not file then
        logger.err("SleepWakeTracker: Failed to open log file for writing:", err)
        return false
    end
    file:write(event_type .. "|" .. ts .. "|" .. string.format("%.1f", bat_value) .. "\n")
    file:close()
    
    self.last_event_type = event_type
    self.last_event_ts = ts
    self.cached_events = nil
    
    logger.dbg("SleepWakeTracker: Logged", event_type, "at", os.date("%H:%M:%S", ts), "bat:", bat_value)
    return true
end

function SleepWakeTracker:getLastEvent()
    local filepath = self:getLogFilePath()
    if not lfs.attributes(filepath) then
        return nil
    end
    local file = io.open(filepath, "r")
    if not file then return nil end
    file:seek("end")
    local last_line = ""
    local chunk_size = 1024
    local pos = file:seek()
    while pos > 0 do
        local start = math.max(0, pos - chunk_size)
        file:seek("set", start)
        local data = file:read("*all")
        file:seek("set", start)
        local lines = {}
        for line in data:gmatch("[^\n]*") do
            if line ~= "" then table.insert(lines, line) end
        end
        if #lines > 0 then
            last_line = lines[#lines]
            break
        end
        pos = start
        if pos == 0 then break end
    end
    file:close()
    if last_line == "" then return nil end
    local parts = {}
    for part in last_line:gmatch("[^|]+") do table.insert(parts, part) end
    if #parts < 3 then return nil end
    return {
        type = parts[1],
        timestamp = tonumber(parts[2]),
        battery = tonumber(parts[3]),
    }
end

-- 重新从日志文件恢复最后一条事件状态（导入/覆盖数据后调用，使后续真实事件去重正确）
function SleepWakeTracker:reloadLastEvent()
    local last = self:getLastEvent()
    if last then
        self.last_event_type = last.type
        self.last_event_ts = last.timestamp
    else
        self.last_event_type = nil
        self.last_event_ts = nil
    end
end

-- 读取全量事件（带缓存+损坏容错）
function SleepWakeTracker:readAllEvents()
    if self.cached_events then
        return self.cached_events
    end
    local filepath = self:getLogFilePath()
    local events = {}
    local file, err = io.open(filepath, "r")
    if not file then
        logger.warn("SleepWakeTracker: Cannot read log file:", err)
        self.cached_events = events
        return events
    end
    local line_num = 0
    local has_error = false
    for line in file:lines() do
        line_num = line_num + 1
        local parts = {}
        for part in line:gmatch("[^|]+") do table.insert(parts, part) end
        if #parts >= 3 then
            local ts = tonumber(parts[2])
            local bat = tonumber(parts[3])
            if ts and bat and bat >= BATTERY_UNKNOWN and bat <= 100 then
                table.insert(events, {
                    type = parts[1],
                    timestamp = ts,
                    battery = bat,
                })
            else
                has_error = true
                logger.warn("SleepWakeTracker: Invalid data at line", line_num)
            end
        else
            has_error = true
            logger.warn("SleepWakeTracker: Malformed line", line_num, ":", line)
        end
    end
    file:close()
    if has_error then
        logger.warn("SleepWakeTracker: Log file has corrupted lines, cleaning up")
        self:writeAllEvents(events)
    end
    table.sort(events, function(a, b) return a.timestamp < b.timestamp end)
    self.cached_events = events
    return events
end

-- 判断电量是否为有效采样值（非未知占位）
local function isValidBattery(bat)
    return bat ~= nil and bat >= 0 and bat <= 100
end

-- 安全计算电量差：仅当两端电量均有效时返回差值，否则返回 nil
local function safeBatteryDrain(bat_start, bat_end)
    if isValidBattery(bat_start) and isValidBattery(bat_end) then
        return bat_start - bat_end
    end
    return nil
end

-- 核心统计函数：首尾校准 + 阈值过滤 + 符号统一
function SleepWakeTracker:formatEventsForDisplay(all_events, date_str)
    local cycles = {}
    local total_active = 0
    local total_sleep = 0
    local active_drain = 0.0
    local sleep_drain = 0.0
    local active_charge = 0.0
    local sleep_charge = 0.0
    -- 分段带符号净变化（end-start 的累加），使“分段净变化之和”与全天首尾校准值对齐
    local active_net_signed = 0.0
    local sleep_net_signed = 0.0

    local start_ts = os.time{
        year = tonumber(date_str:sub(1,4)),
        month = tonumber(date_str:sub(6,7)),
        day = tonumber(date_str:sub(9,10)),
        hour = 0, min = 0, sec = 0
    }
    local end_ts = start_ts + 86400 - 1
    local now = os.time()
    local is_today = os.date("%Y-%m-%d", now) == date_str

    -- 找到当日开始前的最后一个事件
    local prev_event = nil
    for _, ev in ipairs(all_events) do
        if ev.timestamp < start_ts then
            prev_event = ev
        else
            break
        end
    end

    -- 提取当日所有事件，并记录次日第一条事件用于跨日段闭合
    local day_events = {}
    local next_event = nil
    for _, ev in ipairs(all_events) do
        if ev.timestamp >= start_ts and ev.timestamp <= end_ts then
            table.insert(day_events, ev)
        elseif ev.timestamp > end_ts and not next_event then
            next_event = ev
        end
    end

    -- 内部工具：按误差阈值计入充放电；同时累加带符号净变化（net = end - start = -drain）
    local function addDrainToStats(drain, is_active)
        if drain > BATTERY_EPSILON then
            if is_active then active_drain = active_drain + drain; active_net_signed = active_net_signed - drain
            else sleep_drain = sleep_drain + drain; sleep_net_signed = sleep_net_signed - drain end
        elseif drain < -BATTERY_EPSILON then
            local charge_val = math.abs(drain)
            if is_active then active_charge = active_charge + charge_val; active_net_signed = active_net_signed + charge_val
            else sleep_charge = sleep_charge + charge_val; sleep_net_signed = sleep_net_signed + charge_val end
        end
    end

    -- 处理跨天初始段
    if prev_event then
        local segment_start = start_ts
        local first_event = #day_events > 0 and day_events[1] or nil
        local segment_end = first_event and first_event.timestamp or (is_today and now or end_ts)
        local duration = segment_end - segment_start
        -- 仅当两端电量均有效时才计算电量差
        local drain = nil
        if first_event
            and ((prev_event.type == "WAKE" and first_event.type == "SLEEP")
              or (prev_event.type == "SLEEP" and first_event.type == "WAKE"))
        then
            drain = safeBatteryDrain(prev_event.battery, first_event.battery)
        end
        if prev_event.type == "WAKE" then
            table.insert(cycles, {
                type = "ACTIVE_CROSSDAY_START",
                start_time = segment_start,
                end_time = segment_end,
                duration = duration,
                drain = drain,
            })
            total_active = total_active + duration
            if drain then addDrainToStats(drain, true) end
        else
            table.insert(cycles, {
                type = "SLEEPING_CROSSDAY_START",
                start_time = segment_start,
                end_time = segment_end,
                duration = duration,
                drain = drain,
            })
            total_sleep = total_sleep + duration
            if drain then addDrainToStats(drain, false) end
        end
    end

    -- 预计算“下一个 SLEEP/WAKE”索引（一次 O(n) 反向扫描），避免逐事件嵌套扫描 O(n^2)
    local next_sleep = {}
    local next_wake = {}
    local last_sleep, last_wake = nil, nil
    for k = #day_events, 1, -1 do
        if day_events[k].type == "SLEEP" then
            last_sleep = k
        elseif day_events[k].type == "WAKE" then
            last_wake = k
        end
        next_sleep[k] = last_sleep
        next_wake[k] = last_wake
    end

    -- 活跃段统计（WAKE → SLEEP）
    for i, ev in ipairs(day_events) do
        if ev.type == "WAKE" then
            local j = next_sleep[i]
            if j then
                local sleep = day_events[j]
                local duration = sleep.timestamp - ev.timestamp
                local drain = safeBatteryDrain(ev.battery, sleep.battery)
                table.insert(cycles, {
                    type = "ACTIVE",
                    start_time = ev.timestamp,
                    end_time = sleep.timestamp,
                    duration = duration,
                    drain = drain,
                })
                total_active = total_active + duration
                if drain then addDrainToStats(drain, true) end
            else
                local end_time = is_today and now or end_ts
                local duration = end_time - ev.timestamp
                local cur_bat = is_today and self:getBatteryLevel() or nil
                if (not is_today) and next_event and next_event.type == "SLEEP" then
                    cur_bat = next_event.battery
                end
                local drain = safeBatteryDrain(ev.battery, cur_bat)
                table.insert(cycles, {
                    type = is_today and "ACTIVE_UNCLOSED_TODAY" or "ACTIVE_UNCLOSED_PAST",
                    start_time = ev.timestamp,
                    end_time = nil,
                    duration = duration,
                    drain = drain,
                })
                total_active = total_active + duration
                if drain then
                    addDrainToStats(drain, true)
                end
            end
        end
    end

    -- 休眠段统计（SLEEP → WAKE）
    for i, ev in ipairs(day_events) do
        if ev.type == "SLEEP" then
            local j = next_wake[i]
            if j then
                local wake = day_events[j]
                local duration = wake.timestamp - ev.timestamp
                local drain = safeBatteryDrain(ev.battery, wake.battery)
                local is_abnormal = duration < 60
                table.insert(cycles, {
                    type = "SLEEPING",
                    start_time = ev.timestamp,
                    end_time = wake.timestamp,
                    duration = duration,
                    drain = drain,
                    abnormal = is_abnormal,
                })
                total_sleep = total_sleep + duration
                if drain then addDrainToStats(drain, false) end
            else
                local end_time = is_today and now or end_ts
                local duration = end_time - ev.timestamp
                local cur_bat = is_today and self:getBatteryLevel() or nil
                if (not is_today) and next_event and next_event.type == "WAKE" then
                    cur_bat = next_event.battery
                end
                local drain = safeBatteryDrain(ev.battery, cur_bat)
                table.insert(cycles, {
                    type = is_today and "SLEEPING_UNCLOSED_TODAY" or "SLEEPING_UNCLOSED_PAST",
                    start_time = ev.timestamp,
                    end_time = nil,
                    duration = duration,
                    drain = drain,
                })
                total_sleep = total_sleep + duration
                if drain then
                    addDrainToStats(drain, false)
                end
            end
        end
    end

    -- ========== 日终首尾校准：全天净变化以首尾电量为准，彻底消除累加误差 ==========
    local total_time = total_active + total_sleep
    local total_net_change = 0
    local avg_drain_rate = 0
    local estimated_remaining = "--"

    if #day_events > 0 then
        local day_start_bat = day_events[1].battery
        local day_end_bat = day_events[#day_events].battery
        -- 今日未闭合状态用实时电量作为终点
        if is_today then
            local last_type = day_events[#day_events].type
            if last_type == "WAKE" or last_type == "SLEEP" then
                local live_bat = self:getBatteryLevel()
                if live_bat then
                    day_end_bat = live_bat
                end
            end
        end
        -- 仅当首尾电量均有效时才计算净变化
        if isValidBattery(day_start_bat) and isValidBattery(day_end_bat) then
            total_net_change = day_end_bat - day_start_bat

            -- 平均耗电率仅在净耗电时计算
            if total_time > 300 and total_net_change < 0 then
                local net_drain = math.abs(total_net_change)
                avg_drain_rate = (net_drain / total_time) * 3600
                local current_bat = self:getBatteryLevel()
                if current_bat and current_bat > 0 and avg_drain_rate > 0 then
                    local hours = current_bat / avg_drain_rate
                    local h = math.floor(hours)
                    local m = math.floor((hours - h) * 60)
                    estimated_remaining = h .. "时" .. m .. "分"
                end
            end
        else
            total_net_change = 0
            estimated_remaining = "--"
        end
    end

    -- 分段净变化：用带符号累加值（与各分段电量差之和一致），与下方“总计净变化（首尾校准）”口径对齐
    local active_net_change = active_net_signed
    local sleep_net_change = sleep_net_signed

    -- 活跃/休眠每小时平均耗电：只统计真实放电量，不用充电抵消，避免边充边用时误导。
    local active_drain_rate = 0
    local sleep_drain_rate = 0
    if total_active > 0 and active_drain > BATTERY_EPSILON then
        active_drain_rate = (active_drain / total_active) * 3600
    end
    if total_sleep > 0 and sleep_drain > BATTERY_EPSILON then
        sleep_drain_rate = (sleep_drain / total_sleep) * 3600
    end

    -- 构建显示列表
    local items = {}
    table.insert(items, { text = T(_("事件日期：%1"), date_str), bold = true })
    
    table.insert(items, { 
        text = T(_("总活跃时间：%1  净电量变化：%2%"), 
            self:secondsToDuration(total_active), 
            string.format("%+.1f", active_net_change)), 
        bold = true 
    })
    table.insert(items, { 
        text = T(_("总休眠时间：%1  净电量变化：%2%"), 
            self:secondsToDuration(total_sleep), 
            string.format("%+.1f", sleep_net_change)), 
        bold = true 
    })
    table.insert(items, {
        text = T(_("活跃平均耗电：%1%/小时  休眠平均耗电：%2%/小时"),
            string.format("%.2f", active_drain_rate),
            string.format("%.2f", sleep_drain_rate)),
        bold = true
    })
    table.insert(items, { 
        text = T(_("总计时间：%1  净电量变化：%2%（首尾校准）"), 
            self:secondsToDuration(total_time), 
            string.format("%+.1f", total_net_change)), 
        bold = true 
    })
    
    if avg_drain_rate > 0 then
        table.insert(items, { 
            text = T(_("平均耗电率：%1%/小时  预计剩余：%2"), 
                string.format("%.2f", avg_drain_rate), 
                estimated_remaining) 
        })
    end
    
    table.insert(items, { text = "-------------------------", keep_menu_open = true })

    -- 按时间倒序排列周期
    table.sort(cycles, function(a, b) return a.start_time > b.start_time end)
    
    for _, c in ipairs(cycles) do
        local start_t = os.date("%H:%M:%S", c.start_time)
        local line
        local drain_str
        if c.drain == nil then
            drain_str = "电量跨日累计"
        else
            drain_str = c.drain >= 0 and string.format("-%.1f%%", c.drain) or string.format("+%.1f%%", math.abs(c.drain))
        end
        local abnormal_tag = c.abnormal and " [异常]" or ""

        if c.type == "ACTIVE" then
            local end_t = os.date("%H:%M:%S", c.end_time)
            local dur = self:secondsToDuration(c.duration)
            line = T("唤醒于 %1 → 休眠于 %2 (%3) [%4]", start_t, end_t, dur, drain_str)
        elseif c.type == "ACTIVE_CROSSDAY_START" then
            local end_t = os.date("%H:%M:%S", c.end_time)
            local dur = self:secondsToDuration(c.duration)
            line = T("跨日活跃 → %1 结束 (%2) [%3]", end_t, dur, drain_str)
        elseif c.type == "ACTIVE_UNCLOSED_TODAY" then
            local dur = self:secondsToDuration(c.duration)
            line = T("唤醒于 %1 → 至今 (%2) [%3]", start_t, dur, drain_str)
        elseif c.type == "ACTIVE_UNCLOSED_PAST" then
            local dur = self:secondsToDuration(c.duration)
            line = T("唤醒于 %1 → 跨日 (%2) [耗电未知]", start_t, dur)
        elseif c.type == "SLEEPING" then
            local end_t = os.date("%H:%M:%S", c.end_time)
            local dur = self:secondsToDuration(c.duration)
            line = T("休眠于 %1 → 唤醒于 %2 (%3) [%4]%5", start_t, end_t, dur, drain_str, abnormal_tag)
        elseif c.type == "SLEEPING_CROSSDAY_START" then
            local end_t = os.date("%H:%M:%S", c.end_time)
            local dur = self:secondsToDuration(c.duration)
            line = T("跨日休眠 → %1 结束 (%2) [%3]", end_t, dur, drain_str)
        elseif c.type == "SLEEPING_UNCLOSED_TODAY" then
            local dur = self:secondsToDuration(c.duration)
            line = T("休眠于 %1 → 至今 (%2) [%3]", start_t, dur, drain_str)
        elseif c.type == "SLEEPING_UNCLOSED_PAST" then
            local dur = self:secondsToDuration(c.duration)
            line = T("休眠于 %1 → 跨日 (%2) [耗电未知]", start_t, dur)
        end
        -- 周期详情行仅展示，点击不关闭菜单
        table.insert(items, { text = line, keep_menu_open = true })
    end

    if #cycles == 0 then
        table.insert(items, { text = _("该日期无完整周期"), keep_menu_open = true })
    end
    return items
end

function SleepWakeTracker:secondsToDuration(seconds)
    -- 时间回拨或跨日计算异常时可能出现负时长，钳到 0（负时长无意义）
    if seconds < 0 then seconds = 0 end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    local parts = {}
    if h > 0 then table.insert(parts, h .. "时") end
    if m > 0 then table.insert(parts, m .. "分") end
    if s > 0 or #parts == 0 then table.insert(parts, s .. "秒") end
    return table.concat(parts, " ")
end

function SleepWakeTracker:showEventsForDate(date_str)
    local all_events = self:readAllEvents()
    local items = self:formatEventsForDisplay(all_events, date_str)

    -- 先声明 menu 变量，确保闭包能正确捕获局部引用（而非全局 nil）
    local menu

    -- 插入电量图表跳转入口（直接加载电量图表插件，避免 broadcastEvent 不可靠）
    table.insert(items, 2, {
        text = _("查看电量图表"),
        callback = function()
            if menu then
                UIManager:close(menu)
            end
            UIManager:scheduleIn(0.15, function()
                self:openBatteryGraph()
            end)
        end
    })
    table.insert(items, 3, { text = "", keep_menu_open = true, separator = true })
    menu = Menu:new{
        title = _("休眠/唤醒事件"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

-- 直接打开电量图表插件（绕过不可靠的 UIManager:broadcastEvent 跨插件通信）
-- 直接打开电量图表（合并后由主插件进程内提供，无需 dofile 跨插件加载，
-- 消除 zip 形态下路径不存在而静默失效的雷）
function SleepWakeTracker:openBatteryGraph()
	if self._monitor and self._monitor.onShowBatteryGraph then
		self._monitor:onShowBatteryGraph()
	else
		UIManager:show(InfoMessage:new{
			text = _("电量图表模块不可用")
		})
	end
end

function SleepWakeTracker:onShowSleepWakeToday()
    local today = os.date("%Y-%m-%d")
    self:showEventsForDate(today)
    return true
end

function SleepWakeTracker:onShowSleepWakeYesterday()
    local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
    self:showEventsForDate(yesterday)
    return true
end

function SleepWakeTracker:showYearSelector()
    local dates = self:getAvailableDates()
    local current_year = os.date("%Y")
    local years = {}
    local seen_years = {}
    for _, date in ipairs(dates) do
        local y = date:match("^(%d+)")
        if y and not seen_years[y] then
            seen_years[y] = true
            table.insert(years, y)
        end
    end
    table.sort(years, function(a, b) return a > b end)
    local items = {}
    table.insert(items, { text = T(_("今日"), current_year), bold = true,
        callback = function() self:onShowSleepWakeToday() end })
    table.insert(items, { text = T(_("昨日"), current_year),
        callback = function() self:onShowSleepWakeYesterday() end })
    table.insert(items, { text = "", keep_menu_open = true, separator = true })
    table.insert(items, { text = T(_("当前年份（%1）"), current_year), bold = true,
        callback = function() self:showMonthSelector(current_year) end })
    table.insert(items, { text = "", keep_menu_open = true, separator = true })
    if #years == 0 then
        table.insert(items, { text = _("未找到数据"), enabled = false })
    else
        for _, year in ipairs(years) do
            if year ~= current_year then
                table.insert(items, { text = year, callback = function() self:showMonthSelector(year) end })
            end
        end
    end
    UIManager:show(Menu:new{ title = _("选择年份"), item_table = items, is_borderless = true })
end

function SleepWakeTracker:showMonthSelector(year)
    local dates = self:getAvailableDates()
    local months = {}
    local seen_months = {}
    for _, date in ipairs(dates) do
        local y, m = date:match("^(%d+)-(%d+)")
        if y == year and not seen_months[m] then
            seen_months[m] = true
            table.insert(months, m)
        end
    end
    table.sort(months, function(a, b) return a > b end)
    local items = {}
    local month_names = {
        ["01"]="一月",["02"]="二月",["03"]="三月",["04"]="四月",
        ["05"]="五月",["06"]="六月",["07"]="七月",["08"]="八月",
        ["09"]="九月",["10"]="十月",["11"]="十一月",["12"]="十二月"
    }
    for _, month in ipairs(months) do
        table.insert(items, { text = T("%1（%2）", month_names[month] or month, month),
            callback = function() self:showDaySelector(year, month) end })
    end
    UIManager:show(Menu:new{ title = T(_("选择月份（%1）"), year), item_table = items, is_borderless = true })
end

function SleepWakeTracker:showDaySelector(year, month)
    local dates = self:getAvailableDates()
    local days = {}
    for _, date in ipairs(dates) do
        local y, m = date:match("^(%d+)-(%d+)")
        if y == year and m == month then
            table.insert(days, date)
        end
    end
    local items = {}
    for _, date_str in ipairs(days) do
        local events = self:readEventsForDate(date_str)
        local wake_count = 0
        for _, e in ipairs(events) do if e.type == "WAKE" then wake_count = wake_count + 1 end end
        table.insert(items, { text = T("%1（唤醒%2）", date_str, wake_count),
            callback = function() self:showEventsForDate(date_str) end })
    end
    UIManager:show(Menu:new{ title = T(_("选择日期（%1-%2）"), year, month), item_table = items, is_borderless = true })
end

function SleepWakeTracker:readEventsForDate(date_str)
    local all = self:readAllEvents()
    local filtered = {}
    local start_ts = os.time{year=tonumber(date_str:sub(1,4)), month=tonumber(date_str:sub(6,7)), day=tonumber(date_str:sub(9,10)), hour=0, min=0, sec=0}
    local end_ts = start_ts + 86400 - 1
    for _, ev in ipairs(all) do
        if ev.timestamp >= start_ts and ev.timestamp <= end_ts then
            table.insert(filtered, ev)
        end
    end
    return filtered
end

function SleepWakeTracker:getAvailableDates()
    local all = self:readAllEvents()
    local date_set = {}
    for _, ev in ipairs(all) do
        local d = os.date("%Y-%m-%d", ev.timestamp)
        date_set[d] = true
    end
    local dates = {}
    for d in pairs(date_set) do table.insert(dates, d) end
    table.sort(dates, function(a, b) return a > b end)
    return dates
end

function SleepWakeTracker:confirmClearToday()
    local today = os.date("%Y-%m-%d")
    local all = self:readAllEvents()
    local start_ts = os.time{
        year = tonumber(today:sub(1,4)),
        month = tonumber(today:sub(6,7)),
        day = tonumber(today:sub(9,10)),
        hour = 0, min = 0, sec = 0
    }
    local end_ts = start_ts + 86400 - 1
    local new_all = {}
    for _, ev in ipairs(all) do
        if ev.timestamp < start_ts or ev.timestamp > end_ts then
            table.insert(new_all, ev)
        end
    end
    self:writeAllEvents(new_all)
    self:reloadLastEvent()
    UIManager:show(InfoMessage:new{text = _("已删除今日日志。"), timeout = 2})
end

function SleepWakeTracker:confirmClearAll()
    UIManager:show(ConfirmBox:new{
        text = _("警告：确定要删除所有历史记录吗？此操作不可撤销！"),
        ok_text = _("删除全部"),
        cancel_text = _("取消"),
        ok_callback = function()
            os.remove(self:getLogFilePath())
            for i = 1, self.max_backup_count do
                os.remove(self:getLogFilePath() .. ".bak." .. i)
            end
            os.remove(self:getLogFilePath() .. ".bak")
            self.last_event_type = nil
            self.last_event_ts = nil
            self.cached_events = nil
            -- 整改 2.4：清除全部为低频用户操作，大块缓存用毕主动回收
            collectgarbage("collect")
            UIManager:show(InfoMessage:new{text = _("所有历史已删除。"), timeout = 2})
        end
    })
end

function SleepWakeTracker:writeAllEvents(events)
    local filepath = self:getLogFilePath()
    local file, err = io.open(filepath, "w")
    if not file then
        logger.err("SleepWakeTracker: Failed to write events:", err)
        return
    end
    table.sort(events, function(a,b) return a.timestamp < b.timestamp end)
    for _, ev in ipairs(events) do
        file:write(ev.type .. "|" .. ev.timestamp .. "|" .. string.format("%.1f", ev.battery) .. "\n")
    end
    file:close()
    self.cached_events = nil
end

function SleepWakeTracker:getDeviceRoot()
    -- Kindle 优先：KPW 系列使用 /mnt/us，避免在 Kobo 路径不存在时做无效探测
    local candidates = {
        "/mnt/us", "/mnt/onboard", "/mnt/ext1", "/sdcard"
    }
    for _, path in ipairs(candidates) do
        if lfs.attributes(path, "mode") == "directory" then
            return path
        end
    end
    return DataStorage:getDataDir()
end

function SleepWakeTracker:getExportPath()
    return self:getDeviceRoot() .. "/.sleepwaketracker_export.csv"
end

function SleepWakeTracker:exportToCSV()
    local csv_path = self:getExportPath()
    local all = self:readAllEvents()
    local file, err = io.open(csv_path, "w")
    if not file then
        UIManager:show(InfoMessage:new{text = T(_("导出失败：%1"), err), timeout = 3})
        return
    end
    file:write("日期,时间,事件,电量\n")
    local count = 0
    for _, ev in ipairs(all) do
        local date_str = os.date("%Y-%m-%d", ev.timestamp)
        local time_str = os.date("%H:%M:%S", ev.timestamp)
        local bat_str = isValidBattery(ev.battery) and string.format("%.1f", ev.battery) or ""
        file:write(string.format("%s,%s,%s,%s\n", date_str, time_str, ev.type, bat_str))
        count = count + 1
    end
    file:close()
    -- 整改 2.4：导出为低频用户操作，整读的大块 events 表用毕主动回收
    all = nil
    collectgarbage("collect")
    UIManager:show(InfoMessage:new{text = T(_("已导出 %1 条事件到隐藏文件：\n%2"), count, csv_path), timeout = 5})
end

-- CSV 导入时安全解析电量：缺失或非法值返回 nil（不回退为 0）
local function safeParseBattery(bat_str)
    if not bat_str or bat_str == "" then return nil end
    local val = tonumber(bat_str)
    -- 0 与负值均为无效读数（设备刚唤醒常返回 0），与 BATTERY_UNKNOWN(-1) 一并拒绝，避免污染统计
    if not val or val <= 0 or val > 100 then return nil end
    return val
end

function SleepWakeTracker:importFromCSVAppend()
    local csv_path = self:getExportPath()
    if not lfs.attributes(csv_path) then
        UIManager:show(InfoMessage:new{text = T(_("未找到文件：\n%1\n\n请将 .sleepwaketracker_export.csv 放在根目录。"), csv_path), timeout = 5})
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("此操作将把 CSV 内容追加到现有数据中（自动去重），确定继续吗？"),
        ok_text = _("追加"),
        cancel_text = _("取消"),
        ok_callback = function()
            local file, err = io.open(csv_path, "r")
            if not file then
                UIManager:show(InfoMessage:new{text = T(_("导入失败：%1"), err), timeout = 3})
                return
            end
            local existing = self:readAllEvents()
            local seen = {}
            for _, ev in ipairs(existing) do
                seen[ev.type .. "|" .. ev.timestamp] = true
            end
            local count = 0
            local first_line = file:read("*l")
            if not first_line or not first_line:match("日期,时间,事件") then
                file:seek("set")
            end
            for line in file:lines() do
                local date_str, time, event_type, bat = line:match("([^,]+),([^,]+),([^,]+),?([^,]*)")
                if date_str and time and event_type then
                    local ts = os.time{
                        year = tonumber(date_str:sub(1,4)),
                        month = tonumber(date_str:sub(6,7)),
                        day = tonumber(date_str:sub(9,10)),
                        hour = tonumber(time:sub(1,2)),
                        min = tonumber(time:sub(4,5)),
                        sec = tonumber(time:sub(7,8))
                    }
                    local key = event_type .. "|" .. ts
                    if ts and not seen[key] then
                        local battery = safeParseBattery(bat)
                        if battery then
                            table.insert(existing, {type=event_type, timestamp=ts, battery=battery})
                            seen[key] = true
                            count = count + 1
                        end
                    end
                end
            end
            file:close()
            if count > 0 then
                self:writeAllEvents(existing)
                self:reloadLastEvent()
                UIManager:show(InfoMessage:new{text = T(_("已追加 %1 条新事件。"), count), timeout = 3})
            else
                UIManager:show(InfoMessage:new{text = _("没有可追加的新事件。"), timeout = 3})
            end
        end
    })
end

function SleepWakeTracker:importFromDefaultCSV()
    local csv_path = self:getExportPath()
    if not lfs.attributes(csv_path) then
        UIManager:show(InfoMessage:new{text = T(_("未找到文件：\n%1\n\n请将 .sleepwaketracker_export.csv 放在根目录。"), csv_path), timeout = 5})
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("此操作将用 CSV 文件内容替换所有现有数据，确定继续吗？"),
        ok_text = _("覆盖"),
        cancel_text = _("取消"),
        ok_callback = function()
            local file, err = io.open(csv_path, "r")
            if not file then
                UIManager:show(InfoMessage:new{text = T(_("导入失败：%1"), err), timeout = 3})
                return
            end
            local new_events = {}
            local count = 0
            local first_line = file:read("*l")
            if not first_line or not first_line:match("日期,时间,事件") then
                file:seek("set")
            end
            for line in file:lines() do
                local date_str, time, event_type, bat = line:match("([^,]+),([^,]+),([^,]+),?([^,]*)")
                if date_str and time and event_type then
                    local ts = os.time{
                        year = tonumber(date_str:sub(1,4)),
                        month = tonumber(date_str:sub(6,7)),
                        day = tonumber(date_str:sub(9,10)),
                        hour = tonumber(time:sub(1,2)),
                        min = tonumber(time:sub(4,5)),
                        sec = tonumber(time:sub(7,8))
                    }
                    if ts then
                        local battery = safeParseBattery(bat)
                        if battery then
                            table.insert(new_events, {type=event_type, timestamp=ts, battery=battery})
                            count = count + 1
                        end
                    end
                end
            end
            file:close()
            if count > 0 then
                self:writeAllEvents(new_events)
                self:reloadLastEvent()
                UIManager:show(InfoMessage:new{text = T(_("已导入 %1 条事件（覆盖了现有数据）。"), count), timeout = 3})
            else
                UIManager:show(InfoMessage:new{text = _("CSV 中未找到有效事件。"), timeout = 3})
            end
        end
    })
end

-- 合并后不再自行注册主菜单；改为向主插件提供子菜单项，由 BatteryMonitor 统一挂接。
function SleepWakeTracker:getMenuSubItems()
	return {
		{ text = _("显示今日事件"), callback = function() self:onShowSleepWakeToday() end },
		{ text = _("显示昨日事件"), callback = function() self:onShowSleepWakeYesterday() end },
		{ text = _("浏览历史"), callback = function() self:showYearSelector() end },
		{
			text = _("数据管理"),
			sub_item_table = {
				{ text = _("导出为 CSV"), callback = function() self:exportToCSV() end },
				{ text = _("从 CSV 导入（覆盖）"), callback = function() self:importFromDefaultCSV() end },
				{ text = _("从 CSV 导入（追加）"), callback = function() self:importFromCSVAppend() end },
				{ text = _("清除今日日志"), callback = function() self:confirmClearToday() end },
				{ text = _("清除全部历史"), callback = function() self:confirmClearAll() end },
			},
		},
		{
			text = _("关于"),
			callback = function()
				UIManager:show(InfoMessage:new{
					text = _[[休眠/唤醒追踪器（优化最终版）
核心特性：
- 日终首尾校准，全天电量统计100%准确
- 硬件采样误差过滤，杜绝休眠虚增充电
- 跨天周期单独标注，统计不串日
- 异常短休眠自动标记
- 平均耗电率与续航估算
- 内存缓存加速，日志自动轮转
- CSV导入导出，支持覆盖/追加双模式
- Standby 事件追踪（支持设备）]],
					timeout = 8,
				})
			end,
		},
	}
end

function SleepWakeTracker:onSuspend()
    logger.dbg("SleepWakeTracker: onSuspend")
    self:logEvent("SLEEP")
end

function SleepWakeTracker:onResume()
    logger.dbg("SleepWakeTracker: onResume")
    self:logEvent("WAKE")

    -- 刚唤醒时电源后端可能仍返回休眠前缓存电量。
    -- 延迟重采样并更新最后一条 WAKE 的电量，可修复"实际掉电但段统计为 0%"的问题。
    local refreshed = false
    local function refresh_wake_battery()
        if refreshed then return end
        local battery = self:getBatteryLevel()
        if battery then
            self:updateLastEventBattery("WAKE", battery)
            refreshed = true
        end
    end
    UIManager:scheduleIn(5, refresh_wake_battery)
    UIManager:scheduleIn(15, refresh_wake_battery)

    self:cleanOldEvents()
end

-- 支持 standby（轻量待机）事件的设备（部分 Kobo、PocketBook 等）
function SleepWakeTracker:onEnterStandby()
    logger.dbg("SleepWakeTracker: onEnterStandby")
    self:logEvent("SLEEP")
end

function SleepWakeTracker:onLeaveStandby()
    logger.dbg("SleepWakeTracker: onLeaveStandby")
    self:logEvent("WAKE")
end

return SleepWakeTracker