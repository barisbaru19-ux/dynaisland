import AppKit
import SwiftUI

// MARK: - Data

/// One line of the "Hari ini" checklist.
/// - Routine (`isRoutine`): comes back unchecked every morning (drink water, exercise, read…).
/// - Task: stays until it's done; finished tasks disappear the next day, unfinished ones carry over.
struct ChecklistItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var isRoutine: Bool
    /// Day ("2026-10-31") it was last checked off.
    var doneOn: String?
    /// Day it was added (to mark tasks carried over from earlier days).
    var addedOn: String
}

enum DayKey {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(_ date: Date = Date()) -> String {
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    static func previous(_ date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date.addingTimeInterval(-86_400)
    }
}

/// Saved in UserDefaults, kept on this Mac only.
enum ChecklistStorage {
    static let itemsKey = "checklistItems"
    static let dayKey = "checklistDay"
    static let completedDaysKey = "checklistCompletedDays"

    static func loadItems() -> [ChecklistItem] {
        guard let data = UserDefaults.standard.data(forKey: itemsKey),
              let items = try? JSONDecoder().decode([ChecklistItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [ChecklistItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: itemsKey)
        }
    }

    static let suggestions: [String] = [
        "Minum air 8 gelas", "Olahraga 15 menit", "Baca Al-Qur'an", "Cek email", "Jalan kaki 5.000 langkah", "Tidur sebelum jam 11",
    ]
}

// MARK: - "Hari ini" tab

@MainActor
struct TodayTabView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if model.checklist.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.7))
                Text("Mulai hari dengan checklist")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
                Text("Rutinitas muncul lagi setiap pagi. Tugas yang belum selesai terbawa ke besok.")
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    ForEach(ChecklistStorage.suggestions.prefix(3), id: \.self) { title in
                        Button(action: { model.addChecklistItem(title, routine: true) }) {
                            Text("+ " + title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 9)
                                .frame(height: 22)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                CapsuleButton(title: "Tambah", symbol: "plus", prominent: true) {
                    DynaIslandApp.delegate.addChecklistItem()
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                header
                    .padding(.horizontal, 18)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(model.checklist) { item in
                            ChecklistRow(model: model, item: item)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 2)
        }
    }

    private var header: some View {
        let total = model.checklist.count
        let done = model.checklistDoneCount
        let progress = total > 0 ? Double(done) / Double(total) : 0
        return HStack(spacing: 10) {
            ZStack {
                FocusRing(progress: progress, tint: NoticeTint.green.color, lineWidth: 3)
                Text("\(done)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundColor(.white)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(done == total ? "Semua selesai!" : "\(done) dari \(total) selesai")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.5))
            }
            Spacer(minLength: 6)
            if model.checklistStreak > 0 {
                Label("\(model.checklistStreak) hari", systemImage: "flame.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.62, blue: 0.22))
                    .help("Hari berturut-turut semua checklist selesai")
            }
            CapsuleButton(title: "Tambah", symbol: "plus") {
                DynaIslandApp.delegate.addChecklistItem()
            }
        }
    }
}

@MainActor
struct ChecklistRow: View {
    @ObservedObject var model: IslandModel
    let item: ChecklistItem

    var body: some View {
        let done = model.isDoneToday(item)
        let carried = !item.isRoutine && item.addedOn < model.checklistDay
        Button(action: { model.toggleChecklistItem(item.id) }) {
            HStack(spacing: 9) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(done ? NoticeTint.green.color : Color.white.opacity(0.5))
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(done ? Color.white.opacity(0.45) : .white)
                    .strikethrough(done, color: Color.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if item.isRoutine {
                    Image(systemName: "repeat")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.35))
                        .help("Rutinitas: muncul lagi setiap hari")
                } else if carried {
                    Text("dari kemarin")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(red: 1.0, green: 0.8, blue: 0.0).opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .contextMenu {
            Button(item.isRoutine ? "Jadikan tugas sekali" : "Ulangi setiap hari (rutinitas)") {
                model.setChecklistRoutine(item.id, routine: !item.isRoutine)
            }
            Divider()
            Button("Hapus") { model.removeChecklistItem(item.id) }
        }
    }
}
