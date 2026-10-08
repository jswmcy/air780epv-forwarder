-- util_smsctl.lua · 号码过滤与短信指令（纯本地，无任何网络依赖）
-- 职责三件：号码归一化比较、黑名单丢弃、管理员指令（代发短信）。
-- 从云端版的 remote_config.lua 里拆出来 —— 那版把"拉配置"和"号码判断"混在一起，
-- 本地版不需要前者，就单独留一个干净的小模块。
local util_smsctl = {}

-- 号码归一化：只留数字，国内取后 11 位。
-- 为什么必须归一：同一个号码可能以 +8613800000000 / 13800000000 / 8613800000000 出现，
-- 直接字符串比较会漏判（黑名单漏判=垃圾照转发，管理员漏判=指令不生效）。
local function norm_num(n)
    n = tostring(n or ""):gsub("%D", "")
    if #n > 11 then n = n:sub(-11) end
    return n
end

--- 是否管理员号码（config.ADMIN_PHONE）
function util_smsctl.is_admin(sender)
    local a = config.ADMIN_PHONE
    if not a or a == "" then return false end
    local s = norm_num(sender)
    return s ~= "" and s == norm_num(a)
end

--- 是否命中黑名单（config.NUMBER_BLACKLIST，每行一个号码）
function util_smsctl.is_blacklisted(sender)
    local bl = config.NUMBER_BLACKLIST
    if not bl or bl == "" then return false end
    local s = norm_num(sender)
    if s == "" then return false end
    for line in tostring(bl):gmatch("[^\r\n]+") do
        if norm_num(line) == s then return true end
    end
    return false
end

--- 解析"代发"指令：SMS,<目标号码>,<内容>
-- @return 目标号码, 内容；不是代发格式则返回 nil
-- 号码长度 5~20 的约束是防呆：太短多半是格式写错，太长可能是构造出来的怪串。
function util_smsctl.parse_send(sms_content)
    if config.SMS_SEND_ENABLED == false then return nil end
    local phone, content = tostring(sms_content or ""):match("^%s*SMS,(+?%d+),(.+)$")
    if not phone or not content then return nil end
    if #phone < 5 or #phone > 20 then return nil end
    return phone, content
end

return util_smsctl
