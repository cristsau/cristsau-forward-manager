# cristsau一键转发管理脚本

`v1.0`

一个面向 `realm` 转发场景的 Bash 管理脚本项目，提供菜单和 CLI 双入口。

## Current Script

- `scripts/cristsau-realm-pro.sh`

## Included Features

- `realm` 自动安装与更新
- 端点增删改查
- 分片渲染配置与快照输出
- 备份与恢复
- `systemd` 服务与 watchdog 管理
- 自定义启动命令安装
- 节点文本识别、导入链接和二维码输出

## Notes

- 当前主转发引擎是 `realm`
- 这版重点修过状态文件解析安全、配置预校验、IPv6 地址渲染和依赖按需检查
