local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")

-- 合并自 batterygraph（电量曲线）与 sleepwaketracker（休眠/唤醒追踪）两个插件。
-- 子控制器 batterygraph_ctrl / sleepwake_ctrl 仅提供能力，不再自行注册菜单或暴露全局；
-- 统一由本插件注册单一主菜单、接收生命周期事件并委派给子控制器。
local BatteryGraphController = require("batterygraph_ctrl")
local SleepWakeController = require("sleepwake_ctrl")

local BatteryMonitor = WidgetContainer:extend{
	name = "batterymonitor",
	is_doc_only = false,
}

function BatteryMonitor:init()
	logger.info("BatteryMonitor: init (合并 电量监测)")

	-- 单一全局实例：供内部 widget（graphwidget 的休眠跳转）调用；始终指向常驻实例，避免失效。
	_G.BatteryMonitorInstance = self

	-- 子控制器：连续电量采样（原 batterygraph）
	self.battery = BatteryGraphController:new{ ui = self.ui, _monitor = self }
	-- 子控制器：休眠/唤醒追踪（原 sleepwaketracker）
	self.sleepwake = SleepWakeController:new{ ui = self.ui, _monitor = self }

	-- 注册单一主菜单入口（合并后的统一菜单）
	local retry_count = 0
	local function register_menu()
		retry_count = retry_count + 1
		if self.ui and self.ui.menu then
			self.ui.menu:registerToMainMenu(self)
			logger.dbg("BatteryMonitor: Registered to main menu")
		elseif retry_count < 5 then
			UIManager:scheduleIn(0.5, register_menu)
		else
			logger.warn("BatteryMonitor: Failed to register to main menu after 5 attempts")
		end
	end
	register_menu()

	self:registerDispatcherActions()
end

-- 菜单排序：归入「更多工具」，避免 MenuSorter 将未排序项当作 orphan 加 "NEW: " 前缀。
function BatteryMonitor:registerDispatcherActions()
	Dispatcher:registerAction("batterymonitor_graph", {
		category = "none",
		event = "ShowBatteryGraph",
		title = _("电量监测：电量曲线"),
		device = true,
	})
	Dispatcher:registerAction("batterymonitor_sleepwake_today", {
		category = "none",
		event = "ShowSleepWakeToday",
		title = _("电量监测：休眠/唤醒今日"),
		general = true,
	})
end

function BatteryMonitor:addToMainMenu(menu_items)
	-- 归入「更多工具」分类，避免 orphan
	local ok_ro, order = pcall(require, "ui/elements/reader_menu_order")
	if ok_ro and type(order) == "table" and order.more_tools then
		local found = false
		for _, id in ipairs(order.more_tools) do
			if id == "batterymonitor" then found = true; break end
		end
		if not found then table.insert(order.more_tools, "batterymonitor") end
	end
	local ok_fo, fm_order = pcall(require, "ui/elements/filemanager_menu_order")
	if ok_fo and type(fm_order) == "table" and fm_order.more_tools then
		local found = false
		for _, id in ipairs(fm_order.more_tools) do
			if id == "batterymonitor" then found = true; break end
		end
		if not found then table.insert(fm_order.more_tools, "batterymonitor") end
	end

	menu_items.batterymonitor = {
		text = _("电量监测"),
		sorting_hint = "more_tools",
		sub_item_table = {
			{
				text = _("电量曲线"),
				keep_menu_open = false,
				callback = function()
					self:onShowBatteryGraph()
				end,
			},
			{
				text = _("休眠/唤醒记录"),
				sub_item_table = self.sleepwake:getMenuSubItems(),
			},
			{
				text = _("关于"),
				callback = function()
					UIManager:show(InfoMessage:new{
						text = _[[电量监测（BatteryMonitor）
由「电量图表」与「休眠/唤醒追踪器」合并而成。

功能：
-连续电量曲线（放电/充电周期、按天数）
-休眠/唤醒时间戳与分段电量消耗统计
-活跃时长 /待机时长对比
-数据 CSV 导入导出

原插件：电量图表（BatteryGraph）、休眠/唤醒追踪器（sleepwaketracker）。]],
						timeout = 8,
					})
				end,
			},
		},
	}
end

-- ===== 委派方法（供菜单 / Dispatcher / 内部 widget 调用）=====
function BatteryMonitor:onShowBatteryGraph()
	return self.battery:onShowBatteryGraph()
end

function BatteryMonitor:onShowSleepWakeToday()
	return self.sleepwake:onShowSleepWakeToday()
end

-- ===== 生命周期事件：主插件接收后委派给子控制器 =====
function BatteryMonitor:onSuspend()
	if self.battery then self.battery:onSuspend() end
	if self.sleepwake then self.sleepwake:onSuspend() end
end

function BatteryMonitor:onResume()
	if self.battery then self.battery:onResume() end
	if self.sleepwake then self.sleepwake:onResume() end
end

function BatteryMonitor:onCharging()
	if self.battery then self.battery:onCharging() end
end

function BatteryMonitor:onNotCharging()
	if self.battery then self.battery:onNotCharging() end
end

function BatteryMonitor:onEnterStandby()
	if self.sleepwake then self.sleepwake:onEnterStandby() end
end

function BatteryMonitor:onLeaveStandby()
	if self.sleepwake then self.sleepwake:onLeaveStandby() end
end

function BatteryMonitor:onCloseDocument()
	-- 只清理子控制器的定时器；全局引用始终指向常驻实例，不在此清空。
	if self.battery then self.battery:onCloseDocument() end
	logger.info("BatteryMonitor: cleaned up on close document")
end

return BatteryMonitor
