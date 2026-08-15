# ezprot Docker 镜像：构建与发布

镜像 = R 4.4.0 + `manifest/packages.json` 的全部依赖。镜像内运行插件自己的
`install_packages.R` 与 `check_runtime.R`（清单即单一事实源），**构建完成即通过
运行时探针**，否则 build 直接失败。发布后用户 `docker pull` 成品，使用侧完全
不再依赖 CRAN/Bioc 镜像质量。

## 1. 本地构建（在装有 Docker 的机器上）

```powershell
cd D:\ResearchProject\ezprot-dsh-plugin
docker build -t ezprot:latest -f docker/Dockerfile .
```

首次构建约 15–30 分钟（镜像内全量装包）。构建成功 = 探针全绿。

> **镜像内装包策略（Linux）**：CRAN 包走 Posit PPM 二进制仓库
> （`repos.linuxBinaryCran`，Westlake 镜像没有 Linux 二进制，codename 按容器
> 自动切换），**日期固定在 2024-11-15**（Bioc 3.20 同期快照——PPM 的
> `latest` 已转向 R ≥ 4.5，会与 Bioc 3.20 的 ggtree 等冲突）；Bioc 3.20 包走
> Westlake Bioc 镜像源码编译（r-ver 自带 gcc）；已归档的 gghalves/ggalt 走
> Westlake CRAN archive。全部在 `install_packages.R` 内按平台自动选择，
> Windows/macOS 路径不变。
>
> 若 Docker Hub 拉取基础镜像不稳定，可换镜像站构建：
> ```powershell
> docker build --build-arg R_BASE=hub.rat.dev/rocker/r-ver:4.4.0 -t ezprot:latest -f docker/Dockerfile .
> ```
>
> 若构建环境访问不了 Ubuntu 官方源（如部分国内网络），可用
> `--build-arg APT_MIRROR=https://mirrors.westlake.edu.cn/ubuntu` 把系统
> 库安装（libuv1/zlib1g-dev/libxml2-dev 等）切到 Westlake Ubuntu 镜像。
>
> 若构建日志出现 `rspm-sync.rstudio.com` 的 “Couldn't resolve host name”
> （PPM 二进制实际由该 CDN 主机提供，部分网络的容器 DNS 解析抖动），可把
> 该主机钉到已知 IPv4 再构建（`install_packages.R` 内置重试 + Westlake 源码
> 回退，即使个别包失败也会自动收敛）：
> ```powershell
> docker build --add-host rspm-sync.rstudio.com:18.64.122.75 -t ezprot:latest -f docker/Dockerfile .
> ```

## 2. 本地验证

```powershell
# 冒烟：镜像内跑一遍运行时探针
docker run --rm ezprot:latest Rscript /opt/ezprot/check_runtime.R /opt/ezprot/manifest-runtime.json
# 期望最后一行：CHECK_RESULT: ALL OK
```

## 3. 发布到镜像仓库（二选一）

### 方式 A：Docker Hub（本项目默认，镜像地址 `yukunru/ezprot`）

```powershell
docker login                                        # 用你的 Docker Hub 账号
docker tag ezprot:latest yukunru/ezprot:0.1.0
docker push yukunru/ezprot:0.1.0
docker tag ezprot:latest yukunru/ezprot:latest
docker push yukunru/ezprot:latest
```

### 方式 B：GitHub Container Registry (GHCR)

1. GitHub → Settings → Developer settings → Personal access tokens → 新建
   classic token，勾选 `write:packages`、`read:packages`；
2. 用 token 登录并推送：

```powershell
$env:CR_PAT = '<你的token>'
$env:CR_PAT | docker login ghcr.io -u <你的GitHub用户名> --password-stdin
docker tag ezprot:latest ghcr.io/<你的GitHub用户名>/ezprot:0.1.0
docker push ghcr.io/<你的GitHub用户名>/ezprot:0.1.0
```

### 多平台（可选，覆盖 M 系列 Mac / 服务器）

```powershell
docker buildx create --use
docker buildx build --platform linux/amd64,linux/arm64 `
  -t <registry>/ezprot:0.1.0 --push -f docker/Dockerfile .
```

## 4. 插件侧使用

发布后，在 profile 的 `cordis.patch.yml` 里配置：

```yaml
- id: ezprot
  config:
    enableInstall: true
    backend: auto          # auto: 本地 R 优先；无 R 且检测到 Docker 时用镜像
    dockerImage: 'yukunru/ezprot:latest'   # 插件默认值；换成 ghcr.io/<用户名>/ezprot:latest 可切 GHCR
```

用户侧体验：`proteomics_environment action=status` 会报告 Docker 是否可用；
需要装环境时，agent 会**询问用户选 Docker 还是本地 R**（附优劣对比）。
选 Docker 时插件执行 `docker pull` + 容器内探针验证，并把选择记住——后续所有
分析步骤都在容器里跑（插件把项目目录和背景库缓存挂载进容器，数据不出本机）。

## 优劣对比（agent 询问用户时使用）

| | Docker 镜像 | 本地 R（自动安装） |
|---|---|---|
| 环境稳定性 | 镜像固定，结果可复现 | 取决于镜像源质量（已有重试/回退/离线快照） |
| 系统污染 | 零污染，装在容器里 | 装到插件私有目录，不碰系统 R |
| 前置要求 | 需安装 Docker（WSL2 等） | 无需任何前置，自动下载安装 R |
| 首次耗时 | 拉镜像几分钟（一次） | 装 R+包 10–20 分钟（一次） |
| 断网可用 | 需先有镜像；离线快照不可用 | 支持离线快照 zip 恢复 |
