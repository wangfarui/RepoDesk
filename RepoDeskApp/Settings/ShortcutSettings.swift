import Foundation
import AppKit
import SwiftUI

enum AppShortcutID: String, CaseIterable, Codable, Identifiable, Sendable {
    case save
    case javaTypeSearch
    case javaSymbolSearch
    case refresh
    case fullTextSearch
    case section1
    case section2
    case section3
    case section4
    case closeFileTab
    case undoFileDeletion
    case deleteFileItem
    case copyFileTreeItem
    case pasteFileTreeItem
    case changesGroupDirectory
    case changesGroupModule
    case historyGroupDirectory
    case historyGroupModule
    case commit
    case goToLine
    case declaration
    case superDeclaration
    case implementation
    case implementationAlternate
    case navigationBack
    case navigationForward
    case contentFind
    case nextMatch
    case previousMatch

    var id: Self { self }

    var title: String {
        switch self {
        case .save: "保存"
        case .javaTypeSearch: "Java 类搜索"
        case .javaSymbolSearch: "Java 符号搜索"
        case .refresh: "刷新 Repository 和文件状态"
        case .fullTextSearch: "全文检索"
        case .section1: "切换到当前第 1 个模块"
        case .section2: "切换到当前第 2 个模块"
        case .section3: "切换到当前第 3 个模块"
        case .section4: "切换到当前第 4 个模块"
        case .closeFileTab: "关闭当前文件标签"
        case .undoFileDeletion: "撤销最近一次文件删除"
        case .deleteFileItem: "删除文件或目录"
        case .copyFileTreeItem: "复制文件树项目"
        case .pasteFileTreeItem: "粘贴文件树项目"
        case .changesGroupDirectory, .historyGroupDirectory: "按目录分组"
        case .changesGroupModule, .historyGroupModule: "按模块分组"
        case .commit: "提交改动"
        case .goToLine: "跳转到行"
        case .declaration: "跳转到声明"
        case .superDeclaration: "跳转到父声明"
        case .implementation: "跳转到实现"
        case .implementationAlternate: "跳转到实现（回车）"
        case .navigationBack: "返回文件导航"
        case .navigationForward: "前进文件导航"
        case .contentFind: "编辑器内查找"
        case .nextMatch: "下一个匹配项"
        case .previousMatch: "上一个匹配项"
        }
    }

    var group: String {
        switch self {
        case .save, .javaTypeSearch, .javaSymbolSearch, .refresh, .fullTextSearch,
             .section1, .section2, .section3, .section4:
            "全局"
        case .closeFileTab, .undoFileDeletion, .deleteFileItem, .copyFileTreeItem, .pasteFileTreeItem:
            "Files"
        case .changesGroupDirectory, .changesGroupModule, .commit:
            "Changes"
        case .historyGroupDirectory, .historyGroupModule:
            "History"
        default:
            "代码编辑器"
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .save: ShortcutBinding(key: "s", modifiers: [.command])
        case .javaTypeSearch: ShortcutBinding(key: "o", modifiers: [.command])
        case .javaSymbolSearch: ShortcutBinding(key: "o", modifiers: [.command, .option])
        case .refresh: ShortcutBinding(key: "r", modifiers: [.command])
        case .fullTextSearch: ShortcutBinding(key: "f", modifiers: [.command, .shift])
        case .section1: ShortcutBinding(key: "1", modifiers: [.command])
        case .section2: ShortcutBinding(key: "2", modifiers: [.command])
        case .section3: ShortcutBinding(key: "3", modifiers: [.command])
        case .section4: ShortcutBinding(key: "4", modifiers: [.command])
        case .closeFileTab: ShortcutBinding(key: "w", modifiers: [.command])
        case .undoFileDeletion: ShortcutBinding(key: "z", modifiers: [.command])
        case .deleteFileItem: ShortcutBinding(key: "delete", modifiers: [.command])
        case .copyFileTreeItem: ShortcutBinding(key: "c", modifiers: [.command])
        case .pasteFileTreeItem: ShortcutBinding(key: "v", modifiers: [.command])
        case .changesGroupDirectory, .historyGroupDirectory: ShortcutBinding(key: "p", modifiers: [.control])
        case .changesGroupModule, .historyGroupModule: ShortcutBinding(key: "m", modifiers: [.control])
        case .commit: ShortcutBinding(key: "return", modifiers: [.command])
        case .goToLine: ShortcutBinding(key: "l", modifiers: [.command])
        case .declaration: ShortcutBinding(key: "b", modifiers: [.command])
        case .superDeclaration: ShortcutBinding(key: "u", modifiers: [.command])
        case .implementation: ShortcutBinding(key: "b", modifiers: [.command, .option])
        case .implementationAlternate: ShortcutBinding(key: "return", modifiers: [.command, .option])
        case .navigationBack: ShortcutBinding(key: "left", modifiers: [.command, .option])
        case .navigationForward: ShortcutBinding(key: "right", modifiers: [.command, .option])
        case .contentFind: ShortcutBinding(key: "f", modifiers: [.command])
        case .nextMatch: ShortcutBinding(key: "g", modifiers: [.command])
        case .previousMatch: ShortcutBinding(key: "g", modifiers: [.command, .shift])
        }
    }
}

enum ShortcutModifier: String, CaseIterable, Codable, Sendable {
    case command
    case option
    case control
    case shift

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        }
    }

    var eventFlag: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        }
    }
}

struct ShortcutBinding: Codable, Equatable, Sendable {
    var key: String
    var modifiers: Set<ShortcutModifier>

    init(key: String, modifiers: Set<ShortcutModifier> = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    var modifierFlags: NSEvent.ModifierFlags {
        modifiers.reduce(into: []) { $0.formUnion($1.eventFlag) }
    }

    var eventModifiers: EventModifiers {
        modifiers.reduce(into: []) { result, modifier in
            switch modifier {
            case .command: result.insert(.command)
            case .option: result.insert(.option)
            case .control: result.insert(.control)
            case .shift: result.insert(.shift)
            }
        }
    }

    var displayName: String {
        let ordered = [ShortcutModifier.command, .option, .control, .shift]
        let modifierText = ordered.filter(modifiers.contains).map(\.symbol).joined()
        let keyText: String
        switch key {
        case "return": keyText = "↩"
        case "delete": keyText = "⌫"
        case "left": keyText = "←"
        case "right": keyText = "→"
        default: keyText = key.uppercased()
        }
        return modifierText + keyText
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "return": .return
        case "delete": .delete
        default: KeyEquivalent(Character(key))
        }
    }

    static func defaults() -> [AppShortcutID: ShortcutBinding] {
        Dictionary(uniqueKeysWithValues: AppShortcutID.allCases.map { ($0, $0.defaultBinding) })
    }
}
