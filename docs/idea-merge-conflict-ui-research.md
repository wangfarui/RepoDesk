# IntelliJ IDEA 三方冲突合并交互调研

调研日期：2026-09-30。范围：IntelliJ IDEA 2026.2 官方帮助、官方截图，以及 IntelliJ Community `master` 的合并查看器实现。以下只陈述能由这些一方资料确认的行为；具体键位和视觉细节可能随版本、平台或键位方案变化。

## 1. 入口与文件级流程

| 功能点 | IDEA 行为 | 来源 |
| --- | --- | --- |
| 触发 | Git 合并、拉取、变基、拣选等产生冲突时，自动出现 `Conflicts` 文件列表；从命令行产生冲突或关闭列表后，还可在 Changes 的 `Merge Conflicts` 节点继续解决，或在顶部工具栏继续 / 中止合并。 | [1] |
| 整文件快速选择 | 每个冲突文件可选 `Accept Yours`、`Accept Theirs`、`Resolve Manually`；前两者分别保留当前分支或并入分支的整份文件。 | [1] |
| 批量简单冲突 | 文件列表提供 `Resolve All Simple Conflicts`，在逐文件手动处理之前尝试自动解决。 | [1] |
| 打开编辑器 | 双击冲突文件，或选中后点 `Resolve Manually`，进入三栏工具。 | [1] |
| 保存与继续 | `Apply Changes` 结束当前文件并打开下一个冲突文件；`Save and Close` 保存当前进度并返回文件列表。 | [1] |
| 撤销文件解决 | 文件列表中右键已处理文件可执行 `Revert conflict resolution`，使其回到冲突状态。 | [1] |
| 完成 | 列表无剩余冲突后，`Accept and Finish` 才启用，用于完成合并。 | [1] |

## 2. 三栏信息结构

| 功能点 | IDEA 行为 | 来源 |
| --- | --- | --- |
| 左侧 | 本地版本（当前检出的分支），只读。 | [1] |
| 右侧 | 仓库 / 并入版本，只读。 | [1] |
| 中间 | `Result` 可直接编辑；初始内容是两侧共同祖先 `Base`，随后承载选择与手工编辑后的结果。不能把初始 Base 误当成最终结果或 Git 工作树冲突标记文本。 | [1][2] |
| 视觉标记 | 官方图例区分修改、删除、新增和冲突行；截图中差异块横向连通三栏，来源栏标题旁有只读锁图标。 | [1][7] |
| 状态 | 顶部显示未处理变更和冲突数量；源码在全部归零时显示完成图标。 | [7][3] |

## 3. 逐块解决

| 功能点 | IDEA 行为 | 来源 |
| --- | --- | --- |
| 两侧独立动作 | 左、右变更块各有朝向结果栏的 `Accept` 和 `Ignore` 操作。用户分别决定是否纳入左侧、右侧内容，再核对中间结果；源码为每个变更分别保存左右两个 resolved 状态。 | [1][4] |
| 单侧接受后的状态 | 源码允许冲突先接受一侧但继续保持另一侧待决；接受/忽略并非简单的整块二选一。由此可以组合双方内容，且中列仍可编辑。 | [4] |
| 快速选择一侧 | 在中列高亮冲突上右键，`Resolve using Left` / `Resolve using Right` 分别完成采用某侧并舍弃另一侧的组合操作。 | [1][5] |
| 自动解决局部简单冲突 | 对同一行不同位置等可安全合并的冲突，`Resolve simple conflicts` 动作才可用；它需要单独触发，`Apply All Non-Conflicting Changes` 不会处理此类冲突。源码按模型 `hasAutoResolvableConflictedChanges` 决定按钮可用性。 | [1][3] |
| 中列直接修改 | 中列是完整编辑器，可在其中手工改代码；编辑器里的修改与合并操作支持撤销/重做，冲突状态随文本同步。 | [1][2] |
| 撤销局部选择 | 源码为已解决块提供 `ResetResolvedChangeAction`，将该块恢复为 Base 内容并标为未解决；还提供 `RevertConflictResolutionAction` 工具栏动作。 | [3][4][5] |
| 修改标记工具栏 | 鼠标悬停中列 gutter 变更标记并点击，可弹出显示该行之前内容的工具栏，其中有 `Revert`。官方建议先批量应用无冲突改动，再撤销不需要的少数变更。 | [1] |

## 4. 批量、导航和比较

| 功能点 | IDEA 行为 | 来源 |
| --- | --- | --- |
| 应用无冲突改动 | 工具栏有 `Apply All Non-Conflicting Changes`，也有仅应用左侧 / 右侧无冲突改动的动作。三个动作在对应侧没有待应用内容时不可用。 | [1][2][3] |
| 自动应用设置 | `Tools | Diff & Merge` 的 `Automatically apply non-conflicting changes` 使三方工具打开后自动执行上述 All 动作。 | [1][6][3] |
| 差异导航 | 工具栏含上一个 / 下一个差异按钮；官方 Diff & Merge 参考给出 `Shift+F7` / `F7`（默认 macOS 键位同名），具体快捷键可由键位方案改变。 | [2][8] |
| 初始定位与批量操作后定位 | 查看器可以初始滚动到首个变更；应用无冲突改动或可自动解决的冲突后，源码定位到首个尚未解决的变更。 | [9][3] |
| 比较内容 | 工具栏 `Compare contents` 提供不同版本两两比较；源码列出 Left/Middle、Right/Middle、Left/Right，以及 Base 与 Left/Middle/Right。此处 `Base` 始终指共同祖先，`Middle` 指当前合并结果。 | [1][3] |
| 滚动联动 | 三方查看器继承的同步滚动实现按变更块映射行位置，并由 `Enable Sync Scroll` 设置控制。工具栏/弹出菜单还有自动滚动开关。不要把它理解为三栏同一绝对行号同步。 | [9][3] |
| 上下文折叠与显示设置 | 三方工具含折叠未变更区域的开关，差异设置还可控制空白忽略与高亮粒度；Merge 设置有 `Highlight modified lines in gutter`。 | [3][8][6] |

## 5. 结束行为的边界

官方截图可见三方窗口底部还有整文件 `Accept Left` / `Accept Right`，与顶部逐块箭头是两个层级。源码对 `Apply Changes` 的底层确认逻辑还显示：若仍有未处理块，点击完成会弹确认框，允许用户显式选择将当前内容标为已解决；因此“仍有未处理块时按钮一律禁用”不是 IDEA 的准确行为。产品上是否照搬这种有风险的确认，需要单独决策。[7][3]

`Save and Close` 与 `Apply Changes` 的区别尤其重要：前者保留未完成状态，后者表示用户认可本文件的合并结果。冲突列表的 `Accept and Finish` 又是跨文件的最终步骤。这三个动作不能合并成一个模糊的“保存”。[1]

## 官方来源

1. JetBrains IntelliJ IDEA Help, [Resolve Git conflicts](https://www.jetbrains.com/help/idea/resolve-conflicts.html)，2026.2，页面最后修改日期 2026-08-17；同页 [Markdown 版](https://www.jetbrains.com/help/idea/resolve-conflicts.html.md)。
2. JetBrains IntelliJ IDEA Help, [Diff Viewer for files](https://www.jetbrains.com/help/idea/differences-viewer.html)，`Diff & Merge viewer`、`Merge actions`、`Keyboard shortcuts`；[Markdown 版](https://www.jetbrains.com/help/idea/differences-viewer.html.md)。
3. JetBrains IntelliJ Community, [`MergeThreesideViewer.java`](https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/merge/MergeThreesideViewer.java)：工具栏、局部动作、自动应用、状态、完成确认。
4. JetBrains IntelliJ Community, [`MergeConflictModel.kt`](https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/merge/MergeConflictModel.kt) 与 [`TextMergeChange.kt`](https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/merge/TextMergeChange.kt)：左右独立解决状态、替换/忽略/复位逻辑。
5. JetBrains IntelliJ Community, [`MergeThreesideViewerActions.kt`](https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/merge/MergeThreesideViewerActions.kt)：中列右键菜单与局部动作。
6. JetBrains IntelliJ IDEA Help, [Diff & Merge settings](https://www.jetbrains.com/help/idea/settings-tools-diff-and-merge.html.md)。
7. JetBrains 官方帮助中的 [三方合并窗口截图](https://resources.jetbrains.com/help/img/idea/2026.2/resolveConflict.png) 与 [颜色图例](https://resources.jetbrains.com/help/img/idea/2026.2/conflict_resolution_tool_legend.png)。
8. JetBrains IntelliJ Community, [`MergeRequestProcessor.java`](https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/merge/MergeRequestProcessor.java)：导航动作与底部按钮。
9. JetBrains IntelliJ Community, [`ThreesideTextDiffViewerEx.java`](https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/tools/simple/ThreesideTextDiffViewerEx.java)：同步滚动、变更导航与初始定位。
