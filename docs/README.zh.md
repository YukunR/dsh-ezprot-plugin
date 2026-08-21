# dsh-ezprot-plugin

[English](../README.md) | [中文](README.zh.md)

一个**即插即用的 DeepSeek Harness 蛋白质组学分析插件**。它把完整的蛋白表达分析流程——归一化 → PCA → 批次校正 → 差异分析 → GO/KEGG 富集 → GSEA——包装成一场对话：把数据文件交给 agent，回答几个问题（哪些列是什么、比较哪些组），插件就会自动准备好一切，逐步执行并展示每一步的摘要和图形，最后给出解读报告。

不需要会 R、不需要碰终端：插件会在第一次使用时自动检测或静默安装自己的 R 4.4.0 运行时和包库（一次性，约 10–20 分钟）。Docker 是可选后端：当本机无法搭建可用的 R 环境时插件会自动改用 Docker 镜像，网络受限的机器也可把一次性 GO/KEGG 背景构建放进镜像内完成。

## 安装

### 通过 DSH Desktop 插件市场安装

[DSH Desktop](https://github.com/anywhere-labs/deepseek-harness-desktop#dsh-desktop) 自带插件市场。添加一次我们的目录来源后即可在界面中安装：

1. 设置 → 插件 → 插件市场 → 来源 → **添加标准来源**；
2. 填入 `https://dsh-plugin.yukunr.top/catalog-source.json`；
3. 打开「发现」，搜索 `ezprot`，点击 `dsh-ezprot-plugin` 卡片安装 —— Desktop 会在安装前再次核对精确版本与当前 profile；
4. 重启 Desktop，新建会话即可使用 `proteomics_*` 工具。

带截图的图文步骤：[安装指南](install.zh.md)。

### 命令行安装

前置要求：Node.js（自带 `npx`）和 pnpm——`npm install -g pnpm`。

需要 [`dsh`](https://github.com/deepseek-ai/deepseek-harness) 命令行工具（Windows / macOS / Linux 通用），一条命令：

```bash
npx @deepseek-ai/dsh plugin --profile web add dsh-ezprot-plugin@0.1.1
```

已全局安装 `dsh` 时，去掉 `npx @deepseek-ai/` 前缀即可：

```bash
dsh plugin --profile web add dsh-ezprot-plugin@0.1.1
```

然后重启 `dsh web`。每个会话的 agent 都会获得 `proteomics_*` 工具。

## 使用

直接和 agent 对话即可。例如：

> 我的蛋白组数据在 `D:\我的实验\origin_data.txt`，样本分组在 `D:\我的实验\sample_info.txt`，小鼠样本，帮我分析 HC、HD 分别对 NC 的差异蛋白。

Agent 会检查数据质量、和你确认比较组、逐步完成分析，并写出解读报告（关键蛋白、富集通路、候选靶点）。详细说明见：[给生物学家的使用指南](biologist-guide.zh.md)（[English](biologist-guide.md)）。

## 开发

见 [CONTRIBUTING](../CONTRIBUTING.md)。
