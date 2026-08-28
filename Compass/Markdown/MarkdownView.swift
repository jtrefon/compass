import SwiftUI
import Markdown

struct MarkdownView<CodeBlockContent: View>: View {
    private let document: Document
    private let codeBlock: (String, String?) -> CodeBlockContent
    private let fontSize: Double?
    private let fontFamily: String?

    init(
        markdown: String,
        fontSize: Double? = nil,
        fontFamily: String? = nil,
        @ViewBuilder codeBlock: @escaping (String, String?) -> CodeBlockContent
    ) {
        self.document = Document(parsing: markdown)
        self.codeBlock = codeBlock
        self.fontSize = fontSize
        self.fontFamily = fontFamily
    }

    init(
        document: Document,
        fontSize: Double? = nil,
        fontFamily: String? = nil,
        @ViewBuilder codeBlock: @escaping (String, String?) -> CodeBlockContent
    ) {
        self.document = document
        self.codeBlock = codeBlock
        self.fontSize = fontSize
        self.fontFamily = fontFamily
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            let children = Array(document.children)
            ForEach(Array(children.indices), id: \.self) { index in
                BlockView(child: children[index], codeBlock: codeBlock, fontSize: fontSize, fontFamily: fontFamily)
            }
        }
    }
}

// MARK: - Block Renderer

private struct BlockView<CodeBlockContent: View>: View {
    let child: Markup
    let codeBlock: (String, String?) -> CodeBlockContent
    let fontSize: Double?
    let fontFamily: String?

    var body: some View {
        switch child {
        case let paragraph as Paragraph:
            InlineRenderer(markup: paragraph, fontSize: fontSize, fontFamily: fontFamily)
                .fixedSize(horizontal: false, vertical: true)
        case let heading as Heading:
            InlineRenderer(markup: heading, fontSize: headingFontSize(heading.level), fontFamily: fontFamily)
                .fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)
        case let code as CodeBlock:
            codeBlock(code.code, code.language)
        case let list as OrderedList:
            ListRenderer(items: Array(list.children), isOrdered: true, codeBlock: codeBlock, fontSize: fontSize, fontFamily: fontFamily)
        case let list as UnorderedList:
            ListRenderer(items: Array(list.children), isOrdered: false, codeBlock: codeBlock, fontSize: fontSize, fontFamily: fontFamily)
        case let quote as BlockQuote:
            BlockQuoteRenderer(quote: quote, codeBlock: codeBlock, fontSize: fontSize, fontFamily: fontFamily)
        case is ThematicBreak:
            Divider()
        case let table as Markdown.Table:
            TableRenderer(table: table, fontSize: fontSize, fontFamily: fontFamily)
        default:
            if child.childCount > 0 {
                let children = Array(child.children)
                ForEach(Array(children.indices), id: \.self) { index in
                    BlockView(child: children[index], codeBlock: codeBlock, fontSize: fontSize, fontFamily: fontFamily)
                }
            }
        }
    }

    private func headingFontSize(_ level: Int) -> Double? {
        guard let base = fontSize else { return nil }
        let sizes: [Double] = [24, 20, 18, 16, 14, 12]
        let index = min(max(level, 1), 6) - 1
        return max(base, base + sizes[index] - 12)
    }
}

// MARK: - Inline Renderer

private struct InlineRenderer: View {
    let markup: Markup
    let fontSize: Double?
    let fontFamily: String?

    var body: some View {
        renderChildren(markup)
            .font(resolveBaseFont())
    }

    private func renderChildren(_ markup: Markup) -> SwiftUI.Text {
        markup.children.map(renderInline).reduce(into: SwiftUI.Text("")) { result, text in
            result = SwiftUI.Text("\(result)\(text)")
        }
    }

    private func renderInline(_ markup: Markup) -> SwiftUI.Text {
        switch markup {
        case let text as Markdown.Text:
            return SwiftUI.Text(text.string)
        case let emphasis as Emphasis:
            return renderChildren(emphasis).italic()
        case let strong as Strong:
            return renderChildren(strong).bold()
        case let strikethrough as Strikethrough:
            return renderChildren(strikethrough).strikethrough()
        case let code as InlineCode:
            return SwiftUI.Text(code.code)
                .font(.system(.body, design: .monospaced))
        case let link as Markdown.Link:
            return renderChildren(link)
                .foregroundColor(.blue)
                .underline()
        case let image as Markdown.Image:
            let alt = image.children.reduce("") { $0 + (($1 as? Markdown.Text)?.string ?? "") }
            return SwiftUI.Text("[\(alt)]")
                .foregroundColor(.secondary)
        case is SoftBreak:
            return SwiftUI.Text("\n")
        case is LineBreak:
            return SwiftUI.Text("\n")
        default:
            guard markup.childCount > 0 else { return SwiftUI.Text("") }
            return renderChildren(markup)
        }
    }

    private func resolveBaseFont() -> Font? {
        guard let fontSize else { return nil }
        if let fontFamily, let nsFont = NSFont(name: fontFamily, size: CGFloat(fontSize)) {
            return Font(nsFont)
        }
        return .system(size: CGFloat(fontSize))
    }
}

// MARK: - List

private struct ListRenderer<CodeBlockContent: View>: View {
    let items: [Markup]
    let isOrdered: Bool
    let codeBlock: (String, String?) -> CodeBlockContent
    let fontSize: Double?
    let fontFamily: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.indices), id: \.self) { index in
                if let item = items[index] as? ListItem {
                    HStack(alignment: .top, spacing: 6) {
                        let marker = isOrdered ? "\(index + 1)." : "\u{2022}"
                        SwiftUI.Text(marker)
                            .font(resolveBaseFont())
                        VStack(alignment: .leading, spacing: 4) {
                            let itemChildren = Array(item.children)
                            ForEach(Array(itemChildren.indices), id: \.self) { childIndex in
                                BlockView(child: itemChildren[childIndex], codeBlock: codeBlock, fontSize: fontSize, fontFamily: fontFamily)
                            }
                        }
                    }
                }
            }
        }
    }

    private func resolveBaseFont() -> Font? {
        guard let fontSize else { return nil }
        if let fontFamily, let nsFont = NSFont(name: fontFamily, size: CGFloat(fontSize)) {
            return Font(nsFont)
        }
        return .system(size: CGFloat(fontSize))
    }
}

// MARK: - Block Quote

private struct BlockQuoteRenderer<CodeBlockContent: View>: View {
    let quote: BlockQuote
    let codeBlock: (String, String?) -> CodeBlockContent
    let fontSize: Double?
    let fontFamily: String?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 3)
            LazyVStack(alignment: .leading, spacing: 6) {
                let children = Array(quote.children)
                ForEach(Array(children.indices), id: \.self) { index in
                    BlockView(child: children[index], codeBlock: codeBlock, fontSize: fontSize, fontFamily: fontFamily)
                }
            }
            .padding(.leading, 8)
        }
    }
}

// MARK: - Table

private struct TableRenderer: View {
    let table: Markdown.Table
    let fontSize: Double?
    let fontFamily: String?

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 4) {
            if table.head.childCount > 0 {
                GridRow {
                    let headChildren = Array(table.head.children)
                    ForEach(Array(headChildren.indices), id: \.self) { index in
                        if let cell = headChildren[index] as? Markdown.Table.Cell {
                            InlineRenderer(markup: cell, fontSize: fontSize, fontFamily: fontFamily)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity, alignment: alignment(at: index, table: table))
                        }
                    }
                }
                .padding(.bottom, 2)
            }

            let bodyChildren = Array(table.body.children)
            ForEach(Array(bodyChildren.indices), id: \.self) { rowIndex in
                if let row = bodyChildren[rowIndex] as? Markdown.Table.Row {
                    GridRow {
                        let rowChildren = Array(row.children)
                        ForEach(Array(rowChildren.indices), id: \.self) { colIndex in
                            if let cell = rowChildren[colIndex] as? Markdown.Table.Cell {
                                InlineRenderer(markup: cell, fontSize: fontSize, fontFamily: fontFamily)
                                    .frame(maxWidth: .infinity, alignment: alignment(at: colIndex, table: table))
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(AppConstants.Layout.cornerXs)
    }

    private func alignment(at index: Int, table: Markdown.Table) -> Alignment {
        guard index < table.columnAlignments.count else { return .leading }
        switch table.columnAlignments[index] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }
}
