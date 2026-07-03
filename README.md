# X-MILI

X-MILI 是基于 3X-UI 改造的简化面板版本，保留代理面板的核心管理能力，并加入 VPNGate/OpenVPN 一键连接能力。

GitHub 地址：

```text
https://github.com/Aimilibot/X-MILI.git
```

## 主要功能

- 面板登录、用户密码、双因素认证
- 入站管理和客户端管理
- 客户端流量统计、到期时间、流量上限
- 按小时、天、周、月自动重置流量
- Xray 出站、路由、DNS 配置
- 出站延迟测试和出站流量统计
- 数据库备份和恢复
- Xray 启停、日志查看、配置查看
- VPNGate/OpenVPN 一键连接并生成 `vpngate` 出站

## 一键安装

Linux VPS 使用 root 执行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Aimilibot/X-MILI/main/install.sh)
```

安装完成后使用：

```bash
ml
```

首次打开菜单会提示选择语言：

```text
1. English
2. 简体中文
```

## 一键更新

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Aimilibot/X-MILI/main/update.sh)
```

更新菜单脚本：

```bash
ml
```

然后选择 `更新菜单`。

## VPNGate/OpenVPN 一键连接

面板已集成 VPNGate 节点列表和 OpenVPN 托管连接。

使用流程：

1. 进入 `Xray 配置`
2. 打开 `VPNGate`
3. 拉取节点列表
4. 选择默认、固定国家或动态国家规则
5. 点击添加出站
6. 面板显示进度：安装 OpenVPN、准备配置、尝试连接、连接成功
7. 连接成功后会填入 `vpngate` 出站
8. 保存 Xray 配置
9. 在路由规则里选择 `vpngate` 出站标签，匹配的流量才会走 OpenVPN

连接过程中可以随时取消。

## 流量套餐示例

每个用户每月 100GB，持续 12 个月：

- 客户端总流量设置为 `100GB`
- 客户端到期时间设置为 12 个月后
- 入站流量重置设置为 `每月`

这样客户端每月自动清零流量，到期后自动禁用。

## Docker 运行

推荐使用 Docker 一键脚本，主机会生成 `ml` 管理菜单，用来管理容器：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Aimilibot/X-MILI/main/install-docker.sh)
```

常用命令：

```bash
ml
ml status
ml restart
ml restart-xray
ml log
```

如果手动运行 Docker，VPNGate/OpenVPN 需要 host 网络、TUN 设备和 NET_ADMIN 权限：

```bash
docker build -t ml .
docker run -d \
  --name ml \
  --network host \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -v ./db:/etc/x-ui \
  -v ./cert:/root/cert \
  -e XRAY_VMESS_AEAD_FORCED=false \
  -e XUI_ENABLE_FAIL2BAN=false \
  ml
```

访问：

```text
http://服务器IP:2053
```

## Linux 宿主机说明

VPNGate/OpenVPN 托管连接需要 Linux 环境，并依赖：

- `openvpn`
- `iproute2`
- 系统允许创建 `tun/tap` 设备
- 进程有权限执行 `ip route` 和 `ip rule`

面板会尝试自动安装 OpenVPN。生产环境建议直接安装在 Linux 宿主机上运行，路由行为更稳定。

## 注意事项

- 原上游面板更新入口已禁用，避免误拉回上游代码。
- Go 模块路径仍保留原导入路径，用于保证现有代码正常编译。
- VPNGate 出站只在路由规则选择 `vpngate` 标签时生效，不会默认接管全部流量。
