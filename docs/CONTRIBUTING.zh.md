# 参与贡献

[English](../CONTRIBUTING.md) | [中文](CONTRIBUTING.zh.md)

感谢你对本项目的关注！项目遵循官方 DeepSeek Harness 插件规范（[插件开发文档](https://deepseek-harness.github.io/deepseek-harness/develop/basic/)）。

## 开发环境

```powershell
pnpm install   # devDeps：typescript + 与部署版本对齐的 @deepseek-ai/* 类型
pnpm build     # tsc：src/*.ts -> lib/*.js（+ .d.ts）
pnpm test      # vitest 单元测试（无需 R）
```

开发安装（link 协议实时挂载进 profile）：

```powershell
dsh plugin --profile web add "link:<本仓库绝对路径>"
```

- `link:` 协议是符号链接：改 `src/*.ts` 后只需 `pnpm build`（无需重装）；
  `r/` 脚本或 `cordis.patch.yml` 的改动直接生效。
- 生产用户不受影响：npm/github/tarball 安装的是静态快照（`lib/` 已提交，
  git 直装无需构建）。
- CI：`.github/workflows/ci.yml`（`pnpm install → tsc → vitest`）。
- 没有 pnpm 的机器：`scripts/install.ps1`（先尝试 `dsh plugin add`，失败则
  真实路径拷贝 + 手动追加 bundles）。

## 开发验证

```powershell
node --check lib\*.js               # 语法检查
node tests\e2e\mount-smoke.mjs      # bundle 解析 + apply() + 8 工具注册（无需 R）
node tests\e2e\drive.mjs            # 用 fixtures 小鼠数据跑通全流程（需本机 R 4.4.0 + 完整包库）
node tests\e2e\summary-check.mjs    # 对已完成项目做步骤摘要检查
node tests\e2e\env-fresh.mjs        # 全新机器安装模拟（干净 R + 空库）
```

## 目录结构

| 路径 | 用途 |
|---|---|
| `src/` | TypeScript 插件源码（构建到 `lib/`） |
| `lib/` | 构建产物（已提交；git 直装无需构建） |
| `r/` | R 计算内核（`setup/` 环境脚本、`run.R` 步骤入口、`core/`、`utils/`、`background/`、`import/`） |
| `manifest/packages.json` | 必需 R 包清单（R 4.4.0 / Bioc 3.20） |
| `cordis.patch.yml` | bundle 配置层（仅通用默认值） |
| `tests/unit/` | vitest 单元测试 |
| `tests/e2e/` | 端到端驱动（需本机 R 4.4 + 完整包库） |
| `tests/fixtures/` | e2e 用的小鼠示例数据 |
| `docker/` | Docker 可选后端镜像（构建与发布指南：`docker/README.md`） |
| `scripts/` | 部署工具（一键安装、离线快照制作、Linux 诊断探针） |

## 配置项

插件的默认值在 `cordis.patch.yml` 中；机器特异的覆盖写在 profile 自己的
`cordis.patch.yml`（按 id 覆盖）或 `$DSH_HOME/cordis.patch.yml`：

| 字段 | 默认 | 含义 |
|---|---|---|
| `dataDir` | `$DSH_HOME/proteomics` | 运行时缓存（R 安装、包库、背景库、下载） |
| `libraryDir` | `dataDir/runtime/library` | R 包库；指向已有完整库（如 renv 库）可跳过安装 |
| `rscript` | 自动探测 | 固定 Rscript 路径 |
| `cranRepo` | 西湖 CRAN | CRAN 镜像 |
| `biocRepo` | 西湖 Bioconductor | Bioconductor 镜像 |
| `enableInstall` | `true` | 是否允许自动安装 R/包 |
| `defaultTimeoutMs` | `1800000` | 单步骤超时 |
| `backend` | `auto` | `auto`（本地 R 优先，无 R 且检测到 Docker 时用镜像）/ `local` / `docker` |
| `dockerImage` | `yukunru/ezprot:latest` | docker 后端使用的镜像 |

## 规范约定

- bundle patch（`cordis.patch.yml`）只放大多数用户会保留的默认值；机器
  特异的取值放 profile 自己的 `cordis.patch.yml`。
- 所有可调项都必须是带 schema 默认值的 `Config` 字段——绝不在代码里硬编码
  两个部署环境可能不同的值。
- 所有注册都发生在 `apply()` 内，以便 HMR/卸载时清理。
- 优先用结构化摘要（CSV 推导）而不是解析 R 日志文本。
- 每个用户可见的改动都要更新 `CHANGELOG.md`。

## 提交 Pull Request

1. `pnpm build && pnpm test` 必须通过。
2. R 流水线改动保持最小且非交互（禁止 `readline()`）。
3. 新增物种或参数时，更新 `README.md` 和生物学家指南
   （`docs/biologist-guide.md` / `docs/biologist-guide.zh.md`）。
