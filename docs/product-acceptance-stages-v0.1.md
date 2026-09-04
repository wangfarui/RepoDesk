# RepoDesk v0.1 产品功能分阶段验收计划

> 文档状态：执行基线
> 制定日期：2026-08-08
> 产品基线：`product-spec-v0.1.md`
> 功能修订：`product-spec-v0.1-amendment.md`

> 新会话主 Agent：本文件是任务接手入口。请完整阅读本文件及其指定基线，检查代码与阶段记录，从第一个未通过阶段继续；不要要求用户重新陈述需求。

## 1. 目的

本计划用于把 RepoDesk v0.1 从当前可运行版本推进到可整体交付版本，并控制开发与产品验收的节奏。

阶段划分以用户能够完整体验的一组大功能为单位，不按单个按钮、模型或技术模块频繁拆分。每个阶段内部的设计、实现、测试、修复和本地构建连续执行；只有当该阶段已经形成完整体验并通过自动验证后，才提交用户验收。

分阶段验收用于尽早确认产品方向是否符合预期，不代表阶段之间可以留下半成品。最终仍需通过第四阶段的全流程验收，才能认定 v0.1 完成。

### 1.1 跨会话接手说明

本文件同时是后续新会话的主要交接入口。用户在其他会话中说“按验收文档继续”“开始下一阶段”或类似指令时，主 Agent 不得要求用户重新描述产品需求，应先完成以下启动动作：

1. 进入项目目录 `/Users/wangfarui/workspaces/wfr/RepoDesk`。
2. 完整阅读本文件，再完整阅读 `product-spec-v0.1.md`、`product-spec-v0.1-amendment.md` 和 `architecture.md`。
3. 查看本文件的“阶段总览”“当前执行快照”和“阶段执行记录”，确认第一个尚未通过的阶段。
4. 检查 `git status` 和实际文件，保留现有未提交修改；不得把工作区当作全新项目重建。
5. 检查本机 Xcode、Swift、XcodeGen 和测试能力，不沿用可能已经过期的环境判断。
6. 将当前阶段更新为 `实施中`，建立内部开发计划，并评估是否适合并行 subagent。
7. 连续实施当前阶段直到达到通用完成门槛，再更新本文件并提交用户验收。

上下文优先级从高到低为：

1. 用户在当前会话中的最新明确决定。
2. 本文件中已经通过验收的阶段决定和执行记录。
3. `product-spec-v0.1-amendment.md`。
4. `product-spec-v0.1.md`。
5. `architecture.md` 与其他说明文档。

其中，“Files 支持安全编辑”和“显式 Git 操作正式进入 v0.1”已经由修订文件覆盖原基线中的 Files/Git 只读决定。

### 1.2 固定产品与技术上下文

- 产品：原生 macOS 个人应用 RepoDesk，一个窗口管理一个大型 Workspace，并手动切换其中的子 Git Repository。
- Workspace 与 Repository 是不同领域对象；Workspace 可以不是 Git 仓库。
- 顶部模块按上下文显示：Workspace 为 Overview、Changes、Files、Maven；Repository 为 Changes、Files、History、Maven。
- Git 自动刷新与跨仓库 Review 保持只读；v0.1 正式包含用户显式触发的 Commit、Fetch/Pull/Push、Checkout、Merge、Rename、安全 Delete、冲突解决和 Blame，不包含 Reset、Rebase、force Push、任意 Git 命令或自动 Git 写入。
- Files 支持原生文本编辑、安全保存、Markdown 预览和外部冲突保护，但不扩展为 IDE。
- Maven 复用通用任务进程能力，重点覆盖 Workspace 级 Maven 配置、Repository 模块树和 Lifecycle 执行。
- 明确不做 Java 索引、代码补全、LSP、重构、Debugger、Profiler、插件和远程协作。
- 技术栈：Swift 6、SwiftUI、少量 AppKit、Foundation `Process`、系统 Git、Swift Testing 和 XcodeGen。
- 工程配置以 `project.yml` 为源；生成的 Xcode 工程不作为手工维护源。
- 所有 Git 和任务参数保持数组，不通过 Shell 字符串拼接执行。
- 用户数据保留在本地，不引入账号、遥测或云同步。
- 开发 RepoDesk 时，除非用户明确授权，不在 RepoDesk 源码仓库创建 Git Commit；此约束不影响应用内已经验收的 Commit 功能。

主要代码区域：

- `RepoDeskApp/App`：应用生命周期和窗口级状态协调。
- `RepoDeskApp/Workspace`、`Repository`：Workspace 持久化、Repository 登记和发现。
- `RepoDeskApp/Files`：文件树、搜索、文档读取和保存。
- `RepoDeskApp/Git`：Git 查询、模型、解析，以及显式 Git 操作边界。
- `RepoDeskApp/Tasks`：任务模型、持久化、解析、运行和停止。
- `RepoDeskApp/Features`：SwiftUI/AppKit 用户界面。
- `RepoDeskTests`：Swift Testing 测试。

### 1.3 当前执行快照

> 快照日期：2026-08-20。每个开发会话结束前必须更新本节；新会话以代码和最新记录为准，不盲目信任旧描述。

- 当前活动阶段：v0.1 全部阶段与 `REL-01` 已通过用户验收，版本开发完成。完整 Xcode 测试链路仍受环境阻塞，并按已接受的替代验证记录保留。
- 当前应用可通过 `build/RepoDesk.app` 本地运行。
- 已有基础：Workspace 打开与恢复、Repository 登记与发现、五个主页面、Git 状态/Diff/History/Blame 与显式操作、文件树与快速打开、原生文本编辑器、安全保存、Maven 配置和流式日志。
- 第一阶段已通过用户验收：真实递归文件系统事件监听、合并防抖、已加载目录增量刷新、目录错误重试、单子目录紧凑显示、安全编辑和块级 Markdown 原生渲染均已确认。
- 第二阶段已按上下文重构：Workspace 显示 Overview/Changes/Files/Maven，Repository 显示 Changes/Files/History/Maven；工作区 Changes 支持全部或单仓库，Repository Changes 固定当前仓库；Files 根目录随上下文切换；History 使用上方 Side-by-side Diff、下方 Commit + 改动文件的 IDEA 风格布局。
- 第二阶段后续 Git 能力已正式纳入并通过验收：Repository Changes 支持选中文件 Commit、Commit And Push、Push 单独重试；Repository 支持 Fetch/Pull/Push、Branch Checkout/Compare/Merge/Push/Rename/Delete、远程 tracking Branch、冲突解决和双侧 Blame。Workspace 全仓库 Changes 不能 Commit，后台刷新不会自动执行 Git 写操作。
- Workspace 侧栏支持多个最近工作区，并把 Git 仓库与工作区拆成独立滚动区域；仓库发现入口只保留在 Workspace Overview。
- 第三阶段已完成 Maven 日常闭环：Workspace 级 Maven Home、JDK/JAVA_HOME、User settings file、Local repository、Profiles、`-am`、附加参数和运行记录策略；Repository 自动扫描多模块 POM，展示最终 executable、参数数组、环境和工作目录；Lifecycle 支持 clean、compile、package、install、deploy，deploy 执行前确认。
- History 的上下及下方左右分栏比例按 Workspace 持久化；切换 Commit 时保留旧内容直至新数据原子替换，避免闪烁和空 Commit 导致的布局收缩。
- Maven Home 会异步执行 `bin/mvn -version` 校验，成功显示 Maven 版本，失败明确提示路径有误。
- Maven/JDK/settings/local repository 在运行前再次校验；配置保存执行回读确认，失败会显示明确错误；不可执行 Maven Wrapper 会显示告警。
- Maven 运行使用独立进程组，Stop 先向整个组发送 `SIGTERM`，2 秒后仍存活则发送 `SIGKILL`，真实子进程夹具已验证不会遗留 Maven/Java 子进程。
- 最近 Maven 运行按 Workspace 持久化并按 Repository 展示，支持查看状态、模块、Goal、完成时间、耗时、历史日志、删除和按最终命令重跑；日志持久化默认关闭，可配置记录数、单条容量并清理。只持久化显式 `JAVA_HOME`，不写入完整进程环境中的 Token 或凭据。
- Maven 实时输出默认跟随最新内容；用户向上滚动后自动暂停跟随并显示“跳转到最新输出”按钮，回到底部后恢复新内容自动下滚。历史运行日志保持静态查看。
- Repository 内 `pom.xml`、`mvnw` 或 `mvnw.cmd` 变化会增加项目 revision 并异步重扫；普通源码变化不触发 Maven 扫描，重扫时保留旧模块树直至新结果原子替换，失败也不清空现有树。
- Workspace 打开或 Repository 列表变化后，不论当前停留在 Overview、Changes、Files 还是 Maven，都会以最多 4 个并发任务自动补齐全部 Repository 的 Git Snapshot；不再依赖用户逐个选择仓库触发。
- 已有 Snapshot 的后台刷新不进入可见加载状态；相同 Snapshot 不重复写入可观察状态，失败时保留现有列表，选中 Diff 在后台原子更新，避免仓库行、Changes 列表和 Diff 闪烁。
- 已修复批量文件变化导致主线程无响应的问题：普通 FSEvents 保留精确文件路径，相关 `.git` 元数据才映射到 Repository 根目录；Repository 采用单向子路径匹配，Workspace 根文件不会误刷新全部嵌套仓库；目录刷新规划不再执行“事件 × 已加载目录”交叉匹配。
- Repository Snapshot 请求按仓库去重，Git 子命令具有 10 秒超时并在取消时终止进程；文件事件在任何页面都会刷新实际受影响的仓库，使侧栏改动数持续保持最新。
- 后台诊断日志位于 `~/Library/Application Support/RepoDesk/Logs/RepoDesk.log`，Workspace 菜单可直接打开；记录监控启动、大事件批次、处理阶段、耗时和监控错误，并保留一份轮转日志。
- 最近一次真实 `pangmaoyun` 启动验证在约 1 秒内自动加载 23 个 Repository，稳定后进程为 `0.0% CPU / 0.3% MEM`；1 万文件事件、500 个已加载目录的规划验证约 0.183 秒。
- `INT-01 Settings` 已提供通用、Files、Diff、Maven 四个集中页签，可通过 `Command+,` 或主窗口齿轮打开；应用级偏好即时生效并持久化，Maven 配置继续按 Workspace 保存。
- `INT-02` 已补齐 Workspace 导航、页面、文件/Markdown、Changes、History 和 Maven 选择恢复；增加 `Command+1...4` 页面切换、`Command+R` 刷新，以及 Workspace/Repository 失效后的直接恢复入口。
- Settings 已完成整版样式优化：固定侧栏、页头、分组设置行与版本信息在 760x600、840x660 和 980x720 的浅色/深色渲染中无重叠，长中英文路径可压缩显示。
- App 图标母版和 ICNS 已接入 XcodeGen 与直接本地构建，应用显示版本为 `0.1.0`；最终构建显式验证图标资源、Info.plist 和 ad-hoc 签名。
- 当前执行环境没有可用的 Xcode developer directory、XcodeGen 和 Swift Testing 运行链路，不能执行 `xcodebuild test`；用户已验收现有真实 Git/FSEvents/Maven、进程组、持久化、严格并发和应用构建替代验证。
- 当前工作区包含未提交开发文件；必须保留，不对 RepoDesk 源码仓库执行破坏性重置或创建 Commit。
- 最新界面证据包括：`build/application-main-blame-direct.png`、`build/application-main-side-by-side-fixed.png`、`build/commit-execution-states.png`、`build/output-follow-preview.png`、`build/maven-stage3-workspace-window.png`、`build/maven-stage3-repository-window.png`、`build/repository-counts-no-flicker.png`、`build/settings-general.png`、`build/settings-files.png`、`build/settings-diff.png`、`build/settings-maven.png`、`build/settings-general-compact.png`、`build/settings-general-wide-dark.png`、`build/interaction-compact-light.png` 和 `build/interaction-wide-dark.png`。

常用验证入口：

```sh
./scripts/verify-local.sh
open build/RepoDesk.app
```

`verify-local.sh` 的替代验证不等同于完整 `xcodebuild test`；实际能力应根据新会话检查到的工具链决定。

用户在新会话中可以直接使用以下简短指令，主 Agent 应按本文件自动展开完整工作：

```text
继续 RepoDesk 开发。完整阅读 docs/product-acceptance-stages-v0.1.md 及其指定基线，
从第一个未通过阶段继续实施。阶段内部自动开发和验证；适合并行时由主 Agent
自动启用多个 subagent 并统一集成。达到阶段完成门槛后停止并提交我验收，
验收通过前不要进入下一阶段，不在 RepoDesk 源码仓库创建 Git Commit。
```

## 2. 执行与验收规则

1. 以本计划、产品基线和已确认修订为开发依据，不要求用户重复描述需求。
2. 当前版本已有的功能纳入对应阶段一起复核，不因“已经有界面”而默认通过。
3. 每个阶段内部自动连续实施和验证，不针对普通技术细节请求用户确认。
4. 只有涉及产品行为明显改变、数据风险或超出基线的决定，才在阶段中途请求确认。
5. 阶段完成后停止进入下一阶段，提供可运行应用、变更摘要和简短验收步骤，等待用户明确回复验收结果。
6. 用户提出的问题继续在当前阶段修复；修复完成后重新提交该阶段验收。
7. 用户明确表示阶段验收通过后，才开始下一阶段。
8. 开发 Agent 不在 RepoDesk 源码仓库创建 Git Commit，除非用户后续明确授权。
9. 第四阶段通过前，不使用“完整版已完成”或同等表述。
10. 每个会话结束前更新“当前执行快照”、阶段状态和阶段执行记录，使下一会话能够直接接手。

### 2.1 阶段状态

- `待实施`：尚未进入本阶段。
- `实施中`：正在开发或自动验证。
- `待验收`：功能与自动验证已完成，等待用户体验。
- `验收修正中`：用户发现偏差，仍停留在本阶段。
- `已通过`：用户明确确认通过。

### 2.2 通用完成门槛

每个阶段提交验收前必须同时满足：

- 阶段范围内不存在已知阻断问题或用占位界面代替的功能。
- 正常路径、空状态、加载状态、失败状态和数据恢复行为完整。
- 对有数据覆盖风险的操作提供明确确认或冲突保护。
- 新增领域逻辑有测试；关键文件系统、Git 或进程行为有真实运行验证。
- Swift 严格并发类型检查通过，测试源码可编译或解析。
- 本地 `RepoDesk.app` 重新构建并完成启动检查。
- 不破坏此前已经通过的阶段。
- 阶段验收说明只要求用户验证产品效果，不把内部技术步骤转嫁给用户。

### 2.3 多 subagent 并行开发规则

用户已授权主 Agent 在阶段实施过程中自行判断并启用多个 subagent，以提高开发效率。常规并行不需要再次向用户确认，但必须遵守以下规则：

1. 主 Agent 先理解完整产品上下文、当前阶段和工作区状态，再决定是否并行；不得把阅读和解释本验收基线整体外包给 subagent。
2. 当工作可以拆成两个或以上相互独立、边界清晰且文件冲突可控的子任务时，应优先并行，例如“文件监控实现”“独立测试夹具”“非重叠 UI 页面”“文档核对”。
3. 对强顺序依赖、需要共同修改同一核心文件或任务规模很小的工作，不为了形式而启动 subagent。
4. 主 Agent 根据当前环境可用并发槽位自动控制 subagent 数量，不固定要求并行数量。
5. 每个 subagent 必须获得具体、有限的任务范围、可修改文件范围、验收标准和“不在 RepoDesk 源码仓库创建 Commit”的约束。
6. `AppState.swift`、共享领域模型、工程配置和阶段文档属于高冲突区域；原则上由主 Agent 统一修改，或只授权一个 subagent 修改。
7. 主 Agent 负责协调文件所有权、处理重叠修改、整合结果、复核产品一致性和运行最终统一验证，不能直接把 subagent 的“已完成”当作阶段完成。
8. subagent 失败、超时或产出不符合阶段目标时，主 Agent 应接管或重新拆分，不把内部协作问题转交用户处理。
9. 阶段验收报告应简要说明使用了哪些并行工作及统一验证结果，但不要求用户分别验收 subagent 产物。
10. subagent 只服务于当前阶段内部开发；是否进入下一阶段仍由用户验收门禁决定。

## 3. 阶段总览

| 阶段 | 大功能主题 | 主要验收目标 | 当前状态 |
| --- | --- | --- | --- |
| 第一阶段 | Workspace 与 Files | 大目录可以稳定管理，文件树、搜索、编辑和外部变化形成完整闭环 | 已通过 |
| 第二阶段 | Git Review 与操作 | 多仓库 Review、Commit/远程/Branch/冲突操作和 Blame 形成完整 Git 闭环 | 已通过 |
| 第三阶段 | Maven | Maven 环境、模块参数、执行、停止、日志和最近记录达到日常可用 | 已通过 |
| 第四阶段 | 整体集成与最终交付 | 设置、恢复、性能、错误体验、完整测试和端到端流程全部收口 | 已通过 |

当前代码已完成前三阶段和第四阶段全部实施；`QA-01` 替代验证已获用户接受，`REL-01` 已通过最终验收，完整 Xcode 测试链路限制保留在交付记录中。

## 4. 第一阶段：Workspace 与 Files

### 4.1 阶段目标

用户能够打开 `pangmaoyun` 这类大型工作目录，稳定浏览整个 Workspace，在多个子仓库之外独立使用文件树；Codex 或其他程序修改文件后，文件树和当前文档能及时、可靠地同步；普通文本文件可以安全编辑和保存。

### 4.2 实施范围

- 原生打开、关闭、切换和恢复 Workspace。
- 最近 Workspace 与不可用 Workspace 状态。
- 手动登记和按需发现 Workspace 内的 Git Repository，支持根仓库、嵌套仓库、`.git` 目录和 `.git` 文件。
- Repository 显示名称、置顶、排序、移除登记和当前选择持久化。
- Workspace 文件树懒加载、隐藏文件开关和目录错误重试。
- 双击 Shift 进行文件名模糊搜索并打开所有类型文件，`Command+Shift+F` 在当前 Workspace 或 Repository 内进行全文检索，跳过隐藏文件及常见构建和缓存目录。
- 原生文本编辑器、水平滚动、语法着色、撤销、查找和 `Cmd+S`。
- UTF-8、UTF-16、ISO Latin-1 编码识别和保存。
- 二进制提示、大文件只读降级和超大文件拒绝加载。
- Markdown 源码与预览切换，预览使用当前编辑缓冲区。
- 未保存文件切换、Workspace 切换、重新加载和退出保护。
- 保存前版本检查、外部冲突处理、原子写入、符号链接和执行权限保护。
- 基于文件系统事件的 Workspace 变化监控、合并防抖和文件树增量刷新。
- 应用回到前台时执行一致性检查。

### 4.3 阶段验收场景

1. 打开 `pangmaoyun`，关闭并重新打开应用后自动恢复该 Workspace。
2. 展开多个层级目录，确认大型目录不会在打开时一次性全量扫描，也不会明显阻塞界面。
3. 使用双击 Shift 按文件名打开任意类型文件，或使用 `Command+Shift+F` 搜索文件内容并跳转到对应行，路径和内容正确。
4. 编辑普通文本文件并使用 `Cmd+S` 保存；重新加载后内容、编码和脚本权限保持正确。
5. 打开长行文件，确认内容不会压缩成窄列，能够横向滚动并正常编辑。
6. 外部新增、删除、重命名文件，文件树在合理时间内自动同步且保留无关目录的展开状态。
7. 外部修改当前未编辑文件时自动刷新；当前有未保存修改时显示冲突选择，不静默覆盖任何一方。
8. Markdown 预览、二进制提示、大文件只读模式和隐藏文件开关表现明确。
9. 带未保存修改时切换文件、Workspace 或退出应用，均不会直接丢失内容。

### 4.4 本阶段明确不包含

- 代码补全、语义索引、LSP、重构和 Debugger。
- 新建、移动、重命名和删除文件的文件管理器功能，除非后续产品决定另行加入。
- 多标签编辑器和多窗口编辑。

## 5. 第二阶段：Git Review 与操作

### 5.1 阶段目标

用户能够在一个 Workspace 内查看全部已登记仓库的未提交改动，并针对当前选中的 Repository 查看可按分支和用户过滤的 Git Log；在单 Repository 上下文中可以完成 Commit、远程同步、Branch、Merge、冲突解决和 Blame 工作流。外部改动和新提交自动刷新，但后台刷新不执行 Git 写操作。

### 5.2 实施范围

- Repository 不可用状态、重新定位入口和保留登记行为。
- Overview 仅在 Workspace 上下文展示仓库名称、相对路径、分支或 detached HEAD、ahead/behind、改动数量以及最近提交摘要、作者和相对时间；没有仓库时保留空状态和发现入口。
- 选择 Workspace 后自动后台加载全部已登记仓库的改动数量，不依赖当前页面或手动选择；Overview 和 Changes 可手动刷新全部仓库，文件系统事件在任意页面只刷新实际受影响仓库。
- Changes 可选择全部已登记 Repository 或单个 Repository，并按 Repository -> Changes/Unversioned Files -> Directory 或 Module 分层展示；同一已跟踪文件不因 index 与 worktree 同时变化而重复出现，范围和分组记忆到 Workspace 窗口状态。
- Module 以最近的 `pom.xml`、Gradle 文件、`Package.swift`、`package.json` 或 `project.yml` 识别，找不到时回退到顶层目录。
- 新增、修改、删除、重命名、复制、冲突、特殊文件名和二进制状态具有明确标识。
- 文件类型图标与 Git 状态标识分离，优先覆盖 Java/Maven 项目常见文件类型。
- Changes 的结构化 Diff 统一比较 HEAD 与当前工作区文件并支持 Unified/Side-by-side；History 固定使用 Side-by-side。两者均不显示 `diff --git`、`index`、`---`、`+++` 和 `@@` header，长代码行保持单行并可水平滚动，同时支持忽略空白、折叠/展开未改动片段和 Jump To Source；Changes 额外支持上一个/下一个改动。
- History 只读取当前 Repository，不聚合其他仓库，也不提供 Selected File History。
- History 支持当前分支、全部分支、本地/远程指定分支和 Git 作者过滤，Branch/User 选择器支持输入搜索。
- 本地及远程 Branches、当前分支标识、复制 Hash 和提交信息。
- 提交摘要、作者、时间、Hash、Ref 和文件列表；默认选择首个改动文件，每次只懒加载一个文件的 Diff，避免一次渲染整个 Commit Patch。
- History 手动刷新、外部新提交刷新、分页、空结果和提交详情错误状态。
- 当前 Repository、页面、Changes 选择、History Branch/User 过滤和选中提交恢复。
- Repository Changes 支持逐文件纳入/排除 Commit、Commit 信息、Commit 和 Commit And Push；Push 失败保留 Commit 成功结果并支持只重试 Push。Workspace 全仓库范围不能 Commit。
- Repository 工具栏支持 Fetch、Pull 和 Push；Branch 选择器支持本地/远程搜索、Checkout、远程 tracking Branch 创建、Compare、Push、Merge、Rename 和安全 Delete。
- Pull 或 Merge 发生冲突时展示 ours/theirs/merge result，支持整文件或逐冲突块接受、Mark Resolved、Abort Merge 和 Continue Merge。
- Side-by-side Diff 左右两侧可独立启用 Blame，已提交行展示作者、日期和短 Hash，工作区新增行展示未提交状态。

### 5.3 阶段验收场景

1. 登记至少三个子仓库并在仓库间切换，Overview 数据与各仓库实际状态一致。
2. 在 Changes 中同时查看多个仓库，确认每个仓库只包含 Changes 和 Unversioned Files；`AM`、`MM` 等部分暂存文件只在 Changes 出现一次，Untracked 文件只在 Unversioned Files 出现。
3. 在 Directory 和 Module 两种分组间切换，目录层级、模块归属和文件选择保持正确。
4. 检查 rename、copy、特殊文件名和 binary 文件，确认原路径/来源路径、状态标识和 Binary Diff 明确；忽略空白、上一个/下一个改动不会改变 Git 工作区。
5. 选择一个 Repository 进入 History，使用当前分支、全部分支或指定本地/远程分支，再叠加 User 过滤，确认不混入其他仓库提交。
6. 分页加载提交，并查看任意提交的摘要、作者、时间、Hash、Ref 和文件列表；在文件间切换时确认上方仅原子更新当前文件 Side-by-side Diff，并验证未改动片段展开和 Jump To Source。
7. 外部产生新提交或新改动后，当前相关页面自动刷新。
8. 暂时移动一个已登记仓库，界面显示明确失效状态且不自动删除登记；恢复或重新定位后可继续使用。
9. 在单 Repository Changes 中排除部分文件后创建 Commit，确认只提交选中路径；执行 Commit And Push 并分别验证成功、Push 失败和只重试 Push。
10. 执行 Fetch/Pull/Push，在本地与远程 Branch 间切换，验证 tracking Branch、Compare、Merge、Rename 和安全 Delete；冲突场景可解决、Abort 或 Continue。
11. 在 Side-by-side Diff 左右两侧分别开启 Blame，确认加载、未提交行、错误状态和行对齐互不影响。

### 5.4 安全门槛

- 自动 Snapshot、FSEvents 刷新、Changes/History 筛选和分组只读取 Git，不会触发写入或远程操作。
- Commit、Fetch/Pull/Push、Checkout、Merge、Rename、安全 Delete 和冲突解决必须由用户在单 Repository 上下文显式触发。
- Git 参数保持数组并禁用终端交互提示；Commit 信息从命令错误中脱敏。
- v0.1 不实现 Discard、Reset、Rebase、force Push、强制删除 Branch、任意 Git 命令或自动 Git 写入。
- Commit And Push 不伪装成原子操作；Push 失败必须保留已创建 Commit，并且重试 Push 不得创建第二个 Commit。

## 6. 第三阶段：Maven

### 6.1 阶段目标

用户能够在 Workspace 配置 Maven 运行环境，在 Repository 中以类似 IDEA Maven 插件的模块树和 Lifecycle 方式执行 Maven；执行前可核对最终命令，运行、停止和回看结果达到日常可用。通用任务模型作为内部进程基础保留，v0.1 不再提供独立的通用 Tasks 页面。

### 6.2 实施范围

- Workspace 上下文配置 Maven Home、JDK/JAVA_HOME、User settings file、Local repository 和必要的默认参数，并提供原生路径选择与校验。
- Maven Home 优先级为 Repository Maven Wrapper、Workspace Maven Home、系统 `mvn`；校验成功展示 Maven 版本。
- Repository 上下文自动扫描根 POM 和多模块结构，按模块展示 Lifecycle：clean、compile、package、install、deploy。
- 支持模块、profiles、`-am`、goals 和附加参数；参数全程保持数组，不拼接为 Shell 命令。
- 执行前展示最终 executable、参数、环境和工作目录；deploy 强制确认并展示最终命令。
- stdout/stderr 实时输出、复制、清除、退出码、耗时和完成时间。
- Stop 终止整个任务进程组；先温和终止，超时后强制清理 Maven/Java 子进程。
- 最近 Maven 运行记录可查看和重新运行，并保留模块、Goal、最终命令、退出码和耗时。
- 日志持久化开关、保留数量或大小限制以及清理入口。
- 配置保存失败、POM 解析失败、参数格式错误和可执行文件不可用时提供明确反馈。
- v0.1 只读取 Repository 的 POM/Maven Wrapper，不自动导入或执行其他仓库任务配置。

### 6.3 阶段验收场景

1. 在 Workspace 配置 Maven/JDK/settings/local repository，确认路径校验、版本展示和重新打开后的恢复正确。
2. 进入多模块 Repository，确认模块树与 POM 结构一致；选择模块、profiles、`-am` 和自定义参数后，最终命令与预期逐项一致。
3. 运行 clean、compile、package 或 install，实时看到输出、退出码、耗时和完成状态。
4. 运行一个长时间任务并点击 Stop，确认主进程和其子进程均被终止，界面恢复可再次运行状态。
5. 选择 deploy，确认执行前必须二次确认并展示最终命令；验收不要求真正执行发布。
6. 从最近记录重新运行 Maven Goal，应用能正确处理成功、非零退出和配置变化。
7. 关闭并重新打开应用，任务配置、最近记录和用户选择的日志策略仍然有效。
8. 故意填写不可用路径或错误变量，应用在运行前给出可理解的错误。

## 7. 第四阶段：整体集成与最终交付

### 7.1 阶段目标

收口前三阶段之间的联动、状态恢复、设置、性能、错误体验和工程验证，并以一条连续的真实使用流程验收 RepoDesk v0.1 整体版本。

### 7.2 实施范围

- Settings 页面，集中管理刷新行为、编辑器偏好、隐藏文件、任务日志、默认 Maven/JDK/settings 等本地选项。
- Workspace、当前 Repository、页面、文件、Changes 选择、History 范围、Maven 选择和必要界面状态恢复。
- Workspace 或 Repository 被移动、删除、无权限访问时的一致错误体验和恢复入口。
- 菜单、工具栏、快捷键、焦点、键盘导航、空状态、加载状态和错误状态统一。
- 浅色与深色模式、常见窗口尺寸以及长路径/中英文内容布局检查。
- 大型 Workspace 的目录浏览、仓库发现、Git 刷新、Diff、Blame、History、Git 操作、编辑和 Maven 日志性能检查。
- App 图标、版本信息和本地应用基础视觉资源。
- Swift 严格并发、Swift Testing、真实 Git 集成、文件系统、进程生命周期和状态持久化测试。
- 在完整 Xcode/XcodeGen 环境执行 `xcodebuild test` 和最终应用构建；若环境仍缺失，不能静默标记为通过，必须在验收报告中明确说明并由用户决定是否接受替代验证。
- 更新 README、架构、产品修订和最终验收记录。
- 生成可直接运行的本地 `RepoDesk.app`，开发过程不在 RepoDesk 源码仓库创建 Git Commit。

### 7.3 最终端到端验收场景

1. 启动 RepoDesk 并打开 `pangmaoyun`。
2. 登记或恢复至少三个子仓库，在 Overview 确认各仓库状态。
3. 在 Changes 中按 Repository、Changes/Unversioned Files 和 Directory/Module 查看 Agent 产生的工作区改动。
4. 外部再次修改文件，确认文件树、编辑器和 Diff 正确更新。
5. 使用 Files 搜索、打开、编辑并保存 Java 或 Markdown 文件，验证预览和冲突处理。
6. 在当前仓库 History 中按 Branch 和 User 过滤提交，并查看任一提交详情。
7. 在单 Repository 中选择文件创建 Commit，验证 Commit And Push 的分阶段结果、Branch 操作、冲突处理和双侧 Blame。
8. 配置公司 Maven settings、JDK、模块和附加参数，核对最终 Maven 命令。
9. 执行安全 Maven Goal、实时查看日志、获得退出码，并验证停止长任务。
10. 切换 Workspace 或 Repository，确认上下文没有串用，也不会把 Git 操作作用到错误仓库。
11. 退出并重新打开应用，确认 Workspace、Repository、页面和关键选择得到恢复。
12. 完整流程中不发生界面卡死、数据静默丢失、非用户触发的 Git 写入或遗留 Maven/Java 子进程。

### 7.4 v0.1 最终通过条件

- 第一、第二、第三阶段均已获得用户明确验收通过。
- 最终端到端场景全部通过。
- 没有未披露的阻断问题或用文档描述代替实现的功能。
- 所有已知限制均属于产品基线明确延后的范围。
- 用户明确回复整体版本验收通过。

## 8. 每阶段验收交付格式

阶段完成时，开发方统一提供以下内容：

1. **阶段结论**：本阶段是否达到待验收状态。
2. **实际完成内容**：按用户可感知的功能说明，不用代码文件数量代替。
3. **与原计划的差异**：列出阶段中发生的产品行为调整及原因。
4. **自动验证结果**：测试、运行时验证、构建和启动结果。
5. **用户验收步骤**：控制在 5～10 个连续步骤，能够覆盖本阶段核心体验。
6. **已知限制**：只列真实存在且不阻断本阶段的限制。
7. **应用位置**：给出最新 `RepoDesk.app` 的绝对路径。
8. **下一步门禁**：明确等待用户验收，不自动开始下一阶段。

验收结果记录格式：

```text
阶段：第一阶段 Workspace 与 Files
提交验收日期：YYYY-MM-DD
验收结果：待验收 / 验收修正中 / 已通过
用户确认：
主要问题与处理：
对应应用构建：
```

## 9. 计划外需求处理

- 不改变阶段目标的小调整，纳入当前阶段一起完成，不增加额外验收节点。
- 明显属于后续阶段的需求，记录到后续阶段，不打断当前阶段的完整交付。
- 会改变产品定位、扩大现有 Git 写操作范围、自动执行外部任务或带来数据风险的需求，必须先更新产品决定再实施。
- Java 索引、LSP、Debugger、多窗口、插件、远程协作、Reset、Rebase、force Push、任意/自动 Git 写操作、自动更新和正式发布签名继续属于 v0.1 计划外范围。

## 10. 阶段执行记录

本表是跨会话交接的一部分。开始实施、提交验收、验收修正和用户通过时都要更新，不得只在聊天中记录。

| 日期 | 阶段 | 状态变化 | 实施与验证摘要 | 用户结论 |
| --- | --- | --- | --- | --- |
| 2026-08-08 | 验收计划 | 文档建立 | 建立四个大阶段、统一完成门槛、跨会话交接和并行 subagent 规则 | 待确认 |
| 2026-08-08 | 第一阶段 Workspace 与 Files | 待实施 -> 实施中 | 复核产品基线、现有 Files 实现与本机工具链；开始收口文件系统事件、合并防抖、增量刷新和目录错误重试 | 实施中 |
| 2026-08-08 | 第一阶段 Workspace 与 Files | 实施中 -> 待验收 | 完成递归 FSEvents 监听、0.3 秒合并防抖、已加载目录增量刷新、失效子树清理、目录错误重试和前台一致性刷新；严格并发检查、测试解析、真实事件验证、隔离 UI 回归、构建与启动均通过 | 待用户验收 |
| 2026-08-08 | 第一阶段 Workspace 与 Files | 待验收 -> 验收修正中 | 用户要求文件树支持 IDEA 风格的单子目录紧凑显示并可切换展开方式，同时提高 Markdown 预览入口的可发现性 | 修正中 |
| 2026-08-08 | 第一阶段 Workspace 与 Files | 验收修正中 -> 待验收 | 新增默认开启且可关闭的单子目录紧凑显示，验证 `Compact/src/main/java/com/example` 可整体折叠并可恢复逐层目录；Markdown 改为明确的 Source / Preview 分段控件并通过原生 UI 验证 | 待用户复验 |
| 2026-08-08 | 第一阶段 Workspace 与 Files | 待验收 -> 验收修正中 | 用户截图反馈 Markdown 虽已切换 Preview，但内容仍近似纯文本；复现确认当前单个 SwiftUI Text 未呈现标题、列表、代码块等块级语义 | 修正中 |
| 2026-08-08 | 第一阶段 Workspace 与 Files | 验收修正中 -> 待验收 | 替换单个 Text 预览为块级解析与原生渲染，覆盖标题、段落、列表、任务项、引用、代码块、分隔线和基础表格；最小回归检查、完整验证及同一 AGENTS.md 前后截图均通过 | 待用户复验 |
| 2026-08-08 | 第一阶段 Workspace 与 Files | 待验收 -> 已通过 | 用户明确回复“ok，继续下一阶段实施” | 已通过 |
| 2026-08-08 | 第二阶段 Git Review | 待实施 -> 实施中 | 复核现有只读 Git 状态、Diff、History、Branches 与持久化实现；开始收口仓库失效恢复、Review 计数/取消、自动刷新和错误闭环 | 实施中 |
| 2026-08-08 | 第二阶段 Git Review | 实施中 -> 待验收 | 完成 Review 双向切换、总数/分组未查看计数和内容摘要失效；补齐 staged copy detection、rename 原路径 Diff、冲突/特殊文件名/二进制处理；History/Branches/Commit 独立错误、手动及外部提交刷新、File History 空状态和范围/提交恢复；仓库失效保留登记并支持重新定位和本地状态迁移。严格并发检查、测试源码解析、真实临时 Git 仓库、真实文件及 Git metadata FSEvents、应用构建和 Overview/Changes/History 截图检查均通过 | 待用户验收 |
| 2026-08-08 | 第二阶段 Git Review | 待验收 -> 验收修正中 | 用户取消 Review/已查看概念；Changes 调整为跨已登记仓库的未提交改动视图，并要求 Repository、Directory、Module 分组和更明确的 Git 状态；History 调整为仅针对当前 Repository 的 Branch + User 过滤 Git Log，取消 Selected File History | 修正中 |
| 2026-08-08 | 第二阶段 Git Review | 验收修正中 -> 待验收 | 删除 Review/已查看 UI、持久化和内容指纹残留；Changes 改为跨仓库的 Repository -> Git 状态 -> Directory/Module 层级，覆盖 conflict/staged/unstaged/untracked/rename/copy/binary；History 改为当前 Repository 的 Branch + User Git Log。完整本地验证通过，并使用隔离双仓库完成状态、Binary Diff 和 History 提交详情原生截图检查 | 待用户复验 |
| 2026-08-08 | 第二阶段 Git Review | 待验收 -> 验收修正中 | 用户要求减少中间栅栏，将五个主导航放到顶部；Changes 增加全部/单 Repository 范围并显著区分 Directory/Module，补齐 Java/Maven 常用文件图标；History 的 Branch/User 改为可输入搜索；Changes/History 统一改为按文件懒加载的结构化 Unified/Side-by-side Diff，隐藏原始 Git header，并支持折叠未改动片段和 Jump To Source；除五个主导航和专业术语外界面尽量中文化 | 修正中 |
| 2026-08-08 | 第二阶段 Git Review | 验收修正中 -> 待验收 | 完成顶部主导航和两列窗口结构；Changes 的 Repository 范围及 Directory/Module 分组可记忆，Module 使用 Maven 优先识别和模块相对包路径；History 增加 Branch/User 搜索弹层、Commit 文件列表和首文件自动选择；共享单文件 Diff 接口覆盖工作区及 Commit，支持 Unified/Side-by-side、未改动片段展开、Binary 状态和 Jump To Source。严格并发、测试解析、真实 FSEvents、真实 Git、应用构建全部通过，并使用隔离双仓库完成 Directory、Module、Side-by-side 和 History 原生截图检查 | 待用户复验 |
| 2026-08-10 | 第二阶段 Git Review / 第三阶段 Maven | 待验收 -> 验收修正中 | 用户确认按 Workspace/Repository 上下文重新组织模块：Overview 仅 Workspace；Changes/Files 随上下文限定范围；History 仅 Repository 并改为 IDEA Git Log 上下布局；Tasks 改为 Maven；侧栏支持多 Workspace 切换 | 修正中 |
| 2026-08-10 | 第二阶段 Git Review / 第三阶段 Maven | 验收修正中 -> 待验收 | 完成上下文导航与窗口状态恢复、独立侧栏滚动区、Workspace/Repository Changes 与 Files 范围、IDEA 风格 History，以及 Maven 配置、多模块扫描、Lifecycle 运行/停止/deploy 确认。Swift 6 严格并发、测试解析、真实 FSEvents/Git/Maven 验证和本地构建通过；使用真实 pangmaoyun 工作区完成六类原生截图检查并恢复原偏好 | 待用户复验 |
| 2026-08-10 | 第二阶段 Git Review / 第三阶段 Maven | 待验收 -> 验收修正中 | 用户反馈 History 切换 Commit 时闪烁并重置分栏、空 Commit 改变宽度；其他 Agent 批量修改工作区时应用无响应；Workspace Maven 缺少路径与版本校验 | 修正中 |
| 2026-08-10 | 第二阶段 Git Review / 第三阶段 Maven | 验收修正中 -> 待验收 | History 改为内容原子替换和持久化 NSSplitView；Maven Home 异步执行 `mvn -version` 并展示版本/错误；定位无响应根因为主线程文件事件笛卡尔匹配，新增目录级事件压缩和线性规划算法，压力验证由 500 事件约 0.59 秒降至约 0.02 秒，1 万事件约 0.2 秒；新增可从 Workspace 菜单打开的轮转诊断日志 | 待用户复验 |
| 2026-08-10 | 第二阶段 Git Review | 待验收 -> 验收修正中 | 用户反馈新增 Workspace 后仓库扫描可能长期停留在“正在等待 Git 状态”，并且优化后侧栏不再自动显示全部仓库改动数；已有仓库后台刷新时还会用加载状态替换数字和 Diff，产生明显闪烁 | 修正中 |
| 2026-08-10 | 第二阶段 Git Review | 验收修正中 -> 待验收 | 将全部仓库缺失 Snapshot 加载提升到 Root，任意页面自动后台加载；Repository 刷新限制为最多 4 并发并按仓库去重；普通文件事件使用精确路径和单向仓库匹配，任意页面刷新实际受影响仓库；缓存刷新不显示加载态，相同 Snapshot 不重写，失败保留旧列表，Diff 静默原子更新。真实 `pangmaoyun` 启动约 1 秒加载 23 个仓库，稳定后 0.0% CPU，并完成无转圈截图验证 | 待用户复验 |
| 2026-08-10 | 第二阶段 Git Review | 待验收 -> 已通过 | 用户在同步文档与后续任务后明确要求“开始下一阶段的开发实施工作”，按阶段门禁视为第二阶段通过；同时补充 Git Snapshot 250ms/1s 有限退避重试、取消与上下文失效保护及 `repository-refresh` 诊断日志 | 已通过 |
| 2026-08-10 | 第三阶段 Maven | 实施中 -> 待验收 | 完成 JDK/JAVA_HOME 与 Maven 路径校验、Profiles/`-am`/附加参数、最终命令预览、deploy 同命令确认、独立进程组停止、最近运行/重跑/日志策略、配置保存错误、POM/Wrapper 自动同步和敏感环境过滤。并行完成刷新判定、历史 Store 和 UI，主 Agent 统一接入 AppState；严格并发、测试解析、真实 FSEvents/Git/Maven/进程组和 App 构建全部通过，窗口级截图检查完成 | 待用户验收 |
| 2026-08-11 | 第三阶段 Maven | 待验收 -> 验收修正中 | 用户要求 Maven 实时输出在查看最新位置时自动跟随，向上滚动后暂停，并提供快速回到底部入口 | 修正中 |
| 2026-08-11 | 第三阶段 Maven | 验收修正中 -> 待验收 | `NativeCodeEditor` 增加底部位置检测和跟随状态绑定；Maven 输出向上滚动后显示跳转按钮，手动或按钮回到底部后恢复自动跟随；新增原生滚动夹具验证暂停、跳转和恢复行为，完整本地验证及应用重建通过 | 待用户验收 |
| 2026-08-11 | 第二阶段 Git Review | 已通过 -> 验收修正中 | 用户要求 Changes 采用 IDEA Commit 语义，不再按 Conflicted/Staged/Unstaged/Untracked 严格分组；仅保留 Changes 与 Unversioned Files，同一部分暂存文件只出现一次，Diff 直接比较 HEAD 与当前工作区文件 | 修正中 |
| 2026-08-11 | 第二阶段 Git Review | 验收修正中 -> 待用户复验 | 完成 Changes/Unversioned Files 两组模型、旧四状态窗口选择迁移和刷新后分类规范化；AM/MM/冲突等已跟踪文件只出现一次，Diff 统一比较 HEAD 与 Working Tree，无 HEAD 仓库动态使用 empty tree；严格并发、测试解析、目录回归、真实临时 Git 场景和应用构建通过 | 待用户复验 |
| 2026-08-11 | 第一/二阶段 Files 与 Git Review | 已通过 -> 验收修正中 | 用户要求 Changes、Files、History 右侧文件内容支持水平滚动，避免长代码行换行或无法查看最右侧内容 | 修正中 |
| 2026-08-11 | 第一/二阶段 Files 与 Git Review | 验收修正中 -> 待用户复验 | 共享 GitDiffView 按最长行扩展 Unified/Side-by-side 内容宽度、禁止代码行换行并显示水平滚动指示器；Files 原生编辑器补强二维触控板滚动，Markdown 正文保留语义换行，代码块和表格继续独立横滚；严格并发、布局指标、原生编辑器实际横滚、Git 回归、截图和应用构建通过 | 待用户复验 |
| 2026-08-17 | 第一/二阶段 Files 与 Git Review | 待用户复验 -> 已通过 | 用户明确确认 Git Review 修正及后续代码功能均已验收，Changes/Files/History 水平滚动与 IDEA Commit 分组正式收口 | 已通过 |
| 2026-08-17 | 第三阶段 Maven | 待验收 -> 已通过 | 用户明确确认 Maven 第三阶段已经验收，环境配置、Lifecycle、停止、运行历史、日志策略、POM 同步和输出跟随作为 v0.1 已通过能力 | 已通过 |
| 2026-08-17 | 第二阶段 Git Review 与操作 | 范围扩展 -> 已通过 | 用户确认近期代码调整均为正式需求且已经验收；将选中文件 Commit、Commit And Push/Push 重试、Fetch/Pull/Push、Branch Checkout/Compare/Merge/Push/Rename/Delete、tracking Branch、冲突解决和双侧 Blame 正式纳入 v0.1，并同步产品、领域、架构与验收文档 | 已通过 |
| 2026-08-17 | 第四阶段 INT-01 Settings | 待实施 -> 待验收 | 新增原生 Settings Scene 与主窗口齿轮入口，集中通用刷新、Files、Diff 和 Workspace Maven 配置；应用级偏好持久化并实际驱动文件监听、前台刷新、文件树、Markdown 默认视图及 Changes Diff。Settings 持久化/旧键迁移、四页签渲染、完整本地回归、应用构建和签名验证均通过 | 待用户验收 |
| 2026-08-17 | 第四阶段 INT-01 Settings | 待验收 -> 验收修正中 -> 待验收 | 用户确认基础功能无误，但系统自动生成的 Settings 快捷键未可靠生效；现已在应用命令菜单显式注册 `Command+,`，并将“应用返回前台时刷新”改名为“切回 RepoDesk 时检查外部变化”及补充悬停说明。整版样式优化按用户决定延后到第四阶段功能收口后统一实施；完整本地回归和应用重建通过 | 待用户复验快捷键 |
| 2026-08-17 | 第四阶段 INT-01 Settings | 待验收 -> 已通过 | 用户在确认磁盘空间不足时不安装 Xcode/XcodeGen，并明确要求继续下一阶段开发；按阶段门禁记录 Settings 基础功能和 `Command+,` 修正通过 | 已通过 |
| 2026-08-17 | 第四阶段 INT-02 状态恢复与交互一致性 | 待实施 -> 待验收 | 扩展统一 Workspace 窗口状态，恢复导航、页面、文件/Markdown、Workspace Changes 当前文件、History Commit 文件及分栏、Maven 模块/Goal/最近运行；Repository 重定位同步迁移选择。新增 `Command+1...4`、`Command+R` 和 Workspace/Repository 失效恢复入口；旧状态迁移、恢复行为、浅色最小窗口、深色宽窗口、完整回归、应用构建与签名均通过 | 待用户验收 |
| 2026-08-17 | 第四阶段 INT-02 状态恢复与交互一致性 | 待验收 -> 已通过 | 用户明确回复“验收通过，继续下一轮开发”，状态恢复、快捷键和失效恢复入口正式收口 | 已通过 |
| 2026-08-17 | 第四阶段 PERF-01 大型 Workspace 性能门槛 | 待实施 -> 待验收 | 新增统一性能夹具，覆盖仓库发现、文件树/搜索、Git Snapshot、Changes、Diff、Blame、History、Git 操作和 Maven 日志；History 解析复用日期格式化器，流式日志合并 UI flush 并按运行身份增量追加，Workspace 批次路径只标准化一次。连续 200 批 Agent 写入保持单 Repository 命中，完整回归、应用构建和签名均通过 | 待用户验收 |
| 2026-08-17 | 第四阶段 PERF-01 大型 Workspace 性能门槛 | 待验收 -> 已通过 | 用户明确回复“验收完成，开始下一阶段任务”，大型 Workspace 性能门槛正式通过 | 已通过 |
| 2026-08-17 | 第四阶段 QA-01 完整测试工具链 | 受环境阻塞 -> 替代验证完成，待验收 | 新增 QA 集成夹具，串联真实 Git Snapshot/Commit/Blame、远程 tracking Branch、冲突解决与 Continue Merge、窗口状态 UserDefaults 往返和 AppState 恢复；统一回归同时通过 FSEvents、进程组、持久化、Git、Maven 和本地应用构建。由于用户已确认磁盘空间限制，本轮未执行 `xcodegen generate` 或 `xcodebuild test` | 待用户确认替代验证 |
| 2026-08-17 | 第四阶段 QA-01 完整测试工具链 | 替代验证完成，待验收 -> 已通过 | 用户明确回复“已验收，开始下一步的实施”，接受未执行完整 `xcodebuild test` 的已知限制，并以现有替代验证作为本机 v0.1 交付依据 | 已通过（替代验证） |
| 2026-08-17 | 第四阶段 REL-01 最终交付收口 | 待实施 -> 待最终验收 | 生成并接入 RepoDesk App 图标，应用显示版本为 `0.1.0`；Settings 完成固定侧栏、分组设置、版本信息和 Maven 响应式布局，覆盖浅色/深色、760x600/840x660/980x720、长中英文路径；更新 README、架构、验收和发布记录。最终回归除当前受限沙箱无法启动 FSEvents 外均通过，真实 FSEvents 已有宿主权限验收记录；版本/图标与签名验证通过并生成最终 `build/RepoDesk.app` | 待用户最终验收 |
| 2026-08-18 | 第四阶段 REL-01 最终交付收口 | 待最终验收 -> 验收修正中 -> 待用户复验 | 用户发现应用菜单同时出现“设置…”与 `Settings...`，且选择 Maven 后“通用”残留键盘焦点蓝框；删除手工 `.appSettings` 命令组，仅保留系统 Settings Scene 菜单，并关闭侧栏按钮焦点效果。严格并发类型检查、测试源码解析、Settings 全尺寸渲染、应用重建和签名验证通过 | 待用户复验 |
| 2026-08-20 | 第四阶段 REL-01 最终交付收口 | 待用户复验 -> 已通过 | 用户确认整体验收通过。最终图标采用 1C 方案；修复手写 ICNS 小尺寸块不兼容问题，改用 ImageIO 多尺寸缩略图、TIFF 和 Apple `tiff2icns` 标准链路，内部构建号提升为 2，应用显示版本保持 `0.1.0`；图标、版本、应用签名与最终本地构建验证通过 | 已通过 |

每次新增记录时，同时检查阶段总览中的状态是否一致。聊天上下文与本表冲突时，以用户最新明确结论为准，并把结论补写回本表。

当前验收记录：

```text
阶段：第一阶段 Workspace 与 Files
提交验收日期：2026-08-08
验收结果：已通过
用户确认：ok，继续下一阶段实施
主要问题与处理：单个 Text 无法呈现块级语义；已替换为标题、段落、列表、任务项、引用、代码块、分隔线和基础表格的块级原生渲染，并完成同文件截图验证。
对应应用构建：/Users/wangfarui/workspaces/wfr/RepoDesk/build/RepoDesk.app
```

```text
阶段：第二阶段 Git Review 与操作
提交验收日期：2026-08-17
验收结果：已通过
用户确认：Git Review 修正复验通过；近期开发的 Git 功能均为正式需求且已经验收，正式纳入 v0.1。
主要问题与处理：Changes 使用 Changes/Unversioned Files 与 IDEA Commit 语义，Files/Changes/History 长行支持水平滚动；Repository Changes 支持选中文件 Commit、Commit And Push 和 Push 重试；Repository 支持 Fetch/Pull/Push、Branch Checkout/Compare/Merge/Push/Rename/Delete、远程 tracking Branch、冲突解决和双侧 Blame。后台刷新继续只读，Workspace 全仓库 Changes 不能 Commit，Reset/Rebase/force Push/自动 Git 写入不在 v0.1 范围。
对应应用构建：/Users/wangfarui/workspaces/wfr/RepoDesk/build/RepoDesk.app
```

```text
阶段：第三阶段 Maven
提交验收日期：2026-08-17
验收结果：已通过
用户确认：Maven 第三阶段验收通过，近期代码功能均已验收。
主要问题与处理：Workspace Maven 已覆盖 Maven/JDK/settings/local repository 校验、Profiles、-am、附加参数和日志策略；Repository Maven 提供模块树、Lifecycle、最终命令、进程组停止、最近运行重跑和 POM 自动同步。配置保存、路径、Wrapper、缺失 POM、模块变化、非零退出和无日志记录均有稳定状态。
对应应用构建：/Users/wangfarui/workspaces/wfr/RepoDesk/build/RepoDesk.app
截图：build/maven-stage3-workspace-window.png、build/maven-stage3-repository-window.png
```

```text
阶段：第四阶段整体集成与最终交付
提交验收日期：2026-08-20
验收结果：已通过
用户确认：整体验收通过，创建本地 Git 仓库标记 0.1.0 版本开发完成。
主要问题与处理：完成 Settings、状态恢复、性能门槛、替代 QA、版本与 App 图标收口；最终图标采用 1C 方案，并使用 Apple 标准 ICNS 生成链路修复系统通用图标回退。
对应应用构建：/Users/wangfarui/workspaces/wfr/RepoDesk/build/RepoDesk.app
```

## 11. 接下来需求任务

本节是后续开发的执行队列。优先级相同的任务按表中顺序实施；每完成一项必须补充自动验证和真实应用验收证据，不因已有部分代码而直接标记完成。

| ID | 优先级 | 阶段 | 任务 | 完成标准 | 当前状态 |
| --- | --- | --- | --- | --- | --- |
| GR-02 | P0 | 第二阶段 | Git Snapshot 失败恢复 | 初次加载或后台刷新发生暂时错误时使用有上限的退避重试；缓存存在时继续展示旧数据，无缓存时显示可重试错误；日志能够区分超时、取消和命令失败 | 已完成 |
| GR-01 | P0 | 第二阶段 | Git Review 最终体验验收 | 在真实多仓库 Workspace 验证自动改动数、Changes 全部/单仓库、Directory/Module、History Branch/User、Commit 文件切换、后台刷新无闪烁；用户明确确认通过 | 已通过 |
| GIT-01 | P0 | 第二阶段 | Git 写操作与 Blame 正式纳入 v0.1 | Commit/Push、Fetch/Pull/Push、Branch、Merge/冲突和双侧 Blame 与最新代码一致，产品边界、安全约束和验收结论完成同步 | 已通过 |
| MVN-01 | P1 | 第三阶段 | Maven 环境配置补齐 | 增加 JDK/JAVA_HOME；Maven Home、settings.xml、Local repository、JDK 均有路径选择、校验和清晰错误；配置按 Workspace 恢复 | 已通过 |
| MVN-02 | P1 | 第三阶段 | Maven 运行参数与命令预览 | 支持 Profiles、模块参数、`-am` 和附加参数；运行前可查看 executable、参数数组、环境和工作目录；deploy 确认展示同一最终命令 | 已通过 |
| MVN-03 | P1 | 第三阶段 | Maven 进程生命周期 | Stop 先温和结束整个进程组，超时后强制清理 Maven/Java 子进程；取消后可以立即再次运行，无遗留进程 | 已通过 |
| MVN-04 | P1 | 第三阶段 | 最近运行与日志策略 | 展示最近 Maven 运行，支持重跑；记录模块、Goal、退出码、耗时和完成时间；支持日志持久化开关、容量限制和清理 | 已通过 |
| MVN-05 | P1 | 第三阶段 | Maven 项目自动同步与错误闭环 | POM 或模块变化后增量重新扫描；缺失 POM、无效模块、Wrapper 不可执行、配置保存失败和非零退出均有稳定状态，不阻塞界面 | 已通过 |
| MVN-06 | P1 | 第三阶段 | Maven 输出跟随控制 | 实时输出停留底部时自动跟随新内容；用户向上滚动后暂停并显示快速跳转按钮；回到底部后恢复自动跟随 | 已通过 |
| INT-01 | P2 | 第四阶段 | Settings 集中配置 | 提供刷新、Files、Diff、Maven/JDK/settings 和日志策略入口，消除分散且不可发现的偏好设置 | 已通过 |
| INT-02 | P2 | 第四阶段 | 状态恢复与交互一致性 | 恢复 Workspace、Repository、页面、文件、Changes/History/Maven 选择和分栏；统一快捷键、空/加载/错误状态、键盘导航和中英文布局 | 已通过 |
| PERF-01 | P2 | 第四阶段 | 大型 Workspace 性能门槛 | 为仓库发现、Snapshot、Changes、Diff、Blame、History、Git 操作、文件树和 Maven 日志建立可重复性能场景；持续 Agent 写入时保持可操作、无全仓库刷新风暴 | 已通过 |
| QA-01 | P2 | 第四阶段 | 完整测试工具链 | 在完整 Xcode + XcodeGen 环境生成工程并执行 `xcodebuild test`；补齐 Git 读写、Blame、FSEvents、进程组、持久化和关键 AppState 回归测试 | 已通过（用户接受替代验证）；完整 Xcode 链路受环境阻塞 |
| REL-01 | P2 | 第四阶段 | 最终交付收口 | 完成 App 图标、版本信息、Settings 整版样式、README/架构/验收记录更新，并执行第四阶段端到端场景，生成最终本地应用 | 已通过 |

v0.1 实施队列和最终用户验收已全部完成；完整 Xcode 测试可在具备磁盘空间和工具链时补跑。
