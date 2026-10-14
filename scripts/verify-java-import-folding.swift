import AppKit
import SwiftUI
@testable import RepoDesk

@main
@MainActor
enum VerifyJavaImportFolding {
    static func main() throws {
        _ = NSApplication.shared
        let source = """
        /* import fake.Comment; */
        package example;

        import java.util.List;

        import static java.util.Collections.emptyList;
        import java.util.Map;

        /** 类注释 😀 */
        @Deprecated
        public class Example {
            String text = "import fake.String;";
        }
        """
        let region = try unwrap(JavaImportRegion.find(in: source), "Import region missing")
        try require((source as NSString).substring(with: region.keywordRange) == "import", "Wrong import keyword")
        try require(!(source as NSString).substring(with: region.hiddenRange).contains("类注释"), "Class documentation was folded")
        for invalid in ["// import fake.Comment;\nclass X {}", "class X { String s = \"import fake.String;\"; }", "package x;\n/** import fake.Doc; */\nclass X {}"] {
            try require(JavaImportRegion.find(in: invalid) == nil, "False import in comments or body")
        }
        let crlf = source.replacingOccurrences(of: "\n", with: "\r\n")
        try require(JavaImportRegion.find(in: crlf) != nil, "CRLF import detection failed")
        try require(JavaImportRegion.find(in: "import java.util.List;\nclass X {}") != nil, "Single import missing")
        try require(JavaImportRegion.find(in: "package x;\nclass X {}") == nil, "No-import file was folded")

        let editor = NativeCodeEditor(text: .constant(source), isEditable: true,
                                      style: .source(fileExtension: "java"), showsLineNumbers: true,
                                      foldsJavaImports: true)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let textView = try unwrap(findTextView(host), "Missing editor")
        let layout = try unwrap(textView.layoutManager, "Missing layout")
        let folding = try unwrap(layout.delegate as? NativeJavaImportFolding, "Missing folding delegate")
        let classOffset = (source as NSString).range(of: "public class").location
        let classLine = SourceLineIndex(text: source).lineNumber(containingUTF16Offset: classOffset)
        let collapsedY = lineY(classOffset, in: textView)
        try require(!folding.isExpanded, "Imports should default to collapsed")
        try require(textView.string == source, "Folding changed source")
        try require(collapsedY < 130, "Imports still consume vertical space: \(collapsedY)")
        let button = try unwrap(textView.subviews.compactMap { $0 as? NSButton }.first, "Missing ellipsis button")
        try require(!button.isHidden && button.frame.width > 20, "Ellipsis is invisible")
        try screenshot(host, name: "java-imports-collapsed")
        host.appearance = NSAppearance(named: .darkAqua)
        try screenshot(host, name: "java-imports-collapsed-dark")
        host.appearance = NSAppearance(named: .aqua)
        button.performClick(nil)
        let expandedY = lineY(classOffset, in: textView)
        try require(folding.isExpanded && expandedY > collapsedY + 30, "Click did not expand imports: \(collapsedY) -> \(expandedY)")
        try require(button.isHidden, "Expanded imports still show ellipsis")
        try screenshot(host, name: "java-imports-expanded")
        let ruler = try unwrap(textView.enclosingScrollView?.verticalRulerView, "Missing line ruler")
        let importY = lineY(region.keywordRange.location, in: textView) + textView.textContainerOrigin.y + 8
        let rulerY = ruler.convert(NSPoint(x: 0, y: importY), from: textView).y
        let clickPoint = ruler.convert(NSPoint(x: ruler.bounds.maxX - 7, y: rulerY), to: nil)
        let click = try unwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: clickPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ), "Missing gutter click")
        ruler.mouseDown(with: click)
        try require(!folding.isExpanded && abs(lineY(classOffset, in: textView) - collapsedY) < 1, "Gutter refolding failed")
        try require(SourceLineIndex(text: textView.string).lineNumber(containingUTF16Offset: classOffset) == classLine, "Original line numbers changed")
        textView.selectAll(nil)
        try require((textView.string as NSString).substring(with: textView.selectedRange()) == source, "Copy selection loses hidden imports")
        folding.reveal(NSRange(location: classOffset, length: 5))
        try require(!folding.isExpanded, "Navigating to the class expanded imports")
        let coordinator = try unwrap(textView.delegate as? NativeCodeEditor.Coordinator, "Missing editor coordinator")
        let importMatch = (source as NSString).range(of: "java.util.Map")
        coordinator.applyContentSearch(ContentSearchPresentation(
            ranges: [importMatch], activeRange: importMatch, navigationRequestID: UUID()
        ))
        try require(folding.isExpanded && textView.selectedRange() == importMatch, "Search did not reveal the original import range")
        folding.toggle()
        coordinator.navigateIfNeeded(to: NativeTextNavigationRequest(line: 6))
        try require(folding.isExpanded, "Go to import line did not reveal it")
        try require(textView.selectedRange().location == SourceLineIndex(text: source).lineStartOffsets[5], "Go to line lost the source position")
        folding.toggle()
        coordinator.navigateIfNeeded(to: NativeTextNavigationRequest(line: classLine))
        try require(!folding.isExpanded && textView.selectedRange().location == classOffset, "Go to class should keep imports folded")
        try require(!coordinator.textView(textView, shouldChangeTextIn: importMatch, replacementString: ""), "A keystroke modified hidden imports")
        try require(folding.isExpanded && textView.string == source, "Editing should reveal imports before changing them")
        folding.toggle()
        textView.setSelectedRange(NSRange(location: importMatch.location, length: 0))
        try require(folding.isExpanded, "Keyboard caret can enter invisible imports")
        folding.configure(enabled: true, expanded: true, sourceChanged: false)
        try require(folding.isExpanded, "Expanded tab state lost")
        folding.configure(enabled: true, expanded: false, sourceChanged: true)
        try require(!folding.isExpanded, "New tab did not reset folding")
        folding.configure(enabled: false, expanded: false, sourceChanged: true)
        try require(folding.region == nil && lineY(classOffset, in: textView) == expandedY, "Disabled folding affects another viewer")
        let plainEditor = NativeCodeEditor(text: .constant(source), isEditable: false,
                                           style: .source(fileExtension: "java"))
        let plainHost = NSHostingView(rootView: plainEditor)
        plainHost.frame = host.frame
        plainHost.layoutSubtreeIfNeeded()
        let plainView = try unwrap(findTextView(plainHost), "Missing non-Files editor")
        try require(!(plainView.layoutManager?.delegate is NativeJavaImportFolding), "Folding leaked to other source viewers")
        print("Java import folding verification passed (layout, interaction, source positions and copy)")
    }

    static func lineY(_ offset: Int, in view: NSTextView) -> CGFloat {
        let layout = view.layoutManager!
        layout.ensureLayout(for: view.textContainer!)
        return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil).minY
    }

    static func findTextView(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { findTextView($0) }.first
    }

    static func screenshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "Missing screenshot")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try unwrap(bitmap.representation(using: .png, properties: [:]), "Missing PNG")
        try png.write(to: URL(fileURLWithPath: "build/\(name).png"))
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "JavaImportFolding", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: "JavaImportFolding", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }
}
