# 任务书：WQFiles + MCP（+ 合入 Erosion 相关模块）

> 跨会话自包含。任何新会话从这份读起即可续做。

## 目标
产出 **一个 App**：官方 WQFiles 0.9.19（文件浏览器 / App 容器管理 / 缓存清理，ObjC，GPL-3.0）+ **内置 MCP 服务端**（`http://127.0.0.1:18765/mcp`，5 工具：search / read / plan / commit / backups），并把 Erosion-CN 中**可 ObjC 化的模块**（缓存清理增强、开屏广告缓存锁死）折叠进来；Erosion 的 MobileGestalt 系统定制（Swift）作为独立可选模块，不强行并入（成本不成比例）。

## 依据（已实测）
- **0.7 MCP 改版**是第三方在 WQFiles 0.7 源码上加了 `WQMCPServer`（ObjC 类，BSD socket accept → handleSocket → rpc → tool:arguments: → search/plan/commit）。文件名 `WQFiles-0.7-MCP-unofficial`。**无公开仓库**（GitHub 搜 WQFiles mcp = 0 结果）。
- **官方仓库** https://github.com/kolbicz/WQFiles ：纯 ObjC，GPL-3.0，`build.sh`（xcrun clang + actool + codesign，需 macOS CI 或本地 SDK 替身）。默认分支 main，latest v0.9.19。
- **Erosion-CN** https://github.com/Kianuni/Erosion-CN ：Swift，GPL-3.0，`Erosion.xcodeproj` + `ipabuild.sh`（Xcode/CI）。
- 本地源码：`/var/minis/workspace/WQFiles/`（已 clone，main 分支）。

## 关键 API（WQAccess.h，直接调用）
```c
NSArray<NSString*> *wq_list(NSString *dir, NSString **err);
NSData *wq_read(NSString *path, NSUInteger maxBytes, NSString **err);
BOOL wq_write(NSString *path, NSData *data, NSString **err);
BOOL wq_write_if_unchanged(NSString *path, NSData *data, NSDictionary *expected, NSString **err);
BOOL wq_create_file(NSString *path, NSData *data, NSString **err);
BOOL wq_create_dir(NSString *path, NSString **err);
BOOL wq_delete(NSString *path, NSString **err);
BOOL wq_delete_expecting(NSString *path, NSDictionary *identity, NSString **err);
BOOL wq_rename(NSString *path, NSString *newName, NSString **err);
BOOL wq_move(NSString *path, NSString *destDir, NSString **err);
BOOL wq_grant(NSString *path);                 // 沙盒授权（worse_query）
NSData *wq_read_range(NSString *path, unsigned long long offset, NSUInteger len, NSString **err);
NSDictionary *wq_file_version(NSString *path);  // 用于 plan 一致性
NSDictionary *wq_item_identity(NSString *path);
BOOL wq_is_protected_folder(NSString *path);
NSString *wq_app_group(void);
NSString *wq_backup_root(void);
NSString *wq_app_backup_root(void);
WQMeasureResult wq_measure_tree(NSString *dir, WQScanCancellation *c, ...); // 算大小
NSArray<NSString*> *wq_enumerate(NSString *dir, int64_t maxInode, ...);      // 全扫
```
App 备份/清空/恢复：`WQApps.m` 的 `wq_make_app_backup` / `wq_purge_and_verify` / restore journal（部分 static，MCP 侧如需调用要提权为 extern 或加声明）。
缓存清理：`WQCache.m` 的 `WQCacheCleanerViewController` + `wq_cache_custom_target_*`。

## MCP 协议（照 0.7 二进制）
- HTTP: `HTTP/1.1 %d %@`，`Content-Length: %lu`，`WWW-Authenticate: Bearer`（401 时）
- 鉴权：`Authorization: Bearer <secret>`，secret 存 `Library/Application Support/WQMCP/token`（App 内「Copy Bearer Token」）
- JSON-RPC 方法：`initialize`（返回 `serverInfo` + `protocolVersion` + capabilities）、`tools/list`、`tools/call`
- 监听 `127.0.0.1:18765`（硬编码；端口占用报 "Port 18765 unavailable"；启动日志 "Listening on 127.0.0.1:18765"）

### 5 个工具（schema 来自 0.7 二进制字符串）
1. **search** — "Filename substring search (case-insensitive, no file contents). Initial path/query; continue using cursor only. Bounded 2000 nodes/2 seconds per page; cursor expires in 120 seconds." 参数：path, query(1..256), cursor?, limit?。错误："Search requires path and a 1..256 character query"、"Unknown, consumed or expired search cursor; restart search"、"Too many active searches; wait for expiration"
2. **read** — "Read at most 262144 bytes. encoding utf8 or base64; byte offset, not character offset." 参数：path, offset?, length?(<=262144), encoding?
3. **plan** — "Stage a mutation WITHOUT executing it. Show the exact returned targets, sizes and irreversible items to the user; obtain explicit confirmation before commit. Close target app manually. Expires after 120 seconds; one use." 参数：operation(write/delete/rename/mkdir/move/app_backup/app_clear/app_restore...), 及各自参数。返回 plan token + targets + sizes + irreversible。
4. **commit** — "Execute an unchanged, unexpired plan ONLY after the user explicitly confirmed its targets and risks. The confirmation token is consumed even on failure; no auto retry." 参数：token。错误："Unknown, expired or already consumed confirmation token"、"Target changed since plan; create a new plan and ask for confirmation again"
5. **backups** — "List validated upstream app backups for an app container." 参数：bundleID 或 container。

## 阶段
- **Stage 1（核心，先做）**：WQFiles 0.9.19 + WQMCPServer（5 工具）→ 编 IPA。产出 = 文件/容器/缓存 + MCP。
- **Stage 2**：合入 Erosion 可 ObjC 化的「开屏广告缓存锁死」（清缓存文件 + 放 0.0.0.0 字节 `.erosion_adlock` 哨兵 + 目录 0555 + 排除 SplashBoard/WebKit/Cookies/Downloads）。
- **Stage 3（可选，独立）**：Erosion MobileGestalt 系统定制（Swift），单独 App 跑（bundle 不同，与 WQFiles 并存），不并入本项目。

## 文件
- `WQMCPServer.h` / `WQMCPServer.m` — 新增 MCP 服务端
- `main.m` — App 启动后调 `[[WQMCPServer shared] start]`
- `WQUI.m` / `WQUI.h` — 设置页加「MCP Server」入口 + Copy Bearer Token 按钮
- `build.sh` — 把 `WQMCPServer.m` 加进 clang 源文件列表

## 构建
- 本地 iSH 无完整 xcrun/actool；走 **macOS CI**（mickeu/iconbuilder 公开库，workflow 参照 GLOBAL 的 widget4.yml，macOS runner 免费）。
- 产物：`WQFiles-MCP.ipa`，交付带版本号 + SHA-256。

## 验收门（用户 2026-11-21 升级）
**10 轮连续零 bug 才算通过；任何一轮发现 bug → 审查计数归零，从第 1 轮重数。**
每轮覆盖：编译（-Werror 零告警）、符号冲突、生命周期、权限、资源、UI 挂载、MCP 协议。
功能门（全绿才算）：
1. macOS CI `xcodebuild` 通过（含 Swift + ObjC 全量）
2. 装到 iPhone 15 Pro（iOS 27.0）启动正常，两 tab（文件 / Erosion）都在
3. Erosion 主页/TweaksView/文件浏览 可进；WQFiles 文件浏览/容器/缓存 可进
4. MCP：`curl 127.0.0.1:18765/mcp`（Bearertoken）返回 initialize；`minis-mcp-cli tools wqfiles` 列 5 工具
5. search 能搜、read 能读、plan→commit 能写/删（受保护路径拒绝）
6. worse_query 在 27.0 生效（Erosion 与 WQFiles 两套逃逸都通）

## 进度
- [x] 合并树 EWMerge（Erosion 最新 + WQSource 最新），synchronized folder 验证
- [x] ErosionApp 去 @main、抽 bootstrap、暴露 `@_cdecl WQErosionMakeRootViewController`
- [x] 根改为 文件/Erosion 两 tab
- [x] 符号冲突扫描：两套逃逸栈无重叠
- [x] Info.plist 合并（WQFiles 文档类型/UTI/本地网络/14 语言）
- [x] entitlements 合并（两 App Group）
- [ ] 首次 macOS CI build（Erosion `ipabuild.sh`）→ 修编译错
- [ ] 三轮…→十轮审查
- [ ] 真机验收

## 约束
- worse_query 在 iOS 27.3 beta2+ 封堵，目标机须 27.0–27.2.1 或 26.0–26.7.2
- 必须保留 App Group entitlement（entitlements.plist 里 `group.W98A28M8HV.DF7vj`）
- GPL-3.0：派生作品须保留许可证

## 交付状态（2026-11-22 08:1x）
- 产品：`Erosion + WQFiles + MCP` 单 App，bundle `com.jbdotparty.Erosion` 1.0.6 (31)，iOS 26+。
- 构建：CI `mickeu/wqerosion-merge`（macos-26 + Xcode 26.6，`-scheme Erosion -destination generic/platform=iOS`）。
- MCP：`127.0.0.1:18765/mcp`，5 工具（search/read/plan/commit/backups），Bearer 鉴权；app_backup/app_clear/app_restore 已接 `WQMCPApp*` 包装（安全备份 + restore journal + 排除自身容器）。
- 自检：App 内「MCP 服务」页自动跑 create/read/rename/mkdir/move/read2/delete + 跨容器 + 备份根，8 项全 PASS（跨容器 3/3，约 1500 个容器）。
- 本地化：WQFiles 走独立 `WQFiles` 表（14 语言，1136 键 + MCP 2 键）。
- 图标：自适应 light/dark/tinted（`gen_icon.py`）。
- 已知限制：顶部三栏不支持左右滑动（三层方案均被 UIKit 手势仲裁吞掉，已放弃）；App 必须前台，MCP 才响应。
- 审查：**通过**。累计修 23 处；R44–R54 连续 11 轮零发现，设备自检 8 项全 PASS 一致。
- 最终产物 SHA-256：`08d33abc3d31f70514018fb3a1ba0a9da49bdef48e9b22544dddb3e8e3cc7c26`

## 复现（给别人看）
```
git clone https://github.com/mickeu/wqerosion-merge && cd wqerosion-merge
# CI: macOS 26 + Xcode 26.6，workflow 见 .github/workflows/build.yml
xcodebuild -project Erosion.xcodeproj -scheme Erosion -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DD \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ENTITLEMENTS="" CODE_SIGNING_ALLOWED=NO clean build
```
合并要点见 `docs/` 与 commit 历史；MCP 服务端在 `Erosion/WQSource/WQMCPServer.m`。
