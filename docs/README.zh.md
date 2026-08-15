# dsh-ezprot-plugin

[English](../README.md) | [中文](README.zh.md)

一个**即插即用的 DeepSeek Harness 蛋白质组学分析插件**。它把完整的蛋白表达分析流程——归一化 → PCA → 批次校正 → 差异分析 → GO/KEGG 富集 → GSEA——包装成一场对话：把数据文件交给 agent，回答几个问题（哪些列是什么、比较哪些组），插件就会自动准备好一切，逐步执行并展示每一步的摘要和图形，最后给出解读报告。

不需要会 R、不需要 Docker、不需要碰终端：插件会在第一次使用时自动检测或静默安装自己的 R 4.4.0 运行时和包库（一次性，约 10–20 分钟）。

## 安装

前置要求：Node.js（自带 `npx`）和 pnpm——`npm install -g pnpm`。

需要 [`dsh`](https://github.com/deepseek-ai/deepseek-harness) 命令行工具（Windows / macOS / Linux 通用），一条命令：

```bash
npx @deepseek-ai/dsh plugin --profile web add github:YukunR/dsh-ezprot-plugin
```

已全局安装 `dsh` 时，去掉 `npx @deepseek-ai/` 前缀即可：

```bash
dsh plugin --profile web add github:YukunR/dsh-ezprot-plugin
```

git 直装首次会编译一次（pnpm 会提示允许构建脚本）：按提示在 `$DSH_HOME/profiles/web/pnpm-workspace.yaml` 的 `allowBuilds` 里加入 `dsh-ezprot-plugin`，然后重跑上面的安装命令。

然后重启 `dsh web`。每个会话的 agent 都会获得 `proteomics_*` 工具。

## 使用

直接和 agent 对话即可。例如：

> 我的蛋白组数据在 `D:\我的实验\origin_data.txt`，样本分组在 `D:\我的实验\sample_info.txt`，小鼠样本，帮我分析 HC、HD 分别对 NC 的差异蛋白。

Agent 会检查数据质量、和你确认比较组、逐步完成分析，并写出解读报告（关键蛋白、富集通路、候选靶点）。详细说明见：[给生物学家的使用指南](biologist-guide.zh.md)（[English](biologist-guide.md)）。

## 开发

见 [CONTRIBUTING](../CONTRIBUTING.md)。
