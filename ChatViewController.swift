import UIKit

final class ChatViewController: UIViewController, UITableViewDataSource, UITextViewDelegate {
    private var messages: [ChatMessage] = []
    private let client = ClaudeClient()
    private var streaming = false
    private var renderPending = false

    private let table = UITableView(frame: .zero, style: .plain)
    private let bar = UIView()
    private let input = UITextView()
    private let sendButton = UIButton(type: .system)
    private var barBottom: NSLayoutConstraint!
    private var inputHeight: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Claude"
        view.backgroundColor = .appBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "New", style: .plain, target: self, action: #selector(newChat))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Key", style: .plain, target: self, action: #selector(askKey))
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if Keychain.load() == nil { askKey() }
    }

    // MARK: UI

    private func buildUI() {
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.allowsSelection = false
        table.keyboardDismissMode = .interactive
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 60
        table.register(BubbleCell.self, forCellReuseIdentifier: BubbleCell.id)

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = .appBar

        input.translatesAutoresizingMaskIntoConstraints = false
        input.font = .preferredFont(forTextStyle: .body)
        input.delegate = self
        input.layer.cornerRadius = 10
        input.backgroundColor = .appBackground
        input.textColor = .appText
        input.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        view.addSubview(table); view.addSubview(bar)
        bar.addSubview(input); bar.addSubview(sendButton)

        barBottom = bar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        inputHeight = input.heightAnchor.constraint(equalToConstant: 40)
        let g = view.safeAreaLayoutGuide
        let bg = bar.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: g.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barBottom,

            input.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
            input.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -8),
            input.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            input.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            inputHeight,

            sendButton.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: input.bottomAnchor, constant: -4)
        ])
    }

    @objc private func keyboardChanged(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let dur = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let overlap = max(0, view.bounds.height - view.convert(end, from: nil).minY)
        barBottom.constant = -overlap
        UIView.animate(withDuration: dur) { self.view.layoutIfNeeded() }
        scrollToBottom()
    }

    func textViewDidChange(_ tv: UITextView) { resizeInput() }

    private func resizeInput() {
        guard input.bounds.width > 0 else { return }
        let h = input.sizeThatFits(CGSize(width: input.bounds.width, height: .greatestFiniteMagnitude)).height
        let clamped = min(max(h, 40), 120)
        if inputHeight.constant != clamped { inputHeight.constant = clamped; view.layoutIfNeeded() }
    }

    // MARK: Table

    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }

    func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: BubbleCell.id, for: ip) as! BubbleCell
        let m = messages[ip.row]
        cell.configure(text: m.text, isUser: m.role == "user")
        return cell
    }

    private func scrollToBottom() {
        guard !messages.isEmpty else { return }
        table.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: false)
    }

    private func nearBottom() -> Bool {
        table.contentOffset.y + table.bounds.height >= table.contentSize.height - 80
    }

    // MARK: Actions

    @objc private func sendTapped() {
        if streaming { client.cancel(); finish(nil); return }
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let key = Keychain.load(), !key.isEmpty else { askKey(); return }

        input.text = ""; resizeInput()
        messages.append(ChatMessage(role: "user", text: text))
        messages.append(ChatMessage(role: "assistant", text: ""))
        let n = messages.count
        table.insertRows(at: [IndexPath(row: n - 2, section: 0), IndexPath(row: n - 1, section: 0)], with: .none)
        scrollToBottom()
        setStreaming(true)

        // cap history (bounds payload + latency); must start with a user turn
        var history = Array(messages.dropLast().suffix(20))
        while history.first?.role == "assistant" { history.removeFirst() }

        client.send(messages: history, apiKey: key,
                    onDelta: { [weak self] chunk in self?.appendChunk(chunk) },
                    onDone: { [weak self] err in self?.finish(err) })
    }

    private func appendChunk(_ s: String) {
        messages[messages.count - 1].text += s
        guard !renderPending else { return }
        renderPending = true
        // coalesce UI updates (~25 fps) = smooth, low CPU
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.renderPending = false
            self?.renderLast()
        }
    }

    private func renderLast() {
        guard let last = messages.last else { return }
        let ip = IndexPath(row: messages.count - 1, section: 0)
        let stick = nearBottom()
        if let cell = table.cellForRow(at: ip) as? BubbleCell {
            cell.setText(last.text)
            UIView.performWithoutAnimation { table.beginUpdates(); table.endUpdates() }
        }
        if stick { scrollToBottom() }
    }

    private func finish(_ error: Error?) {
        renderLast()
        setStreaming(false)
        if messages.last?.role == "assistant", messages.last?.text.isEmpty == true {
            messages.removeLast()
            if let u = messages.popLast() { input.text = u.text; resizeInput() }
            table.reloadData()
        }
        if let e = error {
            let a = UIAlertController(title: "Error", message: e.localizedDescription, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
        }
    }

    private func setStreaming(_ on: Bool) {
        streaming = on
        sendButton.setTitle(on ? "Stop" : "Send", for: .normal)
    }

    @objc private func newChat() {
        client.cancel(); setStreaming(false)
        messages.removeAll(); table.reloadData()
    }

    @objc private func askKey() {
        let a = UIAlertController(title: "Anthropic API key", message: "Stored in Keychain on this device.", preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = "sk-ant-..."
            tf.isSecureTextEntry = true
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        a.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            let k = a.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !k.isEmpty { Keychain.save(k) }
        })
        a.addAction(UIAlertAction(title: "Delete key", style: .destructive) { _ in Keychain.delete() })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(a, animated: true)
    }
}

// MARK: Cell

final class BubbleCell: UITableViewCell {
    static let id = "BubbleCell"
    private let bubble = UIView()
    private let label = UILabel()
    private var botSide: NSLayoutConstraint!
    private var userSide: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 16
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        contentView.addSubview(bubble)
        bubble.addSubview(label)
        botSide = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        userSide = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.85),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(text: String, isUser: Bool) {
        setText(text)
        label.textColor = isUser ? .white : .appText
        bubble.backgroundColor = isUser ? .appUser : .appBot
        botSide.isActive = !isUser
        userSide.isActive = isUser
    }

    func setText(_ t: String) { label.text = t.isEmpty ? "…" : t }
}

// MARK: Colors (iOS 12 safe, dark mode on 13+)

extension UIColor {
    static var appBackground: UIColor { if #available(iOS 13.0, *) { return .systemBackground }; return .white }
    static var appBar: UIColor { if #available(iOS 13.0, *) { return .secondarySystemBackground }; return UIColor(white: 0.95, alpha: 1) }
    static var appBot: UIColor { if #available(iOS 13.0, *) { return .secondarySystemBackground }; return UIColor(white: 0.92, alpha: 1) }
    static var appText: UIColor { if #available(iOS 13.0, *) { return .label }; return .black }
    static var appUser: UIColor { UIColor(red: 0, green: 0.478, blue: 1, alpha: 1) }
}
