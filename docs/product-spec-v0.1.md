# RepoDesk 产品说明 v0.1

> 历史基线说明：本文保留最初的 v0.1 产品定义。后续已经验收的 Files 编辑、Git Review、显式 Git 写操作、Blame、上下文导航和 Maven 决定以 `product-spec-v0.1-amendment.md` 为准，并覆盖本文中的冲突内容，特别是“Git 完全只读”和“延后 Commit/Branch 操作”等旧决定。

> 状态：历史基线，冲突内容由 `product-spec-v0.1-amendment.md` 覆盖
> 产品形态：个人使用的原生 macOS 应用
> 核心场景：Codex Agent 修改代码后，浏览文件、检查 Git 改动与历史、执行项目任务

## 1. 产品定位

RepoDesk 是一个面向 Agent 开发流程的本地仓库工作台。它用一个窗口管理一个大型工作目录，并允许用户在其中切换多个子 Git 仓库。

它不是 IDE，不负责代码补全、项目索引、重构、启动调试器或运行语言服务器。它负责把 Agent 完成修改后的人工确认工作集中到一个轻量应用中。

### 1.1 产品目标

- 一个窗口完成文件浏览、Git 检查、历史查看和任务执行。
- 适配 `example-workspace` 这类包含多个子仓库的大型目录。
- 自动感知 Codex 或其他外部程序产生的文件变化。
- 允许不同工作区、不同仓库使用不同的 Maven 参数和环境。
- 原生、快速、无账号、无遥测、数据完全保留在本地。

### 1.2 非目标

- 不提供 Java 代码补全、语义索引或重构。
- 不提供 Debugger、Profiler、数据库工具和服务启动面板。
- 不替代 Codex Agent 的代码修改能力。
- v0.1 不提供 Reset、Discard、Rebase、Merge 等高风险 Git 写操作。
- v0.1 不提供插件系统或远程协作。

## 2. 核心术语

### Workspace（工作区）

用户通过系统目录选择器打开的大目录，例如：

```text
/Users/you/workspaces/example-workspace
```

工作区负责文件浏览、仓库登记、仓库发现、工作区任务和最近状态。工作区本身可以不是 Git 仓库。

### Repository（仓库）

工作区内部登记的 Git 仓库。仓库可以位于任意深度，也可以是工作区根目录本身。当前仓库决定 Changes、History、Branches 和仓库级任务的上下文。

### Active Repository（当前仓库）

用户当前选中的仓库。应用一次只持续监控一个当前仓库，减少大型工作区的后台开销。

### Task（任务）

一个可重复执行的本地命令定义。Maven 是第一类使用场景，但任务模型不与 Maven 绑定。

### Review State（审查状态）

用户对当前改动文件的人工查看进度。文件内容再次变化后，其“已查看”状态自动失效。

## 3. 信息架构

应用采用单窗口结构：

```text
Window
├── Title Bar
│   ├── 当前工作区
│   ├── 当前仓库
│   └── Refresh / Settings
├── Workspace Sidebar
│   ├── Repositories
│   └── Files
├── Primary Navigation
│   ├── Overview
│   ├── Changes
│   ├── Files
│   ├── History
│   └── Tasks
└── Content
    ├── 列表
    └── 详情
```

### 3.1 窗口恢复规则

- 首次打开工作区时进入 Overview。
- 再次打开时恢复上次选中的仓库和页面。
- 当前仓库仍存在时，Changes 页面恢复原来的文件选择。
- 仓库被移动或删除时显示失效状态，不自动删除登记信息。

## 4. 主要用户流程

### 4.1 打开 example-workspace 并检查 Agent 改动

1. 用户打开 `example-workspace` 工作区。
2. 应用恢复上次登记的子仓库。
3. Overview 显示每个仓库的分支、改动数量和上次提交。
4. 用户选择 `sample-service`。
5. 应用切换当前仓库并加载 Git 状态。
6. 用户进入 Changes，逐个查看未暂存和已暂存 Diff。
7. 用户将文件标记为已查看。
8. Codex 再次修改文件时，应用刷新 Diff，并取消该文件的已查看状态。

### 4.2 执行 Maven Deploy

1. 用户进入当前仓库的 Tasks 页面。
2. 选择仓库任务 `Inventory Deploy`。
3. 应用展示解析后的 executable、arguments、工作目录和环境。
4. Deploy 类任务弹出确认。
5. 用户确认后执行任务。
6. 应用实时合并展示标准输出和错误输出。
7. 任务完成后展示退出码、耗时和完成时间。
8. 用户可以复制完整日志或重新执行。

### 4.3 浏览文件和历史

1. 用户通过 Files 树、双击 Shift 的文件名搜索或 `Command+Shift+F` 全文检索查找文件。
2. 应用只读展示代码、XML、YAML、JSON 或 Markdown。
3. 用户可以切换 Markdown 源码和预览。
4. 用户可以从文件菜单进入 File History。
5. History 页面展示提交列表和所选提交的文件 Diff。

## 5. 功能需求

### 5.1 Workspace

- 通过原生目录选择器打开工作区。
- 保存最近工作区和安全访问状态。
- 一个窗口同时只打开一个工作区。
- 支持关闭和切换工作区。
- 支持手动登记工作区下的仓库。
- 提供按需“发现仓库”，不在启动时强制递归扫描。
- 仓库发现默认跳过 `.git`、`target`、`build`、`.gradle`、`node_modules`、`.idea` 和隐藏缓存目录。
- 支持 `.git` 目录和 `.git` 文件。
- 记住仓库显示名称、排序和是否置顶。

### 5.2 Repository Overview

- 展示仓库名称和相对路径。
- 展示当前分支或 detached HEAD。
- 展示未暂存、已暂存和未跟踪文件数量。
- 展示本地分支相对上游的 ahead/behind 状态。
- 展示最近一次提交的摘要、作者和相对时间。
- 支持点击仓库切换当前上下文。
- 默认只刷新当前仓库；Overview 手动刷新时并发刷新已登记仓库。

### 5.3 Changes

- 分组展示 Staged、Unstaged 和 Untracked。
- 支持新增、修改、删除、重命名、冲突和二进制文件状态。
- 展示统一 Diff。
- 支持忽略空白差异开关。
- 支持上一个/下一个改动文件。
- 支持“已查看”标记和未查看数量。
- 文件发生变化时自动取消已查看。
- v0.1 只读，不提供丢弃或修改文件功能。

### 5.4 Files

- 浏览整个 Workspace，而非仅当前仓库。
- 支持按目录懒加载，避免一次枚举全部文件。
- 支持双击 Shift 按文件名模糊匹配并快速打开所有类型的文件（排除隐藏文件和常见构建/缓存目录）。
- 支持 `Command+Shift+F` 在当前 Workspace 或 Repository 根目录内进行全文检索。
- 支持文本编码检测和二进制文件提示。
- 支持 Java、Kotlin、XML、YAML、JSON、Properties、Shell 和 Markdown 高亮。
- Markdown 支持源码与预览切换。
- 超大文件进入只读降级模式并关闭语法高亮。
- 外部修改当前文件时自动重新加载；若未来开放编辑，需要先处理未保存冲突。

### 5.5 History and Branches

- 分页加载提交历史。
- 展示提交摘要、作者、时间、Hash 和 Ref。
- 展示所选提交的文件列表和 Diff。
- 支持当前仓库全部分支、仅当前分支和文件历史。
- 展示本地分支和远程分支。
- 支持复制分支名、Hash 和提交信息。
- v0.1 仅查看分支，不提供 Checkout、Delete 或 Rebase。

### 5.6 Tasks

- 支持全局、工作区和仓库三个任务层级。
- 层级优先级为 Repository > Workspace > Global。
- 支持 executable、arguments、workingDirectory 和 environment。
- 支持 Maven Wrapper，并优先推荐 `${repositoryRoot}/mvnw`。
- 支持选择 Maven、JDK 和 `settings.xml` 路径。
- 支持变量 `${workspaceRoot}`、`${repositoryRoot}`、`${selectedFile}`、`${userHome}` 和 `${env:NAME}`。
- 参数以数组保存，不拼接为 Shell 字符串。
- 支持实时日志、停止、复制、清除和重新执行。
- 保存最近任务记录、退出码和耗时；日志持久化可关闭。
- Deploy、Publish 等任务可配置强制确认。
- 仓库提供的任务定义在工作区获得信任前不得执行。

### 5.7 External Change Monitoring

- 监控当前仓库的文件系统变化。
- 对连续写入进行防抖。
- 忽略 `.git` 内高频但与界面无关的临时事件。
- 外部变化触发 Git Snapshot 刷新。
- 正在显示的文件变化时刷新文档。
- 应用回到前台时执行一次一致性刷新。

## 6. 任务配置模型

建议逻辑格式如下，具体文件格式由实现阶段确定：

```json
{
  "version": 1,
  "tasks": [
    {
      "id": "inventory-deploy",
      "name": "Inventory Deploy",
      "executable": "/opt/apache-maven/bin/mvn",
      "arguments": [
        "-s",
        "/opt/apache-maven/conf/settings-example.xml",
        "-pl",
        "sample-client,sample-service",
        "-am",
        "clean",
        "deploy"
      ],
      "workingDirectory": "${repositoryRoot}",
      "environment": {},
      "confirmation": "required"
    }
  ]
}
```

### 6.1 配置存储

- 全局配置：应用的 Application Support 目录。
- 工作区和仓库本地覆盖：默认仍存储在 Application Support，通过路径关联，不污染公司仓库。
- 后续可选择导出为 `.repodesk/tasks.json`，方便共享；导入后必须重新确认信任。
- 密码、Token 和 Maven Server 凭据不写入任务配置。

## 7. 技术方案

### 7.1 技术栈

- Swift 6
- SwiftUI 为主，AppKit 处理文本和 macOS 特有交互
- Foundation `Process` 执行 Git 和任务
- 系统 Git CLI
- CodeEditSourceEditor 或经验证的原生文本模块
- Swift Testing
- XcodeGen 维护工程配置
- `xcodebuild` 完成构建与测试

### 7.2 主要模块

```text
RepoDeskApp
├── Workspace
│   └── 打开目录、登记仓库、文件树、变化监控
├── GitRepository
│   └── 状态、Diff、历史、分支、Git 输出解析
├── TaskRunner
│   └── 配置解析、变量展开、进程、日志、取消
├── DocumentViewer
│   └── 文件加载、高亮、Markdown、大文件降级
└── LocalSettings
    └── 最近工作区、任务覆盖、信任和界面恢复
```

每个模块通过一个较小的 Interface 暴露完整行为。Git 命令、进程管理、文件监听和配置合并等复杂性保留在模块 Implementation 内，不泄露给界面。

### 7.3 测试策略

- GitRepository 使用临时真实 Git 仓库进行集成测试。
- Git 输出解析使用固定 fixture 测试重命名、冲突和特殊文件名。
- TaskRunner 使用可替换的进程 Adapter 测试输出流、失败和取消。
- 变量解析、任务层级覆盖和信任判断使用纯逻辑测试。
- Workspace 使用临时目录测试嵌套仓库和忽略规则。
- 每个里程碑执行 `xcodebuild test` 和 Release 构建。

## 8. 性能与安全约束

- 不运行 Java Language Server。
- 不建立全工作区语义索引。
- 不默认扫描工作区全部 Git 状态。
- 历史和 Diff 按需加载。
- 任务运行结束后不保留 Maven/Java 子进程。
- 不使用 Shell 字符串拼接执行命令。
- 不自动执行仓库中的任务定义。
- 应用不包含账号、遥测或云同步。
- Git 网络操作和 Maven Deploy 只能由用户明确触发。

## 9. v0.1 交付范围

### 必须具备

- 原生单窗口应用骨架。
- 打开和恢复 Workspace。
- 手动登记、移除和切换 Repository。
- 仓库 Overview。
- Changes 列表和只读 Diff。
- History、Branches 和提交详情。
- Workspace 文件树和只读文件查看。
- 全局、工作区、仓库任务配置。
- Maven 任务运行、实时日志和停止。
- 当前仓库自动刷新。
- 浅色和深色模式。

### 延后

- Git 暂存和提交。
- Git 分支切换。
- Markdown 完整扩展语法。
- 多窗口。
- 可共享任务市场或插件。
- 自动更新和正式发布签名。

## 10. 待确认的产品决定

以下为推荐默认值，确认后作为 v0.1 基线：

1. 应用暂名 `RepoDesk`，正式命名可以在首个可运行版本后调整。
2. 一个窗口只打开一个 Workspace；v0.1 不做多窗口。
3. 启动后恢复上次页面；首次打开进入 Overview。
4. 仓库发现采用手动登记优先，自动发现按需执行。
5. Changes v0.1 完全只读，但包含 Review 标记。
6. Branches v0.1 完全只读。
7. 任务配置默认保存在应用本地，不修改公司仓库。
8. Deploy 类任务默认要求确认。
9. 应用采用非 App Store 的个人本地构建，暂不启用 App Sandbox。
10. 最低系统版本根据实际开发电脑确定，不为旧 macOS 增加兼容成本。

## 11. 验收场景

v0.1 完成时，应当能够连续完成以下流程：

1. 打开 `example-workspace`。
2. 登记至少三个子 Git 仓库。
3. 在仓库间切换并看到正确分支和改动。
4. 查看 Codex 产生的所有未暂存与已暂存 Diff。
5. Codex 再次修改文件后，界面自动刷新。
6. 查看当前仓库提交历史、分支和任一提交详情。
7. 在当前 Workspace 或 Repository 根目录中按文件名搜索并打开任意类型文件，或通过全文检索定位任意文本文件中的匹配行。
8. 为某个仓库配置带公司 Maven settings 和模块参数的 Deploy 任务。
9. 执行任务、实时查看日志、获取退出码并可以停止任务。
10. 关闭并重新打开应用后恢复工作区、当前仓库和页面。
