-- main.lua · Air780EPV 纯本地短信转发器
-- 功能：收到短信/来电 → 按 config.NOTIFY_TYPE 推送到钉钉/飞书/企业微信/Telegram/Bark/
--       PushDeer/WxPusher/Gotify/Pushover/邮件/自定义HTTP/串口 等通道；全程不需要任何自建服务器。
--
-- 文件结构（每个模块只管一件事，改哪块看哪个文件）：
--   config.lua            唯一需要改的配置
--   util_notify.lua       发送队列 + fskv 防丢 + 指数退避重试
--   util_notify_channel.lua 各通知通道的实现（加新通道在这里）
--   util_http.lua         HTTP 封装（含闪烁提示钩子）
--   util_smsctl.lua       黑名单 / 管理员 / 代发指令（纯本地判断，不联网）
--   util_watchdog.lua     网络自愈（裸 TCP 探测 + 只重启兜底，绝不碰射频）
--   util_mobile.lua       信号/运营商/流量/号码等设备信息
--   util_location.lua     基站定位（可选，默认关闭）
--   util_netled.lua       网络指示灯
--   lbsLoc.lua / lib_smtp.lua / libnet.lua  定位算法 / SMTP 实现 / socket 封装
PROJECT = "air780epv-local-forwarder"
VERSION = "1.0.0-local"

log.setLevel("INFO")            -- 调试时改 "DEBUG"（日志会多很多，串口看得更细）
log.info("main", PROJECT, VERSION)

sys = require "sys"
sysplus = require "sysplus"

-- 硬件看门狗：Lua 卡死时由它复位，比"应用层自检"可靠得多。
-- 9 秒超时、3 秒喂一次 —— 意味着任何一次阻塞超过 9 秒的代码路径都会导致重启，
-- 所以业务代码里不要写长循环/长阻塞调用。
wdt.init(9000)
sys.timerLoopStart(wdt.feed, 3000)

-- 每小时回收一次 Lua 堆（长期运行的设备，碎片化比泄漏更常见）
sys.timerLoopStart(function()
    log.info("main", "回收一次内存", collectgarbage("count") .. "KB")
    collectgarbage("collect")
end, 3600000)

-- DNS：阿里 + 114，都是国内可达的公共解析
socket.setDNS(nil, 1, "223.5.5.5")
socket.setDNS(nil, 2, "119.29.29.29")

-- 固件级网络自愈：SIM 自动恢复、周期性取小区信息、网络异常时自动复位协议栈。
-- ⚠ 应用层不要再手动切飞行模式，会和这里的 auto_reset_stack 打架（详见 util_watchdog.lua）。
mobile.setAuto(10000, 300000, 8, true, 120000)

-- fskv：待转发消息的持久化存储（断电不丢）
log.info("main", "fskv.init", fskv.init())

-- 记录重启原因与累计重启次数：排障时"设备是不是在反复重启"看一眼就知道
do
    local pk, chg, hw = pm.lastReson()
    local r = (pk == 1 and "pwrkey " or "") .. (chg == 1 and "charge " or "") .. (hw == 1 and "hw " or "")
    if r == "" then r = "soft" end
    BOOT_REASON = r
    local bc = fskv.get("boot_count")      -- ⚠ 先落局部变量：fskv.get 缺键返回"零个值"而非 nil
    BOOT_COUNT = (tonumber(bc) or 0) + 1
    fskv.set("boot_count", tostring(BOOT_COUNT))
    log.info("main", "重启原因", BOOT_REASON, "累计重启", BOOT_COUNT, "次")
end

-- 加载模块（config 必须最先，后面都用它）
config = require "config"
util_http = require "util_http"
util_netled = require "util_netled"
util_mobile = require "util_mobile"
util_location = require "util_location"
util_smsctl = require "util_smsctl"
util_notify = require "util_notify"
util_watchdog = require "util_watchdog"

-- 网络指示灯尽早初始化（LED_DISABLE=true 时是"把所有灯钉成灭"，见 util_netled.lua）
util_netled.init()

-- 电源键（短按=发一条测试通知，长按=向运营商查流量）
-- 引脚按 BSP 取：EC618→35，EC718P→46。取不到就整块跳过，按钮功能失效但不崩。
local pin_table = { ["EC618"] = 35, ["EC718P"] = 46 }
local powerkey_pin = pin_table[rtos.bsp()]
if powerkey_pin then
    local last_press, last_release = 0, 0
    gpio.setup(powerkey_pin, function()
        local now = mcu.ticks()
        if gpio.get(powerkey_pin) == 0 then          -- 按下
            last_press = now
            return
        end
        if last_press == 0 then return end            -- 开机前就按着，开机后才松开
        if now - last_release < 250 then return end   -- 防抖：连按
        local duration = now - last_press
        last_release = now
        if duration > 2000 then
            sys.publish("POWERKEY_LONG_PRESS", duration)
        elseif duration > 50 then
            sys.publish("POWERKEY_SHORT_PRESS", duration)
        end
    end, gpio.PULLUP)
end

-- 串口通道：NOTIFY_TYPE 含 "serial" 时才建。MASTER 把收到的短信也从串口吐出去；
-- SLAVE 则把自己收到的串口数据原样转发（配合另一台设备做级联）。
local function contains_value(t, value)
    if t == value then return true end
    if type(t) ~= "table" then return false end
    for _, v in pairs(t) do if v == value then return true end end
    return false
end

if contains_value(config.NOTIFY_TYPE, "serial") then
    uart.setup(1, 115200, 8, 1, uart.NONE)
    uart.on(1, "receive", function(id, len)
        local data = uart.read(id, len)
        log.info("main", "串口收到", id, len, data)
        if config.ROLE == "MASTER" then
            util_notify.add(data)
        else
            uart.write(1, data)
        end
    end)
end

-- ============================ 短信接收：本项目的核心入口 ============================
sms.setNewSmsCb(function(sender_number, sms_content, m)
    local time_str = string.format("%d/%02d/%02d %02d:%02d:%02d",
        m.year + 2000, m.mon, m.day, m.hour, m.min, m.sec)
    log.info("smsCallback", time_str, sender_number, sms_content)

    -- ① 黑名单：命中直接丢，不转发也不回任何东西
    if util_smsctl.is_blacklisted(sender_number) then
        log.warn("smsCallback", "命中黑名单，忽略", sender_number)
        return
    end

    local is_admin = util_smsctl.is_admin(sender_number)

    -- ② 管理员代发指令：SMS,<目标号码>,<内容>
    --    ⚠ 只有 ADMIN_PHONE 发来的才被执行；ADMIN_PHONE 留空则所有指令都不生效。
    local is_ctrl = false
    local phone, content = util_smsctl.parse_send(sms_content)
    if is_admin and phone then
        sms.send(phone, content)
        is_ctrl = true
        log.info("smsCallback", "已代发给", phone)
    end

    -- ③ 转发这条短信。末尾的 #SMS 是给 util_notify 判断"要不要持久化"的标记，别删。
    util_notify.add({
        sms_content, "",
        "发件号码: " .. sender_number,
        "发件时间: " .. time_str,
        "#SMS" .. (is_ctrl and " #CTRL" or ""),
    })
end)

-- ============================ 开机后的定时任务 ============================
sys.taskInit(function()
    -- 等网络就绪（最多等 5 分钟；等不到也继续跑，收短信本身不需要网络）
    sys.waitUntil("IP_READY", 1000 * 60 * 5)

    util_watchdog.start()

    if config.BOOT_NOTIFY then
        sys.timerStart(function()
            util_notify.add("#BOOT_" .. BOOT_REASON)
        end, 1000 * 5)
    end

    -- 对时：时间不准会导致通知里的发件时间错乱、以及 fskv 消息年龄判断失真
    if os.time() < 1714500000 then
        socket.sntp("ntp.aliyun.com")
    end
    if type(config.SNTP_INTERVAL) == "number" and config.SNTP_INTERVAL >= 1000 * 60 then
        sys.timerLoopStart(function() socket.sntp("ntp.aliyun.com") end, config.SNTP_INTERVAL)
    end

    -- 定时查流量（运营商会回一条短信，那条短信本身也会被正常转发）
    if type(config.QUERY_TRAFFIC_INTERVAL) == "number" and config.QUERY_TRAFFIC_INTERVAL >= 1000 * 60 then
        sys.timerLoopStart(util_mobile.queryTraffic, config.QUERY_TRAFFIC_INTERVAL)
    end

    -- 定时基站定位（室内/弱信号经常查不到，默认关闭）
    if type(config.LOCATION_INTERVAL) == "number" and config.LOCATION_INTERVAL >= 1000 * 60 then
        util_location.refresh(nil, true)
        sys.timerLoopStart(util_location.refresh, config.LOCATION_INTERVAL)
    end

    -- 定时"活着"上报
    if type(config.REPORT_INTERVAL) == "number" and config.REPORT_INTERVAL >= 1000 * 60 then
        sys.timerLoopStart(function() util_notify.add("#ALIVE_REPORT") end, config.REPORT_INTERVAL)
    end

    -- 卫生重启：兜底极端累积问题。卡死有硬件看门狗、网络故障有固件自愈，都不靠它。
    local reboot_iv = tonumber(config.REBOOT_INTERVAL) or 0
    if reboot_iv >= 1000 * 60 then
        sys.timerLoopStart(function()
            log.info("main", "卫生重启")
            rtos.restart()
        end, reboot_iv)
    end

    -- 电源键动作
    sys.subscribe("POWERKEY_SHORT_PRESS", function() util_notify.add("#ALIVE") end)
    sys.subscribe("POWERKEY_LONG_PRESS", util_mobile.queryTraffic)
end)

-- SIM PIN 解锁：开机 5 秒还没联网才试（多数卡没设 PIN，这段直接跳过）
sys.taskInit(function()
    if type(config.PIN_CODE) ~= "string" or config.PIN_CODE == "" then return end
    if not sys.waitUntil("IP_READY", 1000 * 5) then
        util_mobile.pinVerify(config.PIN_CODE)
    end
end)

-- ============================ 来电通知（可选，模组支持通话时才有意义）============
if cc then
    local is_calling = false
    sys.subscribe("CC_IND", function(status)
        if status == "INCOMINGCALL" then
            if is_calling then return end       -- 一次来电会重复触发，只报第一次
            is_calling = true
            log.info("cc_status", "INCOMINGCALL", cc.lastNum())
            util_notify.add({
                "来电号码: " .. cc.lastNum(),
                "来电时间: " .. os.date("%Y-%m-%d %H:%M:%S"),
                "#CALL #CALL_IN",
            })
            return
        end
        if status == "DISCONNECTED" then
            is_calling = false
            log.info("cc_status", "DISCONNECTED", cc.lastNum())
            util_notify.add({
                "来电号码: " .. cc.lastNum(),
                "挂断时间: " .. os.date("%Y-%m-%d %H:%M:%S"),
                "#CALL #CALL_DISCONNECTED",
            })
            return
        end
        log.info("cc_status", status)
    end)
end

sys.run()
