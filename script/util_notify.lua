-- util_notify.lua · 转发队列（防丢设计）
--
-- 一条消息的完整生命周期：
--   收到 → ① 立刻写 fskv（断电/重启都不丢） → ② 入内存队列 → ③ 逐通道发送
--   ├─ 成功：删 fskv，终结
--   ├─ 失败：回队，指数退避重试（5s→10s→…→300s 封顶），最多 NOTIFY_RETRY_MAX 次
--   └─ 超单轮上限：不再高频死磕，但 **fskv 副本保留**，由每 5 分钟的重扫任务继续低频补发，
--      直到成功，或超过 NOTIFY_MSG_TTL_HOURS（默认 72h）才彻底放弃并记 error。
--
-- 为什么这么设计：纯本地版没有"云端兜底留存"可依赖，所以"不丢"只能靠 fskv + 重试；
-- 而"不无限堆"又必须有存活时间上限，否则一个填错的 webhook 会让 flash 里的待发消息越攒越多。
local util_notify_channel = require "util_notify_channel"

local util_notify = {}

local msg_queue = {}          -- 内存发送队列
local msg_count = 0           -- 发送计数（生成 id 用）
local error_count = 0         -- 连续失败计数（只用于通知里标注"重发次数"）
local inflight = {}           -- id -> 剩余未终结的通道项数（补发去重用）

local RESYNC_INTERVAL = 1000 * 60 * 5      -- fskv 重扫间隔
local SLOW_RETRY_INTERVAL = 300000         -- 超单轮上限后的低频退避（5 分钟）

-- 需要持久化补发的是真实业务消息（短信/来电），开机通知、存活上报这类噪声不存盘
local function is_durable(msg)
    return type(msg) == "string" and (msg:find("#SMS") ~= nil or msg:find("#CALL") ~= nil)
end

--- 终结一条消息的某个通道项
-- @param keep_persist true=保留 fskv 副本（稍后重扫再战）；false=删掉（已成功或已彻底放弃）
local function finish_item(id, keep_persist)
    if not keep_persist then
        if fskv.get(id) then
            fskv.del(id)
        end
    end
    if inflight[id] then
        inflight[id] = inflight[id] - 1
        if inflight[id] <= 0 then
            inflight[id] = nil
        end
    end
end

--- 实际发送一次
-- @return true 无需重发（成功或"重试也没用"的入参错误）；false 需要重发
local function send(msg, channel)
    log.info("util_notify.send", "发送通知", channel)

    if type(msg) ~= "string" or msg == "" then
        log.error("util_notify.send", "msg 参数错误，不重发", type(msg))
        return true
    end
    if channel and util_notify_channel[channel] == nil then
        log.error("util_notify.send", "未知通知渠道，不重发", channel)
        return true
    end

    local code, headers, body = util_notify_channel[channel](msg)

    -- 无 code：通道函数因"未配置"直接 return，或压根没响应。当作可重试——
    -- 用户很可能只是稍后才把 webhook 填上，别把这条消息判死。
    if code == nil then
        log.warn("util_notify.send", "发送失败(未配置/无响应)，等待重试", "channel:", channel)
        return false
    end
    -- 4xx 配置类终态错误（400/401/403/404/410/414）：改配置才可能好，**不能当成功**。
    -- 这里刻意返回 false 走重试，因为纯本地版没有别的地方能落这条消息，
    -- 万一只是临时故障（部分网关会返回 403），重试还能救回来。
    if code == 400 or code == 401 or code == 403 or code == 404 or code == 410 or code == 414 then
        log.error("util_notify.send", "配置类失败(终态)，仍按失败重试", "code:", code, "body:", body)
        return false
    end
    if code >= 200 and code < 300 then
        log.info("util_notify.send", "发送通知成功", "code:", code, "body:", body)
        return true
    end
    -- 3xx 未跟随重定向、以及 4xx 里的非终态码：都不算送达
    if code >= 300 and code < 500 and code ~= 408 and code ~= 409 and code ~= 425 and code ~= 429 then
        log.warn("util_notify.send", "疑似未送达(3xx/4xx)", "code:", code)
        return false
    end
    log.error("util_notify.send", "发送通知失败, 等待重发", "code:", code, "body:", body)
    return false
end

--- 加入发送队列
-- @param msg 字符串或字符串数组（数组会按行拼成一条）
-- @param channels 通道列表，默认取 config.NOTIFY_TYPE
-- @param id 消息 id（补发时传入以复用同一条 fskv 记录）
function util_notify.add(msg, channels, id)
    if type(msg) == "string" and msg:find("#BOOT_") and not config.BOOT_NOTIFY then
        log.info("util_notify.add", "BOOT_NOTIFY 关闭，忽略上线通知")
        return
    end

    msg_count = msg_count + 1
    if id == nil or id == "" then
        id = "msg-t" .. os.time() .. "c" .. msg_count .. "r" .. math.random(9999)
    end

    -- 去重：该 id 仍在途就跳过，防止"定时重扫"和实时队列打架（同一条发两遍）
    if inflight[id] then
        log.info("util_notify.add", "该 id 在途中，跳过重复入队", id)
        return
    end

    if type(msg) == "table" then
        msg = table.concat(msg, "\n")
    end

    channels = channels or config.NOTIFY_TYPE
    if type(channels) ~= "table" then
        channels = { channels }
    end

    -- ① 立刻落盘：杜绝"还没来得及首发就断电/重启"造成的丢失
    if is_durable(msg) then
        fskv.set(id, msg)
    end

    inflight[id] = #channels
    for _, channel in ipairs(channels) do
        table.insert(msg_queue, { id = id, channel = channel, msg = msg, retry = 0, born = os.time() })
    end
    sys.publish("NEW_MSG")
    log.debug("util_notify.add", "入队, 队列长度:", #msg_queue, "id:", id)
end

--- 队列轮询（由下面的常驻 task 反复调用）
local function poll()
    -- 未注册网络时快跳：省掉一次 20 秒的 HTTP 超时，被动等 IP_READY
    if mobile.status() ~= 1 then
        log.warn("util_notify.poll", "网络未就绪，等待恢复", util_mobile.status())
        sys.waitUntil("IP_READY", 30000)
        return
    end

    if next(msg_queue) == nil then
        sys.waitUntil("NEW_MSG", 1000 * 10)
        return
    end

    local item = msg_queue[1]
    table.remove(msg_queue, 1)

    -- 超过单轮重试上限：要么低频续命，要么超时彻底放弃
    if item.retry > (tonumber(config.NOTIFY_RETRY_MAX) or 5) then
        local ttl_h = tonumber(config.NOTIFY_MSG_TTL_HOURS) or 72
        local age = os.time() - (item.born or os.time())
        if ttl_h > 0 and age > ttl_h * 3600 then
            log.error("util_notify.poll", "超过存活时间，彻底放弃", item.id,
                "已等待" .. math.floor(age / 3600) .. "小时，请检查通道配置")
            finish_item(item.id, false)          -- 删 fskv，别再占空间
        else
            log.warn("util_notify.poll", "超单轮上限，转低频补发（fskv 副本保留）", item.id)
            finish_item(item.id, true)           -- 交给 5 分钟重扫继续试
        end
        return
    end

    local msg = item.msg
    if config.NOTIFY_APPEND_MORE_INFO and not string.find(msg, "开机时长:") then
        msg = msg .. util_mobile.appendDeviceInfo()
    end
    if error_count > 0 then
        msg = msg .. "\n重发次数: " .. error_count
    end

    if send(msg, item.channel) then
        error_count = 0
        finish_item(item.id, false)
        return
    end

    -- 失败：回队 + 指数退避。⚠ 这里绝不切飞行模式（见 util_watchdog.lua 文件头铁律1）
    error_count = error_count + 1
    item.retry = item.retry + 1
    table.insert(msg_queue, item)
    local backoff = math.min(5000 * (2 ^ math.min(item.retry, 6)), SLOW_RETRY_INTERVAL)
    log.warn("util_notify.poll", "等待下次重发", "id:", item.id, "重发次数:", item.retry,
             "连续失败:", error_count, "退避:", backoff .. "ms")
    sys.wait(backoff)
end

--- 从 fskv 补发未完成的历史消息（开机后 + 每 5 分钟）
function util_notify.resend_from_fskv()
    local keys = {}
    local iter = fskv.iter()
    if iter then
        while true do
            local k = fskv.next(iter)
            if not k then break end
            if type(k) == "string" and k:sub(1, 4) == "msg-" then
                keys[#keys + 1] = k
            end
        end
    end
    local n = 0
    for _, id in ipairs(keys) do
        if not inflight[id] then
            -- ⚠ LuatOS 的 fskv.get 在键不存在时返回"零个值"而不是 nil，
            --   所以必须先落到局部变量，绝不能内联成 tonumber(fskv.get(k)) —— 那会崩掉整个 Lua VM。
            local v = fskv.get(id)
            if type(v) == "string" and v ~= "" then
                util_notify.add(v, nil, id)
                n = n + 1
            end
        end
    end
    if n > 0 then
        log.info("util_notify", "从 fskv 补发", n, "条未完成消息")
    end
end

function util_notify.queue_len()
    return #msg_queue
end

-- 主发送循环：pcall 兜底，poll 里任何异常都不许杀死这个 task，
-- 否则设备从此不再转发，而且表面上看还在正常运行——这是最难发现的一类故障。
sys.taskInit(function()
    while true do
        local ok, err = pcall(poll)
        if not ok then
            log.error("util_notify", "poll 异常已捕获，3s 后继续", tostring(err))
            sys.wait(3000)
        end
        sys.wait(100)
    end
end)

-- 开机 + 定时重扫：把"会话内放弃 / 断电重启前没发出去"的消息重新入队
sys.taskInit(function()
    sys.waitUntil("IP_READY")
    sys.wait(10000)
    while true do
        util_notify.resend_from_fskv()
        sys.wait(RESYNC_INTERVAL)
    end
end)

return util_notify
