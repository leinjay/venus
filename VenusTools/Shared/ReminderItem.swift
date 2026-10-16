import Foundation

struct ReminderItem: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var dueAt: Date
    var isDone: Bool

    init(id: UUID = UUID(), title: String, dueAt: Date, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.isDone = isDone
    }
}
