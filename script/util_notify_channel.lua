local lib_smtp = require "lib_smtp"

local function urlencodeTab(params)
    local msg = {}
    for k, v in pairs(params) do
        table.insert(msg, string.urlEncode(k) .. "=" .. string.urlEncode(v))
        table.insert(msg, "&")
    end
    table.remove(msg)
    return table.concat(msg)
end

return {
    -- 发送到 custom_post
    ["custom_post"] = function(msg)
        if config.CUSTOM_POST_URL == nil or config.CUSTOM_POST_URL == "" then
            log.error("util_notify", "未配置 `config.CUSTOM_POST_URL`")
            return
        end
        if type(config.CUSTOM_POST_BODY_TABLE) ~= "table" then
            log.error("util_notify", "未配置 `config.CUSTOM_POST_BODY_TABLE`")
            return
        end

        local header = { ["content-type"] = config.CUSTOM_POST_CONTENT_TYPE }
        local body = json.decode(json.encode(config.CUSTOM_POST_BODY_TABLE))
        -- 遍历并替换其中的变量。
        -- 注意：gsub 的替换串里 % 是元字符，短信含 "50%" 会抛 invalid use of '%'。
        --       先把替换串里的 % 转义成 %% 再替换。
        local repl = tostring(msg):gsub("%%", "%%%%")
        local function traverse_and_replace(t)
            for k, v in pairs(t) do
                if type(v) == "table" then
                    traverse_and_replace(v)
                elseif type(v) == "string" then
                    t[k] = string.gsub(v, "{msg}", repl)
                end
            end
        end
        traverse_and_replace(body)

        -- 根据 content-type 进行编码, 默认为 application/x-www-form-urlencoded
        if string.find(config.CUSTOM_POST_CONTENT_TYPE, "json") then
            body = json.encode(body)
        else
            body = urlencodeTab(body)
        end

        log.info("util_notify", "POST", config.CUSTOM_POST_URL, config.CUSTOM_POST_CONTENT_TYPE, body)
        return util_http.fetch(nil, "POST", config.CUSTOM_POST_URL, header, body)
    end,
    -- 发送到 telegram
    ["telegram"] = function(msg)
        if config.TELEGRAM_API == nil or config.TELEGRAM_API == "" then
            log.error("util_notify", "未配置 `config.TELEGRAM_API`")
            return
        end
        if config.TELEGRAM_CHAT_ID == nil or config.TELEGRAM_CHAT_ID == "" then
            log.error("util_notify", "未配置 `config.TELEGRAM_CHAT_ID`")
            return
        end

        local header = { ["content-type"] = "application/json" }
        local body = { ["chat_id"] = config.TELEGRAM_CHAT_ID, ["disable_web_page_preview"] = true, ["text"] = msg }

        log.info("util_notify", "POST", config.TELEGRAM_API)
        return util_http.fetch(nil, "POST", config.TELEGRAM_API, header, json.encode(body))
    end,
    -- 发送到 gotify
    ["gotify"] = function(msg)
        if config.GOTIFY_API == nil or config.GOTIFY_API == "" then
            log.error("util_notify", "未配置 `config.GOTIFY_API`")
            return
        end
        if config.GOTIFY_TOKEN == nil or config.GOTIFY_TOKEN == "" then
            log.error("util_notify", "未配置 `config.GOTIFY_TOKEN`")
            return
        end

        local url = config.GOTIFY_API .. "/message?token=" .. config.GOTIFY_TOKEN
        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = { title = config.GOTIFY_TITLE, message = msg, priority = config.GOTIFY_PRIORITY }

        log.info("util_notify", "POST", config.GOTIFY_API)
        return util_http.fetch(nil, "POST", url, header, json.encode(body))
    end,
    -- 发送到 pushdeer
    ["pushdeer"] = function(msg)
        if config.PUSHDEER_API == nil or config.PUSHDEER_API == "" then
            log.error("util_notify", "未配置 `config.PUSHDEER_API`")
            return
        end
        if config.PUSHDEER_KEY == nil or config.PUSHDEER_KEY == "" then
            log.error("util_notify", "未配置 `config.PUSHDEER_KEY`")
            return
        end

        local header = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        local body = { pushkey = config.PUSHDEER_KEY or "", type = "text", text = msg }

        log.info("util_notify", "POST", config.PUSHDEER_API)
        return util_http.fetch(nil, "POST", config.PUSHDEER_API, header, urlencodeTab(body))
    end,
    -- 发送到 bark
    ["bark"] = function(msg)
        if config.BARK_API == nil or config.BARK_API == "" then
            log.error("util_notify", "未配置 `config.BARK_API`")
            return
        end
        if config.BARK_KEY == nil or config.BARK_KEY == "" then
            log.error("util_notify", "未配置 `config.BARK_KEY`")
            return
        end

        local header = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        local body = { body = msg }
        local url = config.BARK_API .. "/" .. config.BARK_KEY

        log.info("util_notify", "POST", url)
        return util_http.fetch(nil, "POST", url, header, urlencodeTab(body))
    end,
    -- 发送到 WxPusher（微信公众号消息推送）
    -- API: POST https://wxpusher.zjiecode.com/api/send/message
    -- 成功约定：HTTP 200 且 body.code == 1000；业务失败(1001 等)同样回 HTTP 200，
    -- 必须像钉钉通道一样内检，否则"200 但没送达"会被判成功并删 fskv → 静默丢消息
    ["wxpusher"] = function(msg)
        if config.WXPUSHER_API == nil or config.WXPUSHER_API == "" then
            log.error("util_notify", "未配置 `config.WXPUSHER_API`")
            return
        end
        if config.WXPUSHER_APP_TOKEN == nil or config.WXPUSHER_APP_TOKEN == "" then
            log.error("util_notify", "未配置 `config.WXPUSHER_APP_TOKEN`")
            return
        end
        local uids = {}
        for u in tostring(config.WXPUSHER_UIDS or ""):gmatch("[^,%s]+") do uids[#uids + 1] = u end
        if #uids == 0 then
            log.error("util_notify", "未配置 `config.WXPUSHER_UIDS`")
            return
        end

        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local ct = tonumber(config.WXPUSHER_CONTENT_TYPE) or 1
        if ct ~= 2 and ct ~= 3 then ct = 1 end       -- 1=文本 2=HTML 3=MD，其余一律按文本
        local body = json.encode({
            appToken = config.WXPUSHER_APP_TOKEN,
            content = msg,
            contentType = ct,
            uids = uids,
        })

        log.info("util_notify", "POST", config.WXPUSHER_API)
        local res_code, res_headers, res_body = util_http.fetch(nil, "POST", config.WXPUSHER_API, header, body)

        -- 业务码分类，勿一律转 500：1001 内容超限 / 1002 令牌无效是【永久失败】，
        -- 重试到上限只是白耗流量并把配置错误伪装成网络抖动。400 在 util_notify 里是终态、直接走兜底。
        if res_code == 200 and res_body and res_body ~= "" then
            local ok, res_data = pcall(json.decode, res_body)
            if ok and res_data then
                local biz = tonumber(res_data.code) or 0
                if biz == 1000 then
                    return 200, res_headers, res_body
                end
                if biz == 1001 or biz == 1002 then
                    log.error("util_notify", "WxPusher永久失败(不重试)", "code:", biz, res_data.msg)
                    return 400, res_headers, res_body
                end
                log.warn("util_notify", "WxPusher业务失败(转可重试)", "code:", biz, "msg:", res_data.msg)
                return 500, res_headers, res_body
            end
        end
        return res_code, res_headers, res_body
    end,
    -- 发送到 WxPusher · 极简推送（SPT）
    -- 与上面 appToken+UIDs 版是【两个独立渠道】：NOTIFY_TYPE 里分别为 wxpusher / wxpusher_spt，
    -- 可同时勾选（各推一条）。极简推送不用建应用，微信扫码关注后拿 SPT 即可，
    -- 但只能推给扫码者本人；要多人接收就勾 appToken 那个。
    -- API: POST https://wxpusher.zjiecode.com/api/send/message/simple-push
    --      body = {spt, content, summary, contentType}，成功同样要内检 body.code==1000
    ["wxpusher_spt"] = function(msg)
        if config.WXPUSHER_SPT == nil or config.WXPUSHER_SPT == "" then
            log.error("util_notify", "未配置 `config.WXPUSHER_SPT`")
            return
        end
        local url = "https://wxpusher.zjiecode.com/api/send/message/simple-push"
        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        -- 摘要兜底：Lua 里空串是真值，`x or 默认` 对云端下发的空串无效，必须显式判空
        local summary = tostring(config.WXPUSHER_SUMMARY or "")
        if summary == "" then summary = "Air780EPV 短信转发" end
        -- contentType 固定 1=纯文本。刻意不给这条通道做类型开关：两个卡片同在
        -- 一个 form 内，复用 WXPUSHER_CONTENT_TYPE 会变成重名输入框互相覆盖。
        local body = json.encode({
            spt = config.WXPUSHER_SPT,
            content = msg,
            summary = summary,
            contentType = 1,
        })

        log.info("util_notify", "POST", url)
        local res_code, res_headers, res_body = util_http.fetch(nil, "POST", url, header, body)

        if res_code == 200 and res_body and res_body ~= "" then
            local ok, res_data = pcall(json.decode, res_body)
            if ok and res_data then
                local biz = tonumber(res_data.code) or 0
                if biz == 1000 then
                    return 200, res_headers, res_body
                end
                if biz == 1001 or biz == 1002 then
                    log.error("util_notify", "WxPusher极简永久失败(不重试)", "code:", biz, res_data.msg)
                    return 400, res_headers, res_body
                end
                log.warn("util_notify", "WxPusher极简业务失败(转可重试)", "code:", biz, "msg:", res_data.msg)
                return 500, res_headers, res_body
            end
        end
        return res_code, res_headers, res_body
    end,
    -- 发送到 dingtalk
    ["dingtalk"] = function(msg)
        if config.DINGTALK_WEBHOOK == nil or config.DINGTALK_WEBHOOK == "" then
            log.error("util_notify", "未配置 `config.DINGTALK_WEBHOOK`")
            return
        end

        local url = config.DINGTALK_WEBHOOK
        -- 如果配置了 config.DINGTALK_SECRET 则需要签名(加签), 没配置则为自定义关键词
        if (config.DINGTALK_SECRET and config.DINGTALK_SECRET ~= "") then
            -- 时间异常则等待同步
            if os.time() < 1714500000 then
                socket.sntp("ntp.aliyun.com")
                sys.waitUntil("NTP_UPDATE", 1000 * 10)
            end
            local timestamp = tostring(os.time()) .. "000"
            local sign = crypto.hmac_sha256(timestamp .. "\n" .. config.DINGTALK_SECRET, config.DINGTALK_SECRET):fromHex():toBase64():urlEncode()
            url = url .. "&timestamp=" .. timestamp .. "&sign=" .. sign
        end

        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = { msgtype = "text", text = { content = msg } }
        body = json.encode(body)

        log.info("util_notify", "POST", url)
        local res_code, res_headers, res_body = util_http.fetch(nil, "POST", url, header, body)

        -- 处理响应：钉钉即使 HTTP 200，只要 errcode≠0 也当“可重试失败”，避免静默丢弃
        -- https://open.dingtalk.com/document/orgapp/custom-robots-send-group-messages
        if res_code == 200 and res_body and res_body ~= "" then
            local ok, res_data = pcall(json.decode, res_body)
            if ok and res_data then
                local errcode = res_data.errcode or 0
                local errmsg = res_data.errmsg or ""
                if errcode ~= 0 then
                    if errcode == 310000 and (string.find(errmsg, "timestamp") or string.find(errmsg, "过期")) then
                        socket.sntp("ntp.aliyun.com") -- 时间戳过期，先对时再重试
                    end
                    return 500, res_headers, res_body
                end
            end
        end
        return res_code, res_headers, res_body
    end,
    -- 发送到 feishu
    ["feishu"] = function(msg)
        if config.FEISHU_WEBHOOK == nil or config.FEISHU_WEBHOOK == "" then
            log.error("util_notify", "未配置 `config.FEISHU_WEBHOOK`")
            return
        end

        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = { msg_type = "text", content = { text = msg } }

        log.info("util_notify", "POST", config.FEISHU_WEBHOOK)
        local res_code, res_headers, res_body = util_http.fetch(nil, "POST", config.FEISHU_WEBHOOK, header, json.encode(body))
        -- 飞书即使 HTTP 200，code/StatusCode≠0 也当“可重试失败”
        if res_code == 200 and res_body and res_body ~= "" then
            local ok, d = pcall(json.decode, res_body)
            if ok and d then
                local c = d.code
                if c == nil then c = d.StatusCode end
                if (c or 0) ~= 0 then
                    return 500, res_headers, res_body
                end
            end
        end
        return res_code, res_headers, res_body
    end,
    -- 发送到 wecom
    ["wecom"] = function(msg)
        if config.WECOM_WEBHOOK == nil or config.WECOM_WEBHOOK == "" then
            log.error("util_notify", "未配置 `config.WECOM_WEBHOOK`")
            return
        end

        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = { msgtype = "text", text = { content = msg } }

        log.info("util_notify", "POST", config.WECOM_WEBHOOK)
        local res_code, res_headers, res_body = util_http.fetch(nil, "POST", config.WECOM_WEBHOOK, header, json.encode(body))

        -- 处理响应
        -- https://developer.work.weixin.qq.com/document/path/90313
        if res_code == 200 and res_body and res_body ~= "" then
            local ok, res_data = pcall(json.decode, res_body)
            if ok and res_data then
                local errcode = res_data.errcode or 0
                if errcode ~= 0 then
                    return 500, res_headers, res_body -- 任意业务错误都可重试
                end
            end
        end
        return res_code, res_headers, res_body
    end,
    -- 发送到 pushover
    ["pushover"] = function(msg)
        if config.PUSHOVER_API_TOKEN == nil or config.PUSHOVER_API_TOKEN == "" then
            log.error("util_notify", "未配置 `config.PUSHOVER_API_TOKEN`")
            return
        end
        if config.PUSHOVER_USER_KEY == nil or config.PUSHOVER_USER_KEY == "" then
            log.error("util_notify", "未配置 `config.PUSHOVER_USER_KEY`")
            return
        end

        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = { token = config.PUSHOVER_API_TOKEN, user = config.PUSHOVER_USER_KEY, message = msg }
        local url = "https://api.pushover.net/1/messages.json"

        log.info("util_notify", "POST", url)
        return util_http.fetch(nil, "POST", url, header, json.encode(body))
    end,
    -- 发送到 inotify
    ["inotify"] = function(msg)
        if config.INOTIFY_API == nil or config.INOTIFY_API == "" then
            log.error("util_notify", "未配置 `config.INOTIFY_API`")
            return
        end
        if not config.INOTIFY_API:endsWith(".send") then
            log.error("util_notify", "`config.INOTIFY_API` 必须以 `.send` 结尾")
            return
        end

        local url = config.INOTIFY_API .. "/" .. string.urlEncode(msg)

        log.info("util_notify", "GET", url)
        return util_http.fetch(nil, "GET", url)
    end,
    -- 发送到 next-smtp-proxy
    ["next-smtp-proxy"] = function(msg)
        if config.NEXT_SMTP_PROXY_API == nil or config.NEXT_SMTP_PROXY_API == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_API`")
            return
        end
        if config.NEXT_SMTP_PROXY_USER == nil or config.NEXT_SMTP_PROXY_USER == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_USER`")
            return
        end
        if config.NEXT_SMTP_PROXY_PASSWORD == nil or config.NEXT_SMTP_PROXY_PASSWORD == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_PASSWORD`")
            return
        end
        if config.NEXT_SMTP_PROXY_HOST == nil or config.NEXT_SMTP_PROXY_HOST == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_HOST`")
            return
        end
        if config.NEXT_SMTP_PROXY_PORT == nil or config.NEXT_SMTP_PROXY_PORT == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_PORT`")
            return
        end
        if config.NEXT_SMTP_PROXY_TO_EMAIL == nil or config.NEXT_SMTP_PROXY_TO_EMAIL == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_TO_EMAIL`")
            return
        end

        local header = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        local body = {
            user = config.NEXT_SMTP_PROXY_USER,
            password = config.NEXT_SMTP_PROXY_PASSWORD,
            host = config.NEXT_SMTP_PROXY_HOST,
            port = config.NEXT_SMTP_PROXY_PORT,
            form_name = config.NEXT_SMTP_PROXY_FORM_NAME,
            to_email = config.NEXT_SMTP_PROXY_TO_EMAIL,
            subject = config.NEXT_SMTP_PROXY_SUBJECT,
            text = msg,
        }

        log.info("util_notify", "POST", config.NEXT_SMTP_PROXY_API)
        return util_http.fetch(nil, "POST", config.NEXT_SMTP_PROXY_API, header, urlencodeTab(body))
    end,

    ["smtp"] = function(msg)
        local subject = config.SMTP_MAIL_SUBJECT  -- 默认主题
        
        -- 判断消息类型
        if msg:find("#BOOT_") then
            subject = config.SMTP_MAIL_SUBJECT_BOOT
        elseif msg:find("#SMS") then
            subject = config.SMTP_MAIL_SUBJECT_SMS
        end

        local smtp_config = {
            host = config.SMTP_HOST,
            port = config.SMTP_PORT,
            username = config.SMTP_USERNAME,
            password = config.SMTP_PASSWORD,
            mail_from = config.SMTP_MAIL_FROM,
            mail_to = config.SMTP_MAIL_TO,
            tls_enable = config.SMTP_TLS_ENABLE,
        }
        local result = lib_smtp.send(msg, subject, smtp_config)  -- 使用动态主题
        log.info("util_notify", "SMTP", result.success, result.message, result.is_retry)
        if result.success then
            return 200, nil, result.message
        end
        if result.is_retry then
            return 500, nil, result.message
        end
        return 400, nil, result.message
    end,

    -- 发送到 serial
    ["serial"] = function(msg)
        uart.write(1, msg)
        log.info("util_notify", "serial", "消息已转发到串口")
        sys.wait(1000)
        return 200
    end,
}
