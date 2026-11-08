import AppKit
import TmuxManagerCore

/// Add / edit sheet.
final class EntryEditor {
    private static var active: EntryEditor?

    private let model: AppModel
    private let original: Entry?
    private var window: NSWindow!
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let sessionField = NSTextField()
    private let tmuxPathField = NSTextField()
    private let sshOptionsView = NSTextView()
    private let detachBox = NSButton(checkboxWithTitle: "Detach other clients on reconnect (-D)",
                                     target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var parent: NSWindow?

    private init(model: AppModel, entry: Entry?) {
        self.model = model
        self.original = entry
    }

    static func present(entry: Entry?, model: AppModel, on parent: NSWindow) {
        let editor = EntryEditor(model: model, entry: entry)
        editor.show(on: parent)
        active = editor
    }

    // MARK: - Building

    private func show(on parent: NSWindow) {
        self.parent = parent
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
                          styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.title = original == nil ? "Add Host:Session" : "Edit \(original!.displayName)"

        let content = NSView()
        window.contentView = content

        configureTextFields()

        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("SSH host"), hostField],
            [label("tmux session"), sessionField],
            [label("tmux path"), tmuxPathField],
            [label("Extra ssh options"), scrollView(for: sshOptionsView)],
            [NSGridCell.emptyContentView, detachBox],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 110
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline

        var hintText = "Leave Name empty to show host:session. Host may be an ~/.ssh/config alias or user@host."
        if let original, model.isActive(original) {
            hintText += " This console is open: host/session changes apply after a reconnect."
        }
        let hint = NSTextField(labelWithString: hintText)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 500

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 500
        statusLabel.stringValue = ""

        testButton.target = self
        testButton.action = #selector(runTest)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [testButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, hint, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        fill(from: original)
        window.defaultButtonCell = saveButton.cell as? NSButtonCell
        parent.beginSheet(window) { _ in
            EntryEditor.active = nil
        }
        window.makeFirstResponder(hostField)
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func configureTextFields() {
        hostField.placeholderString = "azure-japan or cyb@10.0.0.5"
        sessionField.placeholderString = "main"
        nameField.placeholderString = "host:session"
        tmuxPathField.placeholderString = "tmux"
        for field in [nameField, hostField, sessionField, tmuxPathField] {
            field.font = .systemFont(ofSize: 12)
            field.controlSize = .regular
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        }
    }

    private func scrollView(for textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 58).isActive = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 3, height: 3)
        scroll.documentView = textView
        return scroll
    }

    private func fill(from entry: Entry?) {
        guard let entry else {
            detachBox.state = .on
            return
        }
        nameField.stringValue = entry.name ?? ""
        hostField.stringValue = entry.host
        sessionField.stringValue = entry.session
        tmuxPathField.stringValue = entry.tmuxPath ?? ""
        sshOptionsView.string = entry.sshOptions.joined(separator: "\n")
        detachBox.state = entry.detachOtherClients ? .on : .off
    }

    // MARK: - Actions

    private func draft() -> Entry {
        var entry = original ?? Entry(host: "", session: "")
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.name = name.isEmpty ? nil : name
        entry.host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.session = sessionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmuxPath = tmuxPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.tmuxPath = tmuxPath.isEmpty ? nil : tmuxPath
        entry.sshOptions = sshOptionsView.string
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        entry.detachOtherClients = detachBox.state == .on
        return entry
    }

    @objc private func runTest() {
        let entry = draft()
        guard Validation.isValidHost(entry.host) else {
            statusLabel.stringValue = "Enter an SSH host first."
            statusLabel.textColor = .systemRed
            return
        }
        testButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Testing \(entry.host)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SSHProbe.check(host: entry.host, sshOptions: entry.sshOptions)
            DispatchQueue.main.async {
                self.testButton.isEnabled = true
                self.statusLabel.stringValue = result.summary
                switch result.kind {
                case .ok: self.statusLabel.textColor = .systemGreen
                case .tmuxMissing, .unverified: self.statusLabel.textColor = .systemOrange
                case .failed: self.statusLabel.textColor = .systemRed
                }
            }
        }
    }

    @objc private func save() {
        let entry = draft()
        let problems = EntryValidator.problems(for: entry, all:
            model.config.entries.filter { $0.id != entry.id } + [entry])
        if let message = EntryValidator.message(for: problems) {
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
            return
        }
        if original == nil {
            guard model.add(entry, thenProbe: true) else { return }
        } else {
            guard model.update(entry) else { return }
        }
        close()
    }

    @objc private func cancel() {
        close()
    }

    private func close() {
        guard let parent else { return }
        parent.endSheet(window)
    }
}
