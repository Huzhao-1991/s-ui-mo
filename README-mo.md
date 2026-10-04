# S-UI 1.6.3 魔改版

基于 [alireza0/s-ui](https://github.com/alireza0/s-ui) **v1.6.3**（2026-09-16 发布）的二次开发版本，
把 [Teminuosi/s-ui](https://github.com/Teminuosi/s-ui)（基于 v1.4.2）里已验证过的体验改进，重新移植到 1.6.3 上。

上游版权归原作者，本项目遵循 GPL-3.0。

---

## 1. 和魔改版的关系：为什么没有照搬

原魔改版基于 **v1.4.2**，而 1.6.3 中间隔了 1.5.0 → 1.6.3 共十个版本。逐文件比对后，
**它 README 里主打的几项功能，上游早已并入，而且实现更好**，所以这次没有搬：

| 魔改版声称的功能 | 1.6.3 现状 | 本次处置 |
|---|---|---|
| 阶段1：协议模板（一键建 VLESS+Reality 等） | `core/protocol/` 已内置，且比魔改版**多** `snell`、`shadowsocks` | 不搬 |
| `core/inbound_users.go` 客户端批量处理 | 已内置 | 不搬 |
| Reject SSL handshake for unknown SNI | 已内置，且额外支持**证书热重载**（`certReloader`） | 不搬 |
| hashed panel password | 已内置且更完整：`subtle.ConstantTimeCompare` + `BurnPasswordCheck` 防用户名枚举 | 不搬 |
| 用 `X-Forwarded-For` 取客户端 IP | 1.6.3 改用 `c.ClientIP()`，走 gin 受信代理白名单，伪造头无效 | 不搬 |

真正还差、本次移植的是下面五块。

---

## 2. 本次新增/移植的功能

### 2.1 全自动安装（`SUI_AUTO=1`）

```bash
SUI_AUTO=1 bash <(curl -Ls https://raw.githubusercontent.com/<你的仓库>/main/install.sh)
```

- 全程零交互。新机器上**随机生成**管理员账号、密码、面板路径、订阅路径，装完打印一次。
- **已装过的机器走「保留现有设置」分支**，不动账号与路径。这条规则是自更新功能的地基：
  Web 点一下升级也是以 `SUI_AUTO=1` 重跑 install.sh，如果这里重新生成账号，点一下就把自己锁在面板外。
- 端口被占用时自动顺延（默认从 2095/2096 起找空闲端口），不再出现「装完起不来且没有原因」。
- 可用环境变量覆盖：`SUI_PORT` `SUI_PATH` `SUI_SUB_PORT` `SUI_SUB_PATH` `SUI_USER` `SUI_PASSWORD`。

### 2.2 面板自更新（Web 一键升级）

设置页点按钮 → 后端查 GitHub 最新 release → 下载 `install.sh` → **脱离面板进程**执行 → 装完重启面板。

- `service/panel.go`：`GetUpdateInfo` / `StartUpdate` / `downloadPanelUpdater` / `fetchLatestPanelVersion`。
- 关键点是**让更新进程活过面板自己**：优先用 `systemd-run` 起独立 unit；拿不到 systemd（容器等）退回 `setsid` 脱离进程组。否则脚本装到一半，父进程被杀，留下装了一半的树。
- 下载的脚本有 2MB 上限，避免异常响应把磁盘写满。
- 版本比较按「三段主版本号 → 后缀等级 → 后缀序号」来做，**能正确处理 `mo9` 与 `mo10`**（纯字符串比较会判反）。
- 仓库地址不写死：构建期 `-ldflags -X .../config.PanelRepo=owner/repo`，或运行期环境变量 `SUI_PANEL_REPO` 覆盖。

### 2.3 服务器列表 + 中转（多节点集中管理）

新增一张 `servers` 表和一组接口，让一个面板能直接管理**其它 s-ui 实例**，不用二次登录。

- 列表页 `/servers`：增删改查、在线探测（显示往返延迟 / `unreachable` / `bad token`）。
- 点「管理」→ 前端开始给所有请求带 `X-Remote-Server` 头 → 后端把请求转发到目标实例的 **APIv2**（用该条目里存的 Token 鉴权）。
- 于是整个面板 UI（入站、客户端、路由、TLS…）都在编辑那台远端机器。
- 侧边栏标题下方会显示「当前正在管理 XXX」，列表页顶部有「返回本机面板」，**切错不会不知道**。
- 选择持久化在 localStorage，刷新页面不会悄悄退回本机。
- 删除条目时可勾选「同时删除该服务器上的全部入站」（默认关闭，破坏性操作）。

哪些动作**永远在本机执行、绝不转发**：服务器列表本身、登录/登出、Token 管理、改密码、在线探测。
否则远端就能通过代理改掉本机的凭据。

### 2.4 安装 / 卸载修复

- 新增 `install.sh purge`：只依赖 root，**不依赖任何已安装文件**，把 `/usr/local/s-ui`、`/etc/s-ui`、`/usr/bin/s-ui` 和服务定义全部清掉。
- `s-ui uninstall` / 菜单卸载项**不再先检查「是否已安装」**：装到一半失败时状态本就是「未安装」，那道检查会变成死锁 —— 残留清不掉、重装也进不去。
- `uninstall` 保留 `/etc/s-ui`（数据库），`purge` 才删。上游 README 里手写的卸载命令删错了对象（删的是 `sing-box.service`，且没删 `/etc/s-ui`），照做只会留一地残留。
- 菜单新增第 21 项 Purge。

### 2.5 若干修复

- `s-ui token` 新子命令：为第一个管理员打印 APIv2 Token（默认复用已有 Token，`-new` 强制新建）。配置多节点时用来取 Token。Token 走 stdout、错误走 stderr，脚本里可 `TOKEN=$(s-ui token)` 直接接。
  - **用完之后要重启一次面板**才会生效：这个子命令是另起一个进程直接写数据库的，而运行中的面板只在启动时加载一次 Token 表（面板界面里「添加 Token」按钮会就地重载，所以走界面的那条路不需要重启）。实测确认过这一点，别把它当成 Token 没配对。
- `util/shadowsocks.go`：补上 `2022-blake3-aes-256-gcm`、`2022-blake3-chacha20-poly1305` 的两个 32 字节密钥方法映射 —— 缺失时生成的链接会用 16 字节密钥。

---

### 2.6 中转管理（入站流量经落地节点转发）

新增独立页面 `/relay`（侧边栏「中转管理」，紧挨入站管理），把任意入站的出口流量整个改道到一台落地节点。
这是参考魔改版最核心的功能，本次按其行为完整移植并加了成倍的注释。

- **数据模型**：不新增表。「一个中转」= 一个落地出站 + 一条 `{inbound:[...], action:'route', outbound:tag}` 路由规则，
  页面从 `config.route.rules` + `outbounds` 里实时推导展示，与出站/路由页永远一致。
- **添加向导**：粘贴落地节点分享链接（`vless:// vmess:// trojan:// ss:// hysteria2:// tuic:// …`），
  SOCKS5 另支持 `IP:端口:用户:密码` 裸写法（前端直接解析）；其余协议走 `api/linkConvert` 转换。
  自动分配不冲突的出站 tag，保存出站与路由规则后立即 `api/checkOutbound` 探测落地连通性。
- **入口默认全不选**：路由规则会把选中入站的出口整个改道，默认全选会把现有所有节点一次性推到落地 IP 后面
  （「我原来的节点全变成中转的 IP 了」就是这么做出来的），所以必须手动挑。
- **删除** = 先删路由规则、再删落地出站（顺序不能反，否则规则会短暂指向不存在的出站）；支持全部删除。
- 每张中转卡片可单独测速、可出示**入口入站上客户端的二维码**（中转对用户透明，用户连的还是入口节点）。
- 附带「导出链接」弹窗：所有客户端的订阅 URL / 全部分享链接（明文或 Base64 整包），直接粘进 v2rayN 批量导入。

## 3. 相对原魔改版实现上的改进



移植时没有逐行照抄，下面这些是刻意改掉的：

1. **版本比较支持任意后缀**，不再只认识 `-qs`；且 `mo9`/`mo10` 不再判反。
2. **更新源可配置**，不写死某个账号的仓库。
3. **中转地址做校验**：只允许 `http`/`https`，缺 scheme 自动补，非法输入给出可读错误而不是一个 `http.NewRequest` 的晦涩报错。
4. **远端条目没填 Token 时直接报错**，而不是带着空 Token 发一个必然 401 的请求。
5. **切换节点时重置 `lastLoad`**：那个时间戳只对被请求的那台机器有意义，拿本机的时间戳去问远端「有什么变化」会拿到空增量、界面一片空白。
6. **当前节点持久化到 localStorage**，并在侧边栏显示；原实现刷新页面就静默回到本机。
7. **删除正在管理的节点时自动解除选中**，否则后续请求会一直被转发到一个已经不存在的条目上。
8. **`servers` 不走 `api/load` 轮询**：`api/load` 会被转发到远端，而「列表里有哪些面板」是本机的属性，跟着轮询会被远端的表覆盖。

---

## 4. 构建

需要 **Go 1.26.7+** 与 **Node 22+**，并且**必须在一台 Linux 机器上编译** —— 原因见 4.2。

```bash
# 1) 前端
cd frontend && npm install && npm run build && cd ..
rm -rf web/html/* && mkdir -p web/html && cp -r frontend/dist/* web/html/

# 2) 后端（一条命令编出整张矩阵里装得上编译器的目标）
PANEL_REPO=owner/repo ./build-release.sh

# 只编一个目标
PANEL_REPO=owner/repo ./build-release.sh linux/amd64

# 全静态：自带 libc，任意发行版都能跑（amd64 用 musl-gcc）
CC_NATIVE=musl-gcc SUI_STATIC=1 ./build-release.sh linux/amd64
```

产物在 `dist/`：`s-ui-linux-<arch>.tar.gz` + `SHA256SUMS` + `install.sh`。

### 4.1 CGO 是硬要求

`gorm.io/driver/sqlite` 底层是 `mattn/go-sqlite3`，**是 cgo 绑定**。
用 `CGO_ENABLED=0` 编出来的是一个 stub：体积正常、编译零报错、`-v` 也能打印版本，
但**第一次启动就死**：

```
InitDB: Binary was compiled with 'CGO_ENABLED=0', go-sqlite3 requires cgo to work. This is a stub
```

所以 `build-release.sh` 强制 `CGO_ENABLED=1`，并且**目标平台没有 C 编译器时明确跳过并提示**，
而不是产出一个看着像正常包、丢到服务器上才发现起不来的二进制。

交叉编译需要的包（Debian 12 / Ubuntu）：

```bash
apt-get install -y gcc musl-tools \
    gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf \
    libc6-dev-arm64-cross libc6-dev-armhf-cross
```

最后两个是**关键**。在 Debian 里它们是交叉 gcc 的 `Recommends`，用 `--no-install-recommends`
装不会带上；缺了之后交叉 gcc 会**静默回退到宿主的 `/usr/include`**，报一串
`bits/wordsize.h: No such file or directory` —— 看起来像编译器坏了，实际上只是少了两行包。

### 4.2 为什么必须在 Linux 上编

`with_purego`（运行时 dlopen cronet 而不是链接期）确实省掉了上游 CI 里那套 Chromium/cronet 工具链，
但**它省的是 cronet，不是 cgo**。SQLite 这一条路仍然要真实的目标平台 C 编译器和目标 libc 头文件，
所以 Windows / macOS 上无法直接出可用的 Linux 包（本机试过 `zig cc` 充当交叉 C 编译器，
被安全软件在进程级拦掉了，不可行）。

上游官方 CI 走的是 Bootlin musl sysroot，产出的是各类 arch 的**全静态 musl** 二进制；
`build-release.sh` 在 amd64 上用 `musl-gcc` 得到同等效果，ARM 目标则用 Debian 交叉 gcc + `-static`
（静态 glibc：能跑，但 DNS/NSS 走的是编进 libc 的那一套，不如 musl 干净）。
想完全对齐上游，push 一个 tag，`.github/workflows/release.yml` 会用 Bootlin 工具链照旧产出。

### 4.3 本次构建与验证记录

在 Debian 12 / 1 核 / 973 MB 内存 / 4.9 GB 磁盘的 VPS 上实际跑通：

| 项目 | 结果 |
|---|---|
| 工具链 | Go 1.26.8 + musl-gcc 12.2 + aarch64/armhf 交叉 gcc |
| 前端 | `npm run build` 通过（含 `vue-tsc --noEmit` 类型检查），产物已嵌入 `web/html` |
| amd64 | `s-ui-linux-amd64.tar.gz` 35 662 141 B，**ELF 64-bit LSB, statically linked, stripped** |
| 版本 | `s-ui -v` → `S-UI Panel 1.6.3-mo2` / `Sing-Box v1.14.1` |
| 安装 | `SUI_AUTO=1 bash install.sh` 全流程通过：下载 → SHA256 校验 → 解包 → 随机账号/路径 → systemd 启用并启动 |
| 服务 | `s-ui.service` = enabled + active，监听 `*:2095`（面板）与 `*:2096`（订阅） |
| 接口 | 登录、`api/settings`、`api/servers`、`api/updateInfo`、`api/save object=servers`（落库已回读）、`api/testServer` 全部符合预期 |
| 中转 | 双实例实测：A 自身 `webPort=2095`，带 `X-Remote-Server` 请求返回 **B 的 `webPort=12096`**；`servers` 列表仍由 A 本地提供（守卫生效） |
| 重装 | 再跑一次 `install.sh` 走「保留现有设置」分支，账号/路径不变、服务正常重启 |
| 中转页 | `/relay` 登录后 200；向导全链路实测：建落地出站 → config 追加路由规则落库 → `checkOutbound` 探测 → 按页面同路径删除且无残留 |

**本次交付只出 `linux/amd64` 一份包**（外加 `install.sh` 与 `SHA256SUMS`）。ARM 目标用同一条
`./build-release.sh` 命令即可产出（见 4.1 的交叉编译依赖清单），只是没有纳入这次交付。

构建过程本身也踩了两个只有小机器才会遇到的坑，记录在此以免复现：
- **磁盘**：Go 构建缓存会长到 1.4 GB 量级，加上模块缓存后 4.9 GB 的盘会被写满，表现为
  `mkdir ... no space left on device`。把交换分区从磁盘换到 **zram**（压缩内存交换，不占盘）
  是最划算的一步。
- **内存**：上面那台机器只有 973 MB 内存且是 1 核，靠 `GOMAXPROCS=1` + `GOGC=50` 让编译器
  更早回收即可完成链接；全程 swap 用量不到 20 MB，瓶颈始终是磁盘而不是内存。

---

## 5. 安装 / 升级 / 卸载

```bash
# 全自动安装（推荐）
SUI_AUTO=1 bash <(curl -Ls https://raw.githubusercontent.com/<你的仓库>/main/install.sh)

# 交互式安装
bash <(curl -Ls https://raw.githubusercontent.com/<你的仓库>/main/install.sh)

# 卸载：删程序与服务，保留数据库
s-ui uninstall
# 彻底清除：数据库一起删
s-ui purge        # 或 install.sh purge
```

装完 `s-ui` 打开管理菜单（启停/重启、改设置、改账号、SSL、BBR、Purge…）。

---

## 6. 仓库地址（已配置）

安装脚本、菜单脚本、自更新都从「本仓库」取自己的安装包和更新脚本。

**本仓库已经指向 `Huzhao-1991/s-ui-mo`**，`install.sh` / `s-ui.sh` / `config/config.go` /
`build-release.sh` / `Dockerfile` 的默认值都是它，开箱可用。

要换到别的仓库（比如你 fork 走了），跑一次：

```bash
./setrepo.sh yourname/s-ui-mo
```

它会把这 5 个文件里的默认值一起改写 —— 注意 `build-release.sh` 和 `Dockerfile` 也在内，
因为它们会用 `-X .../config.PanelRepo=` 把仓库名注入二进制；漏掉它们的话，
改完 `config/config.go` 也会在构建时被重新覆盖回旧值。

也可以完全不改源码，用环境变量临时覆盖：

```bash
SUI_REPO=yourname/s-ui-mo   bash install.sh     # 安装/升级源
SUI_PANEL_REPO=yourname/s-ui-mo systemctl restart s-ui   # 自更新检查源
```

CI 发布时会自动用 `-X .../config.PanelRepo=${{ github.repository }}` 把真实仓库写进二进制，
并从 tag 戳版本号到 `config/version`。

---

## 7. 本仓库的结构与打包方式

这个仓库是**内置前端的自包含 fork**，布局和上游有意不同：

| | 上游 `alireza0/s-ui` | 本仓库 |
|---|---|---|
| 前端 | 独立仓库 `s-ui-frontend`，主仓库用 `git submodule` 引用 | **前端源码直接内置**，`.gitmodules` 已删除 |
| `frontend/` | 被 `.gitignore` 忽略（CI 另外拉取） | 随仓库分发，克隆即可看到全部前端改动 |
| `web/html/` | 被忽略（构建时生成） | 已提交（前端已构建并嵌入，`go build` 开箱即用） |
| 与上游的差异 | — | `patches/backend.patch` + `patches/frontend.patch` |

目录大致长这样：

```
.
├── api/ cmd/ config/ core/ database/ service/ util/ ...     Go 后端
├── frontend/src/          前端源码（含 Relay.vue / RelayWizard.vue / ExportLinks.vue 等改动）
├── web/html/              前端构建产物，被 go:embed 打进二进制
├── patches/               相对上游 1.6.3 的完整 diff
├── install.sh             一键安装脚本
├── build-release.sh       跨平台交叉编译 + 打包
└── README-mo.md           本文档
```

只编后端（`web/html` 已就位，不需要 Node）：

```bash
. ./build-tags.sh
CGO_ENABLED=1 go build -tags "$(tags_for docker)" \
  -ldflags "$(ldflags_for docker)" -o sui .
```

改过前端之后要同步一次嵌入目录：

```bash
cd frontend && npm install && npm run build && cd ..
rm -rf web/html && mkdir -p web/html && cp -r frontend/dist/* web/html/
```

`patches/` 只覆盖**代码改动**；`.gitignore`、`.gitmodules` 这类打包元数据的差异不在补丁里。

---

## 8. 已知限制

- **naive 出站**：本机交叉编译用的是 `with_purego` 配置，运行时需要 `libcronet.so` 才能用 naive（与本仓库 Dockerfile 的 docker profile 一致）。不涉及 naive 的部署无影响。
- **翻译**：新增文案做了英文、简体中文、繁体中文；波斯语/越南语/俄语回退到英文（i18n 的 fallback 是 en）。
- **自更新仅支持 Linux**：Windows 构建下点按钮会返回明确错误。
- **官方 CI 的产物与本地手工构建不是同一套工具链**：CI 用 Bootlin musl sysroot（全静态 musl），
  本机 amd64 用 `musl-gcc`（等价），ARM 目标用 Debian 交叉 gcc + `-static`（静态 glibc）。
  两者都能跑，但 ARM 那两份的 DNS/NSS 走静态 glibc 的内置实现，不如 musl 干净；要更干净就直接用 CI 产出。

---

## 9. 改动清单

后端：

| 文件 | 说明 |
|---|---|
| `database/model/server.go` | 新增：Server 模型（name/url/token/remark） |
| `service/serverlist.go` | 新增：ServerListService（GetAll/GetById/Save） |
| `database/schema.go` | 注册 `servers` 表 → 自动迁移 + 纳入备份 |
| `service/config.go` | ConfigService 接入 ServerListService；Save 分发 `servers` |
| `api/remote.go` | 新增：中转中间件、转发、地址校验、在线探测 |
| `api/apiService.go` | 接入 ServerListService；`servers` 局部刷新；updateInfo/updatePanel |
| `api/apiHandler.go` | 注册中转中间件与新路由 |
| `service/panel.go` | 面板自更新全套 |
| `service/user.go` | `GetOrCreateToken` |
| `cmd/token.go` / `cmd/cmd.go` | `s-ui token` 子命令 |
| `util/shadowsocks.go` | SS-2022 32 字节密钥方法 |
| `config/config.go` | `PanelRepo` / `GetPanelRepo` |
| `config/version` | `1.6.3-mo2` |

前端：

| 文件 | 说明 |
|---|---|
| `src/plugins/remote.ts` | 新增：当前被管理面板的 id（含持久化） |
| `src/types/servers.ts` | 新增：Server 类型 |
| `src/layouts/modals/Server.vue` | 新增：服务器增改弹窗 |
| `src/views/Servers.vue` | 新增：服务器列表页 |
| `src/plugins/api.ts` | 每个请求注入 `X-Remote-Server` |
| `src/store/modules/data.ts` | servers / currentServer / loadServers / switchServer |
| `src/router/index.ts` | `/servers` 路由；启动时拉一次列表 |
| `src/layouts/default/Drawer.vue` | 菜单项 + 当前管理对象提示 |
| `src/views/Settings.vue` | 版本检查 + 一键升级按钮 |
| `src/locales/{en,zhcn,zhtw}.ts` | 新增文案 |

脚本 / CI：

| 文件 | 说明 |
|---|---|
| `install.sh` | `SUI_AUTO` 全自动、`purge`/`uninstall`、`SUI_REPO`、端口避让 |
| `s-ui.sh` | `SUI_REPO`、卸载保留数据库、`purge`、`token`、菜单第 21 项 |
| `setrepo.sh` | 新增：一键替换仓库占位符 |
| `build-release.sh` | 新增：跨平台交叉编译 + 打包 + SHA256SUMS |
| `.github/workflows/release.yml` | tag 戳版本号、注入 PanelRepo |
| `Dockerfile` | `ARG PANEL_REPO` |

`patches/backend.patch`、`patches/frontend.patch` 是相对上游的完整 diff，便于逐行审阅。
