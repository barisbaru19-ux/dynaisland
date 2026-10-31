import AppKit
import EventKit

/// A Reminders list, for "new items go to…" in Settings.
struct ReminderList: Identifiable, Equatable {
    let id: String
    let title: String
}

/// What DynaIsland needs from a reminder, copied out on EventKit's own queue.
private struct ReminderSnapshot: Sendable {
    let id: String
    let title: String
    let isCompleted: Bool
    let completionDate: Date?
    let due: Date?
    let isRecurring: Bool

    init(_ reminder: EKReminder) {
        let identifier: String? = reminder.calendarItemIdentifier
        let rawTitle: String? = reminder.title
        id = identifier ?? UUID().uuidString
        title = (rawTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        isCompleted = reminder.isCompleted
        completionDate = reminder.completionDate
        due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        isRecurring = reminder.hasRecurrenceRules
    }
}

/// "Hari ini" checklist ⇄ Apple Reminders (synced with iPhone and iPad through iCloud).
///
/// Shows every reminder due today or overdue, from all lists, plus the ones completed today.
/// Routines are reminders repeating every day, so Reminders itself brings them back each morning.
@MainActor
final class RemindersSync: NSObject {
    private let model: IslandModel
    private let store = EKEventStore()
    /// Stable SwiftUI ids for reminders across refreshes.
    private var uuids: [String: UUID] = [:]
    private var lastRefresh = Date.distantPast
    private var refreshTask: Task<Void, Never>?

    init(model: IslandModel) {
        self.model = model
        super.init()
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: .EKEventStoreChanged, object: store)
        updateAccess()
        if model.remindersSync {
            if model.remindersAccess == .granted { refresh() } else { disable() }
        }
    }

    /// Called once a second.
    func tick() {
        updateAccess()   // so Settings shows a switch flipped in System Settings
        if model.remindersSync && model.remindersAccess != .granted {
            disable()    // access taken away: back to the checklist on this Mac
            return
        }
        guard model.remindersSync, Date().timeIntervalSince(lastRefresh) > 60 else { return }
        refresh()
    }

    // MARK: Switching on / off

    func enable() {
        Task { @MainActor in
            let granted = await self.requestAccessIfNeeded()
            self.updateAccess()
            guard granted else {
                self.model.remindersSync = false
                if self.model.remindersAccess == .denied {
                    PermissionList.openPrivacy("Privacy_Reminders")
                }
                return
            }
            let moved = self.moveLocalChecklist()
            self.model.remindersSync = true
            self.loadLists()
            self.refresh()
            if moved > 0 {
                self.model.show(IslandNotice(symbol: "checklist", title: "Pindah ke Reminders",
                                             detail: "\(moved) item", tint: .green), seconds: 3)
            }
        }
    }

    func disable() {
        model.remindersSync = false
        model.useLocalChecklist()
    }

    private func requestAccessIfNeeded() async -> Bool {
        updateAccess()
        switch model.remindersAccess {
        case .granted: return true
        case .denied: return false
        case .notDetermined:
            if #available(macOS 14.0, *) {
                return (try? await store.requestFullAccessToReminders()) ?? false
            } else {
                return (try? await store.requestAccess(to: .reminder)) ?? false
            }
        }
    }

    func updateAccess() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let access: CalendarAccess
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: access = .granted
            case .notDetermined: access = .notDetermined
            default: access = .denied
            }
        } else {
            switch status {
            case .authorized: access = .granted
            case .notDetermined: access = .notDetermined
            default: access = .denied
            }
        }
        if model.remindersAccess != access { model.remindersAccess = access }
    }

    /// Local checklist items become reminders (routines repeat daily), then the local list is emptied.
    private func moveLocalChecklist() -> Int {
        let local = ChecklistStorage.loadItems()
        let today = DayKey.string()
        var moved = 0
        for item in local {
            if !item.isRoutine, let done = item.doneOn, done != today { continue }   // finished earlier
            if let reminder = makeReminder(title: item.title, routine: item.isRoutine) {
                if item.doneOn == today { reminder.isCompleted = true }
                if (try? store.save(reminder, commit: false)) != nil { moved += 1 }
            }
        }
        try? store.commit()
        ChecklistStorage.save([])
        return moved
    }

    // MARK: Reading

    @objc private func storeChanged() {
        refreshSoon()
    }

    private func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        guard model.remindersSync, model.remindersAccess == .granted else { return }
        lastRefresh = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return }
        let openPredicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil)
        let donePredicate = store.predicateForCompletedReminders(withCompletionDateStarting: startOfToday,
                                                                  ending: endOfToday, calendars: nil)
        Task { @MainActor in
            let open = await self.fetch(openPredicate)
            let done = await self.fetch(donePredicate)
            self.apply(open: open, done: done, startOfToday: startOfToday)
        }
    }

    private func fetch(_ predicate: NSPredicate) async -> [ReminderSnapshot] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map { ReminderSnapshot($0) })
            }
        }
    }

    private func apply(open: [ReminderSnapshot], done: [ReminderSnapshot], startOfToday: Date) {
        guard model.remindersSync else { return }
        let today = DayKey.string()
        var items: [ChecklistItem] = []
        var seen = Set<String>()

        let openSorted = open.filter { $0.due != nil && !$0.title.isEmpty }
            .sorted { ($0.isRecurring ? 0 : 1, $0.due ?? .distantPast) < ($1.isRecurring ? 0 : 1, $1.due ?? .distantPast) }
        for snapshot in openSorted where seen.insert(snapshot.id).inserted {
            items.append(item(for: snapshot, doneOn: nil, today: today))
        }
        for snapshot in done where !snapshot.title.isEmpty && seen.insert(snapshot.id).inserted {
            items.append(item(for: snapshot, doneOn: today, today: today))
        }
        model.applyRemoteChecklist(items)
        loadLists()
    }

    private func item(for snapshot: ReminderSnapshot, doneOn: String?, today: String) -> ChecklistItem {
        let uuid = uuids[snapshot.id] ?? UUID()
        uuids[snapshot.id] = uuid
        let dueDay = snapshot.due.map { DayKey.string($0) } ?? today
        return ChecklistItem(id: uuid, title: snapshot.title, isRoutine: snapshot.isRecurring,
                             doneOn: doneOn, addedOn: min(dueDay, today), remoteID: snapshot.id)
    }

    private func loadLists() {
        let lists = store.calendars(for: .reminder)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if model.remindersLists != lists { model.remindersLists = lists }
    }

    // MARK: Writing

    func add(title: String, routine: Bool) {
        guard let reminder = makeReminder(title: title, routine: routine) else { return }
        try? store.save(reminder, commit: true)
        refreshSoon()
    }

    func setCompleted(_ id: String, completed: Bool) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = completed
        try? store.save(reminder, commit: true)
        refreshSoon()
    }

    func setRoutine(_ id: String, routine: Bool) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
        if routine {
            reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        }
        try? store.save(reminder, commit: true)
        refreshSoon()
    }

    func remove(_ id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try? store.remove(reminder, commit: true)
        refreshSoon()
    }

    /// A new reminder due today in the chosen list (or the default one). Routines repeat daily.
    private func makeReminder(title: String, routine: Bool) -> EKReminder? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let reminder = EKReminder(eventStore: store)
        reminder.title = clean
        let chosen = model.remindersListID.isEmpty ? nil : store.calendar(withIdentifier: model.remindersListID)
        guard let list = chosen ?? store.defaultCalendarForNewReminders() else { return nil }
        reminder.calendar = list
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        if routine {
            reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        }
        return reminder
    }
}
