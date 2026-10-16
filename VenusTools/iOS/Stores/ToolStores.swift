import Foundation
import Combine

final class FocusTimerStore: ObservableObject {
    @Published private(set) var secondsRemaining = 25 * 60
    @Published private(set) var isRunning = false
    private var timer: Timer?

    var progress: Double {
        Double(secondsRemaining) / Double(25 * 60)
    }

    var timeText: String {
        String(format: "%02d:%02d", secondsRemaining / 60, secondsRemaining % 60)
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.secondsRemaining > 0 {
                self.secondsRemaining -= 1
            } else {
                self.pause()
            }
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func reset() {
        pause()
        secondsRemaining = 25 * 60
    }

    deinit {
        timer?.invalidate()
    }
}

struct ChecklistItem: Identifiable, Codable {
    var id: UUID
    var title: String
    var isDone: Bool

    init(id: UUID = UUID(), title: String, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }
}

final class ChecklistStore: ObservableObject {
    @Published private(set) var items: [ChecklistItem] = []
    private let storageKey = "venus.tools.checklist.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ChecklistItem].self, from: data) {
            items = saved
        } else {
            items = [
                ChecklistItem(title: "整理今天的待办"),
                ChecklistItem(title: "读几页书"),
                ChecklistItem(title: "给自己倒杯水", isDone: true)
            ]
            persist()
        }
    }

    func add(title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        items.insert(ChecklistItem(title: value), at: 0)
        persist()
    }

    func toggle(_ item: ChecklistItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
        persist()
    }

    func remove(_ item: ChecklistItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum UnitConverter {
    static func kilometersToMiles(_ value: Double) -> Double {
        value * 0.621371
    }

    static func milesToKilometers(_ value: Double) -> Double {
        value / 0.621371
    }
}
