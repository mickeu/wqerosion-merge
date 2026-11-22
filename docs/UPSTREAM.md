# 上游基线（同步依据）

合并 App 由两个上游派生。**改上游之前先看这里**；记录的是我们实际基于的 commit。

| 上游 | 仓库 | 基线 commit | 版本 | 同步日期 |
|---|---|---|---|---|
| WQ Files | https://github.com/kolbicz/WQFiles | `a8a4d06cbf2651de1cd7bd9f5f8e38f67b025890` | 0.9.20 | 2026-11-22 |
| Erosion-CN | https://github.com/Kianuni/Erosion-CN | `8ef12aa53bd82869bebc6cf4d22eef7bb15ac65f` | 1.0.6 (31) | 2026-11-19 |

许可证：两者上游均为 GPL-3.0（Erosion-CN 是 jailbreakdotparty/Erosion 的简体中文加固分支）。

## 0.9.20 同步记录（2026-11-22）

上游新增：Apps Manager `.adbk` 备份导入、删除/导入时提示「文件被占用」、SQLite 组（`-wal`/`-shm`）整体保留。
我们的补丁按 `diff` 重放：`main.m` 的 import/设置页/根 VC 四处 + `WQApps.m` 尾部 MCP 块，全部 re-apply 成功；14 个语言表由新版 `Localizable.strings` 重新生成后追加 MCP 两键（zh 1145 / en 1143）。
新增依赖：`WQAppsSupport.h` 多了若干 `wq_sqlite_family_*` 等 API（上游自带，无需适配）。

## 我们的改动（同步时必须保留）

### 对 WQ Files 的改动
| 文件 | 改动 |
|---|---|
| `WQMCPServer.h/.m` | **新增**：MCP 服务端（loopback 18765，Bearer，plan/commit，9 个 operation，App 内自检） |
| `WQLocalization.m` | `NSLocalizedString` → `NSLocalizedStringFromTable(key, @"WQFiles", nil)` |
| `WQApps.h/.m` | 尾部追加 `WQMCPAppBackup/Clear/Restore` 包装；内部加 `wq_mcp_container()`（排除自身容器） |
| `main.m` | import WQMCPServer；`wq_make_root_view_controller()` 里追加 Erosion tab；设置页加一行「MCP 服务」（section 1 row 5） |
| `<lang>.lproj/WQFiles.strings` | 14 个语言包（由上游 `Localizable.strings` 改名复制，另加 MCP 键） |

### 对 Erosion 的改动
| 文件 | 改动 |
|---|---|
| `ErosionApp.swift` | 去 `@main`；全局保留；`init()` → `wqErosionBootstrap()`；body → `ErosionRootView`（顶部纯图标玻璃栏 + 三区 switch）；导出 `@_cdecl("WQErosionMakeRootViewController")` |
| `Erosion/Info.plist` | 合并 WQFiles 的文档类型 / UTI / 本地网络 / 14 语言 |
| `Erosion/Erosion.entitlements` | 两个 App Group 都声明 |
| `Assets.xcassets/AppIcon.appiconset` | 自适应 light/dark/tinted（`scripts/gen_icon.py` 生成），删除上游 `AppIcon.icon` |
| `WQSource/` | 整个 WQ Files 源码目录（synchronized folder 自动编入 target） |

## 同步流程

```sh
# 1) 看上游有没有新东西
git ls-remote https://github.com/kolbicz/WQFiles HEAD
git ls-remote https://github.com/Kianuni/Erosion-CN HEAD
# 与上面的基线 commit 对比，相同就不用动

# 2) 拉新版到临时目录，取差异
git clone --depth 1 https://github.com/kolbicz/WQFiles /tmp/wq_new
git -C /tmp/wq_new log -1 --format='%H %s'

# 3) 先比对“我们要保留的改动”是否被上游改到同一处
diff -u /tmp/wq_new/WQAccess.h  Erosion/WQSource/WQAccess.h
diff -u /tmp/wq_new/WQApps.h    Erosion/WQSource/WQApps.h
diff -u /tmp/wq_new/main.m      Erosion/WQSource/main.m | head -80
# 重点盯：WQApps.m 尾部（我们的 WQMCPApp* 追加）、main.m 的 root VC 与设置页段落

# 4) 覆盖除我们改过的文件之外的源码，再把第 3 步的改动重新贴回去
# 5) 更新本文件的基线 commit 与日期
# 6) 本地 -fsyntax-only 过一遍 → 推 CI → resign → install → App 内自检 9 项全 PASS
```

验证命令（iSH 本地，ObjC 可编、Swift 不行）：

```sh
S=/root/.ios-sdk/iPhoneOS26.5.sdk
clang -fsyntax-only -fobjc-arc -target arm64-apple-ios26.0 -isysroot "$S" \
  -F"$S/System/Library/SubFrameworks" -F"$S/System/Library/PrivateFrameworks" \
  -I Erosion/WQSource -Wall -Wextra -Werror -Wno-unused-parameter \
  -Wno-nullability-completeness Erosion/WQSource/WQMCPServer.m
```

## 风险提示

- `worse_query` 在 iOS 27.3 beta2+ 被苹果封堵；上游若跟进到新区建，先确认逃逸是否仍可用
- 上游若重构 `main.m` 的 root VC 或设置页数组，我们的 Erosion tab 与「MCP 服务」行要跟着挪
- 上游若改 `WQLocalization` 的调用方式，独立表方案要重新适配
- 上游若把 `WQApps.m` 的 `wq_make_app_backup` 等静态函数改名，`WQMCPApp*` 包装要同步
