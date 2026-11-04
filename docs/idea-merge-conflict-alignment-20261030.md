# IDEA 合并冲突处理：实现分析与 RepoDesk 功能对齐清单

日期：2026-10-30。状态：**方案已确认并进入实施；Close 按用户明确偏好继续执行 `merge --abort`**。实施行为与验证记录见 [重构交付说明](git-merge-conflict-refactor.md)。

本次以本机 IntelliJ IDEA **2025.2.1，IU-252.25557.131，macOS aarch64** 为实现基线。本节及功能差距表记录重构前状态。RepoDesk 分析基于 HEAD `eccda57c40ee53afffa89cde4cbaf0fcb42408ce` 及当前工作树。现有三个未提交文件保持不动。

## 1. 已确认的主要差异

1. RepoDesk 已读取 Git stage 1/2/3，但编辑器仅解析工作树的 `<<<<<<<` 冲突标记。标记外的合并文本被同时放进左右中三栏，左右不是完整的真实来源版本。
2. IDEA 从 Yours / Base / Theirs 三份原文计算三方差异。结果从 Base 初始化，再根据设置应用无冲突修改；既呈现冲突，也呈现非冲突修改。
3. IDEA 为每块分别记录左右是否处理完成。普通接受一侧后，另一侧可能仍待处理；双方均有内容的常见冲突可以依次接受双方，第二次追加内容。RepoDesk 每块只有一个结果字符串，再点另一侧会覆盖第一次选择。
4. IDEA 的 Result 是一整份可编辑文档，编辑、块范围与撤销状态联动。RepoDesk 只让冲突块单独编辑，标记外内容只读。
5. RepoDesk 文件列表的 Close 执行 `git merge --abort`；IDEA Close 关闭列表，仍有冲突时保留 Git 合并状态并允许再次进入。
6. RepoDesk 部分保存后重新解析剩余标记，会丢掉已处理块的操作状态；已解决文件再次进入时可能没有任何可编辑块。
7. RepoDesk 选择已删除的一侧会写入空文件。IDEA 区分内容接受与删除接受，分别执行暂存或删除。

因此，需要重构的是三方文档模型、块状态和文件/合并会话边界；界面按钮调整无法单独解决这些差异。

## 2. 证据来源、方法与边界

REA 对以下三个安装包执行 `open_binary → inspect_artifact(summary)`，确认包身份、成员与 SHA-256；随后使用 IDEA 随附 Fernflower 对选定 JVM 类进行静态反编译。共核对 161 个 class 成员与 REA 清单的哈希，摘要保留 47 个顶层类。

REA 当前的安装包清单能力不等于 JVM 语义分析。本报告的语义来自所列类的反编译结果；关键查看器/列表入口另用本机 JDK 17 `javap -p -c` 核对。没有启动待测合并、操作用户仓库或做 IDEA UI 回放。

| 证据 | 安装包与 SHA-256 | REA inventory Evidence ID |
| --- | --- | --- |
| E-G | `Contents/plugins/vcs-git/lib/vcs-git.jar`；`3f0965e21c373574b7a838033acc65f313a7afdd6aa9e775f2d0090baa51038e` | `ev_fe674a1ba02cebf793ce9f6c775aae8af4f8293625ec6f2aad102dafa999a481` |
| E-D | `Contents/lib/app-client.jar`；`9d6e8d7198460116f944e9604222ff124474c36979e3e3fdcddc12d8eb3a23f1` | `ev_4100207fd98062a1e1be00817e83764216dcb6f758704ecb203723c0dd7adeb8` |
| E-V | `Contents/lib/modules/intellij.platform.vcs.impl.jar`；`6540096394ca5d5448376ed96c6fd1f9863ebbfaae1ca33c93537848e73bc613` | `ev_e2e06f117f601f6de625c6e7d929ee64adc3a08404308394dda2d254570e7e1b` |

可复用的包摘要、限制与类哈希见 [证据索引](evidence/idea-merge-20261030.json)。完整 REA Evidence、反编译中间结果与 javap 文本暂存在 `/private/tmp/repodesk-idea-merge-20261030` 及索引指定的三个 JSON 文件；临时目录可能被系统清理。仓库不收录反编译代码。

反编译曾输出一条 enum 简化诊断，未将未经核对的 enum 分支作为结论依据。这里的“已确认”指静态实现证据；用户设置、生效的实验开关、实际窗口布局和特殊仓库行为仍需要后续独立验收。

### 核心实现路径

| 编号 | 安装包中的类/方法 | 确认的行为 |
| --- | --- | --- |
| I1 | E-G：`git4idea.merge.GitMergeUtil.loadMergeData` | stage 1/2/3 → ORIGINAL/CURRENT/LAST；携带各版本路径、版本号与冲突类型。stage 1 缺失时有本地内容回退；不能把所有场景都当作存在共同祖先。 |
| I2 | E-V：`MultipleFileMergeDialog.showMergeDialog` | 将 CURRENT / ORIGINAL / LAST 三份内容交给合并请求；按文件类型选择文本或二进制工具。列表支持选取多个文件。 |
| I3 | E-D：`MergeThreesideViewer.doPerformRediff / apply / setInitialOutputContent` | 三份原文生成变更片段，Result 从 Base 初始化；可自动应用无冲突修改；加载完成后 Result 可编辑。 |
| I4 | E-D：`TextMergeChange.myResolved / isResolved / myOnesideAppliedConflict`；`MergeThreesideViewer.replaceChange / ignoreChange` | 左右独立 resolved；接受、追加、忽略各有状态行为。相对侧内容为空等情形可直接完成整块，不能机械要求每块都点两次。 |
| I5 | E-D：`MergeModelBase.processDocumentChange / executeMergeCommand / registerUndoRedo`；查看器 `MyMergeModel.restoreChangeState` | 结果编辑更新块范围；撤销/重做恢复文本与块状态。一般手工输入不等于自动认可所有相关冲突已解决。 |
| I6 | E-D：`applyNonConflictedChanges / applyResolvableConflictedChanges / resolveChangeAutomatically` | 普通无冲突批量应用与简单冲突自动解决分开；文本策略调用 `ComparisonMergeUtil.tryResolveConflict`，还存在语言相关策略。 |
| I7 | E-D：`getResolveAction`；`MergeUtil.showExitWithoutApplyingChangesDialog`；`TextMergeRequestImpl.applyResult` | Apply 仍有待处理项时允许确认后完成；取消有修改时询问丢弃，通常恢复本次打开前的内容，且不标记解决。存在自定义取消处理和过期请求检查。 |
| I8 | E-V：`MultipleFileMergeDialog.createActions / updateModelFromFiles / showMergeDialog$lambda$34` | 列表 Close 使用取消窗口动作；文件完成才调用标记解决；处理完所有文件时关闭列表。 |
| I9 | E-G：`GitMergeProvider.MyMergeSession`；`GitMergeUtil.acceptOneVersion / markConflictResolved` | 整文件选择从来源取内容；删除的一侧走删除路径，其他路径走 add。 |
| I10 | E-G：`GitMergeOperation.MyMergeConflictResolver` → `GitMergeCommittingConflictResolver.proceedAfterAllMerged` → `GitMerger.mergeCommit` | 从分支 Merge 操作进入且所有冲突解决后，可自动创建 merge commit，使用 MERGE_MSG。不能把它描述为“IDEA 必须再手动点 Continue”。从通知重新解决等入口行为有区别。 |
| I11 | E-D：`MergeThreesideViewer.createToolbarActions / resetResolvedChange`；`ThreesideTextDiffViewerEx.MySyncScrollable` | 批量动作、与 Base 比较、块复位；同步滚动根据差异片段映射位置，支持折叠。 |

### 版本校正

仓库原 [界面调研](idea-merge-conflict-ui-research.md) 使用 2026.2 帮助和 Community master。本次找到并核实了 [2025.2 官方帮助](https://www.jetbrains.com/help/idea/2025.2/resolve-conflicts.html)，与安装包的三方模型、分侧接受/忽略、Close 后重进和 Apply 行为一致。

[2026.2 官方帮助](https://www.jetbrains.com/help/idea/resolve-conflicts.html)描述了新文件列表、Save and Close、Apply Changes 后下一文件、Revert conflict resolution、Accept and Finish。本次未分析 2026.2 安装包，不能认为这些都已在本机 2025.2 的同一路径实现；也不能仅凭 Save and Close 名称断定其必然“保存未完成草稿且不暂存”。下文将持久化草稿作为 RepoDesk 建议，单独确认。

## 3. 功能对齐清单

状态“缺口”来自当前工作树静态分析，不代表已运行复现。P0 为建议首轮闭环，P1 为后续效率增强；所有实施范围仍待确认。

### 会话与文件流程

| ID | 功能目标 | IDEA 依据 | RepoDesk 现状 | 建议 |
| --- | --- | --- | --- | --- |
| F01 | 合并冲突自动出现；关闭、切库、重启或命令行合并后可重新进入 | 2025.2 帮助、I8；重启的具体恢复实现未追踪 | 主要依赖内存 `mergeSourceBranch`，缺少由 Git 状态恢复入口 | P0：Git 状态为事实来源；恢复是明确的产品要求 |
| F02 | IDEA 的 Close 只关闭界面；RepoDesk 按用户偏好保留 Close = Abort | I8、2025.2 帮助；用户本次明确覆盖 | Close 直接 abort | 保留，并允许全部文件暂存后仍 Close / Abort |
| F03 | 文件列表显示真实两侧状态，支持选文件或整文件接受 | I2、I9 | 有列表与整文件接受；状态硬编码，单选 | P0 真实状态；多选 P1 |
| F04 | Apply 表示认可文件结果，成功暂存后才显示已解决 | I7–I9 | 写入后 add；失败不移出列表，这部分方向正确 | P0 保留并补 Git 状态核验 |
| F05 | Cancel 放弃本次编辑，发生改动时明确询问 | I7 | 编辑器 Cancel 直接关闭，未保存操作丢失 | P0 |
| F06 | 所有文件完成与创建 merge commit 有明确边界 | I10 | 单独 Continue Merge → `merge --continue` | 见 D3；不能误称当前必须有提交编辑界面才符合 IDEA |
| F07 | 保存进度、已解决重进、撤销文件解决不丢语义 | 持久化草稿为建议；2026.2 文档有文件级回退；I1 中有 `revertMergedFiles` 工具 | 保存后已选块变成普通只读段；重进缺少完整编辑；回退未重新读文件 | P0 建立会话保存/恢复；回退后重读 index、工作树 |

### 三方内容与块状态

| ID | 功能目标 | IDEA 依据 | RepoDesk 现状 | 建议 |
| --- | --- | --- | --- | --- |
| F08 | 左右始终是真实来源全文；Base 独立保存；Result 独立编辑 | I1–I3 | 只解析 result 标记，标记外同文复制三栏 | P0 重构基础 |
| F09 | Result 从 Base 初始化，再应用无冲突修改 | I3、I6 | Result 使用工作树冲突文本，Base 切片靠标记或启发式估算 | P0；默认自动应用见 D2 |
| F10 | 识别左改、右改、共同改动、真正冲突及增删范围 | I3、I4 | 主要只有标记内冲突与标记外 unchanged | P0，保留缺失 stage 信息 |
| F11 | 左右各自待处理/已处理，计数与按钮跟随状态 | I4 | 一个 `resolutions[id]` 字符串 | P0 |
| F12 | 普通接受一侧可以保留另一侧待处理；接受双方时按操作顺序组合 | I4，已用 javap 核对追加分支 | 第二侧覆盖第一侧 | P0；删除/空范围有专门规则，不能一律追加 |
| F13 | Ignore 处理对应侧状态，不应直接删除当前结果文本 | I4 | 无独立逐侧 Ignore | P0 |
| F14 | Resolve using Left/Right 作为明确完成取舍的快捷动作 | I4，2025.2 帮助 | 普通接受直接承担整块二选一 | P0 区分普通接受与快速解决；部分处理后的快捷动作规则需一致定义 |
| F15 | 每块可复位为 Base 和未解决；操作可撤销/重做 | I5、I11 | 只有 mark unresolved，缺少统一文本/状态历史 | P0 |

### 编辑器与效率

| ID | 功能目标 | IDEA 依据 | RepoDesk 现状 | 建议 |
| --- | --- | --- | --- | --- |
| F16 | Result 整份连续编辑，允许跨块编辑、插入和删除 | I3、I5 | 各冲突块独立 TextField；其他内容只读 | P0 |
| F17 | 编辑后块范围、行号、状态、定位同步更新 | I5、I11 | 以分段行数组和单块草稿为主 | P0；不能把“输入过”直接视为已解决 |
| F18 | Apply 尚有待处理项时明确选择继续处理或认可当前结果 | I7 | Apply 一律禁用 | 见 D4；与保存草稿分开 |
| F19 | 批量应用全部/仅左/仅右无冲突修改 | I6 | 缺少独立差异模型，无法完整提供 | P0 全部；分侧 P1 |
| F20 | 简单冲突自动解决单独触发，仅处理可靠可合并的文本 | I6 | 缺少 | P1；失败保持待决，不能只取一侧冒充解决 |
| F21 | 上下差异、未解决项导航；同步滚动、上下文折叠 | I11 | 已有导航和拼接行对齐/折叠 | P0 接入真实三方范围，保留现有可用交互 |
| F22 | 两侧只读、行内差异、与 Base/Result 等版本比较 | I3、I11，2025.2 帮助 | 有来源展示、Base/Blame 等局部功能，语义受当前模型限制 | P0 真实来源；完整比较菜单和高亮粒度 P1 |

### 特殊文件与失败处理

| ID | 功能目标 | IDEA 依据 | RepoDesk 现状 | 建议 |
| --- | --- | --- | --- | --- |
| F23 | 修改/删除冲突区分保留内容与删除文件 | I1、I9 | 选缺失侧会生成空文件 | P0 必须处理 |
| F24 | 二进制只能整文件接受；无论按钮还是双击都走一致入口 | I2、I9 | 能保留 Data；Merge 按钮禁用但双击未统一拦截 | P0 |
| F25 | 缺失 Base、双方新增、空文件、相邻重复片段可确定处理 | I1、I3、I4 | Base 启发式可能返回空；缺失侧与空内容处理有混淆风险 | P0，纳入验收数据 |
| F26 | 重命名/文件类型/子模块冲突不误当普通文本 | I1 保留版本路径；所有边界未完整追踪 | 仅 path，缺少原路径、mode 和完整冲突类型 | P0 识别并显示明确入口或不支持说明；完整专用解决 P1 |
| F27 | 编码、换行、文件大小、外部修改与 Git 失败有明确结果 | IDEA 有大文件/过期请求路径；完整覆盖未验证 | 文本保存固定 UTF-8；部分错误有反馈 | P0 防丢失和错误不冒充成功；编码矩阵需专项验收 |

IDEA 的语法补全、PSI/import 语义合并、AI 辅助和完整插件能力不建议纳入首轮。发现有这些实现入口，不代表需要复制整个 IDE。

## 4. 已确认的产品选择

用户已确认按 D1–D6 推荐方案实施，另明确覆盖 F02：冲突文件列表的 Close 表示放弃本次合并，直接执行 `merge --abort`；文件编辑器的保存进度/Cancel 只退出该文件，保留合并。

| 决策 | 推荐方案 | 可选调整 |
| --- | --- | --- |
| D1 对齐版本与范围 | 以本机 2025.2.1 的三方模型和块语义为基线；先做表中 P0，再做 P1 | 改为针对 2026.2 先补安装包/运行证据再定全部交互 |
| D2 初始 Result | Base 初始化，默认自动应用无冲突修改，并提供设置开关；真正冲突仍由用户处理 | 默认不自动应用，全部操作手动触发 |
| D3 合并提交时机 | 保留 RepoDesk 显式 Continue Merge；所有文件暂存后由用户最后执行一次。此点主动保留现有产品选择 | 严格对齐本机分支 Merge 路径：全部冲突完成后自动提交 |
| D4 未完成时 Apply | 对齐 IDEA：显示剩余变更/冲突数，确认“采用当前结果并标记解决”后才暂存 | 保持严格禁用，要求逐块处理完；两者均不能等同保存草稿 |
| D5 保存和关闭 | 新增可靠的“保存进度并关闭”，保存文档与操作状态但不标记解决、不创建提交；重进继续。这是 RepoDesk 扩展要求 | 首轮仅提供 Apply / 放弃本次编辑，持久化草稿延后 |
| D6 特殊文件与能力 | 首轮完整支持普通文本、常见增删和二进制取一侧；复杂重命名/子模块先识别并明确转外部处理 | 将复杂冲突专用解决也纳入首轮，增加相应验收范围 |

## 5. 状态与验收约定（供确认后实施）

建议区分三个层次：块的左右处理状态、文件的编辑/草稿/已解决状态、仓库的合并中/待提交/完成状态。Git index、MERGE_HEAD 等决定真实仓库状态，内存列表不能作为最终依据。

建议正常流程：

`检测合并中 → 冲突文件列表 → 加载三份原文 → Result 编辑与逐侧取舍 → Apply 写入并暂存 → 重读 Git 状态 → 全部文件完成 → Continue Merge（D3 推荐）`

`保存进度并关闭` 返回列表或仓库，仍未解决；`Cancel` 只放弃本次未保存编辑；列表 `Close` 按用户偏好直接执行 `merge --abort`，包括已解决所有文件但尚未 Continue 的阶段。

这些是后续必须实际运行的验收用例，本次未声称通过：

| 用例 | 操作与预期 |
| --- | --- |
| A01 来源真实性 | 一处只在 Yours 修改、另一处真正冲突；Theirs 栏不得混入 Yours 独有内容，三栏行号各自真实 |
| A02 Base 与默认应用 | 分别关闭/打开自动应用；初始 Result 符合 D2，普通修改与冲突计数正确 |
| A03 双方内容 | 对双方均非空的冲突先接受左再接受右，Result 为左后右；反顺序为右后左；中途仍能忽略待决侧 |
| A04 忽略与快捷解决 | 单侧 Ignore 不破坏已有结果；从未处理状态快捷采用一侧可以完成整块；部分处理状态行为明确且可撤销 |
| A05 连续编辑 | 跨块插入/删除文字，后续块的行号与动作仍指向正确文本 |
| A06 撤销重做/复位 | 撤销同时恢复文本、范围与两侧状态；复位恢复 Base；不会改坏相邻块 |
| A07 保存再进入 | 保存一半后关闭、切库、重启，再进入保持内容和处理状态；全部已取舍但尚未 Apply 也允许保存 |
| A08 Apply 后重进 | 标记解决后查看、再编辑、重新暂存都使用当前结果全文；回退解决后重新读取真实 index 与工作树 |
| A09 关闭边界 | 列表 Close 后合并已中止，HEAD 保持原位置；文件编辑器 Cancel 处理未保存提示，Save Progress 只保留草稿；两者均不中止合并 |
| A10 命令行与外部修改 | 命令行制造冲突后应用可发现；外部编辑/暂存/中止后刷新状态；旧编辑结果不能静默覆盖新内容 |
| A11 删除与二进制 | 选删除侧后文件确实删除并暂存；选保留侧内容一致；二进制逐字节一致，双击不进入文本工具 |
| A12 特殊内容 | 缺失 Base、双方新增、空文件、相邻重复文本、CRLF/LF、非 UTF-8、末尾无换行分别验证 |
| A13 失败恢复 | 写文件失败、git add 失败、continue/hook 失败显示错误；不错误显示已完成，仍可重进处理 |
| A14 完成语义 | 所有未解决 index 消失前不能完成合并；符合 D3 的提交时机和 merge message；不替换无关暂存内容 |
| A15 复杂冲突 | rename/delete、rename/rename、文件类型、子模块按 D6 显示明确处理方式，不生成看似成功的错误文本 |

重构落地时应采用能证明这些用户行为的模型/真实临时 Git 仓库验证，并按照 AGENTS.md 执行 `./scripts/verify-local.sh`，确认应用二进制时间与签名。本调研阶段只新增分析材料；后续重构的构建与验证结果记录在交付说明中。

## 6. RepoDesk 源码定位

| 编号 | 当前文件与行号 | 对应问题 |
| --- | --- | --- |
| R1 | `RepoDeskApp/Git/GitRepositoryOperator.swift:534`；`RepoDeskApp/Git/GitModels.swift:92` | stage 内容、Data、缺失侧与模型 |
| R2 | `RepoDeskApp/Features/BranchOperationViews.swift:484`；`RepoDeskApp/Git/GitConflictParser.swift:16`、`:99`、`:162` | 文档只接收 result/base；单字符串解决；标记解析与 Base 猜测 |
| R3 | `RepoDeskApp/Features/BranchOperationViews.swift:721`、`:942`、`:1349`、`:1401` | 三栏同文、单块编辑、完成门槛与取舍 |
| R4 | `RepoDeskApp/App/AppState.swift:1633`、`:1663`；`RepoDeskApp/Git/GitRepositoryOperator.swift:574` | 保存、标记解决和暂存 |
| R5 | `RepoDeskApp/App/AppState.swift:1690`、`:1715`；`RepoDeskApp/Git/GitRepositoryOperator.swift:589` | 回退后未重载、缺失侧接受 |
| R6 | `RepoDeskApp/App/AppState.swift:1757`、`:1789`；`RepoDeskApp/Git/GitRepositoryOperator.swift:530` | Close/Abort 与 Continue |
| R7 | `RepoDeskApp/Features/BranchOperationViews.swift:196`、`:1099`；`RepoDeskApp/App/AppState.swift:1046`、`:1586` | 重进、Cancel 和内存会话依赖 |

现有未提交改动涉及 `BranchOperationViews.swift`、`ChangesView.swift` 和 `scripts/verify-merge-conflict-rendering.swift`，主要是窗口缩放、鼠标命中与布局验证；后续实现应保留并在新结构中兼容。
