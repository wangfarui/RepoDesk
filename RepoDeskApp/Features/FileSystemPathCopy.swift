import AppKit
import Foundation
import SwiftUI

struct FileSystemPathCopyValues: Equatable, Sendable {
    let name: String
    let relativePath: String
    let absolutePath: String

    init?(itemURL: URL, rootURL: URL) {
        let rootURL = rootURL.standardizedFileURL
        let itemURL = itemURL.standardizedFileURL
        guard let relativePath = Self.relativePath(of: itemURL, from: rootURL) else {
            return nil
        }
        name = itemURL.lastPathComponent
        self.relativePath = relativePath
        absolutePath = itemURL.path
    }

    init?(relativePath: String, rootURL: URL) {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let rootURL = rootURL.standardizedFileURL
        let itemURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard Self.relativePath(of: itemURL, from: rootURL) != nil else { return nil }
        name = itemURL.lastPathComponent
        self.relativePath = relativePath
        absolutePath = itemURL.path
    }

    static func repositoryDirectoryPath(
        path: String,
        modulePath: String?
    ) -> String {
        guard let modulePath, modulePath != "." else { return path }
        return path.isEmpty ? modulePath : "\(modulePath)/\(path)"
    }

    private static func relativePath(of itemURL: URL, from rootURL: URL) -> String? {
        let rootPath = rootURL.path
        let itemPath = itemURL.path
        if itemPath == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else { return nil }
        return String(itemPath.dropFirst(prefix.count))
    }
}

@MainActor
func openFileSystemItemInFinder(at itemURL: URL, isDirectory: Bool) {
    let itemURL = itemURL.standardizedFileURL
    if isDirectory {
        NSWorkspace.shared.open(itemURL)
    } else {
        NSWorkspace.shared.activateFileViewerSelecting([itemURL])
    }
}

private struct FileSystemPathCopyMenuModifier: ViewModifier {
    let values: FileSystemPathCopyValues?
    let copyItem: (() -> Void)?
    let pasteItem: (() -> Void)?
    let newFileItem: (() -> Void)?
    let newDirectoryItem: (() -> Void)?
    let expandSubtreeItem: (() -> Void)?
    let renameItem: (() -> Void)?
    let deleteItem: (() -> Void)?
    let rollbackItem: (() -> Void)?
    let viewGitHistoryItem: (() -> Void)?
    let annotateGitBlameItem: (() -> Void)?
    let isGitBlameAnnotated: Bool
    let openInFinderItem: (() -> Void)?
    let isContextMenuPresented: Binding<Bool>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if values != nil || copyItem != nil || pasteItem != nil || newFileItem != nil
            || newDirectoryItem != nil || expandSubtreeItem != nil || renameItem != nil || deleteItem != nil || rollbackItem != nil
            || viewGitHistoryItem != nil || annotateGitBlameItem != nil || openInFinderItem != nil {
            if let isContextMenuPresented {
                content.overlay {
                    FileSystemContextMenuPresenter(
                        values: values,
                        copyItem: copyItem,
                        pasteItem: pasteItem,
                        newFileItem: newFileItem,
                        newDirectoryItem: newDirectoryItem,
                        expandSubtreeItem: expandSubtreeItem,
                        renameItem: renameItem,
                        deleteItem: deleteItem,
                        rollbackItem: rollbackItem,
                        viewGitHistoryItem: viewGitHistoryItem,
                        annotateGitBlameItem: annotateGitBlameItem,
                        isGitBlameAnnotated: isGitBlameAnnotated,
                        openInFinderItem: openInFinderItem,
                        isPresented: isContextMenuPresented
                    )
                }
            } else {
                content.contextMenu {
                    swiftUIMenuItems
                }
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var swiftUIMenuItems: some View {
        if let expandSubtreeItem {
            Button("展开子树", systemImage: "arrow.up.left.and.arrow.down.right", action: expandSubtreeItem)
        }
        if let copyItem {
            Button("复制", systemImage: "doc.on.doc", action: copyItem)
        }
        if let pasteItem {
            Button("粘贴", systemImage: "doc.on.clipboard", action: pasteItem)
        }
        if let newFileItem {
            Button("新建文件", systemImage: "doc.badge.plus", action: newFileItem)
        }
        if let newDirectoryItem {
            Button("新建目录", systemImage: "folder.badge.plus", action: newDirectoryItem)
        }
        if let renameItem {
            Button("重命名", systemImage: "pencil", action: renameItem)
        }
        if let deleteItem {
            Button("删除", systemImage: "trash", role: .destructive, action: deleteItem)
        }
        if let rollbackItem {
            Button("Rollback", systemImage: "arrow.uturn.backward", action: rollbackItem)
        }
        if let viewGitHistoryItem {
            Button("查看 Git 提交历史", systemImage: "clock.arrow.circlepath", action: viewGitHistoryItem)
        }
        if let annotateGitBlameItem {
            Toggle("Annotate with Git Blame", isOn: Binding(
                get: { isGitBlameAnnotated },
                set: { _ in annotateGitBlameItem() }
            ))
        }
        if let openInFinderItem {
            Button("在Finder中打开", systemImage: "folder", action: openInFinderItem)
        }
        if (copyItem != nil || pasteItem != nil || newFileItem != nil || newDirectoryItem != nil || expandSubtreeItem != nil
            || renameItem != nil
            || deleteItem != nil
            || rollbackItem != nil
            || viewGitHistoryItem != nil
            || annotateGitBlameItem != nil
            || openInFinderItem != nil), values != nil {
            Divider()
        }
        if let values {
            Button("复制相对路径", systemImage: "doc.text") {
                copy(values.relativePath)
            }
            Button("复制绝对路径", systemImage: "folder") {
                copy(values.absolutePath)
            }
            Button("复制名称", systemImage: "textformat") {
                copy(values.name)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
private struct FileSystemContextMenuPresenter: NSViewRepresentable {
    let values: FileSystemPathCopyValues?
    let copyItem: (() -> Void)?
    let pasteItem: (() -> Void)?
    let newFileItem: (() -> Void)?
    let newDirectoryItem: (() -> Void)?
    let expandSubtreeItem: (() -> Void)?
    let renameItem: (() -> Void)?
    let deleteItem: (() -> Void)?
    let rollbackItem: (() -> Void)?
    let viewGitHistoryItem: (() -> Void)?
    let annotateGitBlameItem: (() -> Void)?
    let isGitBlameAnnotated: Bool
    let openInFinderItem: (() -> Void)?
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            values: values,
            copyItem: copyItem,
            pasteItem: pasteItem,
            newFileItem: newFileItem,
            newDirectoryItem: newDirectoryItem,
            expandSubtreeItem: expandSubtreeItem,
            renameItem: renameItem,
            deleteItem: deleteItem,
            rollbackItem: rollbackItem,
            viewGitHistoryItem: viewGitHistoryItem,
            annotateGitBlameItem: annotateGitBlameItem,
            isGitBlameAnnotated: isGitBlameAnnotated,
            openInFinderItem: openInFinderItem,
            isPresented: $isPresented
        )
    }

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        context.coordinator.values = values
        context.coordinator.copyItem = copyItem
        context.coordinator.pasteItem = pasteItem
        context.coordinator.newFileItem = newFileItem
        context.coordinator.newDirectoryItem = newDirectoryItem
        context.coordinator.expandSubtreeItem = expandSubtreeItem
        context.coordinator.renameItem = renameItem
        context.coordinator.deleteItem = deleteItem
        context.coordinator.rollbackItem = rollbackItem
        context.coordinator.viewGitHistoryItem = viewGitHistoryItem
        context.coordinator.annotateGitBlameItem = annotateGitBlameItem
        context.coordinator.isGitBlameAnnotated = isGitBlameAnnotated
        context.coordinator.openInFinderItem = openInFinderItem
        context.coordinator.isPresented = $isPresented
        view.coordinator = context.coordinator
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var values: FileSystemPathCopyValues?
        var copyItem: (() -> Void)?
        var pasteItem: (() -> Void)?
        var newFileItem: (() -> Void)?
        var newDirectoryItem: (() -> Void)?
        var expandSubtreeItem: (() -> Void)?
        var renameItem: (() -> Void)?
        var deleteItem: (() -> Void)?
        var rollbackItem: (() -> Void)?
        var viewGitHistoryItem: (() -> Void)?
        var annotateGitBlameItem: (() -> Void)?
        var isGitBlameAnnotated: Bool
        var openInFinderItem: (() -> Void)?
        var isPresented: Binding<Bool>

        init(
            values: FileSystemPathCopyValues?,
            copyItem: (() -> Void)?,
            pasteItem: (() -> Void)?,
            newFileItem: (() -> Void)?,
            newDirectoryItem: (() -> Void)?,
            expandSubtreeItem: (() -> Void)?,
            renameItem: (() -> Void)?,
            deleteItem: (() -> Void)?,
            rollbackItem: (() -> Void)?,
            viewGitHistoryItem: (() -> Void)?,
            annotateGitBlameItem: (() -> Void)?,
            isGitBlameAnnotated: Bool,
            openInFinderItem: (() -> Void)?,
            isPresented: Binding<Bool>
        ) {
            self.values = values
            self.copyItem = copyItem
            self.pasteItem = pasteItem
            self.newFileItem = newFileItem
            self.newDirectoryItem = newDirectoryItem
            self.expandSubtreeItem = expandSubtreeItem
            self.renameItem = renameItem
            self.deleteItem = deleteItem
            self.rollbackItem = rollbackItem
            self.viewGitHistoryItem = viewGitHistoryItem
            self.annotateGitBlameItem = annotateGitBlameItem
            self.isGitBlameAnnotated = isGitBlameAnnotated
            self.openInFinderItem = openInFinderItem
            self.isPresented = isPresented
        }

        func presentMenu(for event: NSEvent, in view: NSView) {
            let menu = NSMenu()
            menu.delegate = self
            if expandSubtreeItem != nil {
                menu.addItem(menuItem("展开子树", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(expandSubtree)))
            }
            if copyItem != nil {
                menu.addItem(menuItem("复制", symbol: "doc.on.doc", action: #selector(copyFileItem)))
            }
            if pasteItem != nil {
                menu.addItem(menuItem("粘贴", symbol: "doc.on.clipboard", action: #selector(pasteFileItem)))
            }
            if newFileItem != nil {
                menu.addItem(menuItem("新建文件", symbol: "doc.badge.plus", action: #selector(createFileItem)))
            }
            if newDirectoryItem != nil {
                menu.addItem(menuItem("新建目录", symbol: "folder.badge.plus", action: #selector(createDirectoryItem)))
            }
            if renameItem != nil {
                menu.addItem(menuItem("重命名", symbol: "pencil", action: #selector(renameFileItem)))
            }
            if deleteItem != nil {
                menu.addItem(menuItem("删除", symbol: "trash", action: #selector(deleteFileItem)))
            }
            if rollbackItem != nil {
                menu.addItem(menuItem("Rollback", symbol: "arrow.uturn.backward", action: #selector(rollbackFileItem)))
            }
            if viewGitHistoryItem != nil {
                menu.addItem(menuItem("查看 Git 提交历史", symbol: "clock.arrow.circlepath", action: #selector(viewGitHistory)))
            }
            if annotateGitBlameItem != nil {
                let item = menuItem("Annotate with Git Blame", symbol: "person.text.rectangle", action: #selector(annotateGitBlame))
                item.state = isGitBlameAnnotated ? .on : .off
                menu.addItem(item)
            }
            if openInFinderItem != nil {
                menu.addItem(menuItem("在Finder中打开", symbol: "folder", action: #selector(openInFinder)))
            }
            if (copyItem != nil || pasteItem != nil || newFileItem != nil || newDirectoryItem != nil || expandSubtreeItem != nil
                || renameItem != nil
                || deleteItem != nil
                || rollbackItem != nil
                || viewGitHistoryItem != nil
                || annotateGitBlameItem != nil
                || openInFinderItem != nil), values != nil {
                menu.addItem(.separator())
            }
            if values != nil {
                menu.addItem(menuItem("复制相对路径", symbol: "doc.text", action: #selector(copyRelativePath)))
                menu.addItem(menuItem("复制绝对路径", symbol: "folder", action: #selector(copyAbsolutePath)))
                menu.addItem(menuItem("复制名称", symbol: "textformat", action: #selector(copyName)))
            }

            isPresented.wrappedValue = true
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            isPresented.wrappedValue = false
        }

        func menuWillOpen(_ menu: NSMenu) {
            isPresented.wrappedValue = true
        }

        func menuDidClose(_ menu: NSMenu) {
            isPresented.wrappedValue = false
        }

        private func menuItem(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }

        @objc private func copyFileItem() {
            copyItem?()
        }

        @objc private func pasteFileItem() {
            pasteItem?()
        }

        @objc private func createFileItem() {
            newFileItem?()
        }

        @objc private func createDirectoryItem() {
            newDirectoryItem?()
        }

        @objc private func expandSubtree() {
            expandSubtreeItem?()
        }

        @objc private func renameFileItem() {
            renameItem?()
        }

        @objc private func deleteFileItem() {
            deleteItem?()
        }

        @objc private func rollbackFileItem() {
            rollbackItem?()
        }

        @objc private func annotateGitBlame() {
            annotateGitBlameItem?()
        }

        @objc private func viewGitHistory() {
            viewGitHistoryItem?()
        }

        @objc private func openInFinder() {
            openInFinderItem?()
        }

        @objc private func copyRelativePath() {
            guard let values else { return }
            copy(values.relativePath)
        }

        @objc private func copyAbsolutePath() {
            guard let values else { return }
            copy(values.absolutePath)
        }

        @objc private func copyName() {
            guard let values else { return }
            copy(values.name)
        }

        private func copy(_ value: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }

    final class RightClickView: NSView {
        weak var coordinator: Coordinator?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point), let event = NSApp.currentEvent else { return nil }
            if event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
                return self
            }
            return nil
        }

        override func rightMouseDown(with event: NSEvent) {
            coordinator?.presentMenu(for: event, in: self)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                coordinator?.presentMenu(for: event, in: self)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

extension View {
    func fileSystemPathCopyMenu(
        _ values: FileSystemPathCopyValues?,
        copyItem: (() -> Void)? = nil,
        pasteItem: (() -> Void)? = nil,
        newFileItem: (() -> Void)? = nil,
        newDirectoryItem: (() -> Void)? = nil,
        expandSubtreeItem: (() -> Void)? = nil,
        renameItem: (() -> Void)? = nil,
        deleteItem: (() -> Void)? = nil,
        rollbackItem: (() -> Void)? = nil,
        viewGitHistoryItem: (() -> Void)? = nil,
        annotateGitBlameItem: (() -> Void)? = nil,
        isGitBlameAnnotated: Bool = false,
        openInFinderItem: (() -> Void)? = nil,
        isContextMenuPresented: Binding<Bool>? = nil
    ) -> some View {
        modifier(
            FileSystemPathCopyMenuModifier(
                values: values,
                copyItem: copyItem,
                pasteItem: pasteItem,
                newFileItem: newFileItem,
                newDirectoryItem: newDirectoryItem,
                expandSubtreeItem: expandSubtreeItem,
                renameItem: renameItem,
                deleteItem: deleteItem,
                rollbackItem: rollbackItem,
                viewGitHistoryItem: viewGitHistoryItem,
                annotateGitBlameItem: annotateGitBlameItem,
                isGitBlameAnnotated: isGitBlameAnnotated,
                openInFinderItem: openInFinderItem,
                isContextMenuPresented: isContextMenuPresented
            )
        )
    }
}
