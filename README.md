# X-MILI

> 基于 3X-UI 精简改造的 Xray 面板，内置 VPNGate 公益节点出站，适合想快速搭建、分流和管理代理节点的 VPS 用户。

[![GitHub](https://img.shields.io/badge/GitHub-X--MILI-black?style=for-the-badge&logo=github)](https://github.com/Aimilibot/X-MILI)
[![一键安装](https://img.shields.io/badge/一键安装-Linux_VPS-brightgreen?style=for-the-badge)](#一键安装)
[![Docker](https://img.shields.io/badge/Docker-支持-blue?style=for-the-badge&logo=docker)](#docker-版)
[![Telegram](https://img.shields.io/badge/TG交流群-arestemple-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/arestemple)

## 项目介绍

X-MILI 是一个简洁版代理面板：

- 基于 3X-UI，保留常用面板管理能力
- 基于 Xray，支持入站、出站、路由、DNS、证书和日志管理
- 新增 VPNGate/OpenVPN 公益节点出站
- 支持 `vpngate` 标签分流，只有匹配规则的流量才走 VPNGate
- 提供 `ml` 中文管理菜单，安装、更新、重启、日志查看更方便

## 致敬开源

[![3X-UI](https://img.shields.io/badge/3X--UI-面板项目-blue?style=for-the-badge)](https://github.com/MHSanaei/3x-ui)
[![Xray](https://img.shields.io/badge/Xray-代理内核-green?style=for-the-badge)](https://github.com/xtls/xray-core)
[![VPNGate](https://img.shields.io/badge/VPNGate-公益节点-red?style=for-the-badge)](https://www.vpngate.net/cn/)
[![aimili-vpngate](https://img.shields.io/badge/aimili--vpngate-分流逻辑-orange?style=for-the-badge)](https://github.com/baoweise-bot/aimili-vpngate)

## VPS 推荐

| 推荐 | 适合人群 | 亮点 | 入口 |
| --- | --- | --- | --- |
| 搬 瓦 工 | 稳定低延迟| CN2GIA，顶级三网优化 | [立即查看](https://bandwagonhost.com/aff.php?aff=81790) |
| RackNerd | 大流量使用 | 4TB流量，价格低、流量多 | [立即查看](https://my.racknerd.com/aff.php?aff=18708) |

## 一键安装

### 宿主机版

推荐生产环境使用，VPNGate/OpenVPN 路由更稳定。

| 项目 | 说明 |
| --- | --- |
| 支持系统 | Debian、Ubuntu、CentOS、RHEL、Rocky Linux、AlmaLinux、Fedora、Amazon Linux、Oracle Linux、Arch、Manjaro、Alpine、openSUSE 等常见 Linux |
| 必要条件 | root、systemd、TUN/TAP |
| 适合场景 | 长期运行、生产使用、路由稳定优先 |

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Aimilibot/X-MILI/main/install.sh)
```

### Docker 版

适合快速部署、隔离运行和保留数据目录。

| 项目 | 说明 |
| --- | --- |
| 支持系统 | 能正常运行 Docker 和 Docker Compose 插件的 Linux VPS |
| 必要条件 | root、Docker、Docker Compose、TUN/TAP、host 网络 |
| 适合场景 | 快速重装、容器管理、测试环境 |

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Aimilibot/X-MILI/main/install-docker.sh)
```

安装完成后，终端会输出面板地址、账号、密码和安全路径。

## 快速教程

1. 执行一键安装脚本。
2. 选择 `简体中文`。
3. 设置面板账号、密码、端口和安全路径，也可以直接回车随机生成。
4. 打开终端输出的面板地址。
5. 添加入站和客户端。
6. 进入 `Xray 配置` -> `VPNGate`。
7. 拉取 VPNGate 节点。
8. 选择默认、固定国家或动态国家规则。
9. 点击添加出站，等待 OpenVPN 连接成功。
10. 保存 Xray 配置。
11. 在路由规则中选择 `vpngate` 出站标签。

提示：`vpngate` 不会默认接管全部流量，必须在路由规则里手动选择。

## 功能介绍

- 面板登录、随机安全路径、用户密码、双因素认证
- 入站管理、客户端管理、订阅管理
- 客户端流量统计、到期时间、流量上限
- 按小时、天、周、月自动重置流量
- Xray 出站、路由、DNS、证书、日志管理
- 出站延迟测试和出站流量统计
- 数据库备份和恢复
- 防火墙、IP 限制、BBR、SSH 端口转发
- VPNGate/OpenVPN 一键连接并生成 `vpngate` 出站

## ml 快捷键

宿主机版：

```bash
ml                  # 打开菜单
ml start            # 启动
ml stop             # 停止
ml restart          # 重启面板
ml restart-xray     # 重启 Xray
ml status           # 查看状态
ml settings         # 查看设置
ml log              # 查看日志
ml update           # 更新
ml uninstall        # 卸载
```

Docker 版：

```bash
ml                  # 打开菜单
ml start            # 启动容器
ml stop             # 停止容器
ml restart          # 重启容器
ml restart-xray     # 重启 Xray
ml status           # 查看状态
ml log              # 查看日志
ml shell            # 进入容器
ml update           # 更新
ml uninstall        # 卸载，默认保留数据
```

## 常见问题

### 面板打不开

检查 VPS 安全组和系统防火墙，放行安装完成时输出的面板端口。

### VPNGate 连接失败

确认 VPS 支持 TUN/TAP。OpenVZ/LXC 机器通常需要在服务商控制面板手动开启 TUN。

### Docker 版 VPNGate 不工作

确认容器使用 host 网络、`/dev/net/tun` 和 `NET_ADMIN`。一键 Docker 脚本已默认配置。

## 交流与支持

[![Telegram](https://img.shields.io/badge/TG交流群-arestemple-2CA5E0?style=flat-square&logo=telegram&logoColor=white)](https://t.me/arestemple)
[![Forum](https://img.shields.io/badge/交流论坛-339936.xyz-orange?style=flat-square&logo=discourse&logoColor=white)](https://339936.xyz)
[![YouTube](https://img.shields.io/badge/视频教程-YouTube-red?style=flat-square&logo=youtube&logoColor=white)](https://www.youtube.com/watch?v=s-ATfXR8BpI)
[![Email](https://img.shields.io/badge/Bug反馈-Email-red?style=flat-square&logo=gmail&logoColor=white)](mailto:yaohunse7@gmail.com)
