# Git Merge 冲突处理改造

2026-11-03。当前实现以本机 IntelliJ IDEA **2025.2.1 / IU-252.25557.131** 的合并窗口为参照。2026-10-30 的核心模型改造记录保留在 [初始对齐清单](idea-merge-conflict-alignment-20261030.md)；本次界面约定以本文为准。

## 确认后的行为

- 冲突文件列表 **Close = `git merge --abort`**，直接中止本次合并。这是用户要求保留的差异；文件编辑器 Cancel 仅取消该文件的未保存编辑。
- 文件列表保留 Name / Type / Yours / Theirs、Accept Yours / Accept Theirs / Merge、目录分组和 Close。支持多选接受以及依次打开所选文本文件。
- 编辑器是一行工具栏、三个连续代码文档、小标题和底部按钮。左右原文只读，中间 Result 可编辑。
- **每个未处理变更旁直接显示 Accept 双箭头和 Ignore 叉号**，不依赖当前选择的变更；处理一侧后该侧动作消失，另一侧切换为追加箭头。Ctrl+Click 处理整个冲突，已接受一侧时继续按操作顺序组合另一侧。
- 工具栏按 IDEA 顺序提供前后导航、版本比较、左/全部/右无冲突应用、简单冲突解决、空白比较、高亮粒度、上下文折叠、同步滚动和显示设置。F7 / Shift+F7 导航未处理变更；Command+Z / Shift+Command+Z 一并撤销文字与取舍状态。
- 底部左侧是 Accept Left / Accept Right，右侧是 Cancel / Apply；取消有改动的 Result 时显示 Cancel Merge 确认。移除先前自定义的顶部全局 Accept/Ignore、变更下拉和 Save Progress and Close 按钮。
- Apply 写入并暂存文件；未处理完毕时先确认是否使用当前 Result。最后一个冲突文件处理后继续原 merge 流程；不再要求额外的 Continue Merge 按钮。Git 提交失败时保留错误和会话，允许重试或 Close/Abort。

## 证据来源

- REA 对本机 IDEA JAR 的反编译记录见 `docs/evidence/idea-merge-20261030.json`。重点类为 MergeThreesideViewer、TextMergeChange、MergeRequestProcessor 和 MultipleFileMergeDialog。
- 使用 IDEA 官方 `idea merge left right base result` 命令，只对临时目录中的 Java 文件观察窗口。实际核对了工具栏次序、源文件行号栏位置、块旁按钮、接受左侧后右侧追加状态、底部按钮、Settings 菜单和 Escape 的取消确认。
- 原生 AppKit 布局：源文档旁独立操作栏、两条 32 pt 连接区、Result 行号栏；原生文档视口与外层容器双重裁剪，防止长文档侵入工具栏和底部区域。代码字体随包提供 JetBrains Mono，许可见 `Support/Resources/MergeFonts/OFL.txt`。

## 模型与 Git 数据

三方来源直接读取 index stage 1/2/3。每个块保存双方独立状态、UTF-16 范围与可变 Result；支持手工编辑跨块后的范围修正、撤销/重做、空白策略和旧草稿兼容。简单冲突解决采用保守的字符级三方合并，重叠修改继续留给用户。

Git 元数据目录中的草稿以 HEAD/MERGE_HEAD 区分会话，复用前核对来源、工作树和 index。外部修改不能被旧编辑结果直接覆盖。完整接受来源保留原始 Data；接受缺失侧执行删除并暂存，不将删除误写成空文件。

二进制只支持整文件取一侧。重命名、多路径冲突、非普通文件模式、子模块及单版本超过 8 MB 的文件提示使用外部工具。非 UTF-8 文本按二进制处理；可编辑文本使用 UTF-8，保留 LF/CRLF 和末尾换行状态。

## 验证与范围

- `scripts/verify-idea-merge-interaction.swift`：真实 NSButton 的块旁接受/忽略、无需先选中块、Ctrl+Click、双侧组合、撤销/重做、右键动作次序、来源不可变、滚动与缩放裁剪，并输出 `build/idea-merge-parity.png`。
- `scripts/verify-three-way-merge.swift`：核心模型、空白策略、简单冲突、旧草稿，以及临时真实 Git 仓库中的 index、外部修改保护、删除、二进制、Abort 和最后文件自动完成 merge。
- `scripts/verify-merge-conflict-rendering.swift`：三个完整文档、窗口尺寸、同步滚动、原生输入与输入法撤销。
- `./scripts/verify-local.sh`：完整工程验证、独立应用构建与临时签名。

本次复现合并界面的主要布局和操作。IDEA 的 Java PSI/import 语义合并、完整语言编辑器及插件系统没有移植；Resolve Conflicts in Import Statements 明确禁用。版本比较使用本应用只读代码编辑器，不宣称已经移植 IDEA 全部 Diff 编辑器。系统窗口装饰和菜单由 macOS/SwiftUI 绘制，不能据此宣称逐像素一致。

## 2026-11-04 交付核验

- 最后一轮 `./scripts/verify-local.sh` 完整通过，日志位于 `/private/tmp/repodesk-idea-parity-20261103/verify.log`。包含新增原生交互、三方模型和临时真实 Git 流程，以及原有全工程回归。
- 实际鼠标操作临时预览窗口：接受左侧后该侧操作消失，右侧显示追加箭头；再接受右侧组合 Result；Escape 弹出 Cancel Merge 确认。没有对用户业务仓库执行合并或中止。
- 冲突列表及编辑器缩放、三个连续文档、同步滚动、原生输入和输入法撤销均通过。850 行水平滚动检查约 0.071 秒。
- 独立应用 `build/RepoDesk.app/Contents/MacOS/RepoDesk` 的构建时间为 **2026-11-03 15:35:22（Asia/Shanghai）**。2026-11-04 再次执行 `codesign --verify --deep --strict build/RepoDesk.app` 通过；任务文件哈希无漂移，没有比应用更新的 Swift 源码。
- JetBrains Mono 字体及 OFL 许可已进入应用资源目录。`git diff --check` 通过。
- 界面截图：`build/idea-merge-parity.png`、`build/merge-conflict-list.png`。改动保持未提交，原有 `ChangesView.swift` 修改已保留。
