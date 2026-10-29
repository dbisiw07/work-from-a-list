// Work from a List — a floating list of what you're working on today (up to 25 items).
//
// Each morning (5 am by default, before an early start) done tasks clear
// and unfinished ones carry over, urgent flags included. There is no ticking timer: the
// app sleeps until you touch the list, plus one wake-up a day for the reset.

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Storage

struct Item: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    /// Must be done today. At most `Store.maxUrgent` open tasks at a time.
    var urgent = false

    init(text: String) { self.text = text }

    // Lists saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        urgent = try c.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
    }
}

/// Override the reset time with `defaults write io.github.dbisiw07.work-from-a-list resetHour -int 5`.
enum Store {
    static let maxItems = 25
    /// Urgent only means something if it's rare, so only a few at once (a WIP limit).
    static let maxUrgent = 3
    /// Past this many items the list scrolls instead of growing down the screen.
    static let visibleRows = 10

    static var resetHour: Int {
        let d = UserDefaults.standard
        return d.object(forKey: "resetHour") == nil ? 5 : d.integer(forKey: "resetHour")
    }

    /// Today's list: ~/Library/Application Support/WorkFromAList/today.json
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkFromAList/today.json")
    }

    /// The list's day: before the reset hour it still belongs to yesterday. Goes by
    /// the clock hour, not "6 hours ago", so daylight saving days reset on time too.
    static func day(_ now: Date = Date()) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        guard cal.component(.hour, from: now) < resetHour else { return start }
        return cal.date(byAdding: .day, value: -1, to: start) ?? start
    }

    static func dayKey(_ now: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day(now))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func nextReset(after now: Date) -> Date {
        Calendar.current.nextDate(after: now, matching: DateComponents(hour: resetHour, minute: 0, second: 0),
                                  matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
    }

    /// `now` is the item you're working on right now, if any.
    struct File: Codable {
        var day: String
        var items: [Item]
        var now: UUID?
        /// When you started on it.
        var nowSince: Date?
    }

    static func load() -> File {
        (try? Data(contentsOf: url)).flatMap(file(from:)) ?? File(day: dayKey(), items: [])
    }

    /// The list in `data`, or nil if it isn't a list (say, half-written by another app).
    static func file(from data: Data) -> File? {
        guard var file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        // Another app may have copied a task; every row needs its own id.
        var seen = Set<UUID>()
        for i in file.items.indices where !seen.insert(file.items[i].id).inserted { file.items[i].id = UUID() }
        // A list from an earlier day: unfinished tasks carry over with their urgent
        // flags; done ones and the "now" pin clear.
        guard file.day == dayKey() else { return File(day: dayKey(), items: carryOver(file.items)) }
        // Kept in the order you left it, including anything you dragged.
        return File(day: file.day, items: Array(file.items.prefix(maxItems)),
                    now: file.now, nowSince: file.nowSince)
    }

    /// What the HUD last wrote or read, so it can tell its own saves from another app's.
    static var lastWritten: Data?

    /// What a new day starts with: yesterday's unfinished tasks, in order, still urgent if they were.
    static func carryOver(_ items: [Item]) -> [Item] {
        Array(items.filter { !$0.done }.prefix(maxItems))
    }

    static func save(_ items: [Item], now: UUID?, since: Date?) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(File(day: dayKey(), items: items, now: now, nowSince: since))
            lastWritten = data
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Work from a List: couldn't save list: \(error)")
        }
    }
}

/// Calls back when today.json changes on disk. Watches the folder, which sees saves
/// that replace the file, and the file itself, which sees writes in place.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var folder: DispatchSourceFileSystemObject?
    private var file: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        folder = watch(url.deletingLastPathComponent().path, [.write])
        file = watch(url.path, [.write, .extend, .delete, .rename])
    }

    private func watch(_ path: String, _ events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func changed() {
        // A save swaps in a new file, so follow whichever file is there now.
        file?.cancel()
        file = watch(url.path, [.write, .extend, .delete, .rename])
        // One reload per burst of writes.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

/// The flash under the list: one of your mantras, changed with each 25-minute focus
/// block. Edit them in ~/Library/Application Support/WorkFromAList/mantras.txt, one per line.
enum Mantras {
    static var url: URL { Store.url.deletingLastPathComponent().appendingPathComponent("mantras.txt") }

    static let starters = [
        "Every day try some hypothesis on something",
        "What will change for the user when it's done?",
        "What are the core primitives?",
        "Service to God is the main reason we are here",
        "Write down your goals now",
        "Know the algorithm and then apply it",
        "Cold call and sell",
        "Be comfortable with doing it without knowing all the details",
        "Get clarity of everything",
    ]

    /// What the HUD last wrote or read, so it can tell its own saves from yours.
    static var lastText: String?

    /// Your mantras; blank lines and lines starting with # are skipped.
    static func load() -> [String] {
        if !FileManager.default.fileExists(atPath: url.path) { save(starters) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return starters }
        lastText = text
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// True if the file holds something the HUD didn't write.
    static var changedOnDisk: Bool { (try? String(contentsOf: url, encoding: .utf8)) != lastText }

    static func save(_ list: [String]) {
        let lines = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let text = "# One mantra per line. Work from a List shows a new one with each 25-minute focus block.\n"
            + lines.map { $0 + "\n" }.joined()
        lastText = text
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Work from a List: couldn't save mantras: \(error)")
        }
    }

    /// Same blocks as Focus HUD (25 minutes from 6:00 unless you changed its settings),
    /// so a new mantra arrives with a new block.
    private static var schedule: (start: Int, chunk: Int) {
        let focus = UserDefaults(suiteName: "local.focus-hud")
        let start = focus?.object(forKey: "startHour") as? Int ?? 6
        let minutes = focus?.object(forKey: "chunkMinutes") as? Int ?? 25
        return (start * 3600, max(1, minutes) * 60)
    }

    private static func block(_ now: Date) -> Int {
        let seconds = Int(now.timeIntervalSince(Calendar.current.startOfDay(for: now))) - schedule.start
        return Int((Double(seconds) / Double(schedule.chunk)).rounded(.down))
    }

    static func nextChange(after now: Date) -> Date {
        let start = Calendar.current.startOfDay(for: now)
        let next = (block(now) + 1) * schedule.chunk + schedule.start
        return start.addingTimeInterval(TimeInterval(next))
    }

    /// Which of `count` mantras this block shows. Each day gets its own shuffle,
    /// and none repeats until all have shown.
    static func pick(of count: Int, at now: Date = Date()) -> Int? {
        guard count > 0 else { return nil }
        var rng = SplitMix(seed: Store.dayKey(now).utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 })
        let order = Array(0..<count).shuffled(using: &rng)
        let n = block(now) % count
        return order[n < 0 ? n + count : n]
    }

    /// A seeded generator, so the order stays put when the app restarts.
    struct SplitMix: RandomNumberGenerator {
        var seed: UInt64
        mutating func next() -> UInt64 {
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}

// MARK: - Model

final class TodayModel: ObservableObject {
    @Published private(set) var items: [Item] = Store.load().items {
        didSet { scheduleSave() }
    }
    /// The one item you're working on right now (like Linear's In Progress).
    @Published private(set) var nowId: UUID? = Store.load().now {
        didSet {
            if nowId != oldValue { nowSince = nowId == nil ? nil : Date() }
            scheduleSave()
        }
    }
    /// When you pinned the current "now" item, for the quiet "· 40m".
    private(set) var nowSince: Date? = Store.load().nowSince ?? (Store.load().now == nil ? nil : Date())
    @Published var draft = ""
    @Published var hover = false
    @Published var hoveredRow: UUID?
    /// True while the HUD holds the keyboard (you clicked into a text field).
    @Published var editing = false
    /// Briefly true when the last item gets checked off.
    @Published private(set) var allDoneGlow = false
    @Published var scale: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "scale")
        return saved > 0 ? saved : 1
    }() {
        didSet { UserDefaults.standard.set(Double(scale), forKey: "scale") }
    }
    static let scaleRange: ClosedRange<CGFloat> = 0.7...2.5
    /// The card's width before scaling; drag the right edge to change it.
    @Published var width: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "width")
        return saved > 0 ? saved : 300
    }() {
        didSet { UserDefaults.standard.set(Double(width), forKey: "width") }
    }
    static let widthRange: ClosedRange<CGFloat> = 240...600
    @Published var theme = Theme.choice {
        didSet {
            Theme.choice = theme
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
        }
    }
    /// Where the resize grip is, in the hosting view's top-left coordinates.
    var gripRect: CGRect = .zero
    /// Where each row and the visible list are, same coordinates; used to drag rows.
    var rowFrames: [UUID: CGRect] = [:]
    var listRect: CGRect = .zero
    /// The row being dragged to a new place.
    @Published var draggingId: UUID?
    /// The last item you removed, offered back for a few seconds.
    struct Removed { let item: Item; let index: Int; let wasNow: Bool; let since: Date? }
    @Published private(set) var removed: Removed?
    private var undoWork: DispatchWorkItem?
    /// The item just checked off, so its row plays the strike once.
    private var justChecked: UUID?
    var onFinishEditing: (() -> Void)?
    var onHide: (() -> Void)?
    /// Lets the HUD take the keyboard for a click that isn't on a text field.
    var onTakeKeyboard: (() -> Void)?
    var onManageMantras: (() -> Void)?
    var soundOn: Bool {
        get { UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundOn") }
    }
    private var day = Store.dayKey()
    private var saveWork: DispatchWorkItem?
    private var resetTimer: Timer?
    private var watcher: FileWatcher?
    struct Mantra: Identifiable, Equatable { let id = UUID(); var text: String }
    @Published private(set) var mantras: [Mantra] = []
    /// The mantra under the list, if mantras are on.
    @Published private(set) var mantra: String?
    private var mantraId: UUID?
    /// A mantra you chose to keep on show until `heldUntil`, instead of the rotation.
    @Published private(set) var heldMantra = UserDefaults.standard.string(forKey: "heldMantra")
    @Published private(set) var heldUntil = UserDefaults.standard.object(forKey: "heldUntil") as? Date
    /// How long you can keep one; nil is the rest of today (until the morning reset).
    static let holdChoices: [(label: String, minutes: Int?)] = [
        ("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120), ("4 Hours", 240), ("Rest of Today", nil),
    ]
    private var mantraSave: DispatchWorkItem?
    private var mantraTimer: Timer?
    private var mantraWatcher: FileWatcher?
    /// The header's words, yours to change in the Mantras window. Empty hides a line.
    /// `**word**` makes a word heavy.
    static let headerDefaults = [
        "tagline": "make it delightful",
        "subtitle": "**Urgency** and **Hardworking** is how you win",
        "motto": "Do it by hand a few times, feel it, simplify, then build",
    ]
    @Published var tagline = TodayModel.headerLine("tagline") { didSet { save("tagline", tagline) } }
    @Published var subtitle = TodayModel.headerLine("subtitle") { didSet { save("subtitle", subtitle) } }
    @Published var motto = TodayModel.headerLine("motto") { didSet { save("motto", motto) } }
    private static func headerLine(_ key: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? headerDefaults[key] ?? ""
    }
    private func save(_ key: String, _ value: String) { UserDefaults.standard.set(value, forKey: key) }
    func resetHeader() {
        tagline = Self.headerDefaults["tagline"]!
        subtitle = Self.headerDefaults["subtitle"]!
        motto = Self.headerDefaults["motto"]!
    }

    var mantrasOn: Bool {
        get { UserDefaults.standard.object(forKey: "mantrasOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mantrasOn"); showMantra() }
    }

    var doneCount: Int { items.filter(\.done).count }
    var isFull: Bool { items.count >= Store.maxItems }
    var allDone: Bool { !items.isEmpty && doneCount == items.count }
    var nowItem: Item? { items.first { $0.id == nowId && !$0.done } }
    var urgentCount: Int { items.filter { $0.urgent && !$0.done }.count }
    var canMarkUrgent: Bool { urgentCount < Store.maxUrgent }

    /// Where an item belongs: urgent at the top, then other open tasks, then done
    /// (newly finished ones at the top of the done group).
    private func slot(for item: Item) -> Int { Self.slot(for: item, in: items) }

    static func slot(for item: Item, in items: [Item]) -> Int {
        if item.done { return items.firstIndex(where: \.done) ?? items.count }
        if item.urgent { return items.firstIndex(where: { !$0.urgent || $0.done }) ?? items.count }
        return items.firstIndex(where: \.done) ?? items.count
    }

    func start() {
        Store.save(items, now: nowItem?.id, since: nowSince)  // replaces yesterday's file right away if the day has turned
        scheduleReset()
        watcher = FileWatcher(url: Store.url) { [weak self] in self?.reloadIfChanged() }
        mantras = Mantras.load().map { Mantra(text: $0) }
        mantraWatcher = FileWatcher(url: Mantras.url) { [weak self] in
            guard let self, Mantras.changedOnDisk else { return }  // our own save
            self.mantras = Mantras.load().map { Mantra(text: $0) }
            self.showMantra()
        }
        showMantra()
        // A timer doesn't fire while the Mac sleeps, so also check on wake and clock changes.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.checkDay() }
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.checkDay()
            }
        }
    }

    /// Starts the new day once the reset hour has passed: done tasks clear,
    /// unfinished ones stay.
    func checkDay() {
        let key = Store.dayKey()
        if key != day {
            day = key
            onFinishEditing?()
            draft = ""
            items = Store.carryOver(items)
            nowId = nil  // each morning you choose what to start on
            removed = nil
        }
        scheduleReset()
        showMantra()
    }

    /// Shows this block's mantra and wakes up for the next block.
    func showMantra() {
        let now = Date()
        let shown = mantras.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        var pick = mantrasOn ? Mantras.pick(of: shown.count).map { shown[$0] } : nil
        var next = Mantras.nextChange(after: now)
        if let held = heldMantra {
            if let until = heldUntil, until > now, let m = shown.first(where: { $0.text == held }) {
                if mantrasOn { pick = m }
                next = min(next, until)
            } else {
                setHold(nil, until: nil)  // its time is up, or it was deleted
            }
        }
        mantraId = pick?.id
        if pick?.text != mantra {
            withAnimation(.easeInOut(duration: 0.6)) { mantra = pick?.text }
        }
        mantraTimer?.invalidate()
        guard mantrasOn else { return }
        let t = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) {
            [weak self] _ in self?.showMantra()
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        mantraTimer = t
    }

    /// Picks up a change another app or script made to today.json.
    func reloadIfChanged() {
        guard let data = try? Data(contentsOf: Store.url), data != Store.lastWritten else { return }  // gone, or our own save
        guard var file = Store.file(from: data) else {
            // Half-written: the rest is likely on its way. If it's still broken in a
            // second, put back the list the HUD has, so a restart doesn't start empty.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let now = try? Data(contentsOf: Store.url), Store.file(from: now) == nil else { return }
                Store.save(self.items, now: self.nowItem?.id, since: self.nowSince)
            }
            return
        }
        Store.lastWritten = data
        // Keep what you're typing into a task; take everything else from the file.
        if editing {
            var typed: [UUID: String] = [:]
            for item in items { typed[item.id] = item.text }
            for i in file.items.indices { file.items[i].text = typed[file.items[i].id] ?? file.items[i].text }
        }
        day = Store.dayKey()
        undoWork?.cancel()
        removed = nil
        let since = file.now == nowId ? nowSince : nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            nowId = file.now
            nowSince = file.now == nil ? nil : file.nowSince ?? since ?? Date()
            items = file.items
        }
    }

    /// Keeps `text` on show for `minutes`, or for the rest of today when nil.
    func hold(_ text: String, minutes: Int?) {
        let now = Date()
        let until = minutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) } ?? Store.nextReset(after: now)
        setHold(text, until: until)
        showMantra()
    }

    /// Back to a new mantra every 25 minutes.
    func releaseHold() {
        setHold(nil, until: nil)
        showMantra()
    }

    private func setHold(_ text: String?, until: Date?) {
        heldMantra = text
        heldUntil = until
        UserDefaults.standard.set(text, forKey: "heldMantra")
        UserDefaults.standard.set(until, forKey: "heldUntil")
    }

    /// "until 3:40 PM", or "until tomorrow" for the rest of today.
    var heldUntilLabel: String {
        guard let until = heldUntil else { return "" }
        if until >= Store.nextReset(after: Date()).addingTimeInterval(-60) { return "for the rest of today" }
        return "until " + until.formatted(date: .omitted, time: .shortened)
    }

    // Managing mantras. Adding or removing one doesn't swap out the one on show.

    func addMantra(_ text: String) {
        let text = Self.oneLine(text).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        mantras.append(Mantra(text: text))
        mantrasChanged()
    }

    func setMantra(_ id: UUID, _ text: String) {
        guard let i = mantras.firstIndex(where: { $0.id == id }) else { return }
        let new = Self.oneLine(text)
        if mantras[i].text == heldMantra { setHold(new, until: heldUntil) }  // keep holding it as you edit
        mantras[i].text = new
        mantrasChanged()
    }

    func deleteMantra(_ id: UUID) {
        mantras.removeAll { $0.id == id }
        mantrasChanged()
    }

    private func mantrasChanged() {
        if let id = mantraId, let m = mantras.first(where: { $0.id == id }),
           !m.text.trimmingCharacters(in: .whitespaces).isEmpty {
            mantra = m.text  // you edited the one on show
        } else {
            showMantra()
        }
        mantraSave?.cancel()
        let list = mantras.map(\.text)
        let work = DispatchWorkItem { Mantras.save(list) }
        mantraSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushMantras() { mantraSave?.perform(); mantraSave = nil }

    private func scheduleReset() {
        resetTimer?.invalidate()
        let t = Timer(fire: Store.nextReset(after: Date()).addingTimeInterval(1), interval: 0, repeats: false) {
            [weak self] _ in self?.checkDay()
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        resetTimer = t
    }

    /// Writes shortly after the last change, so typing doesn't hit the disk per keystroke.
    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = items, now = nowId, since = nowSince
        let work = DispatchWorkItem { Store.save(snapshot, now: now, since: since) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushSave() {
        saveWork?.perform()
        saveWork = nil
    }

    /// A task is one line; pasted line breaks become spaces.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    func add() {
        let text = Self.oneLine(draft).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isFull else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { items.append(Item(text: text)) }
        draft = ""
    }

    func text(_ id: UUID) -> String { items.first { $0.id == id }?.text ?? "" }

    func setText(_ id: UUID, _ text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].text = Self.oneLine(text)
    }

    /// An item edited down to nothing is removed.
    func commit(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let text = items[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { remove(id, undoable: false) } else { items[i].text = text }
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if !items[i].done { justChecked = id }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            var item = items.remove(at: i)
            item.done.toggle()
            if item.done, nowId == id { nowId = nil }  // finishing it ends "now"
            // Reopening can't push urgent past the limit.
            if !item.done, item.urgent, !canMarkUrgent { item.urgent = false }
            // Like Linear's status groups: open tasks on top, done ones below.
            items.insert(item, at: slot(for: item))
        }
        if allDone { celebrate() }
    }

    /// True once, right after the item was checked off.
    func takeJustChecked(_ id: UUID) -> Bool {
        guard justChecked == id else { return false }
        justChecked = nil
        return true
    }

    func row(at point: CGPoint) -> UUID? {
        guard listRect.contains(point) else { return nil }
        return items.first { rowFrames[$0.id]?.contains(point) == true }?.id
    }

    /// Moves the dragged item into the slot of the row under the cursor.
    func drag(to point: CGPoint) {
        guard let id = draggingId, let from = items.firstIndex(where: { $0.id == id }),
              let target = row(at: point), target != id,
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            items.insert(items.remove(at: from), at: to)
        }
    }

    /// Flags a task as must-do-today and moves it up with the other urgent ones.
    func toggleUrgent(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].done else { return }
        guard items[i].urgent || canMarkUrgent else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            var item = items.remove(at: i)
            item.urgent.toggle()
            items.insert(item, at: slot(for: item))
        }
    }

    /// Marks an item as the one you're working on now; there's only ever one.
    /// Tapping the current one again clears it.
    func setNow(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) { nowId = nowId == id ? nil : id }
    }

    func remove(_ id: UUID, undoable: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if undoable { removed = Removed(item: items[i], index: i, wasNow: nowId == id, since: nowSince) }
            items.remove(at: i)
        }
        rowFrames[id] = nil
        if hoveredRow == id { hoveredRow = nil }
        if nowId == id { nowId = nil }
        guard undoable else { return }
        undoWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.removed = nil }
        }
        undoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Puts the last removed item back where it was.
    func undoRemove() {
        guard let r = removed, !isFull else { return }
        undoWork?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            var item = r.item
            if item.urgent, !item.done, !canMarkUrgent { item.urgent = false }
            items.insert(item, at: min(r.index, items.count))
            if r.wasNow {
                nowId = r.item.id
                nowSince = r.since
            }
            removed = nil
        }
    }

    func clearDone() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            items.removeAll(where: \.done)
            removed = nil
        }
    }

    private func celebrate() {
        if soundOn { NSSound(named: "Glass")?.play() }
        withAnimation(.easeOut(duration: 0.3)) { allDoneGlow = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            withAnimation(.easeInOut(duration: 0.5)) { self?.allDoneGlow = false }
        }
    }
}

// MARK: - Views

/// Solid color themes. Opaque on purpose: the list stands out and reads the
/// same on any wallpaper, in light or dark mode, and skips a live blur.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case paper, teal, midnight, indigo, forest, plum, graphite
    var id: Self { self }

    var label: String { rawValue.capitalized }
    var isLight: Bool { self == .paper }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    /// Top and bottom of the card's gentle gradient.
    var card: [Color] {
        switch self {
        case .teal: return [Self.rgb(0.05, 0.38, 0.40), Self.rgb(0.02, 0.25, 0.27)]
        case .midnight: return [Self.rgb(0.09, 0.16, 0.36), Self.rgb(0.05, 0.09, 0.22)]
        case .indigo: return [Self.rgb(0.29, 0.19, 0.58), Self.rgb(0.18, 0.11, 0.40)]
        case .forest: return [Self.rgb(0.09, 0.32, 0.20), Self.rgb(0.04, 0.20, 0.12)]
        case .plum: return [Self.rgb(0.45, 0.12, 0.27), Self.rgb(0.29, 0.06, 0.17)]
        case .graphite: return [Color(white: 0.13), Color(white: 0.06)]
        case .paper: return [.white, Self.rgb(0.97, 0.97, 0.96)]
        }
    }

    var text: Color { isLight ? Self.rgb(0.09, 0.11, 0.18) : .white }  // ink on paper

    /// Paper is a ruled notebook page: blue lines under each item, a red margin.
    var ruled: Bool { self == .paper }
    var rule: Color { ruled ? Self.rgb(0.55, 0.72, 0.93) : text.opacity(0.22) }
    var margin: Color { Self.rgb(0.93, 0.42, 0.42) }

    /// The add line and caret; picked to pop against each card.
    var accent: Color {
        switch self {
        case .teal, .midnight, .forest: return Self.rgb(1.00, 0.86, 0.45)  // warm yellow
        case .indigo, .plum: return Self.rgb(1.00, 0.78, 0.60)  // peach
        case .graphite: return Self.rgb(0.45, 0.80, 1.00)  // sky blue
        case .paper: return Self.rgb(0.15, 0.38, 0.90)  // blue ink
        }
    }

    var green: Color { isLight ? Self.rgb(0.10, 0.55, 0.28) : Self.rgb(0.62, 1.00, 0.72) }
    /// Urgent, like Linear's orange.
    var urgent: Color { isLight ? Self.rgb(0.93, 0.42, 0.08) : Self.rgb(1.00, 0.62, 0.30) }
    /// In progress is a quiet gray; green stays for done.
    var progress: Color { isLight ? Self.rgb(0.42, 0.44, 0.50) : Color(white: 0.78) }

    static var saved: ThemeChoice {
        ThemeChoice(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .paper
    }
}

enum Theme {
    static var choice = ThemeChoice.saved
    static var card: [Color] { choice.card }
    static var text: Color { choice.text }
    static var dim: Color { choice.text.opacity(choice.isLight ? 0.65 : 0.72) }
    static var faint: Color { choice.text.opacity(choice.isLight ? 0.42 : 0.5) }
    static var accent: Color { choice.accent }
    static var green: Color { choice.green }
    static var progress: Color { choice.progress }
    static var urgent: Color { choice.urgent }
    /// The check inside a done circle: white on Paper's green, card-dark on the mint.
    static var checkMark: Color { choice.isLight ? .white : choice.card[1] }
    static var rule: Color { choice.rule }

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size, weight: bold ? .bold : .medium, design: .rounded)
    }
}

struct TodayView: View {
    @ObservedObject var model: TodayModel

    private var s: CGFloat { model.scale }
    private var radius: CGFloat { 16 * s }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            header
            // A thin rule under the heading.
            Capsule().fill(Theme.rule).frame(height: 1.5 * s)
            // The page: items and the add line, with a notebook margin on Paper
            // between the checkboxes and the writing.
            VStack(alignment: .leading, spacing: 8 * s) {
                if model.items.count > Store.visibleRows {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) { rows }
                            .frame(height: CGFloat(Store.visibleRows) * ItemRow.height(s))
                            // Only the rows in view can be dropped on.
                            .background(FrameReporter { model.listRect = $0 })
                            // A newly added item scrolls into view; removing one elsewhere doesn't jump.
                            .onChange(of: model.items.last?.id) { last in
                                if let last { proxy.scrollTo(last, anchor: .bottom) }
                            }
                    }
                } else if !model.items.isEmpty {
                    rows
                }
                if model.isFull {
                    Text("That's 25 — plenty for one day.")
                        .font(Theme.font(12 * s))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 6 * s)
                        .padding(.top, 2 * s)
                } else {
                    AddField(model: model, scale: s)
                }
            }
            .background(alignment: .leading) {
                if Theme.choice.ruled {
                    Rectangle().fill(Theme.choice.margin.opacity(0.55))
                        .frame(width: 1.5 * s)
                        .padding(.leading, 29 * s)
                }
            }
            if let mantra = model.mantra {
                HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
                    Text("✦").foregroundStyle(Theme.dim)
                    Text(mantra).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.font(12 * s))
                .padding(.horizontal, 6 * s)
                .padding(.top, 10 * s)
                .id(mantra)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6 * s)),
                                        removal: .opacity))
                .contentShape(Rectangle())
                .onTapGesture { model.onManageMantras?() }
                .contextMenu {
                    Menu("Keep This One") {
                        ForEach(TodayModel.holdChoices, id: \.label) { choice in
                            Button(choice.label) { model.hold(mantra, minutes: choice.minutes) }
                        }
                    }
                    if model.heldMantra != nil { Button("Back to a New One Every 25 Minutes") { model.releaseHold() } }
                    Button("Edit Mantras…") { model.onManageMantras?() }
                }
                .help(model.heldMantra == mantra
                      ? "Kept \(model.heldUntilLabel). Right-click to change; click to edit your mantras."
                      : "A new one every 25 minutes. Right-click to keep this one; click to edit your mantras.")
            }
        }
        .padding(16 * s)
        .frame(width: model.width * s, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: Theme.card, startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(model.allDoneGlow ? Theme.green.opacity(0.85) : Theme.text.opacity(0.14),
                              lineWidth: model.allDoneGlow ? 2 * s : 1)
        )
        .overlay(alignment: .trailing) { WidthEdge() }
        .overlay(alignment: .bottomTrailing) { ResizeGrip(model: model, scale: s) }
        .tint(Theme.accent)
        .contentShape(Rectangle())
        .onHover { if model.hover != $0 { model.hover = $0 } }
        .contextMenu {
            Picker("Size", selection: $model.scale) {
                ForEach(HUDSize.allCases) { Text($0.label).tag($0.scale) }
            }
            Picker("Color", selection: $model.theme) {
                ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
            }
            if model.doneCount > 0 { Button("Clear Completed") { model.clearDone() } }
            Button("Hide HUD (keep menu bar icon)") { model.onHide?() }
        }
        .fixedSize()
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                if let removed = model.removed, removed.index == i { UndoRow(model: model, removed: removed, scale: s) }
                ItemRow(model: model, item: item, scale: s)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let removed = model.removed, removed.index >= model.items.count {
                UndoRow(model: model, removed: removed, scale: s)
            }
        }
        // Inside the scroll view the content runs past what's visible; that one reports instead.
        .background(FrameReporter { if model.items.count <= Store.visibleRows { model.listRect = $0 } })
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }

    /// Text where `**word**` is heavy, e.g. "**Urgency** and **Hardworking** is how you win".
    static func marked(_ text: String) -> Text {
        text.components(separatedBy: "**").enumerated().reduce(Text("")) { line, part in
            line + (part.offset.isMultiple(of: 2) ? Text(part.element) : Text(part.element).fontWeight(.heavy))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10 * s) {
            VStack(alignment: .leading, spacing: 5 * s) {
                Group {
                    if model.allDone {
                        Text("All done ✓").foregroundColor(Theme.green)
                    } else {
                        Text("Today").foregroundColor(Theme.text)
                            + Text(trimmed(model.tagline).isEmpty ? "" : " – " + trimmed(model.tagline))
                                .font(Theme.font(22 * s)).foregroundColor(Theme.dim)
                    }
                }
                .font(Theme.font(22 * s, bold: true))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                if !trimmed(model.subtitle).isEmpty {
                    Self.marked(trimmed(model.subtitle))
                        .font(Theme.font(12 * s))
                        .foregroundStyle(Theme.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !trimmed(model.motto).isEmpty {
                    Self.marked(trimmed(model.motto))
                        .font(Theme.font(12 * s))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5 * s)
                }
            }
            Spacer(minLength: 0)
            // Always takes its space, so the header doesn't reflow when you hover.
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15 * s))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.text)
                .contentShape(Rectangle())
                .onTapGesture { model.onHide?() }
                .help("Hide HUD — stays in the menu bar (⌃⌥T brings it back)")
                .opacity(model.hover ? 1 : 0)
                .allowsHitTesting(model.hover)
            progress
        }
        .padding(.horizontal, 6 * s)  // lines up with the rows' circles and × buttons
        .padding(.bottom, 6 * s)
    }

    /// Done out of total, as a small ring.
    private var progress: some View {
        let total = model.items.count
        let fraction = total == 0 ? 0 : CGFloat(model.doneCount) / CGFloat(total)
        return ZStack {
            Circle().stroke(Theme.text.opacity(0.12), lineWidth: 3.5 * s)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(model.allDone ? Theme.green : Theme.text,
                        style: StrokeStyle(lineWidth: 3.5 * s, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(model.doneCount)/\(total)")
                .font(Theme.font(11 * s, bold: true))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
        .frame(width: 38 * s, height: 38 * s)
        .animation(.easeOut(duration: 0.3), value: fraction)
        .help("\(model.doneCount) of \(total) done")
    }
}

struct ItemRow: View {
    @ObservedObject var model: TodayModel
    let item: Item
    let scale: CGFloat
    @FocusState private var hasFocus: Bool
    /// The check-off: the circle pops and the strike draws across.
    @State private var pop = false
    @State private var struck = true

    private var hovered: Bool { model.hoveredRow == item.id }
    private var isNow: Bool { model.nowId == item.id && !item.done }
    private var dragging: Bool { model.draggingId == item.id }
    static func height(_ scale: CGFloat) -> CGFloat { 34 * scale }
    private var font: Font { Theme.font(15 * scale) }

    var body: some View {
        HStack(spacing: 10 * scale) {
            // A half-filled circle marks the one in progress, like Linear.
            // Empty → half-filled (now) → filled (done), like Linear.
            Image(systemName: item.done ? "checkmark.circle.fill" : isNow ? "circle.lefthalf.filled" : "circle")
                .font(.system(size: 17 * scale, weight: item.done || isNow ? .semibold : .regular))
                .symbolRenderingMode(item.done ? .palette : .monochrome)
                .foregroundStyle(item.done ? Theme.checkMark : isNow ? Theme.progress : hovered ? Theme.text : Theme.dim,
                                 Theme.green)
                .scaleEffect(pop ? 1.3 : 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    if hasFocus { finish() }  // its text field goes away, so hand the keyboard back
                    model.toggle(item.id)
                }
                .help(item.done ? "Mark as not done" : "Mark as done")
                .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")
                .accessibilityAddTraits(.isButton)
            // Done items are plain text with a line through it; uncheck an item to edit it again.
            if item.done {
                Text(item.text)
                    .font(font)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.dim)
                            .frame(height: max(1, 1.4 * scale))
                            .offset(y: 1 * scale)
                            .scaleEffect(x: struck ? 1 : 0, anchor: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        guard model.takeJustChecked(item.id) else { return }
                        struck = false
                        withAnimation(.easeOut(duration: 0.3).delay(0.05)) { struck = true }
                    }
            } else {
                TextField("", text: Binding(get: { model.text(item.id) }, set: { model.setText(item.id, $0) }))
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .focused($hasFocus)
                    .onSubmit { finish() }
                    .onExitCommand { finish() }
            }
            if isNow, let since = model.nowSince {
                // Redraws once a minute; nothing else ticks.
                TimelineView(.periodic(from: since, by: 60)) { context in
                    Text(Self.elapsed(from: since, to: context.date))
                        .font(Theme.font(12 * scale))
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                }
                .help("Time since you started on this")
            }
            if !item.done {
                let blocked = !item.urgent && !model.canMarkUrgent
                Image(systemName: item.urgent ? "exclamationmark.square.fill" : "exclamationmark.square")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(item.urgent ? Theme.urgent : Theme.dim)
                    .frame(width: 16 * scale, height: 16 * scale)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleUrgent(item.id) }
                    .opacity(item.urgent ? 1 : hovered ? (blocked ? 0.35 : 1) : 0)
                    .help(item.urgent ? "Not urgent"
                          : blocked ? "\(Store.maxUrgent) urgent already — finish one first"
                          : "Urgent: must be done today")
                    .accessibilityLabel(item.urgent ? "Not urgent" : "Urgent")
                    .accessibilityAddTraits(.isButton)
                Image(systemName: isNow ? "pin.fill" : "pin")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .rotationEffect(.degrees(30))
                    .foregroundStyle(isNow ? Theme.green : Theme.dim)
                    .frame(width: 16 * scale, height: 16 * scale)
                    .contentShape(Rectangle())
                    .onTapGesture { model.setNow(item.id) }
                    .opacity(isNow || hovered ? 1 : 0)
                    .help(isNow ? "Stop working on this" : "Working on this now")
                    .accessibilityLabel(isNow ? "Stop working on this" : "Working on this now")
                    .accessibilityAddTraits(.isButton)
            }
            Image(systemName: "xmark")
                .font(.system(size: 9 * scale, weight: .bold))
                .foregroundStyle(Theme.dim)
                .frame(width: 16 * scale, height: 16 * scale)
                .contentShape(Rectangle())
                .onTapGesture {
                    if hasFocus { finish() }
                    model.remove(item.id)
                }
                .opacity(hovered ? 1 : 0)
                .help("Remove")
                .accessibilityLabel("Remove")
                .accessibilityAddTraits(.isButton)
        }
        .frame(height: Self.height(scale))
        .padding(.horizontal, 6 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .fill(dragging ? AnyShapeStyle(LinearGradient(colors: Theme.card, startPoint: .top, endPoint: .bottom))
                               : AnyShapeStyle(Theme.text.opacity(hovered ? 0.06 : 0)))
        )
        .overlay(alignment: .bottom) {
            if Theme.choice.ruled { Rectangle().fill(Theme.rule.opacity(0.6)).frame(height: 1) }
        }
        .scaleEffect(dragging ? 1.02 : 1)
        .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: 6 * scale, y: 2 * scale)
        .zIndex(dragging ? 1 : 0)
        .background(FrameReporter { model.rowFrames[item.id] = $0 })
        .onChange(of: item.done) { done in
            guard done else { return }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { pop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pop = false }
            }
        }
        .onHover { inside in
            if inside { model.hoveredRow = item.id } else if hovered { model.hoveredRow = nil }
        }
    }

    /// "0m", "40m", "1h 5m".
    static func elapsed(from start: Date, to now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func finish() {
        hasFocus = false
        model.commit(item.id)
        model.onFinishEditing?()
    }
}

/// Takes a removed item's place for a few seconds so you can put it back.
struct UndoRow: View {
    @ObservedObject var model: TodayModel
    let removed: TodayModel.Removed
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .frame(width: 20.5 * scale)  // as wide as a row's circle, so the text lines up
            Text("Removed “\(removed.item.text)”")
                .font(Theme.font(14 * scale))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Undo")
                .font(Theme.font(14 * scale, bold: true))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 4 * scale)
                .contentShape(Rectangle())
                .onTapGesture { model.undoRemove() }
                .accessibilityAddTraits(.isButton)
        }
        .frame(height: ItemRow.height(scale))
        .padding(.horizontal, 6 * scale)
        .overlay(alignment: .bottom) {
            if Theme.choice.ruled { Rectangle().fill(Theme.rule.opacity(0.6)).frame(height: 1) }
        }
        .transition(.opacity)
    }
}

/// The next empty line of the list.
/// The Mantras window: add, edit and delete. Changes save to mantras.txt as you type.
struct MantraManager: View {
    @ObservedObject var model: TodayModel
    @State private var draft = ""
    @FocusState private var adding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Today –", text: $model.tagline, prompt: Text("make it delightful"))
                    TextField("Subtitle", text: $model.subtitle, prompt: Text("Hidden when empty"))
                    TextField("Motto", text: $model.motto, prompt: Text("Hidden when empty"))
                } header: {
                    HStack {
                        Text("Header")
                        Spacer()
                        Button("Reset") { model.resetHeader() }.buttonStyle(.link).font(.caption)
                    }
                } footer: {
                    Text("Put **two stars** around a word to make it bold.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            Text("Mantras").font(.headline).padding(.horizontal, 20)
            Text(model.heldMantra.map { "Keeping “\($0)” \(model.heldUntilLabel)." }
                 ?? "A new one shows under your list every 25 minutes. Use the pin to keep one for a while.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 10)
            List {
                ForEach(model.mantras) { m in
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                            .foregroundStyle(m.text == model.mantra ? Color.green : Color.secondary.opacity(0.4))
                            .help(m.text == model.mantra ? "Showing now" : "")
                        TextField("Mantra", text: Binding(get: { m.text }, set: { model.setMantra(m.id, $0) }))
                            .textFieldStyle(.plain)
                        let held = model.heldMantra == m.text
                        Menu {
                            Section("Keep on show for") {
                                ForEach(TodayModel.holdChoices, id: \.label) { choice in
                                    Button(choice.label) { model.hold(m.text, minutes: choice.minutes) }
                                }
                            }
                            if held { Button("Back to a New One Every 25 Minutes") { model.releaseHold() } }
                        } label: {
                            Image(systemName: held ? "pin.fill" : "pin")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(held ? Color.green : Color.secondary)
                        .help(held ? "Kept \(model.heldUntilLabel)" : "Keep this one on show for a while")
                        Button { model.deleteMantra(m.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Delete")
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("New mantra, then Return", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($adding)
                    .onSubmit {
                        model.addMantra(draft)
                        draft = ""
                        adding = true
                    }
            }
            .padding(16)
        }
        .frame(minWidth: 380, minHeight: 480)
        .onDisappear { model.flushMantras() }
    }
}

struct AddField: View {
    @ObservedObject var model: TodayModel
    let scale: CGFloat
    @FocusState private var hasFocus: Bool
    /// SwiftUI focuses fields on its own; only look focused while typing goes here.
    private var focused: Bool { hasFocus && model.editing }

    var body: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: "plus")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(focused ? Theme.accent : Theme.dim)
                .frame(width: 17 * scale)
                .contentShape(Rectangle())
                // Adds what you've typed, or puts the cursor on the line to start.
                .onTapGesture {
                    if !model.draft.trimmingCharacters(in: .whitespaces).isEmpty { model.add() }
                    model.onTakeKeyboard?()
                    hasFocus = true
                }
                .help("Add")
                .accessibilityLabel("Add")
                .accessibilityAddTraits(.isButton)
            TextField("", text: $model.draft,
                      prompt: Text(model.items.isEmpty ? "What matters today?" : "Think, Break it down, Sweat the details and edges")
                          .foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .font(Theme.font(15 * scale))
                .foregroundStyle(Theme.text)
                .focused($hasFocus)
                // Return adds and keeps the line ready for the next item.
                .onSubmit {
                    if model.draft.trimmingCharacters(in: .whitespaces).isEmpty { return done() }
                    model.add()
                    if model.isFull { done() }
                }
                .onExitCommand { done() }
        }
        .padding(.vertical, 7 * scale)
        .padding(.horizontal, 6 * scale)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(focused ? Theme.accent.opacity(0.75) : Theme.choice.ruled ? Theme.rule.opacity(0.6) : Theme.text.opacity(0.18))
                .frame(height: 1.5 * scale)
                .padding(.horizontal, 6 * scale)
        }
        .help("Return adds it · Return on an empty line or Esc when you're done")
    }

    private func done() {
        hasFocus = false
        model.onFinishEditing?()
    }
}

/// Reports a view's frame in the hosting view's top-left coordinates.
struct FrameReporter: View {
    let report: (CGRect) -> Void
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { report(geo.frame(in: .global)) }
                .onChange(of: geo.frame(in: .global)) { report($0) }
        }
    }
}

/// The right edge: drag it to make the card wider or narrower. Matches the
/// zone the hosting view treats as a width drag.
struct WidthEdge: View {
    /// Inside the card's padding, so it never overlaps a row.
    static let thickness: CGFloat = 12

    var body: some View {
        Color.clear
            .frame(width: Self.thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .help("Drag to make it wider or narrower")
    }
}

/// Sits in the bottom-right corner and reports where it is, so a drag starting
/// there resizes instead of moving. Only visible while hovering.
struct ResizeGrip: View {
    @ObservedObject var model: TodayModel
    let scale: CGFloat
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8 * scale, weight: .bold))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 18 * scale, height: 18 * scale)
            .opacity(model.hover ? 1 : 0)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { model.gripRect = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { model.gripRect = $0 }
            })
            .onHover { inside in
                guard #available(macOS 15, *) else { return }
                if inside {
                    NSCursor.frameResize(position: .bottomRight, directions: .all).push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

enum HUDSize: CaseIterable, Identifiable {
    case small, medium, large, huge
    var id: Self { self }
    var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1
        case .large: return 1.3
        case .huge: return 1.7
        }
    }
    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .huge: return "Huge"
        }
    }
}

// MARK: - Global hotkey (Carbon; no Accessibility permission needed)

private var hotKeyHandler: (() -> Void)?
private var hotKeyRef: EventHotKeyRef?

func registerHotKey(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
    hotKeyHandler = handler
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        hotKeyHandler?()
        return noErr
    }, 1, &spec, nil, nil)
    RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x544F_4459), id: 1),
                        GetApplicationEventTarget(), 0, &hotKeyRef)
}

// MARK: - Panel & app

final class HUDPanel: NSPanel {
    /// Only takes the keyboard when you click into a text field, so the HUD
    /// never steals typing from the app you're working in.
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }

    /// Row dragging, in the hosting view's top-left coordinates.
    var rowAt: ((CGPoint) -> UUID?)?
    var onRowDragBegan: ((UUID) -> Void)?
    var onRowDragged: ((CGPoint) -> Void)?
    var onRowDragEnded: (() -> Void)?
    private var pendingRow: (event: NSEvent, id: UUID)?
    private var draggingRow = false

    // A press on a row is held back until we know what it is: a drag moves the
    // row, a click is replayed so it edits the text or checks the item off.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Selecting text in the field you're typing in stays a text drag.
            if let id = rowAt?(point(event)), !(isKeyWindow && hitsFieldEditor(event)) {
                pendingRow = (event, id)
                draggingRow = false
                return
            }
            press(event)
        case .leftMouseDragged where pendingRow != nil:
            guard let pending = pendingRow else { return }
            let a = pending.event.locationInWindow, b = event.locationInWindow
            if !draggingRow, hypot(b.x - a.x, b.y - a.y) >= 4 {
                draggingRow = true
                NSCursor.closedHand.push()
                onRowDragBegan?(pending.id)
            }
            if draggingRow { onRowDragged?(point(event)) }
        case .leftMouseUp where pendingRow != nil:
            guard let pending = pendingRow else { return }
            pendingRow = nil
            if draggingRow {
                draggingRow = false
                NSCursor.pop()
                onRowDragEnded?()
            } else {
                // A text field tracks the click itself, waiting for the release,
                // so the release goes back in the queue before the press is replayed.
                NSApp.postEvent(event, atStart: true)
                press(pending.event)
            }
        default:
            super.sendEvent(event)
        }
    }

    // Clicks on a text field go straight to it (AppKit routes them past the
    // hosting view), so this is where the keyboard is let in.
    private func press(_ event: NSEvent) {
        if !isKeyWindow, let frameView = contentView?.superview,
           isTextEditor(frameView.hitTest(event.locationInWindow)) {
            allowKey = true
            makeKey()
        }
        super.sendEvent(event)
    }

    private func point(_ event: NSEvent) -> CGPoint {
        guard let view = contentView else { return .zero }
        var p = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped { p.y = view.bounds.height - p.y }
        return p
    }

    private func hitsFieldEditor(_ event: NSEvent) -> Bool {
        contentView?.superview?.hitTest(event.locationInWindow) is NSTextView
    }

    private func isTextEditor(_ view: NSView?) -> Bool {
        var v = view
        while let current = v {
            if current is NSTextField || current is NSTextView { return true }
            v = current.superview
        }
        return false
    }
}

/// The HUD is never the active window, so without this every first click
/// would be swallowed by AppKit instead of reaching SwiftUI.
final class HUDHostingView: NSHostingView<TodayView> {
    var onDragEnded: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var currentScale: (() -> CGFloat)?
    var isResizeZone: ((CGPoint) -> Bool)?
    var currentWidth: (() -> CGFloat)?
    var onWidth: ((CGFloat) -> Void)?
    private enum Mode {
        case undecided, moving, resizing(scale: CGFloat, width: CGFloat), widening(width: CGFloat, scale: CGFloat)
    }
    private var pending: (event: NSEvent, mouse: NSPoint, origin: NSPoint)?
    private var mode = Mode.undecided

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A press is held back until we know what it is: the grip resizes, other
    // drags move the window, plain clicks are replayed to SwiftUI.
    override func mouseDown(with event: NSEvent) {
        pending = (event, NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        if isResizeZone?(p) == true {
            mode = .resizing(scale: currentScale?() ?? 1, width: bounds.width)
        } else if p.x >= bounds.width - WidthEdge.thickness {
            mode = .widening(width: currentWidth?() ?? 300, scale: currentScale?() ?? 1)
        } else {
            mode = .undecided
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = pending, let window else { return super.mouseDragged(with: event) }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - p.mouse.x, dy = mouse.y - p.mouse.y
        switch mode {
        case let .resizing(scale, width):
            // Follow whichever direction the cursor moved most; down/right grows.
            let d = abs(dx) > abs(dy) ? dx : -dy
            onResize?(scale * (width + d) / width)
        case let .widening(width, scale):
            onWidth?(width + dx / scale)
        case .undecided where hypot(dx, dy) < 3:
            return
        default:
            mode = .moving
            window.setFrameOrigin(NSPoint(x: p.origin.x + dx, y: p.origin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pending = nil; mode = .undecided }
        guard let p = pending else { return super.mouseUp(with: event) }
        switch mode {
        case .moving, .resizing, .widening:
            onDragEnded?()
        case .undecided:
            super.mouseDown(with: p.event)
            super.mouseUp(with: event)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = TodayModel()
    var panel: HUDPanel!
    var host: HUDHostingView!
    var statusItem: NSStatusItem!
    var subscriptions: Set<AnyCancellable> = []
    /// Remembered across restarts, so a hidden HUD stays hidden.
    var userHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "hudHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "hudHidden") }
    }
    private var shown = false
    private var statusKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        applyAppearance()

        host = HUDHostingView(rootView: TodayView(model: model))
        host.sizingOptions = []
        host.currentScale = { [weak self] in self?.model.scale ?? 1 }
        host.onResize = { [weak self] in
            self?.model.scale = min(max($0, TodayModel.scaleRange.lowerBound), TodayModel.scaleRange.upperBound)
        }
        host.currentWidth = { [weak self] in self?.model.width ?? 300 }
        host.onWidth = { [weak self] in
            self?.model.width = min(max($0, TodayModel.widthRange.lowerBound), TodayModel.widthRange.upperBound)
        }
        host.isResizeZone = { [weak self] p in
            guard let grip = self?.model.gripRect, !grip.isEmpty else { return false }
            return grip.insetBy(dx: -4, dy: -4).contains(p)
        }
        host.onDragEnded = { [weak self] in self?.saveFrame() }
        panel.rowAt = { [weak self] in self?.model.row(at: $0) }
        panel.onRowDragBegan = { [weak self] id in
            withAnimation(.easeOut(duration: 0.15)) { self?.model.draggingId = id }
        }
        panel.onRowDragged = { [weak self] in self?.model.drag(to: $0) }
        panel.onRowDragEnded = { [weak self] in
            withAnimation(.easeOut(duration: 0.15)) { self?.model.draggingId = nil }
        }
        panel.contentView = host
        fitToContent()
        placeInitially()

        model.onHide = { [weak self] in
            self?.userHidden = true
            self?.updateVisibility()
        }
        model.onManageMantras = { [weak self] in self?.manageMantras() }
        model.onTakeKeyboard = { [weak self] in
            self?.panel.allowKey = true
            self?.panel.makeKey()
        }
        // Hand the keyboard back to whatever app you were in once you're done typing.
        model.onFinishEditing = { [weak self] in
            guard let self, self.panel.isKeyWindow else { return }
            self.panel.makeFirstResponder(nil)
            self.panel.orderOut(nil)
            if self.shown { self.panel.orderFrontRegardless() }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.model.editing = true
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.model.editing = false
            self?.panel.allowKey = false
            self?.panel.makeFirstResponder(nil)
        }
        // Nothing ticks, so re-measuring after each change costs nothing at rest.
        model.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.fitToContent()
                self?.updateStatusItem()
            }
            .store(in: &subscriptions)
        model.$theme.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &subscriptions)
        // Unplugging a display can leave the HUD off every screen; bring it back.
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                           queue: .main) { [weak self] _ in
            guard let self else { return }
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(self.panel.frame) }) {
                self.placeInitially()
            }
        }
        registerHotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in self?.toggleHUD() }

        setupStatusItem()
        model.start()
        updateVisibility()
    }

    /// Menus and text-field chrome follow the card: light on Paper, dark otherwise.
    private func applyAppearance() {
        panel.appearance = NSAppearance(named: model.theme.isLight ? .aqua : .darkAqua)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushSave()
        model.flushMantras()
    }

    private func saveFrame() {
        let f = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: "hudTopLeft")
    }

    private func placeInitially() {
        let size = panel.frame.size
        if let saved = UserDefaults.standard.string(forKey: "hudTopLeft") {
            let topLeft = NSPointFromString(saved)
            let f = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) {
                panel.setFrameOrigin(f.origin)
                return
            }
        }
        // Top left, just under the menu bar.
        guard let vf = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: vf.minX + 16, y: vf.maxY - size.height - 10))
    }

    /// Resizes the window to the card, keeping its top-left corner in place.
    private func fitToContent() {
        // A throwaway measurer: a long-lived one would observe the model and re-render for nothing.
        let measured = NSHostingController(rootView: TodayView(model: model))
            .sizeThatFits(in: CGSize(width: 4000, height: 4000))
        let size = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }
        let f = panel.frame
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height),
                       display: true)
        panel.invalidateShadow()
    }

    private func updateVisibility() {
        let want = !userHidden
        guard want != shown else { return }
        shown = want
        if want {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // SwiftUI parks the cursor in the first field on its own, which shows a
            // stray selection; nothing should be focused until you click in.
            DispatchQueue.main.async { [weak self] in self?.panel.makeFirstResponder(nil) }
        } else {
            model.onFinishEditing?()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = want ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !self.shown else { return }
            self.panel.orderOut(nil)
        })
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let total = model.items.count
        // While something is pinned as "now", the menu bar shows it instead of the count.
        let now = model.nowItem.map { $0.text.count > 30 ? $0.text.prefix(29) + "…" : $0.text }
        let title = now.map { " \($0)" } ?? (total == 0 ? "" : " \(model.doneCount)/\(total)")
        let symbol = now != nil ? "circle.lefthalf.filled" : model.allDone ? "checklist.checked" : "checklist"
        let key = symbol + title
        guard key != statusKey else { return }
        statusKey = key
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Today list")
        image?.isTemplate = true
        button.image = image
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
        ])
    }

    @objc func toggleHUD() {
        userHidden.toggle()
        updateVisibility()
    }

    @objc func toggleSound() { model.soundOn.toggle() }

    @objc func toggleMantras() { model.mantrasOn.toggle() }

    private var mantraWindow: NSWindow?

    @objc func manageMantras() {
        if mantraWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Mantras & Header"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 380, height: 480)
            w.contentView = NSHostingView(rootView: MantraManager(model: model))
            w.center()
            mantraWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        mantraWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func clearDone() { model.clearDone() }

    @objc func clearNow() { if let id = model.nowItem?.id { model.setNow(id) } }

    @objc func toggleItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.toggle(id)
    }

    @objc func setSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? HUDSize else { return }
        model.scale = size.scale
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = ThemeChoice(rawValue: raw) else { return }
        model.theme = theme
    }

    @objc func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "hudTopLeft")
        placeInitially()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let total = model.items.count
        menu.addItem(NSMenuItem(title: total == 0 ? "Nothing on today's list yet"
                                    : "Today · \(model.doneCount) of \(total) done",
                                action: nil, keyEquivalent: ""))
        func short(_ text: String) -> String { text.count > 60 ? text.prefix(59) + "…" : text }
        if let now = model.nowItem {
            let entry = NSMenuItem(title: "Stop Working on “\(short(now.text))”", action: #selector(clearNow), keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        for item in model.items {
            let title = item.urgent && !item.done ? "! " + short(item.text) : short(item.text)
            let entry = NSMenuItem(title: title, action: #selector(toggleItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            entry.state = item.done ? .on : item.id == model.nowItem?.id ? .mixed : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        func add(_ title: String, _ action: Selector, key: String = "", checked: Bool? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
        add(userHidden ? "Show HUD" : "Hide HUD", #selector(toggleHUD), key: "t")

        let sizes = NSMenu()
        for size in HUDSize.allCases {
            let item = NSMenuItem(title: size.label, action: #selector(setSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            item.state = abs(model.scale - size.scale) < 0.01 ? .on : .off
            sizes.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "HUD Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let colors = NSMenu()
        for theme in ThemeChoice.allCases {
            let item = NSMenuItem(title: theme.label, action: #selector(setTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.rawValue
            item.state = model.theme == theme ? .on : .off
            colors.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)

        if model.doneCount > 0 { add("Clear Completed", #selector(clearDone)) }
        add("Chime When All Done", #selector(toggleSound), checked: model.soundOn)
        add("Show Mantras", #selector(toggleMantras), checked: model.mantrasOn)
        add("Mantras & Header…", #selector(manageMantras))
        add("Reset HUD Position", #selector(resetPosition))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
}

// MARK: - Entry

/// `--test`: checks the logic that's easy to break, with no window and without
/// touching your list. Exits 1 if anything fails.
if CommandLine.arguments.contains("--test") {
    var failures = 0
    func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL (line \(line)): \(what)") }
    }
    let cal = Calendar.current
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    let reset = max(1, Store.resetHour)  // whatever you've set; 5 by default

    // The day turns at the reset hour, not at midnight, daylight saving days included.
    check(Store.dayKey(date(2026, 3, 10, reset - 1)) == "2026-03-09", "before the reset it's still yesterday")
    check(Store.dayKey(date(2026, 3, 10, reset)) == "2026-03-10", "at the reset it's today")
    check(Store.dayKey(date(2026, 3, 8, 23)) == "2026-03-08", "late evening is today")
    check(Store.dayKey(date(2026, 11, 1, reset)) == "2026-11-01", "reset on a daylight saving day")
    let next = Store.nextReset(after: date(2026, 3, 10, 14))
    check(cal.component(.hour, from: next) == reset && cal.component(.day, from: next) == 11, "next reset is tomorrow morning")

    // Carry-over keeps unfinished tasks, in order, urgent flags and all.
    var a = Item(text: "a"); a.urgent = true
    var b = Item(text: "b"); b.done = true
    let c = Item(text: "c")
    check(Store.carryOver([a, b, c]).map(\.text) == ["a", "c"], "done tasks clear, open ones stay in order")
    check(Store.carryOver([a]).first?.urgent == true, "urgent carries over")
    check(Store.carryOver(Array(repeating: c, count: 40)).count == Store.maxItems, "carry-over caps at maxItems")

    // Reading files written by other apps.
    let today = Store.dayKey()
    let json = { (s: String) in Store.file(from: Data(s.utf8)) }
    check(json(#"{"day":"\#(today)","items":[{"te"#) == nil, "half-written file is rejected")
    let minimal = json(#"{"day":"\#(today)","items":[{"text":"x"},{"text":"y","done":true}]}"#)
    check(minimal?.items.map(\.text) == ["x", "y"] && minimal?.items[1].done == true, "items without ids or flags load")
    let id = UUID().uuidString
    let dupes = json(#"{"day":"\#(today)","items":[{"id":"\#(id)","text":"x"},{"id":"\#(id)","text":"y"}]}"#)
    check(Set(dupes?.items.map(\.id) ?? []).count == 2, "duplicate ids are made unique")
    let stale = json(#"{"day":"2001-01-01","now":"\#(id)","items":[{"id":"\#(id)","text":"x"},{"text":"y","done":true}]}"#)
    check(stale?.day == today && stale?.items.map(\.text) == ["x"] && stale?.now == nil, "an old day's file gets the morning reset")

    // Mantras: every one shows before any repeats, and the order holds all day.
    for count in [1, 2, 9, 10] {
        let start = date(2026, 3, 10, 6)
        let picks = (0..<count).compactMap { Mantras.pick(of: count, at: start.addingTimeInterval(Double($0) * 25 * 60)) }
        check(Set(picks).count == count, "\(count) mantras: no repeats within a round")
    }
    let noon = date(2026, 3, 10, 12, 5)
    check(Mantras.pick(of: 9, at: noon) == Mantras.pick(of: 9, at: noon.addingTimeInterval(60)), "same block, same mantra")
    check(Mantras.pick(of: 0) == nil, "no mantras, nothing shown")
    check(Mantras.pick(of: 5, at: date(2026, 3, 10, 2)) != nil, "before the first block still shows one")
    check(Mantras.nextChange(after: date(2026, 3, 10, 9, 31)) > date(2026, 3, 10, 9, 31), "the next change is in the future")

    // The command line.
    func cli(_ args: [String], _ file: Store.File) -> Store.File? { (try? CLI.perform(args, on: file))?.0 }
    let empty = Store.File(day: today, items: [])
    let one = cli(["add", "Call", "the", "bank"], empty)
    check(one?.items.map(\.text) == ["Call the bank"], "add joins the words")
    var withDone = Store.File(day: today, items: [c, b])  // b is done, so it sits below
    withDone = cli(["add", "new"], withDone) ?? withDone
    check(withDone.items.map(\.text) == ["c", "new", "b"], "a new task goes above done ones")
    let flagged = cli(["add", "-u", "fire"], withDone)
    check(flagged?.items.first?.text == "fire" && flagged?.items.first?.urgent == true, "add -u puts it on top as urgent")
    let pinned = cli(["now", "1"], withDone)
    check(pinned?.now == withDone.items[0].id && pinned?.nowSince != nil, "now pins with a start time")
    check(cli(["done", "1"], pinned!)?.now == nil, "checking off the pinned task unpins it")
    check(cli(["done", "9"], withDone) == nil && cli(["done", "x"], withDone) == nil, "bad numbers are refused")
    check(cli(["rm", "3"], withDone)?.items.count == 2, "rm removes")
    let threeUrgent = Store.File(day: today, items: (0..<3).map { var i = Item(text: "u\($0)"); i.urgent = true; return i } + [c])
    check(cli(["urgent", "4"], threeUrgent) == nil && cli(["add", "-u", "x"], threeUrgent) == nil, "no fourth urgent")
    check(cli(["now", "1"], Store.File(day: today, items: [b])) == nil, "a done task can't be now")
    check((try? CLI.perform([], on: withDone))?.1.contains("1  ○ c") == true, "the list is numbered")

    // Small formatting.
    let t0 = date(2026, 3, 10, 9)
    check(ItemRow.elapsed(from: t0, to: t0.addingTimeInterval(30)) == "0m", "under a minute is 0m")
    check(ItemRow.elapsed(from: t0, to: t0.addingTimeInterval(65 * 60)) == "1h 5m", "1h 5m")
    check(ItemRow.elapsed(from: t0, to: t0.addingTimeInterval(120 * 60)) == "2h", "2h")
    check(TodayModel.oneLine("a\nb") == "a b", "pasted line breaks become spaces")

    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

/// The app used to be called Today HUD. Its list, mantras and settings move over
/// once, the first time the new name runs.
func moveFromTodayHUD() {
    let fm = FileManager.default
    let old = Store.url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TodayHUD")
    let new = Store.url.deletingLastPathComponent()
    if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) {
        try? fm.moveItem(at: old, to: new)
    }
    let defaults = UserDefaults.standard
    if defaults.object(forKey: "movedFromTodayHUD") == nil {
        for (key, value) in defaults.persistentDomain(forName: "local.today-hud") ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "movedFromTodayHUD")
    }
}
moveFromTodayHUD()

// MARK: - Command line

/// `today …`: your list from a terminal, here or over SSH. Changes are written to
/// today.json, and a running HUD shows them within a moment.
enum CLI {
    static let commands: Set<String> = ["list", "add", "done", "now", "urgent", "rm", "help", "--help", "-h"]

    static let usage = """
    today                 show today's list
    today add <task>      add a task (today add -u <task> for urgent)
    today done <n>        check off task n (again to reopen it)
    today now <n>         pin task n as the one you're on (again to unpin)
    today urgent <n>      flag or unflag task n as urgent
    today rm <n>          remove task n
    """

    struct Failure: Error { let message: String }

    /// Applies one command to `file`. Returns the changed file (nil if nothing
    /// changed) and what to print. No disk access, so `--test` can check it.
    static func perform(_ args: [String], on file: Store.File, now: Date = Date()) throws -> (Store.File?, String) {
        var file = file
        guard let command = args.first, command != "list" else { return (nil, render(file, now: now)) }
        if ["help", "--help", "-h"].contains(command) { return (nil, usage) }
        var rest = Array(args.dropFirst())

        if command == "add" {
            var urgent = false
            if let flag = rest.first, flag == "-u" || flag == "--urgent" { urgent = true; rest.removeFirst() }
            let text = TodayModel.oneLine(rest.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { throw Failure(message: "What's the task? today add Call the bank") }
            guard file.items.count < Store.maxItems else { throw Failure(message: "That's \(Store.maxItems) already — plenty for one day.") }
            var item = Item(text: text)
            if urgent {
                guard urgentCount(file) < Store.maxUrgent else { throw Failure(message: "\(Store.maxUrgent) tasks are already urgent — finish one first.") }
                item.urgent = true
            }
            file.items.insert(item, at: TodayModel.slot(for: item, in: file.items))
            return (file, "Added: \(text)")
        }

        guard commands.contains(command) else { throw Failure(message: "Unknown command \"\(command)\".\n\n" + usage) }
        guard let arg = rest.first, let n = Int(arg) else { throw Failure(message: "Which task? Give its number, e.g. today \(command) 2") }
        guard file.items.indices.contains(n - 1) else {
            throw Failure(message: file.items.isEmpty ? "The list is empty." : "No task \(n); there are \(file.items.count).")
        }
        var item = file.items[n - 1]
        switch command {
        case "done":
            file.items.remove(at: n - 1)
            item.done.toggle()
            if item.done, file.now == item.id { file.now = nil; file.nowSince = nil }  // finishing it ends "now"
            if !item.done, item.urgent, urgentCount(file) >= Store.maxUrgent { item.urgent = false }
            file.items.insert(item, at: TodayModel.slot(for: item, in: file.items))
            return (file, (item.done ? "Done: " : "Reopened: ") + item.text)
        case "now":
            guard !item.done else { throw Failure(message: "Task \(n) is done; reopen it first with today done \(n).") }
            if file.now == item.id {
                file.now = nil; file.nowSince = nil
                return (file, "Unpinned: \(item.text)")
            }
            file.now = item.id; file.nowSince = now
            return (file, "Working on: \(item.text)")
        case "urgent":
            guard !item.done else { throw Failure(message: "Task \(n) is done, so it can't be urgent.") }
            if !item.urgent, urgentCount(file) >= Store.maxUrgent {
                throw Failure(message: "\(Store.maxUrgent) tasks are already urgent — finish one first.")
            }
            file.items.remove(at: n - 1)
            item.urgent.toggle()
            file.items.insert(item, at: TodayModel.slot(for: item, in: file.items))
            return (file, (item.urgent ? "Urgent: " : "No longer urgent: ") + item.text)
        default:  // rm
            file.items.remove(at: n - 1)
            if file.now == item.id { file.now = nil; file.nowSince = nil }
            return (file, "Removed: \(item.text)")
        }
    }

    static func urgentCount(_ file: Store.File) -> Int { file.items.filter { $0.urgent && !$0.done }.count }

    /// The list, numbered the way the commands count.
    static func render(_ file: Store.File, now: Date) -> String {
        let done = file.items.filter(\.done).count
        guard !file.items.isEmpty else { return "Nothing on today's list yet. Add one: today add <task>" }
        var lines = ["Today · \(done) of \(file.items.count) done"]
        let width = String(file.items.count).count
        for (i, item) in file.items.enumerated() {
            let number = String(repeating: " ", count: width - String(i + 1).count) + String(i + 1)
            let isNow = item.id == file.now && !item.done
            let mark = item.done ? "✓" : isNow ? "◐" : "○"
            var text = (item.urgent && !item.done ? "! " : "") + item.text
            if isNow, let since = file.nowSince { text += " · " + ItemRow.elapsed(from: since, to: now) }
            lines.append("\(number)  \(mark) \(text)")
        }
        return lines.joined(separator: "\n")
    }

    static func run(_ args: [String]) -> Int32 {
        do {
            let (changed, message) = try perform(args, on: Store.load())
            print(message)
            if let changed {
                Store.save(changed.items, now: changed.now, since: changed.nowSince)
                // Numbers shift as tasks move, so show the new ones.
                print("\n" + render(changed, now: Date()))
            }
            return 0
        } catch let failure as Failure {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            return 1
        } catch {
            return 1
        }
    }
}

// Run as `today` (the command install adds), or with a command word, it's the CLI;
// launched plainly, it's the HUD.
let invokedAs = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let cliArgs = Array(CommandLine.arguments.dropFirst())
if invokedAs == "today" || cliArgs.first.map(CLI.commands.contains) == true || cliArgs.first == "--print" {
    exit(CLI.run(cliArgs.first == "--print" ? [] : cliArgs))
}

// One instance only (launchd and a manual `open` could both start it).
if let bundleId = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
       .contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
