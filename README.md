# OfficeCheckin

macOS 原生 Wi‑Fi 自动打卡工具。使用 SwiftUI、SwiftData、CoreWLAN 和 ServiceManagement；所有数据仅保存在本机。

## 功能

- 目标 Wi‑Fi：`verizion_QV96NR`（可在 App 内修改）
- 每 5 分钟检查一次；当天第一次连接目标 Wi‑Fi 时自动打卡
- SwiftData 本地数据库
- 原生 Dashboard：Today、Current WiFi、当前季度 Working Days、Avg / Week、热力图
- 菜单栏常驻、手动打卡和立即导出 Excel
- 自动生成 `OfficeCheckin_Latest.xlsx`，保存最近两份历史版本
- 可在设置中启用“登录时启动”

## 在 Xcode 中运行

1. 使用 Xcode 16+ 打开 `OfficeCheckin.xcodeproj`。
2. 选择 **OfficeCheckin** scheme，目标为 **My Mac**，运行。
3. 如系统询问位置权限，请允许；macOS 有时需要它才能读取当前 Wi‑Fi 名称。

数据与 Excel 导出位置：`~/Library/Application Support/OfficeCheckin/`。

## GitHub

仓库已在本地初始化。发布到 GitHub 后：

```zsh
git remote add origin git@github.com:YOUR_ACCOUNT/OfficeCheckin.git
git branch -M main
git push -u origin main
```

## 要求

- macOS 14 Sonoma 或更高版本（SwiftData）
- Xcode 16 或更高版本
