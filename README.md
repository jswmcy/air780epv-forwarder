# Air780EPV 短信转发器（纯本地版）

插一张手机卡，收到短信就自动推到你微信/钉钉/邮箱。**不需要服务器、不需要WIFI、不需要内网穿透**——
设备使用4G直连各家推送服务的 HTTPS 接口，月消耗流量约10M。

适合：把某张卡的验证码、通知转发到自己手机上，非常推荐wxpusher通知渠道。
https://wxpusher.zjiecode.com/

```
短信到达 → Air780EPV 模组 → 4G 网络 → HTTPS → 你的微信 / 钉钉 / 飞书 / 邮箱 …
```

---

## 你需要准备

| 物品 | 注意什么 |
|---|---|
| **Air780EPV/M 开发板** | 确认板子支持你那张卡的运营商（有全网通版，也有单运营商版） |
| **一张能收发短信的 SIM** | 能正常打电话收发短信的卡 |
| 天线 | 外置天线座要拧上天线，别裸奔 |
| 5V / 1A 以上供电 | ⚠ 第二个常见坑：Cat.1 发射瞬间电流很大，供电不足会导致**反复重启**（现象很像程序 bug，其实是电源） |
| 一个能收推送的账号 | 微信（WxPusher 公众号，扫码即可）或钉钉群机器人，二选一即可 |

---

## 5 分钟跑通（推到微信，最简单）

### ① 拿一个 WxPusher 的 SPT

手机微信搜索公众号 **WxPusher**，关注后在公众号内获取一串 `SPT_` 开头的令牌（SPT），复制下来。

> 这条路只能推给**你自己**（扫码的那个人），不需要创建应用、不需要服务器。
> 要给多人推，见下面「换别的通道」。

### ② 改配置

打开 `script/config.lua`，只需要动一行：

```lua
WXPUSHER_SPT = "SPT_你刚拿到的那串",     -- ← 填这里
```

（`NOTIFY_TYPE = { "wxpusher_spt" }` 已经是默认值，不用改。）

### ③ 刷进设备

1. 装 [Luatools](https://luatos.com/)（合宙官方调试工具）。
2. 板子接电脑，Luatools 里**选中 `script` 整个目录** → 「功能」→「**下载脚本**」。
   > 必须是「下载脚本」。如果板子还是出厂 AT 固件，要先刷一个 LuatOS 固件（`.pac`）再做这步。
3. 等它跑起来。给这张卡发一条短信，微信应该几秒内收到推送。

没收到？跳到下面的[排错](#收不到通知按这个顺序查)。

---

## 换别的通道

`NOTIFY_TYPE` 是个列表，可以多选，同一条短信会**依次推到每个勾选的通道**。

| 通道 | `NOTIFY_TYPE` 里填 | 需要配置 |
|---|---|---|
| WxPusher 极简（仅本人） | `wxpusher_spt` | `WXPUSHER_SPT` |
| WxPusher（多人） | `wxpusher` | `WXPUSHER_APP_TOKEN` + `WXPUSHER_UIDS` |
| 钉钉群机器人 | `dingtalk` | `DINGTALK_WEBHOOK`（加签方式再填 `DINGTALK_SECRET`） |
| 飞书群机器人 | `feishu` | `FEISHU_WEBHOOK` |
| 企业微信群机器人 | `wecom` | `WECOM_WEBHOOK` |
| Telegram | `telegram` | `TELEGRAM_API`（把 `bot你的BOT_TOKEN` 换成真 token）+ `TELEGRAM_CHAT_ID` |
| Bark（iOS） | `bark` | `BARK_KEY` |
| PushDeer | `pushdeer` | `PUSHDEER_KEY` |
| Gotify | `gotify` | `GOTIFY_API` + `GOTIFY_TOKEN` |
| Pushover | `pushover` | `PUSHOVER_API_TOKEN` + `PUSHOVER_USER_KEY` |
| 邮件 | `smtp` | `SMTP_*`（QQ/163 要用**授权码**不是登录密码） |
| 自定义 HTTP | `custom_post` | `CUSTOM_POST_URL` + `CUSTOM_POST_BODY_TABLE`，`{msg}` 会被替换 |
| 串口输出 | `serial` | 配合 `ROLE`：`MASTER` 把短信也从串口吐出，`SLAVE` 转发串口收到的数据 |

钉钉机器人安全设置选「自定义关键词」时，关键词填 `SMS`（本项目通知正文都带 `#SMS` 标记）；
选「加签」就把 secret 填进 `DINGTALK_SECRET`，比关键词可靠。

---

## 常用配置速查

`config.lua` 里每一项都有注释，这里只列最常动的：

| 想干什么 | 改哪个 |
|---|---|
| 通知里不要附带信号/开机时长（更短） | `NOTIFY_APPEND_MORE_INFO = false` |
| 开机时推一条"我上线了" | `BOOT_NOTIFY = true`（默认关） |
| 允许管理员号远程让设备代发短信 | `ADMIN_PHONE = "你的手机号"`，再从该号发 `SMS,目标号码,内容` |
| 定时查流量（运营商会回一条短信） | `QUERY_TRAFFIC_INTERVAL`，建议 ≥ 24 小时 |
| 基站定位（室内经常拿不到） | `LOCATION_INTERVAL`，默认 0 |
| 指示灯全灭 / 恢复闪烁 | `LED_DISABLE = true / false` |
| 自动重启周期 | `REBOOT_INTERVAL`（默认 2 小时，见下节） |
| 调试时看详细日志 | `main.lua` 里 `log.setLevel("DEBUG")` |

⚠ `ADMIN_PHONE` 留空 = 所有远程短信指令都不生效。填了之后，任何能冒用该号码的人都能让设备发短信，
需要时再设 `SMS_SEND_ENABLED = false` 关掉代发。

---

## 关于"每 2 小时自动重启"

默认 `REBOOT_INTERVAL = 2 小时`，即每天重启 12 次。代价要说清：

- 每次约 1 分钟不可用。这期间到达的短信由运营商 SMSC 重投，**一般会补上**，
  但个别卡/运营商不重投就会漏，而且漏了没有任何提示。
- 每次重启都要重新注册网络，是一笔流量与信令开销。

嫌频繁就改成 `8 * 60 * 60 * 1000`（8 小时）或 `0`（关闭）。

**不要**用"定时切飞行模式"来保号——它会和固件的网络自愈抢射频，实测会造成反复掉线直到死机，
代码里已明确禁用这条路（见 `util_watchdog.lua`）。

---

## 它是怎么保证不丢短信的

- **收到即落盘**：短信一进来就写进 flash（fskv）再慢慢发。发送过程中断电重启，开机后接着发。
- **失败退避重试**：网络没就绪时不空跑；失败按 5s→10s→20s… 指数退避，单轮 5 次后转成每 5 分钟低频补发，
  最长保留 72 小时（`NOTIFY_MSG_TTL_HOURS`）才放弃。
- **硬件看门狗**：程序卡死 9 秒没喂狗就复位，不依赖软件自检。
- **网络自愈**：断网由固件自动重注册；应用层只做"裸 TCP 探测外网"，连续 2 小时全不通才重启设备。
- **长短信**：由 LuatOS 底层拼包，不用你处理。

---

## 收不到通知？按这个顺序查

1. **这张卡本身能不能收发短信？** 先用另一部手机给它发一条。纯流量卡在这一步就会失败。
2. **有没有信号？** 灯全灭是默认设置，别以为它没工作。接串口看日志，或临时 `LED_DISABLE = false`。
3. **`config.lua` 真的刷进去了吗？** 改完必须重新用 Luatools「下载脚本」，只改电脑上的文件没用。
4. **推送凭据填对了吗？** 通道配置错误时设备会重试 5 次然后静默丢弃，日志里有 `发送通知失败`。
5. **系统时间对不对？** 时间不准会让通知里的发件时间错乱。设备每 6 小时自动 NTP 对时。
6. **供电够不够？** 反复重启 + 收不到东西，八成是电源而不是代码。

串口日志是最快的判断手段：`log.info("smsCallback", ...)` 表示收到了短信，
`util_notify.send 发送通知成功/失败` 表示推送结果。

---

## 电源键

| 操作 | 效果 |
|---|---|
| 短按 | 推一条测试通知，验证通道通不通 |
| 长按 2 秒以上 | 向运营商发一条流量查询短信 |

（依赖 `rtos.bsp()` 识别为 `EC718P`；换型号要核对 `main.lua` 里的引脚表。）

---

## 换别的型号

本仓库按 **Air780EPV** 配置。换 Air780EPM 等型号时有两处要核对：
`NETLED_PIN`（指示灯引脚）和 `main.lua` 里电源键的引脚表。
不确定就把 `NETLED_PIN` 填 `nil`——程序不会去猜引脚（猜错可能撞上 SIM/UART/天线控制脚），
只是不处理灯而已。

---

## 许可与致谢

MIT，见 `LICENSE`。

设备端底座是合宙 LuatOS 生态：`libnet.lua`（@lisiqi）、`lbsLoc.lua`（@luatos）等文件保留其原始署名；
`PRODUCT_KEY` 写在 `util_location.lua` 与 `lbsLoc.lua` 里，是合宙官方**演示用**的基站定位 key，
量产/长期使用请换成自己在 iot.openluat.com 创建项目的 key（默认定位是关闭的，不用就无需管）。
通知模型与界面思路参照 [chenxuuu/sms_forwarding](https://github.com/chenxuuu/sms_forwarding)，
部分通知接口的用法参照 [0wQ 的 Air780E 转发器固件](https://github.com/0wQ)。
