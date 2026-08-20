import SwiftUI

struct FileTypeIcon: View {
    let path: String
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: descriptor.symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(descriptor.color)
            .frame(width: size + 3, height: size + 3)
            .accessibilityLabel(descriptor.label)
    }

    private var descriptor: FileIconDescriptor {
        FileIconDescriptor(path: path)
    }
}

private struct FileIconDescriptor {
    let symbol: String
    let color: Color
    let label: String

    private init(symbol: String, color: Color, label: String) {
        self.symbol = symbol
        self.color = color
        self.label = label
    }

    init(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()

        switch name {
        case "pom.xml":
            self = .init(symbol: "shippingbox.fill", color: .orange, label: "Maven POM")
        case "mvnw", "mvnw.cmd":
            self = .init(symbol: "terminal.fill", color: .orange, label: "Maven Wrapper")
        case "dockerfile":
            self = .init(symbol: "shippingbox", color: .blue, label: "Dockerfile")
        case "makefile":
            self = .init(symbol: "hammer.fill", color: .orange, label: "Makefile")
        case ".gitignore", ".gitattributes", ".gitmodules":
            self = .init(symbol: "arrow.triangle.branch", color: .orange, label: "Git 配置")
        default:
            switch fileExtension {
            case "java": self = .init(symbol: "cup.and.saucer.fill", color: .orange, label: "Java 文件")
            case "kt", "kts": self = .init(symbol: "diamond.fill", color: .purple, label: "Kotlin 文件")
            case "groovy": self = .init(symbol: "g.circle.fill", color: .blue, label: "Groovy 文件")
            case "xml": self = .init(symbol: "chevron.left.forwardslash.chevron.right", color: .orange, label: "XML 文件")
            case "yaml", "yml": self = .init(symbol: "list.bullet.indent", color: .purple, label: "YAML 文件")
            case "properties": self = .init(symbol: "slider.horizontal.3", color: .green, label: "Properties 文件")
            case "sql": self = .init(symbol: "cylinder.fill", color: .blue, label: "SQL 文件")
            case "md", "markdown": self = .init(symbol: "doc.richtext.fill", color: .blue, label: "Markdown 文件")
            case "json": self = .init(symbol: "curlybraces.square.fill", color: .yellow, label: "JSON 文件")
            case "html", "htm": self = .init(symbol: "globe", color: .orange, label: "HTML 文件")
            case "css", "scss", "less": self = .init(symbol: "paintbrush.fill", color: .purple, label: "样式文件")
            case "js", "mjs", "cjs": self = .init(symbol: "j.square.fill", color: .yellow, label: "JavaScript 文件")
            case "ts", "tsx": self = .init(symbol: "t.square.fill", color: .blue, label: "TypeScript 文件")
            case "sh", "bash", "zsh", "command": self = .init(symbol: "terminal.fill", color: .green, label: "Shell 脚本")
            case "swift": self = .init(symbol: "swift", color: .orange, label: "Swift 文件")
            case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico": self = .init(symbol: "photo.fill", color: .purple, label: "图片文件")
            case "jar", "war", "zip", "gz", "tar": self = .init(symbol: "archivebox.fill", color: .brown, label: "归档文件")
            case "class": self = .init(symbol: "cube.fill", color: .secondary, label: "Java Class")
            case "log": self = .init(symbol: "text.alignleft", color: .secondary, label: "日志文件")
            case "txt", "csv": self = .init(symbol: "doc.plaintext.fill", color: .secondary, label: "文本文件")
            default: self = .init(symbol: "doc.fill", color: .secondary, label: "文件")
            }
        }
    }
}
