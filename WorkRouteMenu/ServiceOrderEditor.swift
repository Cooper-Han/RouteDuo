import AppKit

/// 独立数据源保证排序界面不影响地址表格的拖动与编辑。
final class ServiceOrderEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Service {
        let id: String
        let name: String
        let status: String
        let enabled: Bool
    }
    private(set) var services: [Service]
    private let originalOrder: [String]
    var onOrderChanged: ((Bool) -> Void)?
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    private let table = RouteAddressTableView()
    private let dragType = NSPasteboard.PasteboardType("com.cooper.RouteDuo.service-order")

    init(services: [Service]) {
        self.services = services
        self.originalOrder = services.map { $0.id }
        super.init()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 30, width: 420, height: 250))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.masksToBounds = true
        table.frame = scroll.bounds
        table.style = .inset
        table.headerView = nil
        table.rowHeight = 36
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("service"))
        column.width = 390
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.registerForDraggedTypes([dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = table
        view.addSubview(scroll)
        let hint = NSTextField(labelWithString: "拖动行以调整顺序 · 取消不会更改系统设置")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 4, y: 4, width: 412, height: 18)
        view.addSubview(hint)
    }

    func updateStatuses(_ status: (Service) -> (String, Bool)) {
        let updated = services.map { item -> Service in
            let (state, enabled) = status(item)
            return Service(id: item.id, name: item.name, status: state, enabled: enabled)
        }
        guard zip(services, updated).contains(where: { $0.status != $1.status || $0.enabled != $1.enabled }) else { return }
        services = updated
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { services.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = services[row]
        let cell = NSTableCellView()
        let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动调整顺序")!)
        grip.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: item.name)
        title.font = .systemFont(ofSize: 13)
        title.textColor = item.enabled ? .labelColor : .secondaryLabelColor
        let state = NSTextField(labelWithString: "● " + item.status)
        state.font = .systemFont(ofSize: 11)
        state.textColor = item.status == "已连接" ? .systemGreen : (["待用", "设备已连接"].contains(item.status) ? .systemYellow : .secondaryLabelColor)
        title.lineBreakMode = .byTruncatingTail
        for child in [grip, title, state] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(child)
        }
        NSLayoutConstraint.activate([
            grip.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            grip.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: state.leadingAnchor, constant: -12),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            state.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            state.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            state.widthAnchor.constraint(equalToConstant: 92)
        ])
        cell.textField = title
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(services[row].id, forType: dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        tableView.setDropRow(min(max(row, 0), services.count), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === tableView,
              let id = info.draggingPasteboard.string(forType: dragType),
              let source = services.firstIndex(where: { $0.id == id }) else { return false }
        var destination = min(max(row, 0), services.count)
        let moved = services.remove(at: source)
        if source < destination { destination -= 1 }
        services.insert(moved, at: destination)
        onOrderChanged?(services.map { $0.id } != originalOrder)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        return true
    }
}
