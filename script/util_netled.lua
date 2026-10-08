-- util_netled.lua · 网络指示灯（默认全关）
--
-- 需求场景：设备常电运行、放在暗环境（床头/办公桌），不希望有任何周期性闪烁。
--
-- 做法：默认**不建闪烁任务**，并且主动把灯脚"钉"在灭电平 + 加下拉，而不是放任浮空。
-- 为什么不能只是"不驱动"：上电瞬间该脚可能停在复位默认态或浮空，外接三极管/MOS 驱动时
-- 会微亮甚至常亮；浮空脚在蜂窝发射时还会感应出毛刺，既费电也不稳定。
--
-- 引脚与极性全部走 config.lua，换板子只改配置不改代码：
--   LED_DISABLE      true=常灭（默认）；false=恢复"极短亮 + 长间隔"闪烁
--   NETLED_PIN       灯脚编号；不确定就填 nil，程序不会去猜引脚（猜错可能撞上 SIM/UART/天线脚）
--   NETLED_OFF_LEVEL 灭时电平：0=低电平灭（默认，常见 NPN 驱动）；1=高电平灭（共阳/反相驱动）
--   LED_OFF_PINS     其它由模组 GPIO 驱动的灯脚列表，一并拉灭
--
-- ⚠ 板子上"通电就亮"的电源灯是硬件直连，软件关不掉，只能改板或遮光。
local util_netled = {}

-- pin -> driver 函数。幂等用：重复 setup 会把引脚方向改回去，反而可能让灯复亮
local off_drivers = {}

-- 把某个脚钉死在"灭"电平。失败（编号非法/已被占用）只记日志，绝不抛出影响主流程。
local function drive_off(pin, off_level)
    if pin == nil or off_drivers[pin] then return end
    local ok, driver = pcall(gpio.setup, pin, off_level,
        (off_level == 0) and gpio.PULLDOWN or gpio.PULLUP)
    if not ok or not driver then
        log.warn("netled", "关灯失败，引脚可能非法或已被占用", tostring(pin))
        return
    end
    pcall(driver, off_level)          -- 部分固件 setup 的初值不生效，显式再写一次
    off_drivers[pin] = driver
    log.info("netled", "已关灯 pin=" .. tostring(pin) .. " 灭电平=" .. tostring(off_level))
end

-- 尽力关掉"固件级"指示灯：不同机型/固件的 API 名字不一样（netLed / netled 都出现过），
-- 全部 pcall 试探，存在就调、不存在就跳过。真正的关灯靠上面的 drive_off。
local function try_disable_fw_led()
    local hit = 0
    for _, lib in ipairs({ _G.netLed, _G.netled }) do
        if type(lib) == "table" and type(lib.setWorkMode) == "function" then
            for _, mode_key in ipairs({ "WORK_MODE_DISABLE", "MODE_DISABLE", "WORK_MODE_OFF" }) do
                local mode = lib[mode_key]
                if mode ~= nil then
                    for id = 0, 3 do
                        if pcall(lib.setWorkMode, id, mode) then hit = hit + 1 end
                    end
                end
            end
        end
    end
    if hit > 0 then log.info("netled", "固件级指示灯禁用接口已调用，命中 " .. hit .. " 次") end
end

--- 关掉所有能关的灯（幂等，可重复调用）
function util_netled.all_off()
    try_disable_fw_led()
    drive_off(config.NETLED_PIN, tonumber(config.NETLED_OFF_LEVEL) or 0)
    if type(config.LED_OFF_PINS) == "table" then
        local off_level = tonumber(config.NETLED_OFF_LEVEL) or 0
        for _, pin in ipairs(config.LED_OFF_PINS) do
            drive_off(pin, off_level)
        end
    end
end

-- LED_DISABLE=false 时的节奏：默认 1ms 亮 / 30s 灭 —— 存在感极低，但能确认"设备还活着"
local function resume_blink()
    sys.taskInit(function()
        local pin = config.NETLED_PIN
        if pin == nil then
            log.warn("netled", "LED_DISABLE=false 但没配 NETLED_PIN，无法闪烁")
            return
        end
        local off_level = tonumber(config.NETLED_OFF_LEVEL) or 0
        local driver = off_drivers[pin]
        if not driver then
            local ok, d = pcall(gpio.setup, pin, off_level, gpio.PULLDOWN)
            if not ok or not d then return end
            driver = d
            off_drivers[pin] = d
        end
        while true do
            driver(1 - off_level)
            sys.wait(tonumber(config.NETLED_BLINK_ON) or 1)
            driver(off_level)
            sys.wait(tonumber(config.NETLED_BLINK_INTERVAL) or 30000)
        end
    end)
end

--- 开机初始化：默认关灯
function util_netled.init()
    util_netled.all_off()
    if config.LED_DISABLE == false then
        log.warn("netled", "LED_DISABLE=false，恢复网络闪烁指示")
        resume_blink()
    end
end

--- 请求闪烁提示（util_http 在每次 HTTP 请求前后调用）。
--- 关灯状态下是空操作：不建任务、不动引脚、不报错。
function util_netled.blink(duration, interval, restore)
    if config.LED_DISABLE ~= false then return end
    local driver = off_drivers[config.NETLED_PIN]
    if not driver then return end
    sys.taskInit(function()
        local off_level = tonumber(config.NETLED_OFF_LEVEL) or 0
        driver(1 - off_level)
        sys.wait(duration or 100)
        driver(off_level)
        if restore then sys.timerStart(util_netled.blink, restore) end
    end)
end

return util_netled
