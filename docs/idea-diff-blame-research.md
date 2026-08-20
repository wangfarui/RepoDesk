# IntelliJ IDEA Diff Viewer 与 Git Blame 交互调研

调研日期：2026-08-13

范围：仅使用 JetBrains 官方帮助文档与 IntelliJ Community 官方源码，聚焦双栏 Diff 的分隔器和 `Annotate with Git Blame`。

## 结论摘要

RepoDesk 若要贴近 IDEA，应采用下面的交互模型：

1. Side-by-side 弹框首次打开时，左右内容以 `50% / 50%` 布局，中间分隔线位于弹框正中。
2. 分隔线可直接水平拖动；拖动后保留用户选择的比例，窗口缩放时继续保持该比例，而不是强制回到 `50%`。
3. `Annotate with Git Blame` 的入口属于每一侧编辑器自己的 gutter 右键菜单。在哪一侧右键，就只开关哪一侧的 annotation。
4. Annotation 显示在对应代码侧的 gutter 中，与该侧每行代码垂直对齐。不是全局顶部状态，也不是左右共用的独立面板。
5. Blame 应异步加载：操作期间展示明确进度并禁止同一侧重复请求；成功后才安装 annotation gutter；失败则关闭进度并显示错误。
6. 左右两侧可分别开启、关闭并记忆 annotation 状态。只有能映射到 Git 文件或具体 revision 的一侧才允许开启。

## 1. Annotate 的入口与切换

JetBrains 官方帮助明确说明：用户在编辑器或 Diff Viewer 的 **gutter 上右键**，选择 `Annotate with Git Blame` 开启；关闭时再次右键 gutter，选择 `Close Annotations`。[1]

IntelliJ Community 的实现进一步说明这是一个 toggle：

- 若当前侧尚未显示 annotation，则创建 loader 并加载。
- 若当前侧已经显示，则关闭该侧 editor 的 VCS annotations。
- action 在加载锁持有期间处于 suspended 状态，避免重复触发。[3]

RepoDesk 对齐建议：

- 右键命中区域应是左侧或右侧代码 gutter，包括行号区域，而不是整个弹框的任意空白位置。
- 未开启时菜单显示 `Annotate with Git Blame`。
- 已开启时菜单显示勾选状态，或像官方文档一样显示 `Close Annotations`；二者都可以表达 toggle，但后一种更贴近文档。
- 左右两侧分别维护状态，不用一个全局 `showBlame` 状态同时控制两边。

## 2. Annotation 显示位置与字段

官方文档将 annotation 定义为逐行详细信息，并明确它显示在 annotation gutter 中。默认用不同颜色区分不同 commit；当前 revision 修改的行以粗体和星号标记。[1]

官方文档列出的可展示字段包括：

- 该行来源 revision
- commit date
- author（支持不同名称格式）
- commit number

Diff Viewer 的官方参考页概括为：每行来源 version、提交者 ID、commit date。[2]

源码中，annotation 不是一次性拼成一个文本列，而是向对应 `Editor` 的 gutter 注册多个 `TextAnnotationGutterProvider`。字段来自 `FileAnnotation` 的 aspects，并可附加 revision、历史序号、额外操作列等。[4]

RepoDesk 第一版建议固定显示：

```text
日期  作者  短 Commit Hash
```

这与用户给出的 IDEA 截图和官方字段范围一致。列必须位于各自代码侧的 gutter，并逐行严格对齐；不要把 blame 拼进代码字符串，也不要让它改变 diff 行匹配关系。

## 3. 左右两侧的独立行为

IntelliJ 的 two-side annotator 会先根据当前事件中的 `Editor` 判断用户操作的是 `LEFT` 还是 `RIGHT`。左、右 editor 分别检查、显示和关闭 annotation。[3]

源码还分别记忆两侧的显示状态：`annotationsShown[0]` 对应左侧，`annotationsShown[1]` 对应右侧；viewer 重新初始化时分别恢复。[3]

两侧的数据来源也独立解析：

- 对变更 Diff，左/右分别选择 before revision 与 after revision。
- `CurrentContentRevision` 使用工作区文件加载 annotation。
- 历史 revision 使用对应 `FilePath + VcsRevisionNumber` 加载 annotation。
- 内容若没有可识别的文件、revision 或 patch-base 信息，则该侧没有可用 loader，操作应禁用。[3]

对于未追踪、刚新增或 ignored 文件，IntelliJ 源码直接认为当前文件不能 annotation。[3]

RepoDesk 对齐建议：

- 左侧 HEAD 内容用 `git blame HEAD -- <path>` 或等价 revision blame。
- 右侧 Working Tree 应以当前文件为目标，同时把尚未提交的新行映射成无历史状态，例如 `Not committed yet`，而不是误配到邻近提交。
- 若文件未追踪或该侧无法关联 revision，菜单项应禁用或给出明确不可用原因，不能点击后无反馈。

## 4. 加载、成功与错误反馈

IntelliJ Community 的完整加载流程是：[3]

1. 为当前 viewer + side 获取后台操作锁。
2. 在 Diff Context 中打开 progress bar。
3. 在线程池执行 VCS annotation 和必要的行号映射。
4. 回到 UI 线程关闭 progress bar、释放锁。
5. 有异常时显示 `Can't load annotations` 错误通知，不安装空白 gutter。
6. 有有效结果且 viewer 未销毁时，才向对应 editor 安装 annotations。

错误通知在 Diff 自己的独立窗口中会以 balloon 显示在 viewer 右上附近；若是正常 IDE frame，则走 IDE 通知系统。[3]

RepoDesk 对齐建议：

- 点击后立即出现可见 loading，最好位于弹框工具栏或目标侧 gutter 的加载占位中。
- loading 时该侧菜单项置为 disabled，避免重复任务。
- 成功后 loading 被真实 annotation gutter 替换。
- 空结果与失败必须显示文字原因；不能仅撤销状态而让用户感觉“没反应”。
- 切换文件、关闭弹框或重新发起 diff 时，应取消旧任务或丢弃过期结果。

## 5. 分隔线语义

IntelliJ 的 two-side 内容面板创建 `DiffSplitter`，依次设置左、右内容，没有传入自定义比例。[5] `DiffSplitter` 继承 `JBSplitter`；无参 `JBSplitter` 的默认比例是 `0.5`，即初次布局左右等宽。[6]

分隔器实现将鼠标 cursor 设为水平 resize，并在拖动时根据鼠标横坐标调用 `setProportion`，因此用户可以直接左右拖动。[5][7]

默认 resize 策略为 `KEEP_PROPORTION`：窗口改变尺寸时保留当前比例。[7] 因此 IDEA 的精确语义是：

- 初次打开：中线居中。
- 未手动调整时：弹框缩放后仍然居中。
- 手动拖动后：保持用户设置的新比例，不会每次布局都强制恢复中心。
- IntelliJ 还支持通过平台特定的修饰键点击 divider 恢复 `0.5`，但这不是 RepoDesk 当前需求的必要项。[7]

RepoDesk 实现建议：使用真正的 split-view 布局，初始 fraction 为 `0.5`；拖动只改变左右 pane 的宽度，不改变 diff 行模型、滚动同步或 blame gutter 的行对齐。

## 6. 验收要点

- 打开 Side-by-side 弹框时，中线像素位置接近弹框内容区的 50%。
- 调整弹框宽度而未拖过中线时，中线仍保持 50%。
- 拖动中线后左右 pane 宽度立即变化，并在继续缩放弹框时保持新比例。
- 左侧 gutter 右键开启 blame，只出现左侧 annotation；右侧不变化。
- 右侧 gutter 右键开启 blame，只出现右侧 annotation；左侧状态保持。
- 加载时存在肉眼可见的 progress，不能无反馈。
- committed 行显示日期、作者、短 hash；本地新增行显示未提交状态。
- blame 列出现后，左右 diff 行仍严格对齐，中线位置不被 annotation 宽度意外推移。
- 加载失败显示错误；未追踪文件的操作禁用或明确提示不可用。

## 官方来源

1. JetBrains IntelliJ IDEA Help, “Locate code author (Annotate with Git Blame)”：<https://www.jetbrains.com/help/idea/investigate-changes.html#annotate_blame>
2. JetBrains IntelliJ IDEA Help, “Diff Viewer for files”，gutter context menu 中的 `Annotate with GitBlame`：<https://www.jetbrains.com/help/idea/differences-viewer.html>
3. IntelliJ Community `AnnotateDiffViewerAction.java`（调研 commit `78f0b0a985853fea97243d1096e50daaee6ed1b3`）：<https://github.com/JetBrains/intellij-community/blob/78f0b0a985853fea97243d1096e50daaee6ed1b3/platform/vcs-impl/src/com/intellij/openapi/vcs/actions/AnnotateDiffViewerAction.java>
4. IntelliJ Community `AnnotateToggleAction.java`：<https://github.com/JetBrains/intellij-community/blob/78f0b0a985853fea97243d1096e50daaee6ed1b3/platform/vcs-impl/src/com/intellij/openapi/vcs/actions/AnnotateToggleAction.java>
5. IntelliJ Community `TwosideContentPanel.java` 与 `DiffSplitter.java`：<https://github.com/JetBrains/intellij-community/blob/78f0b0a985853fea97243d1096e50daaee6ed1b3/platform/diff-impl/src/com/intellij/diff/tools/util/side/TwosideContentPanel.java>；<https://github.com/JetBrains/intellij-community/blob/78f0b0a985853fea97243d1096e50daaee6ed1b3/platform/diff-impl/src/com/intellij/diff/tools/util/DiffSplitter.java>
6. IntelliJ Community `JBSplitter.java`：<https://github.com/JetBrains/intellij-community/blob/78f0b0a985853fea97243d1096e50daaee6ed1b3/platform/platform-api/src/com/intellij/ui/JBSplitter.java>
7. IntelliJ Community `Splitter.java`：<https://github.com/JetBrains/intellij-community/blob/78f0b0a985853fea97243d1096e50daaee6ed1b3/platform/util/ui/src/com/intellij/openapi/ui/Splitter.java>
