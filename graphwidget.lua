local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TitleBar = require("ui/widget/titlebar")
local Widget = require("ui/widget/widget")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Screen = Device.screen
-- 缓存常用函数
local math_abs = math.abs
local math_floor = math.floor
local math_min = math.min
local os_date = os.date
-- 网格百分比刻度
local PCT_LEVELS = {25, 50, 75, 100}
-- 图表内边距
local PAD_LEFT   = Size.padding.large * 5
local PAD_RIGHT  = Size.padding.large * 2
local PAD_TOP    = Size.padding.large * 2
local PAD_BOTTOM = Size.padding.large * 5 -- 增加底部边距放图例
local INNER_PAD  = Size.padding.default
local DOT_MARGIN = Size.padding.large
-- 绘图前历史规范化函数：先前置声明，供 CanvasWidget:paintTo 使用
local normalizeHistoryForGraph
-- ===== 画布组件 =====
local CanvasWidget = Widget:extend{
    history = {},
    dimen   = nil,
}
-- Bresenham 画线算法
local function drawLine(bb, x0, y0, x1, y1, thickness, color)
    local offset = math_floor(thickness / 2)
    -- 水平/垂直线快速路径
    if y0 == y1 then
        local x = math_min(x0, x1)
        local w = math_abs(x1 - x0) + thickness
        bb:paintRect(x - offset, y0 - offset, w, thickness, color)
        return
    elseif x0 == x1 then
        local y = math_min(y0, y1)
        local h = math_abs(y1 - y0) + thickness
        bb:paintRect(x0 - offset, y - offset, thickness, h, color)
        return
    end
    local dx = math_abs(x1 - x0)
    local sx = x0 < x1 and 1 or -1
    local dy = -math_abs(y1 - y0)
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    while true do
        bb:paintRect(x0 - offset, y0 - offset, thickness, thickness, color)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end
end
-- 虚线绘制（优化墨水屏对比度）
local function drawDashedLine(bb, x0, y, x1, color)
    for i = x0, x1, 8 do
        local w = math_min(5, x1 - i)
        if w > 0 then bb:paintRect(i, y, w, 1, color) end
    end
end
function CanvasWidget:paintTo(bb, x, y)
    local w = self.dimen.w
    local h = self.dimen.h
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    local graph_x = x + PAD_LEFT
    local graph_y = y + PAD_TOP
    local graph_w = w - PAD_LEFT - PAD_RIGHT
    local graph_h = h - PAD_TOP - PAD_BOTTOM
    -- 绘制网格线
    for i = 1, #PCT_LEVELS do
        local pct = PCT_LEVELS[i]
        local py = graph_y + graph_h - math_floor((pct / 100) * graph_h)
        drawDashedLine(bb, graph_x, py, graph_x + graph_w, Blitbuffer.COLOR_GRAY)
    end
    -- 绘制坐标轴
    bb:paintRect(graph_x, graph_y + graph_h, graph_w, 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(graph_x, graph_y, 2, graph_h + 2, Blitbuffer.COLOR_BLACK)
    local history = normalizeHistoryForGraph(self.history)
    -- 空数据处理
    if not history or not history.ts or #history.ts < 2 then
        -- 空状态提示文字居中绘制（修改：blitbuffer 无 paintText 成员，会 FFI 崩溃；
        -- 改用 TextWidget:paintTo 标准绘制接口，颜色经 fgcolor 指定）
        local font_face = Font:getFace("cfont", 20)
        local text = _("暂无足够电量数据，使用一段时间后即可生成图表")
        local tmp_text = TextWidget:new{text = text, face = font_face, padding = 0, fgcolor = Blitbuffer.COLOR_DARK_GRAY}
        local text_size = tmp_text:getSize()
        local text_w = text_size and text_size.w or 0
        local text_h = text_size and text_size.h or 0
        local text_x = x + (w - text_w) / 2
        local text_y = y + (h - text_h) / 2
        tmp_text:paintTo(bb, text_x, text_y)
        return
    end
    -- 固定时间窗口：优先用 BatteryGraphWidget 传入的窗口边界 [cutoff, now]，
    -- 退化为数据首尾（兼容直接调用画布的场景）。
    local window_start = self.window_start or history.ts[1]
    local window_end   = self.window_end or history.ts[#history.ts]
    if not window_end or window_end <= window_start then
        window_end = window_start + 1
    end
    local prev_x, prev_y = nil, nil
    local draw_w  = graph_w - 2 * INNER_PAD - 2 * DOT_MARGIN
    local span    = window_end - window_start
    local ts_scale = draw_w / span
    local cap_scale = graph_h / 100
    for i = 1, #history.ts do
        local px = graph_x + INNER_PAD + DOT_MARGIN + math_floor((history.ts[i] - window_start) * ts_scale)
        local py = graph_y + graph_h - math_floor(history.capacity[i] * cap_scale)
        -- 充放电统一为黑色实线（KPW3 黑白屏，灰色太淡不美观）
        -- 折线连续绘制，不因采样间隔断开，避免中间线条“断裂”
        local dot_color = Blitbuffer.COLOR_BLACK
        if prev_x and prev_y then
            drawLine(bb, prev_x, prev_y, px, py, 2, Blitbuffer.COLOR_BLACK)
        end
        bb:paintRect(px - 3, py - 3, 6, 6, dot_color)
        prev_x = px
        prev_y = py
    end
end
-- ===== 图表主控件 =====
local BatteryGraphWidget = FocusManager:extend{
    history         = {},
    view_mode       = "30d", -- today | 7d | 30d | 90d | 180d | 365d
    on_mode_change  = nil,
    canvas_widget   = nil,
    filtered_history = nil,
    _monitor        = nil, -- 构造时由 BatteryGraph 传入主插件实例；未传则回退到 _G.BatteryMonitorInstance
}
-- 绘图前规范化历史，避免旧数据时间倒序或未充电电量回弹导致折线错误上升
normalizeHistoryForGraph = function(history)
    history = history or {ts={}, capacity={}, is_charging={}}
    local temp = {}
    for i = 1, #(history.ts or {}) do
        local ts = tonumber(history.ts[i])
        local cap = tonumber(history.capacity and history.capacity[i])
        local charging = history.is_charging and history.is_charging[i] == true or false
        if ts and cap and cap > 0 and cap <= 100 then
            temp[#temp + 1] = {ts = ts, capacity = cap, is_charging = charging}
        end
    end
    table.sort(temp, function(a, b) return a.ts < b.ts end)
    local out = {ts={}, capacity={}, is_charging={}}
    for _, point in ipairs(temp) do
        local n = #out.ts
        if n > 0 and out.ts[n] == point.ts then
            out.capacity[n] = point.capacity
            out.is_charging[n] = point.is_charging
        else
            if n > 0 and (not point.is_charging) and (out.is_charging[n] == false) and point.capacity > out.capacity[n] then
                point.capacity = out.capacity[n]
            end
            out.ts[#out.ts + 1] = point.ts
            out.capacity[#out.capacity + 1] = point.capacity
            out.is_charging[#out.is_charging + 1] = point.is_charging
        end
    end
    return out
end

-- 计算当前视图的时间窗口边界 [start, end]（固定窗口，不随数据多少拉伸）
function BatteryGraphWidget:getWindowBounds()
    local now = os.time()
    if self.view_mode == "today" then
        -- 当天 00:00（本地时区）起，至当前时刻
        local d = os_date("*t", now)
        return os.time{year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0}, now
    else
        local days = ({["7d"] = 7, ["30d"] = 30, ["90d"] = 90, ["180d"] = 180, ["365d"] = 365})[self.view_mode] or 30
        return now - days * 24 * 3600, now
    end
end

-- 根据视图模式(时间窗)过滤历史数据：today=当天0点起, 7d/30d/90d/180d/365d=近N天
function BatteryGraphWidget:getFilteredHistory()
    local history = normalizeHistoryForGraph(self.history)
    if not history or not history.ts or #history.ts == 0 then
        return {ts={}, capacity={}, is_charging={}}
    end
    local now = os.time()
    local cutoff
    if self.view_mode == "today" then
        -- 当天 00:00（本地时区）起
        local d = os_date("*t", now)
        cutoff = os.time{year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0}
    else
        local days = ({["7d"] = 7, ["30d"] = 30, ["90d"] = 90, ["180d"] = 180, ["365d"] = 365})[self.view_mode] or 30
        cutoff = now - days * 24 * 3600
    end
    local filtered = {ts={}, capacity={}, is_charging={}}
    local idx = 1
    for i = 1, #history.ts do
        if history.ts[i] >= cutoff then
            filtered.ts[idx]      = history.ts[i]
            filtered.capacity[idx] = history.capacity[i]
            filtered.is_charging[idx] = history.is_charging[i] == true
            idx = idx + 1
        end
    end
    return filtered
end
-- 获取标题文本
function BatteryGraphWidget:getModeTitle()
    local titles = {
        today  = _("电量图表") .. "  [" .. _("今天") .. "]",
        ["7d"]  = _("电量图表") .. "  [" .. _("近7天") .. "]",
        ["30d"] = _("电量图表") .. "  [" .. _("近30天") .. "]",
        ["90d"] = _("电量图表") .. "  [" .. _("近90天") .. "]",
        ["180d"]= _("电量图表") .. "  [" .. _("近180天") .. "]",
        ["365d"]= _("电量图表") .. "  [" .. _("近365天") .. "]",
    }
    return titles[self.view_mode] or (_("电量图表") .. "  [" .. _("近30天") .. "]")
end
-- 显示模式选择菜单
function BatteryGraphWidget:showViewMenu()
    local menu
    local vm = self.view_mode
    local function mark(active)
        return active and "> " or ""
    end
    local menu_items = {
        {
            text = mark(vm == "today") .. _("今天"),
            callback = function()
                UIManager:close(menu)
                self:switchMode("today", nil)
            end,
        },
        {
            text = mark(vm == "7d") .. _("近7天"),
            callback = function()
                UIManager:close(menu)
                self:switchMode("7d", nil)
            end,
        },
        {
            text = mark(vm == "30d") .. _("近30天"),
            callback = function()
                UIManager:close(menu)
                self:switchMode("30d", nil)
            end,
        },
        { text = "", keep_menu_open = true, separator = true },
        {
            text = mark(vm == "90d") .. _("近90天"),
            callback = function()
                UIManager:close(menu)
                self:switchMode("90d", nil)
            end,
        },
        {
            text = mark(vm == "180d") .. _("近180天"),
            callback = function()
                UIManager:close(menu)
                self:switchMode("180d", nil)
            end,
        },
        { text = "", keep_menu_open = true, separator = true },
        {
            text = mark(vm == "365d") .. _("近365天"),
            callback = function()
                UIManager:close(menu)
                self:switchMode("365d", nil)
            end,
        },
        -- 跳转到休眠/唤醒追踪器（直接调用实例，避免 broadcastEvent 不可靠）
        { text = "", keep_menu_open = true, separator = true },
        {
            text = _("打开休眠/唤醒追踪"),
            callback = function()
                UIManager:close(menu)
                UIManager:close(self)
                UIManager:scheduleIn(0.15, function()
				local monitor = self._monitor or _G.BatteryMonitorInstance
				if monitor then
					monitor:onShowSleepWakeToday()
                else
                        UIManager:show(InfoMessage:new{
                            text = _("未检测到休眠/唤醒追踪器插件，请先安装")
                        })
                    end
                end)
            end,
        },
    }
    menu = Menu:new{
        title = _("显示模式"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
    }
    UIManager:show(menu)
end
-- 优化：切换模式不重建窗口，仅更新数据重绘（消除墨水屏闪烁）
function BatteryGraphWidget:switchMode(mode, period)
    self.view_mode = mode
    if self.on_mode_change then
        self.on_mode_change(mode, period)
    end
    -- 更新标题
    self.title_bar:setTitle(self:getModeTitle())
    -- 更新画布数据
    self:updateCanvas()
    -- 触发全屏重绘
    UIManager:setDirty(self, "full")
end
-- 更新画布与标签（抽离复用）
function BatteryGraphWidget:updateCanvas()
    self.filtered_history = self:getFilteredHistory()
    self.canvas_widget.history = self.filtered_history
    -- 固定时间窗口边界写入画布，使折线按 [cutoff, now] 定位（今天=00:00~now）
    local w_start, w_end = self:getWindowBounds()
    self.canvas_widget.window_start = w_start
    self.canvas_widget.window_end = w_end
    -- 时间标签与轴边界一致（不再取数据首尾，避免“拉伸占满整宽”误导）
    self.text_start:setText(os_date("%m-%d %H:%M", w_start))
    self.text_end:setText(os_date("%m-%d %H:%M", w_end))
end
-- 查找距离点击位置最近的数据点
function BatteryGraphWidget:findNearestPoint(touch_x, touch_y)
    local history = normalizeHistoryForGraph(self.filtered_history)
    if not history or not history.ts or #history.ts < 2 then return nil end
    local canvas_h = self.dimen.h - self.title_bar:getHeight()
    local graph_x = PAD_LEFT
    local graph_y = PAD_TOP
    local graph_w = self.dimen.w - PAD_LEFT - PAD_RIGHT
    local graph_h = canvas_h - PAD_TOP - PAD_BOTTOM
    -- 点击坐标转换为图表相对坐标
    local rel_x = touch_x - graph_x - INNER_PAD - DOT_MARGIN
    if rel_x < 0 or rel_x > (graph_w - 2 * INNER_PAD - 2 * DOT_MARGIN) then return nil end
    -- 与 paintTo 一致：用固定窗口边界做反算（今天=00:00~now，其余=近N天~now）
    local window_start, window_end = self:getWindowBounds()
    if not window_end or window_end <= window_start then window_end = window_start + 1 end
    local span = window_end - window_start
    local target_ts = window_start + (rel_x / (graph_w - 2 * INNER_PAD - 2 * DOT_MARGIN)) * span
    -- 二分查找最近的点
    local left, right = 1, #history.ts
    while left < right do
        local mid = math_floor((left + right) / 2)
        if history.ts[mid] < target_ts then
            left = mid + 1
        else
            right = mid
        end
    end
    -- 比较左右两个点
    local idx = left
    if idx > 1 then
        if math_abs(history.ts[idx-1] - target_ts) < math_abs(history.ts[idx] - target_ts) then
            idx = idx - 1
        end
    end
    return idx
end
-- 显示数据点详情
function BatteryGraphWidget:showPointDetail(idx)
    local history = normalizeHistoryForGraph(self.filtered_history)
    if not idx or not history or not history.ts[idx] then return end
    local ts = history.ts[idx]
    local cap = history.capacity[idx]
    local charging = history.is_charging[idx]
    local status = charging and _("充电中") or _("放电中")
    local time_str = os_date("%Y-%m-%d %H:%M:%S", ts)
    local detail = string.format(
        _("时间：%s\n电量：%.1f%%\n状态：%s"),
        time_str, cap, status
    )
    UIManager:show(InfoMessage:new{
        text = detail,
        timeout = 3,
    })
end
function BatteryGraphWidget:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local GestureRange = require("ui/gesturerange")
        self.ges_events.Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    -- 标题栏
    self.title_bar = TitleBar:new{
        fullscreen             = true,
        width                  = self.dimen.w,
        align                  = "left",
        title                  = self:getModeTitle(),
        left_icon              = "appbar.menu",
        left_icon_tap_callback = function() self:showViewMenu() end,
        close_callback         = function() self:onClose() end,
        show_parent            = self,
    }
    local canvas_h = self.dimen.h - self.title_bar:getHeight()
    local graph_x = PAD_LEFT
    local graph_y = PAD_TOP
    local graph_w = self.dimen.w - PAD_LEFT - PAD_RIGHT
    local graph_h = canvas_h - PAD_TOP - PAD_BOTTOM
    local font_face = Font:getFace("cfont", 16)
    local text_100 = TextWidget:new{text = "100%", face = font_face, padding = 0}
    local text_75  = TextWidget:new{text = " 75%", face = font_face, padding = 0}
    local text_50  = TextWidget:new{text = " 50%", face = font_face, padding = 0}
    local text_25  = TextWidget:new{text = " 25%", face = font_face, padding = 0}
    local text_0   = TextWidget:new{text = "  0%", face = font_face, padding = 0}
    -- 图例文字（充放电统一黑色实线，单一图例即可；避免 ■ 等 cfont 可能缺字形字符）
    local legend_line = TextWidget:new{text = _("电量曲线"), face = font_face, padding = 0, fgcolor = Blitbuffer.COLOR_BLACK}
    self.text_start = TextWidget:new{text = "00-00 00:00", face = font_face, padding = 0}
    self.text_end   = TextWidget:new{text = "00-00 00:00", face = font_face, padding = 0}
    -- 画布组件
    self.canvas_widget = CanvasWidget:new{
        dimen   = Geom:new{w = self.dimen.w, h = canvas_h},
        history = {},
    }
    -- 组装带标签的画布
    self.canvas_with_labels = OverlapGroup:new{
        dimen = Geom:new{w = self.dimen.w, h = canvas_h},
        self.canvas_widget,
        -- 百分比标签
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x - text_100:getWidth() - Size.padding.small, graph_y - text_100:getSize().h/2},
            text_100,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x - text_75:getWidth() - Size.padding.small, graph_y + graph_h*0.25 - text_75:getSize().h/2},
            text_75,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x - text_50:getWidth() - Size.padding.small, graph_y + graph_h*0.5 - text_50:getSize().h/2},
            text_50,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x - text_25:getWidth() - Size.padding.small, graph_y + graph_h*0.75 - text_25:getSize().h/2},
            text_25,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x - text_0:getWidth() - Size.padding.small, graph_y + graph_h - text_0:getSize().h/2},
            text_0,
        },
        -- 时间标签
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x + INNER_PAD, graph_y + graph_h + Size.padding.small},
            self.text_start,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x + graph_w - INNER_PAD - self.text_end:getWidth(), graph_y + graph_h + Size.padding.small},
            self.text_end,
        },
        -- 图例（底部居中）
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {
                (self.dimen.w - legend_line:getWidth()) / 2,
                graph_y + graph_h + Size.padding.large * 2
            },
            legend_line,
        },
    }
    self[1] = FrameContainer:new{
        height     = self.dimen.h,
        width      = self.dimen.w,
        padding    = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.title_bar,
            self.canvas_with_labels,
        }
    }
    -- 初始化数据
    self:updateCanvas()
end
-- 点击事件：图表区域查看详情，其他区域关闭
function BatteryGraphWidget:onTap(arg, ges)
    -- 点击标题栏区域不处理，由标题栏自身响应
    if ges.pos.y <= self.title_bar:getHeight() then
        return false
    end
    -- 尝试查找最近的数据点
    local touch_y = ges.pos.y - self.title_bar:getHeight()
    local idx = self:findNearestPoint(ges.pos.x, touch_y)
    if idx then
        self:showPointDetail(idx)
    else
        -- 点击空白区域关闭
        self:onClose()
    end
    return true
end
function BatteryGraphWidget:onSwipe()
    self:onClose()
    return true
end
function BatteryGraphWidget:onClose()
    UIManager:close(self)
    return true
end
return BatteryGraphWidget
