-- util_watchdog.lua · 网络自愈（被动探测 + 只重启兜底，绝不碰射频）
--
-- 这个模块的全部逻辑都是踩出来的，三条铁律别改：
--
-- 【铁律1】应用层永远不要手动切飞行模式（mobile.flymode）。
--   固件 mobile.setAuto 已开启「自动复位协议栈 + 网络异常检测」，IP_LOSE 后内核会自己重注册
--   （实测约 6 秒就 IP_READY）。手动切飞行模式会与它冲突，实测导致"每 2 分钟
--   IP_LOSE→栈复位→再掉线"的死亡螺旋，最终 ramdump 死机。
--
-- 【铁律2】探测不要用 HTTP，尤其不要用 HEAD。
--   LuatOS 的 http 库在本固件上不支持 HEAD（返回 "NOT SUPPORT HEAD"），而且该不支持分支
--   **泄漏 C 层 http_ctrl**：之后每一次 HTTP 请求都会 "out of memory when malloc http_ctrl"，
--   Lua 的 GC 收不了 C 堆 —— 结果就是"探测把正常的钉钉转发也拖死了"。
--
-- 【铁律3】探测不要用 socket.dns。
--   本固件的 socket.dns 不工作（日志里一次锚点 dns_run 都没有），拿它判活会把"自建服务不可达"
--   误判成"网络僵死"。
--
-- 所以这里只用**裸 TCP 握手**探测中立第三方锚点：socket.connect 同步返回，
-- close + release 严格成对（所有分支都走到，一个都不许漏），零泄漏面。
--
-- 判据（与任何自建服务器无关，设备完全独立自证）：
--   ① 任一锚点 TCP 握手成功 = 互联网可达 → 刷新"上次可达时刻"，什么都不做；
--   ② 连续全灭满 WATCHDOG_REBOOT_AFTER（默认 2h）= 固件自愈已证明无效 → rtos.restart() 清场。
--      这是本模块唯一的动作，也是唯一的重启理由。
local util_watchdog = {}

-- 中立锚点：两个纯 IP（绕开 DNS，专测"链路通不通"）+ 一个域名（顺带验证 DNS+TCP 全链路）
local ANCHORS = {
    { "223.5.5.5", 53 },            -- 阿里 DNS TCP:53
    { "114.114.114.114", 53 },      -- 114 DNS TCP:53
    { "www.baidu.com", 443 },       -- 域名锚点（顺带验 DNS）
}

-- 裸 TCP 握手探测，轮换取一个锚点（避免总打同一个点被限流造成误判）
local anchor_i = 0
local function tcp_probe()
    anchor_i = anchor_i % #ANCHORS + 1
    local a = ANCHORS[anchor_i]
    local ok_conn = false
    local netc = socket.create(nil, function() end)
    if netc then
        local ok, r = pcall(socket.connect, netc, a[1], a[2])
        ok_conn = ok and r and true or false
        socket.close(netc)          -- ⚠ close 与 release 必须成对，见文件头铁律2
        socket.release(netc)
    end
    log.info("watchdog", "TCP探测", a[1] .. ":" .. a[2], ok_conn and "通" or "不通")
    return ok_conn
end

--- 启动看门狗。开机调用一次即可。
function util_watchdog.start()
    sys.taskInit(function()
        -- 开机瞬断交给固件自愈先处理，1 分钟后看门狗再上岗，避免刚上电就误判
        sys.wait(1000 * 60)
        local ok_ms = mcu.ticks()
        while true do
            if tcp_probe() then
                ok_ms = mcu.ticks()
            end
            local dead = mcu.ticks() - ok_ms
            local reboot_after = tonumber(config.WATCHDOG_REBOOT_AFTER) or (1000 * 60 * 120)
            if reboot_after > 0 and dead > reboot_after then
                log.error("watchdog", "外网探测全灭超时, 重启清场", "dead_ms", dead)
                rtos.restart()
            elseif dead > 1000 * 60 * 30 then
                log.warn("watchdog", "外网持续不可达, 继续交固件自愈（不动射频）", "dead_ms", dead)
            end
            sys.wait(tonumber(config.WATCHDOG_PROBE_INTERVAL) or (1000 * 60 * 5))
        end
    end)

    -- ============ 被动 IP_LOSE 计数（与上面的主动探测并行，互不干扰）============
    -- 单次瞬断通常 1~2 个 IP_LOSE 后就 IP_READY，不会触发重启；
    -- 只有"10 分钟内连续 10 次且始终不自愈"才判定 PDP 彻底卡死。
    sys.taskInit(function()
        local loss_count, window_start = 0, 0
        sys.subscribe("IP_LOSE", function(adapter)
            loss_count = loss_count + 1
            if loss_count == 1 then window_start = mcu.ticks() end
            log.warn("watchdog", "IP_LOSE，等待固件自动重注册（不自切飞行模式）",
                "adapter=" .. tostring(adapter), "连续" .. loss_count .. "次")
            local now = mcu.ticks()
            if loss_count >= 10 and (now - window_start) < 600000 then
                log.error("watchdog", "连续 IP_LOSE 且 10 分钟内未自愈，重启设备", loss_count)
                rtos.restart()
            end
        end)
        sys.subscribe("IP_READY", function(adapter)
            if loss_count > 0 then
                log.info("watchdog", "IP_READY，网络已恢复（固件自愈），重置计数", tostring(adapter))
            end
            loss_count = 0
        end)
    end)
end

return util_watchdog
