# IntelliJ IDEA Git Diff 查看设计调研

调研日期：2026-08-31

范围：JetBrains 官方帮助文档与 IntelliJ Community 官方源码。重点关注双击 Git 文件后如何计算、加载和渲染 Diff，以及大文件/大改动的处理方式。

## 结论摘要

当前 RepoDesk 的卡顿风险很可能来自 Diff 查看器的工作模型，而不只是某一条 `git diff` 命令：如果在打开弹框时同步读取两份完整 Blob、构造完整左右文本、再为全文安装透明选择层或逐字符视图，主线程会被大文件和密集改动拖住。IDEA 的模型是：

1. 先确定两个版本（before/after），分别作为两个 editor 的文档内容；
2. 在后台线程对两个不可变文本做可取消的行级 Diff；
3. 仅把计算出的变更区转换成 `LineFragment`/change model；
4. 回到 UI 线程安装变更区的行高亮、必要的词内高亮和 gutter 操作；
5. 未变更区按上下文范围折叠，用户展开时再查看；
6. Diff 过大、任务取消或计算异常都结束 busy 状态并展示通知，不让界面永久停在 loading。

因此，RepoDesk 应把“文件内容加载”和“Diff 视图渲染”拆开：打开弹框先显示轻量的只读 editor 与变更摘要，Diff 计算放后台并可取消；默认只展开变更附近的少量上下文，双击文件不应重新计算整个 Push 范围之外的内容。

## 1. IDEA 的用户语义

官方帮助文档说明 Diff Viewer 用于比较两个文件或同一文件的两个版本，查看器默认提供 side-by-side 与 unified 两种模式；可在提交窗口或 Git 工具窗口对文件执行 Show Diff。未变更片段可以折叠，保留的不可折叠上下文行数可在 Diff & Merge 设置中配置。[1]

同一页面还公开了几个与性能直接相关的设置：

- `Collapse Unchanged Fragments`：折叠两侧所有未变更片段；
- `Highlighting Differences`：可选 Words、Lines、Split changes、Characters、None；对显著修改的文件，文档建议使用 `None`，避免高亮增加阅读困难；
- `Show code lens on scrollbar hover`：通过滚动条悬停查看可视区域之外的代码；
- side-by-side viewer 可同步滚动，但这是交互层能力，不要求复制全文到第三个覆盖控件。[1]

这些设置表明 IDEA 的默认阅读单位是“变更块 + 有限上下文”，不是一次性把整个文件转成大量独立 UI 节点。

## 1.1 提交窗口的按需加载

JetBrains 的 Git 变更窗口把“文件列表”和“文件 Diff 请求”分开：Git Log/Compare Versions 先展示两 revision 间的文件列表，用户选中某个文件后再 Show Diff；官方文档将该行为描述为选中文件后右侧 Diff 会即时显示。[8]

官方源码进一步明确了这一点。`ChangeViewDiffRequestProcessor` 只保存当前 `Change`，通过 `createProducer()` 为当前文件创建 `DiffRequestProducer`；其它文件只用于导航，不会在打开窗口时预加载全部内容。[9] `ChangeDiffRequestProducer.process(context, indicator)` 在后台按需读取当前文件的 before/after revision，内容加载完成后才构造 `SimpleDiffRequest`，并在每个阶段检查取消。[10]

`CacheDiffRequestProcessor` 为 Diff 请求提供 `SoftHardCacheMap` 缓存和 `DiffTaskQueue` 后台队列：命中缓存时直接复用；未命中时先用快速等待窗口尝试完成，只有任务确实变慢才显示 LoadingDiffRequest；取消旧请求后返回可重载的取消状态，最终结果再通过 EDT 应用。[11][12]

这套设计解释了 IDEA 的体感差异：点击文件后通常不会立刻看到长时间 spinner，因为小文件在短等待窗口内完成；慢文件也不会阻塞 UI，且同一文件再次打开可命中缓存。RepoDesk 应按文件维度缓存 `(repository, base, head, path, ignorePolicy)` 的 Diff 模型，不能把“累计文件树”结果当成所有文件内容都已加载。

## 2. 官方源码中的计算/加载流程

### 2.1 两个 editor 文档作为输入

`TextEditorHolder.create` 通过 `DiffUtil.createEditor(content.getDocument(), ...)` 创建真正的 IntelliJ editor，并用 `DiffUtil.configureEditor` 配置。左右两侧因此各自持有一个 `Document`，而不是用字符串拼成一个自定义视图。[4]

`TwosideContentPanel` 将左右 editor 放入 `DiffSplitter`，设置为 side-by-side 内容面板；滚轮事件也直接转发给右侧 editor 的滚动容器。[5]

### 2.2 后台、可取消的 rediff

`SimpleDiffViewer.performRediff(ProgressIndicator)` 调用 `computeDifferences`，捕获 `DiffTooBigException`、`ProcessCanceledException` 和其它异常，分别生成“Diff 太大”、取消或错误通知。[2]

`computeDifferences` 的核心顺序是：

```text
indicator.checkCanceled()
读取两个 Document 的 immutable CharSequence
TextDiffProvider.compare(text1, text2, indicator)
将 LineFragment 转为 SimpleDiffChange
返回一个稍后在 UI 线程执行的 apply Runnable
```

源码中的 `ProgressIndicator` 会一路传入比较算法；算法可以在长 diff 中检查取消。计算阶段不直接修改 Swing/Editor 状态，真正安装模型和高亮在返回的 `Runnable` 中完成。[2]

### 2.3 只渲染变更区

`SimpleDiffChangeUi.installHighlighter` 对每个 `SimpleDiffChange` 安装左右两侧的行高亮；如果有 inner fragments，再安装词内高亮；同时为变更区创建 gutter 操作。它没有为整份文件逐行创建一套额外的透明文本控件。[3]

`SimpleDiffViewer.apply` 先清理旧 presentation，再设置 change model，最后按变更模型安装 folding，并更新状态栏和 divider。UI 更新集中在一次 apply 事务中，避免后台线程直接触碰 editor。[2]

## 3. 未变更区折叠与上下文

`FoldingModelSupport` 接收变更行范围，计算每个变更块之间的折叠区；其 `Settings.range` 控制每个变更前后保留多少上下文，`defaultExpanded` 控制初次是否展开。折叠安装发生在 EDT，并通过 editor 原生 folding model 管理，而不是把未变更内容删除或复制到另一个视图。[6]

这解释了 IDEA 打开大文件仍然流畅的主要原因：完整文档仍可用于滚动和定位，但屏幕默认只绘制变更块及有限上下文；远离变更的大段代码由原生 folding/编辑器处理。

## 4. 行级、词级和“大改动”策略

`ComparisonManagerImpl.compareLines` 先建立行偏移，再调用 `ByLine.compare` 生成 `FairDiffIterable`，最后转换为 `LineFragment`。需要词内高亮时才在行片段基础上调用 `createInnerFragments`；因此词级/字符级高亮是建立在行级差异之后的第二阶段，不应在打开时对全文做昂贵的逐字符 UI 构造。[7]

`SimpleDiffViewer` 将 `DiffTooBigException` 转成专门的“Diff 太大”通知；官方 UI 也允许用户把 highlighting level 调为 `None`，用于显著修改的文件。[1][2]

对 RepoDesk 的直接建议：

- 默认算法先做行级 diff；仅对变更行块做词级高亮；
- 对超大文件或变更比例过高的文件，关闭词级高亮，必要时只显示行级变更；
- 设置明确的文件大小、总行数和变更块上限，超过后显示可读的“文件过大，已降级为行级 Diff”，不要无限等待；
- 所有比较任务必须可取消，窗口关闭、切换文件或重新发起请求时丢弃旧结果。

## 5. 对 RepoDesk 当前 Push Diff 规则的落地约束

用户选择一个 Commit 时，输入应是该 Commit 的 parent 与该 Commit；选择多个 Commit 时，输入是最早 Commit 的 parent 与最新 Commit。文件树可以继续使用累计范围，但双击文件后只读取该文件在这两个版本中的两个 Blob，并执行针对单文件的 diff。

建议的加载状态机：

```text
Idle -> Loading(file, requestID)
Loading -> Ready(diffModel)       成功
Loading -> TooLarge               超限降级
Loading -> Failed(error)          命令/解析失败
Loading -> Idle                   取消或窗口关闭
```

关键约束：

- `git` 子进程在后台队列执行，UI 线程只更新状态；
- 先获取 Blob 元数据/大小，再决定完整读取还是降级；
- 不为全文创建透明 `NSTextView` 覆盖层；复制、选择和滚动使用原生 editor；
- 只安装变更块高亮和 gutter 操作；
- 首次打开默认折叠未变更片段，仅保留有限上下文；
- request ID 或等价 token 校验结果，旧任务不能覆盖新文件；
- 任何取消、错误、超限路径都必须清除 spinner。

## 官方来源

1. JetBrains IntelliJ IDEA Help, “Diff Viewer for files”：<https://www.jetbrains.com/help/idea/differences-viewer.html>
2. IntelliJ Community, `SimpleDiffViewer.java`（`performRediff`、`computeDifferences`、`apply`）：<https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/tools/simple/SimpleDiffViewer.java>
3. IntelliJ Community, `SimpleDiffChangeUi.java`（变更区 highlighter/gutter 安装）：<https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/tools/simple/SimpleDiffChangeUi.java>
4. IntelliJ Community, `TextEditorHolder.java`（Document -> Editor 创建）：<https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/tools/holders/TextEditorHolder.java>
5. IntelliJ Community, `TwosideContentPanel.java` 与 `DiffSplitter.java`：<https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/tools/util/side/TwosideContentPanel.java>；<https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/tools/util/DiffSplitter.java>
6. IntelliJ Community, `FoldingModelSupport.java`（基于 changed lines 的原生 folding）：<https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/tools/util/FoldingModelSupport.java>
7. IntelliJ Community, `ComparisonManagerImpl.java`（行级比较与按需 inner fragments）：<https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/comparison/ComparisonManagerImpl.java>
8. JetBrains IntelliJ IDEA Help, “Investigate changes” （Git Log/Compare Versions 选择文件后 Show Diff）：<https://www.jetbrains.com/help/idea/investigate-changes.html>
9. IntelliJ Community, `ChangeViewDiffRequestProcessor.java`（当前 Change 单文件 producer）：<https://github.com/JetBrains/intellij-community/blob/master/platform/vcs-impl/src/com/intellij/openapi/vcs/changes/ChangeViewDiffRequestProcessor.java>
10. IntelliJ Community, `ChangeDiffRequestProducer.java`（后台按需读取 revision 内容并检查取消）：<https://github.com/JetBrains/intellij-community/blob/master/platform/vcs-impl/src/com/intellij/openapi/vcs/changes/actions/diff/ChangeDiffRequestProducer.java>
11. IntelliJ Community, `CacheDiffRequestProcessor.java`（缓存、慢任务才显示 loading、EDT 应用结果，见 `updateRequest`/`loadRequest`）：<https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/impl/CacheDiffRequestProcessor.java#L37-L179>
12. IntelliJ Community, `DiffTaskQueue.java`（取消旧任务与后台执行）：<https://github.com/JetBrains/intellij-community/blob/master/platform/diff-impl/src/com/intellij/diff/util/DiffTaskQueue.java>

## 对本次卡顿问题的判断

“一直加载”与 IDEA 行为不一致的地方，不应继续靠增加超时或简单并发读取解决。需要优先检查 RepoDesk 是否在 spinner 期间做了以下任一操作：同步读取两份完整文件、对全文构造 SwiftUI `Text`/`NSTextView` 节点、在主线程解析整个 patch、默认展开全部未变更内容、或为支持选择而叠加全量透明文本层。只要存在其中一项，大文件/密集改动就会让窗口看似卡死。

最小可行的 IDEA 对齐方案是：单文件、后台可取消的行级 `git diff`；仅变更区模型；默认折叠上下文；超限降级；原生双 editor side-by-side；不创建全文覆盖层。
