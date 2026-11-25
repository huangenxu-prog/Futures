# 快期云端模拟账户（第一阶段）

新增第二阶段：TqKq 限价模拟委托、撤单、委托及成交查询。仍不含实盘或银期转账。
保留原有本地模拟账本，两者不混用。SDK 的资金与持仓对象在 wait_update 中更新。

## 部署（独立服务，不替换行情网关）

1. 将本仓库 server/trade_gateway.py 安装到 /root/tq_test/server/。
2. 使用 root-only 环境文件 /etc/qihui-trade.env，权限 0600；设置 QIHUI_TRADE_ACCESS_KEY 为随机生成的至少 32 字符密钥（例如 openssl rand -hex 32）。不要上传密钥。
3. 创建独立 systemd 服务，ExecStart=/root/tq_test/.venv/bin/python /root/tq_test/server/trade_gateway.py，EnvironmentFile=/etc/qihui-trade.env，WorkingDirectory=/root/tq_test，Restart=on-failure。不要开启 SDK debug 或 HTTP 请求体日志。
4. 在已有可信 HTTPS 反向代理中，仅把 /v1/trade/ 路径转发到 http://127.0.0.1:8766，保留原始路径和认证头；代理读超时至少 75 秒。不得公开 8766 端口或关闭 TLS 证书校验。若当前 IP 未具备有效证书，先部署有有效证书的域名。
5. 在期汇交易页填写 HTTPS 网关地址（不含 /v1/trade/）、访问密钥、快期账号及密码。账号密码不写入 App 持久化存储或部署配置，服务会话仅在内存中。单用户专用测试，退出或闲置 20 分钟结束会话；服务重启也会清除会话。
6. 与快期官方 App 核对权益、可用、保证金、浮动盈亏、持仓；退出、断网、错误密钥、错误密码以及服务重启均需测试。未通过验证不得开放交易指令。

当前版本没有实盘登录能力。云端数据的连接状态与 SDK 断线判定仍需真机联调完善。

## 第二阶段升级与验收

已有第一阶段服务通过 server/upgrade_trade_gateway.py 升级；保留现有密钥与 Nginx，不重启行情网关。升级会终止当前登录会话，请重新登录。单次委托最多10手，仅限价；上期所和能源中心平仓需明确平今或平昨。委托请求使用唯一 ID，结果未确认时不自动重发。需要在快期官方客户端核对委托、成交、撤单以及资金/持仓变化。没有通过实机验证前不得视为已完成交易验收。
