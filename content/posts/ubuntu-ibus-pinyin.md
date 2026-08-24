+++
title = 'Ubuntu 24.04 中文输入法折腾记：从搜狗到 IBus 智能拼音'
date = 2026-08-23T18:00:00+08:00
draft = false
tags = ['Ubuntu', '输入法', 'IBus', 'Wayland']
categories = ['笔记']
summary = 'Wayland 下 fcitx4 + 搜狗会让终端闪烁，最终回到 IBus 智能拼音，学会用 Shift 切换中英模式。'
+++

## 起因

Ubuntu 24.04 GNOME 默认用 Wayland 会话。装搜狗输入法 Linux 版（4.2.1.145，最后一次更新是 2018 年）之后，每次在终端打字，**终端会闪烁**——光标行像刷新了一样，输入一个字符闪一下，非常难受。

排查后发现是搜狗依赖 fcitx4，而 fcitx4 对 Wayland 支持极差，输入法候选框触发重绘就会拖累整个窗口。

## 备选方案对比

| 方案 | 优点 | 缺点 | Wayland 适配 |
|---|---|---|---|
| IBus 智能拼音 | 系统自带，稳定 | 词库小、无联想、无 v 引导输入 | ✅ 原生 |
| IBus Rime | 强大可定制 | 配置门槛高，要装输入方案 | ✅ 原生 |
| fcitx5 + 中州韵 | 现代化、词库强 | 要换输入法框架，可能影响 GTK | ✅（更好） |
| fcitx4 + 搜狗 | 老牌、词库好 | 已停更，Wayland 下终端闪烁 | ❌ 烂 |

## 最终选择

**IBus 智能拼音**。原因：

1. 系统自带，零额外依赖；
2. Wayland 下行为最稳定；
3. 折腾的代价超过了它功能上的不足。

## 两个我之前不知道的技巧

### 1. Shift 切换中英文模式

在 IBus 智能拼音里，**直接按一下 Shift（不分左右）就切换中/英模式**，不用碰 Super 键或图标：

- 中文模式下打 `hello` 不会上屏英文，会按拼音处理；
- 按一下 Shift，输入法图标变成英，再打 `hello` 就直接出英文。

这个我之前一直以为 IBus 不行，其实只是没找到切换键。

### 2. v 引导输入的替代

搜狗的 `v` 引导输入（直接打 `v` 开头出英文单词）确实方便，但 IBus 智能拼音没有这个功能。**用 Shift 切到英文模式**打完再切回来，效果差不多，只是多一次按键。

## 卸载搜狗

```bash
# 移除搜狗
sudo apt purge -y sogoupinyin sogoupinyin-installer
sudo apt autoremove -y --purge

# 移除 fcitx4（如果之前装过）
sudo apt purge -y fcitx fcitx-bin fcitx-data fcitx-libs fcitx-libs-qt fcitx-module-dbus fcitx-module-kimpanel fcitx-module-x11 fcitx-modules fcitx-frontend-all
sudo apt autoremove -y --purge

# 切回 IBus
sudo apt install -y ibus ibus-pinyin
im-config -n ibus
```

重新登录后系统输入法框架切到 IBus，终端闪烁问题消失。

## 总结

- **Wayland 桌面远离 fcitx4 + 搜狗**，老输入法对新显示服务器适配差；
- **IBus 智能拼音够用**，只要学会 Shift 切换；
- 想要更强词库可以考虑 fcitx5 + 中州韵，但要换输入法框架；
- 不要在没确定兼容性的情况下乱装输入法。
