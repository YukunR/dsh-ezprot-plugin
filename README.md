# ezprot-dsh-plugin

即插即用的 **DeepSeek Harness 蛋白组学分析插件**：JS 编排壳 + R 4.4.0/Bioc 3.20 计算内核。

- **零环境门槛**：自动探测/静默安装 R（免管理员权限），R 包一次性装入插件私有库，只补缺不重装；检测到 Docker 时可用预构建镜像后端。
- **大陆网络友好**：默认西湖大学 CRAN/Bioconductor 镜像 + 下载重试；支持离线快照 zip 一键恢复（实验室断网也能装）。
- **逐步可追溯**：normalize → pca → batch_remove → dea → enrich → gsea 每一步都是一次独立工具调用，在 harness 轨迹里各占一张卡片（参数 + 结构化摘要 + 产物路径 + 日志）；PCA/火山图以 PNG 嵌入聊天直接展示。
- **原始数据导入**：`proteomics_import` 读取生物学家的原始 TSV/CSV/Excel（readxl，多 sheet、无关列），列分类启发式 + 交互确认后整理成规范矩阵。
- **人在环决策点**：比较组经 `proteomics_compare` 确认后才写入（绝不猜测）；PCA 后强制停下展示聚类图，由用户决定继续或批次校正。
- **运行期零联网**：GO/KEGG 富集与 GSEA 全部使用本地背景文件；背景库按物种缓存（内置 mouse，human/rat 首次按需构建一次）。
- **内置 QC 与智能默认**：pre-flight 自动检查样本匹配/缺失率/重复 ID/批次列，自适应 FC 阈值 + 敏感性信息，报告骨架直接生成。

## 目录结构

```
src/            TypeScript 插件源码（构建 → lib/）
lib/            构建产物（ESM + .d.ts，已提交，git 直装可用）
tests/unit/     vitest 单元测试（纯逻辑，无 R 依赖）
tests/e2e/      端到端驱动（需本机 R 4.4 + 完整包库）
tests/fixtures/ 示例小鼠数据（origin_data + sample_info）
r/              计算内核（analysis_steps.R + core/ + utils/ + run.R + main_template.R）
data/backgrounds/mouse/   内置小鼠 GO/KEGG 背景
manifest/packages.json    必需 R 包清单（R 4.4.0 / Bioc 3.20）
cordis.patch.yml          bundle 配置层（dsh.bundle 引用）
docker/         Docker 可选后端镜像
scripts/        部署工具脚本（一键安装、离线快照制作）
docs/biologist-guide.zh.md   面向生物学家的使用说明
```

## 安装（部署者一次性操作）

本包是官方 **bundle** 格式（`dsh.bundle` 声明 + 包内 `cordis.patch.yml`），一条命令安装并自动激活：

```powershell
# npm 发布后（推荐用户路径）
dsh plugin --profile web add ezprot-dsh-plugin

# 或：GitHub 直装（发布前可先用这个）
dsh plugin --profile web add github:<你的账号>/ezprot-dsh-plugin

# 或：本地 tarball（pnpm pack 产物）
dsh plugin --profile web add .\ezprot-dsh-plugin-0.1.0.tgz
```

`dsh plugin add` 会把本包追加进 `dsh.profile.bundles`，无需手改任何配置。重启 `dsh web` 后，每个会话的 agent 都获得 5 个 `proteomics_*` 工具。

**机器特异的覆盖**（可选）：bundle 只带通用默认值；某台机器想复用已有的 R 包库（跳过安装），在 profile 的 `cordis.patch.yml` 里按 id 覆盖整行 config：

```yaml
- id: ezprot
  config:
    enableInstall: true
    backend: auto
    rscript: 'D:/R/R_4.4.0/bin/Rscript.exe'
    libraryDir: 'D:/.../renv/library/windows/R-4.4/x86_64-w64-mingw32'
```

**开发场景（本仓库，TypeScript 工作流）**：

```powershell
pnpm install        # 安装 devDeps（typescript + 与部署版本对齐的 @deepseek-ai/* 类型）
pnpm build          # tsc 编译 src/*.ts → lib/*.js（+ .d.ts）
pnpm test           # vitest 单元测试（tests/unit/，无需 R）
dsh plugin --profile web add "link:D:/ResearchProject/ezprot-dsh-plugin"   # link: 协议，源码实时生效
```

- `link:` 协议是符号链接：改 `src/*.ts` 后只需 `pnpm build`，无需重装；修改 `r/` 脚本或 `cordis.patch.yml` 则直接生效。
- 生产使用者不受影响：npm/github/tarball 安装的是静态快照（`lib/` 已提交，git 直装无需 allowBuilds）。
- CI：`.github/workflows/ci.yml`（pnpm install → tsc → vitest）。

**无 pnpm 的机器**：用 `scripts/install.ps1`（内部先尝试 `dsh plugin add`，失败则真实路径拷贝 + 手动追加 bundles）。

## 配置项

| 字段 | 默认 | 说明 |
|---|---|---|
| `dataDir` | `$DSH_HOME/proteomics` | 运行时缓存（R 安装、包库、背景库、下载） |
| `libraryDir` | `dataDir/runtime/library` | R 包库；已有完整库（如 renv 库）可直接指向 |
| `rscript` | 自动探测 | 固定 Rscript 路径 |
| `cranRepo` | 西湖 CRAN | CRAN 镜像 |
| `biocRepo` | 西湖 Bioconductor | Bioconductor 镜像 |
| `enableInstall` | `true` | 是否允许自动安装 R/包 |
| `defaultTimeoutMs` | `1800000` | 单步骤超时 |
| `backend` | `auto` | `auto`（本地 R 优先，无 R 且检测到 Docker 时用镜像）/ `local` / `docker` |
| `dockerImage` | `ezprot:latest` | docker 后端使用的镜像名 |

## Docker 可选后端

本地托管 R 是默认方案（免管理员、免 Docker）。发布 Docker 镜像后，用户侧就完全
摆脱了对 CRAN/Bioc 镜像质量的依赖（`docker pull` 成品，使用侧零下载）：

1. 在有 Docker 的机器上按 [`docker/README.md`](docker/README.md) 构建并上传镜像
   （镜像内跑插件自己的安装器和运行时探针，构建失败即探针失败）；
2. 插件配置里填镜像名：

```yaml
# cordis.patch.yml
- id: ezprot
  config:
    enableInstall: true
    backend: auto            # 或显式 docker
    dockerImage: '<你的用户名>/ezprot:latest'
```

3. 用户侧体验：`status` 会报告 Docker 是否可用；需要装环境时 agent 会**询问用户
   选 Docker 还是本地 R**（附优劣对比），选择会被记住，后续所有步骤自动走所选后端。

镜像内含 R 4.4.0 + 全部依赖包（Bioc 3.20）；运行时挂载项目目录与背景库缓存，分析数据不出容器。

## 离线部署（无网实验室）

1. 在有网机器上装好包库，执行 `scripts/create-offline-snapshot.ps1` 生成快照 zip；
2. 实验室机器装上 R 4.4.0（插件可自动下载安装，或手动装）；
3. agent 调 `proteomics_environment action=restore_snapshot snapshotPath=<zip>`，或部署者直接把 zip 解压到 `dataDir/runtime`。

## 开发验证

```powershell
node --check lib\*.js   # 语法
node test\drive.mjs     # 用 test\ 下的小鼠示例数据跑通全流程（需本机 R 4.4.0 + renv 包库）
```

详见 `docs/biologist-guide.zh.md`。
