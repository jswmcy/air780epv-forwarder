-- config.lua · 纯本地短信转发器配置
-- 这是唯一需要改的文件。改完用 Luatools 重新下载脚本即可生效，不用重新编译固件。
--
-- ⚠ 安全提醒：下面所有 webhook / token / 密码都是**敏感凭据**，拿到就能以你的身份发消息。
--   公开仓库里请保持占位值，或把本文件加进 .gitignore 后提交一份 config.example.lua。
--
-- 字段分两类：
--   【必填】至少配一个通知通道，否则收到短信无处可发
--   【可选】不改动就能跑

return {
    --==========================================================================
    -- 一、通知通道
    --==========================================================================
    -- 启用的通道，可多选，同一条短信会**依次推到每个勾选的通道**（不是只发第一个）。
    -- 可选值：
    --   "dingtalk" 钉钉机器人      "feishu" 飞书机器人       "wecom"  企业微信机器人
    --   "telegram" Telegram        "bark"   Bark(iOS)       "pushdeer" PushDeer
    --   "wxpusher" WxPusher(多人)  "wxpusher_spt" WxPusher极简(仅本人)
    --   "gotify"   Gotify          "pushover" Pushover       "custom_post" 自定义HTTP
    --   "inotify"  inotify.luatos  "next-smtp-proxy" SMTP代理 "smtp" 邮件
    --   "serial"   串口输出（配合下面的 ROLE 用）
    -- 当前启用：WxPusher 极简（扫码关注公众号即可，不需要任何服务器）。
    -- 想加钉钉就把 "dingtalk" 补进表里，并先把下面的 webhook 换成真实 token，
    -- 否则那条通道会一直重试到上限后静默丢弃（不影响其它通道）。
    NOTIFY_TYPE = { "wxpusher_spt" },

    ------------------------------------------------------------------ 钉钉机器人
    -- 群设置 → 智能群助手 → 添加自定义机器人。安全设置二选一：
    --   ①「自定义关键词」：关键词填 SMS（本项目的通知正文都带 #SMS 标记）→ DINGTALK_SECRET 留空
    --   ②「加签」：把生成的 secret 填 DINGTALK_SECRET（推荐，比关键词可靠）
    DINGTALK_WEBHOOK = "https://oapi.dingtalk.com/robot/send?access_token=在这里粘贴你的token",
    DINGTALK_SECRET = "",

    ------------------------------------------------------------------ 飞书 / 企业微信
    FEISHU_WEBHOOK = "",
    WECOM_WEBHOOK = "",

    ------------------------------------------------------------------ Telegram
    -- {token} 会被替换成 TELEGRAM_CHAT_ID 前先自行替换：本项目直接把整条 URL 当模板，
    -- 所以请把 bot<TOKEN> 换成你的真实 bot token。chat_id 从 @userinfobot 获取。
    TELEGRAM_API = "https://api.telegram.org/bot你的BOT_TOKEN/sendMessage",
    TELEGRAM_CHAT_ID = "",

    ------------------------------------------------------------------ Bark(iOS)
    -- App 里那串 key（https://github.com/Finb/Bark）
    BARK_API = "https://api.day.app",
    BARK_KEY = "",

    ------------------------------------------------------------------ PushDeer
    PUSHDEER_API = "https://api2.pushdeer.com/message/push",
    PUSHDEER_KEY = "",

    ------------------------------------------------------------------ WxPusher（两条独立通道，可同时启用）
    -- ① appToken 版：需在 wxpusher.zjiecode.com 后台创建应用拿 appToken，
    --    接收人关注公众号后在「用户管理」拿 UID（多个用逗号分隔）。**支持多人接收**。
    WXPUSHER_API = "https://wxpusher.zjiecode.com/api/send/message",
    WXPUSHER_APP_TOKEN = "",
    WXPUSHER_UIDS = "",
    WXPUSHER_CONTENT_TYPE = 1,          -- 1=文本 2=HTML 3=Markdown

    -- ② 极简版：扫码关注 WxPusher 公众号即可拿 SPT（SPT_ 开头），不用创建应用，
    --    但**只能推给扫码的那个人**。勾选 "wxpusher_spt" 即走这条。
    -- ⚠ 这串值是凭据：拿到就能往你的微信推消息。分享/提交前确认它是空的。
    WXPUSHER_SPT = "",
    WXPUSHER_SUMMARY = "Air780EPV 短信转发",   -- 微信通知栏那一行标题

    ------------------------------------------------------------------ Gotify / Pushover / inotify
    GOTIFY_API = "",
    GOTIFY_TOKEN = "",
    GOTIFY_TITLE = "Air780EPV",
    GOTIFY_PRIORITY = 8,
    PUSHOVER_API_TOKEN = "",
    PUSHOVER_USER_KEY = "",
    INOTIFY_API = "",                   -- 形如 https://push.luatos.org/XXXXXX.send

    ------------------------------------------------------------------ 自定义 HTTP POST
    -- 想接自己的服务/网关就改这三行；{msg} 会被替换成通知内容
    CUSTOM_POST_URL = "https://example.com/sms-hook",
    CUSTOM_POST_CONTENT_TYPE = "application/json",
    CUSTOM_POST_BODY_TABLE = { ["title"] = "新短信", ["desp"] = "{msg}" },

    ------------------------------------------------------------------ 邮件（SMTP / SMTP 代理）
    SMTP_HOST = "smtp.qq.com",
    SMTP_PORT = 465,
    SMTP_USERNAME = "",                 -- 例：你的邮箱@qq.com
    SMTP_PASSWORD = "",                 -- QQ/163 请用「授权码」而非登录密码
    -- ⚠ 这个怪键名就是「SMTP 发件人地址」，沿用上游固件的历史命名，别改：
    --   云端把配置当 JSON blob 存库、设备按键名取值，改名会让已部署设备的该字段直接失联。
    --   全链路引用共 4 处：本文件 / util_notify_channel.lua / remote_config.lua 白名单 / cloud/schema.py
    SMTP_MAIL_FROM = "",
    SMTP_MAIL_TO = "",
    SMTP_MAIL_SUBJECT = "来自 Air780EPV 的通知",
    SMTP_MAIL_SUBJECT_BOOT = "来自 Air780EPV 的通知 - 上线通知",
    SMTP_MAIL_SUBJECT_SMS = "来自 Air780EPV 的通知 - 正常短信转发",
    SMTP_TLS_ENABLE = true,
    -- 不想自己配 SMTP 服务器时可用现成代理（留空即不启用）
    NEXT_SMTP_PROXY_API = "",
    NEXT_SMTP_PROXY_USER = "",
    NEXT_SMTP_PROXY_PASSWORD = "",
    NEXT_SMTP_PROXY_HOST = "smtp-mail.outlook.com",
    NEXT_SMTP_PROXY_PORT = 587,
    NEXT_SMTP_PROXY_FORM_NAME = "Air780EPV",
    NEXT_SMTP_PROXY_TO_EMAIL = "",
    NEXT_SMTP_PROXY_SUBJECT = "来自 Air780EPV 的通知",

    --==========================================================================
    -- 二、转发行为
    --==========================================================================
    -- 单条消息的**重试上限**（超过后不再死磕，但消息仍留在 flash 里按更长间隔补发，
    -- 直到超过 NOTIFY_MSG_TTL_HOURS 才彻底放弃并记 error）。
    NOTIFY_RETRY_MAX = 5,
    -- 一条待转发消息的最长存活时间（小时）。超时即放弃，防止永久失败的消息把 flash 越堆越多。
    NOTIFY_MSG_TTL_HOURS = 72,
    -- 通知里附带设备信息（信号/运营商/开机时长等）。关掉后通知更短。
    NOTIFY_APPEND_MORE_INFO = true,
    -- 开机上线通知（会消耗一次流量）
    -- 关掉后开机不发任何东西。注意这条本来就不落盘、不进 72 小时补发队列
    -- （只有 #SMS/#CALL 会存盘重扫），语义是"联网后重试次数内能发就发"。
    BOOT_NOTIFY = false,

    --==========================================================================
    -- 三、短信指令（都只有 ADMIN_PHONE 发来的才生效）
    --==========================================================================
    -- 管理员号码：只有它发来的短信能触发下面的指令；留空 = 关闭全部远程指令
    ADMIN_PHONE = "",
    -- 代发格式：SMS,<目标号码>,<内容> —— 设备收到后用自己的号码把内容转发出去。
    -- ⚠ 会产生短信费，且任何知道 ADMIN_PHONE 的人都能让设备发短信，请务必设置管理员号。
    SMS_SEND_ENABLED = true,
    -- 号码黑名单：每行一个号码，命中的来件短信**直接丢弃不转发**（用于屏蔽营销号）
    NUMBER_BLACKLIST = "",

    --==========================================================================
    -- 四、定时任务（单位毫秒，0 = 关闭）
    --==========================================================================
    -- 定时同步时间（NTP 用 ntp.aliyun.com）。时间不准会导致通知里的发件时间错乱。
    SNTP_INTERVAL = 1000 * 60 * 60 * 6,     -- 6 小时
    -- 定时向运营商查流量（移动发 10086 CXLL / 联通 10010 2082 / 电信 10001 108）
    QUERY_TRAFFIC_INTERVAL = 0,
    -- 定时基站定位，结果附在通知里。室内/弱信号常查不到，建议保持 0。
    LOCATION_INTERVAL = 0,
    -- 定时"我还活着"上报
    REPORT_INTERVAL = 0,
    -- 卫生重启周期：兜底极端情况下的内存/句柄累积。0 = 关闭。
    -- 现在设 2 小时 = 每天 12 次重启。代价要清楚知道：
    --   ① 每次约 1 分钟不可用窗口，落在窗口里的短信靠运营商 SMSC 重投，一般会补上，
    --      但个别卡/运营商不重投就会漏（漏了不会有任何提示，因为设备当时不在线）；
    --   ② 每次重启都要重新注册网络 + 拉一次 IP，长期看是一笔流量与信令开销。
    -- 注意：卡死防护不靠它（有硬件看门狗 wdt），网络故障也不靠它（固件自动重注册 +
    -- util_watchdog 的锚点探测）。这里刻意【不】用"切飞行模式"来保号 —— 见 util_watchdog.lua
    -- 铁律1：应用层切飞行模式会与固件 auto_reset_stack 抢射频，实测酿成死亡螺旋直到 ramdump。
    REBOOT_INTERVAL = 2 * 60 * 60 * 1000,    -- 2 小时

    --==========================================================================
    -- 五、网络看门狗（详见 util_watchdog.lua，里面有踩坑说明）
    --==========================================================================
    -- 探测间隔：仅在上一次探测失败后按此节奏重试；外网正常时不浪费这次握手
    WATCHDOG_PROBE_INTERVAL = 1000 * 60 * 5,
    -- 外网探测全灭多久算"真卡死"并重启设备。设很大等于关闭本功能。
    WATCHDOG_REBOOT_AFTER = 1000 * 60 * 120,   -- 2 小时

    --==========================================================================
    -- 六、指示灯（默认全关，暗环境部署）
    --==========================================================================
    -- true = 常灭（默认）。想保留"极短亮 + 长间隔"的活动闪烁就改成 false。
    LED_DISABLE = true,
    -- 网络指示灯引脚。Air780EPV 开发板是 GPIO27；换型号请按规格书核对。
    -- ⚠ 不确定就填 nil —— 程序不会去猜引脚（猜错可能撞上 SIM/UART/天线控制脚），只是不处理它。
    NETLED_PIN = 27,
    -- "灭"对应的电平：0=低电平灭（常见 NPN 驱动，默认）；1=高电平灭（共阳/带反相驱动时填 1）
    NETLED_OFF_LEVEL = 0,
    -- 其它由模组 GPIO 驱动的灯（用户灯等），一并拉灭。填引脚号列表，如 { 27, 28 }
    LED_OFF_PINS = {},
    -- 仅 LED_DISABLE=false 时生效
    NETLED_BLINK_ON = 1,                  -- 亮 1ms
    NETLED_BLINK_INTERVAL = 30000,        -- 每 30s 一次

    --==========================================================================
    -- 七、其它
    --==========================================================================
    -- 本机号码：优先用网络下发（mobile.number()）；取不到时用这个兜底显示。留空则通知里不显示号码
    FALLBACK_LOCAL_NUMBER = "",
    -- SIM 卡 PIN 码。⚠ 敏感：没有强制需求请留空，避免凭据留在代码里
    PIN_CODE = "",
    -- 串口角色（仅 NOTIFY_TYPE 含 "serial" 时有意义）：
    --   MASTER 主机：收到短信 → 同时推网络通道 + 从串口输出
    --   SLAVE  从机：串口收到的数据原样转发（不做网络推送）
    ROLE = "MASTER",
}
