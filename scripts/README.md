# scripts/ — 实际运行的脚本

这个目录收录家用 Linux 自托管栈实际运行的 shell 脚本。

## 脚本清单

| 脚本 | 作用 | 触发方式 |
| --- | --- | --- |
| `health-check.sh` | 检查 wireproxy/gitea/cloudflared + 外网连通性，记日志看趋势 | `health-check.timer` 每 5 分钟触发 |
| `push.sh`（在仓库根目录） | 一键 `git add + commit + push` 走 SSH 443，重试 5 次应对 WARP 抖动 | 手动 `./push.sh "msg"` |

## 部署

用仓库根目录的 `install.sh`：

```bash
./install.sh             # 部署到 ~/Files/scripts/ 和 ~/.config/systemd/user/
./install.sh --dry-run   # 预览
```

## health-check.sh 设计要点

- **重试 3 次过滤 WARP 抖动**：WARP 单次 curl ~30% 超时，重试 3 次后误报率降到 ~3%
- **状态机 streak 计数**：连续失败 N 次才升级告警，避免单次抖动误报
- **日志轮转**：保留最近 1000 行（~3.5 天历史趋势）
- **零依赖**：只用 bash + curl + ss，不引入新包

日志路径：`~/Files/monitor/health.log`
状态文件：`~/Files/monitor/health.state`

## push.sh 设计要点

- 走 `ssh.github.com:443` 绕开国内 22 端口封锁
- 重试 5 次 + 每次 sleep 2s，应对 SSH 抽风
- 默认 commit 信息用当前时间，避免空 commit

## 相关博文

- [轻量健康检查：bash + systemd timer 监控家用 Linux 自托管服务](../content/posts/health-check/)
- [GitHub SSH 规范工作流：ed25519 key + 443 端口绕封锁 + push.sh 自动重试](../content/posts/ssh-workflow/)
