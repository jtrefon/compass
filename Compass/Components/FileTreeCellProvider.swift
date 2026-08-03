import AppKit

@MainActor
final class FileTreeCellProvider {
    private let dataSource: FileTreeDataSource

    init(dataSource: FileTreeDataSource) {
        self.dataSource = dataSource
    }

    func cell(for item: FileTreeItem, outlineView: NSOutlineView,
              fontSize: Double, fontFamily: String) -> NSView? {
        let url = item.url
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView = outlineView.makeView(
            withIdentifier: identifier,
            owner: nil
        ) as? NSTableCellView ?? {
            let cell = NSTableCellView(frame: .zero)
            cell.identifier = identifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            textField.font = NSFont(
                name: fontFamily,
                size: CGFloat(fontSize)
            ) ?? NSFont.systemFont(
                ofSize: CGFloat(fontSize),
                weight: .regular
            )

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.textField = textField
            cell.imageView = imageView

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            return cell
        }()

        cell.textField?.stringValue = (url as URL).lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: (url as URL).path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        cell.textField?.textColor = fileLabelColor(for: url) ?? .labelColor

        return cell
    }

    private func fileLabelColor(for url: NSURL) -> NSColor? {
        guard let labelNumber = try? (url as URL).resourceValues(forKeys: [.labelNumberKey]).labelNumber,
              labelNumber > 0 else { return nil }
        let colors = NSWorkspace.shared.fileLabelColors
        let index = labelNumber - 1
        guard index >= 0, index < colors.count else { return nil }
        return colors[index]
    }
}
