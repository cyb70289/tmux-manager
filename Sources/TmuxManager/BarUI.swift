import AppKit
import TmuxManagerCore

/// One capsule in the bar: gray when the console is closed, green when it is open.
final class EntryButton: NSControl {
    private static let labelFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    /// Capsule labels are hard-capped: longer names are cut, never ellipsized.
    private static let labelCharLimit = 10
    private(set) var entry: Entry
    var isActive: Bool = false { didSet { applyState() } }
    var isBusy: Bool = false { didSet { applyState() } }

    var onOpen: ((Entry) -> Void)?
    var onReconnect: ((Entry) -> Void)?
    var onClose: ((Entry) -> Void)?
    var onEdit: ((Entry) -> Void)?
    var onRemove: ((Entry) -> Void)?

    private let title = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let reconnectButton = HighlightIconButton()
    private var hovered = false { didSet { applyState() } }
    private var tracking: NSTrackingArea?

    private let height: CGFloat = 26

    private var titleHeight: CGFloat {
        let font = title.font ?? Self.labelFont
        return ceil(font.ascender - font.descender + font.leading)
    }
    private let horizontalPadding: CGFloat = 11

    init(entry: Entry) {
        self.entry = entry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.borderWidth = 1

        title.font = Self.labelFont
        title.lineBreakMode = .byClipping
        title.textColor = NSColor.labelColor
        title.isEditable = false
        title.isBordered = false
        title.drawsBackground = false
        addSubview(title)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectClicked)
        reconnectButton.toolTip = "Force reconnect (ssh is restarted, the window stays)"
        addSubview(reconnectButton)

        toolTip = Self.tooltip(for: entry)
        applyState()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(entry: Entry) {
        self.entry = entry
        toolTip = Self.tooltip(for: entry)
        applyState()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private static func tooltip(for entry: Entry) -> String {
        entry.displayName == entry.address ? entry.address : "\(entry.displayName) — \(entry.address)"
    }

    // MARK: - Sizing

    /// Measured directly instead of via the label's intrinsic size, which is stale
    /// before the first layout pass.
    /// The name as shown on the capsule: at most `labelCharLimit` characters.
    private var labelText: String {
        String(entry.displayName.prefix(Self.labelCharLimit))
    }

    private var measuredTextWidth: CGFloat {
        let font = title.font ?? Self.labelFont
        return ceil((labelText as NSString).size(withAttributes: [.font: font]).width)
    }

    override var intrinsicContentSize: NSSize {
        var width = horizontalPadding * 2 + measuredTextWidth + 8
        if isActive { width += 22 }
        if isBusy { width += 18 }
        return NSSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        let centerY = bounds.midY
        let x = horizontalPadding
        let trailing = (isActive ? 22.0 : 0) + (isBusy ? 18.0 : 0)
        title.frame = NSRect(x: x, y: round(centerY - titleHeight / 2),
                             width: max(10, bounds.width - x - trailing - horizontalPadding),
                             height: titleHeight)
        var right = bounds.width - horizontalPadding
        if isActive {
            reconnectButton.frame = NSRect(x: right - 16, y: centerY - 8, width: 16, height: 16)
            right -= 22
        }
        if isBusy {
            spinner.frame = NSRect(x: right - 14, y: centerY - 7, width: 14, height: 14)
        }
    }

    // MARK: - State

    private func applyState() {
        title.stringValue = labelText
        if isActive {
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(hovered ? 0.38 : 0.26).cgColor
            layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovered ? 0.16 : 0.08).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        }
        reconnectButton.isHidden = !isActive
        if isBusy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        guard !isBusy else { return }
        NSApp.activate(ignoringOtherApps: true)
        onOpen?(entry)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let open = NSMenuItem(title: isActive ? "Activate Window" : "Open Console",
                              action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        open.isEnabled = !isBusy
        menu.addItem(open)

        let reconnect = NSMenuItem(title: "Force Reconnect", action: #selector(reconnectFromMenu),
                                   keyEquivalent: "")
        reconnect.target = self
        reconnect.isEnabled = isActive
        menu.addItem(reconnect)

        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Console", action: #selector(closeFromMenu), keyEquivalent: "")
        close.target = self
        close.isEnabled = isActive
        menu.addItem(close)
        menu.addItem(.separator())

        let edit = NSMenuItem(title: "Edit…", action: #selector(editFromMenu), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)

        let remove = NSMenuItem(title: "Remove…", action: #selector(removeFromMenu), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func openFromMenu() { onOpen?(entry) }
    @objc private func reconnectFromMenu() { onReconnect?(entry) }
    @objc private func closeFromMenu() { onClose?(entry) }
    @objc private func editFromMenu() { onEdit?(entry) }
    @objc private func removeFromMenu() { onRemove?(entry) }

    @objc private func reconnectClicked() {
        NSApp.activate(ignoringOtherApps: true)
        onReconnect?(entry)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// An icon-only button that grows its icon slightly on hover. The capsule it sits
/// in keeps its own hover state, so the background is left alone.
private final class HighlightIconButton: NSButton {
    private static let symbolName = "arrow.triangle.2.circlepath"

    private static func icon(pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: "Reconnect")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize,
                                                                 weight: .regular))
    }

    private var hovered = false {
        didSet { image = Self.icon(pointSize: hovered ? 15.5 : 13) }
    }
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        alignment = .center
        contentTintColor = .labelColor
        image = Self.icon(pointSize: 13)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidHide() {
        super.viewDidHide()
        hovered = false
    }
}

/// The floating bar itself.
final class BarView: NSVisualEffectView {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let addButton = PlusButton()
    private var entryButtons: [String: EntryButton] = [:]
    private weak var model: AppModel?

    var onAddRequested: (() -> Void)?

    private let barHeight: CGFloat = 44

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.maximumNumberOfLines = 1
        errorLabel.isHidden = true
        errorLabel.toolTip = "Click to dismiss"
        errorLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(dismissError)))

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add entry")
        addButton.isBordered = false
        addButton.bezelStyle = .inline
        addButton.imagePosition = .imageOnly
        addButton.contentTintColor = NSColor.labelColor
        addButton.toolTip = "Add host:session"
        addButton.target = self
        addButton.action = #selector(addClicked)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.documentView = stack
        addSubview(scrollView)

        reload()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var preferredHeight: CGFloat { barHeight }

    /// Rebuilds the row from the model.
    func reload() {
        guard let model else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var live: Set<String> = []

        if let message = model.errorMessage {
            errorLabel.stringValue = Self.shorten(message)
            errorLabel.toolTip = message + " (click to dismiss)"
            errorLabel.isHidden = false
            stack.addArrangedSubview(errorLabel)
        } else {
            errorLabel.isHidden = true
        }

        for entry in model.config.sortedEntries {
            let button: EntryButton
            if let existing = entryButtons[entry.id] {
                button = existing
                button.update(entry: entry)
            } else {
                button = EntryButton(entry: entry)
                button.onOpen = { [weak self] entry in self?.model?.open(entry) }
                button.onReconnect = { [weak self] entry in self?.model?.reconnect(entry) }
                button.onClose = { [weak self] entry in self?.model?.closeConsole(entry) }
                button.onEdit = { [weak self] entry in self?.editEntry(entry) }
                button.onRemove = { [weak self] entry in self?.removeEntry(entry) }
                entryButtons[entry.id] = button
            }
            button.isActive = model.isActive(entry)
            button.isBusy = model.isBusy(entry)
            live.insert(entry.id)
            stack.addArrangedSubview(button)
        }
        for (id, button) in entryButtons where !live.contains(id) {
            button.removeFromSuperview()
            entryButtons[id] = nil
        }

        stack.addArrangedSubview(addButton)
        needsLayout = true
        if Debug.enabled {
            let sizes = stack.arrangedSubviews.map { "\(type(of: $0))=\($0.intrinsicContentSize.width)" }
            Log.shared.write("bar content width=\(contentWidth) parts=\(sizes)")
        }
    }

    /// Height and width for the window: the content width, capped by `maxWidth`.
    func fittingBarSize(maxWidth: CGFloat) -> NSSize {
        NSSize(width: min(contentWidth, maxWidth), height: barHeight)
    }

    private var contentWidth: CGFloat {
        let insets = stack.edgeInsets
        let widths = stack.arrangedSubviews.map { ceil($0.intrinsicContentSize.width) }
        let gaps = CGFloat(max(0, widths.count - 1)) * stack.spacing
        return max(120, widths.reduce(0, +) + gaps + insets.left + insets.right)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = max(contentWidth, scrollView.contentSize.width)
        stack.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }

    private static func shorten(_ message: String, limit: Int = 58) -> String {
        message.count <= limit ? message : String(message.prefix(limit - 1)) + "…"
    }

    @objc private func addClicked() { onAddRequested?() }
    @objc private func dismissError() { model?.dismissError() }

    private func editEntry(_ entry: Entry) {
        guard let model, let window else { return }
        EntryEditor.present(entry: entry, model: model, near: window)
    }

    private func removeEntry(_ entry: Entry) {
        guard let model else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(entry.displayName)?"
        alert.informativeText = model.isActive(entry)
            ? "The console window for this entry will be closed. The tmux session itself is only killed if you tick the box below."
            : "This only removes the entry from the bar."
        let killBox = NSButton(checkboxWithTitle: "Also kill the remote tmux session (\(entry.session))",
                               target: nil, action: nil)
        killBox.state = .on
        alert.accessoryView = killBox
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.remove(entry, killRemoteSession: killBox.state == .on)
        }
    }
}

/// Square-ish hit target for the "+" control.
final class PlusButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }
}

final class BarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
