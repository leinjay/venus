import SwiftUI

struct FocusView: View {
    @ObservedObject var store: FocusTimerStore

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                BrandHeader(
                    eyebrow: "A QUIETER MOMENT",
                    title: "专注",
                    subtitle: "给重要的事，留出一段安静时间。"
                )

                VStack(spacing: 20) {
                    HStack {
                        AccentLabel(title: "专注时段")
                        Spacer()
                        Image(systemName: "leaf")
                            .foregroundStyle(AppTheme.pine)
                    }

                    ZStack {
                        Circle().stroke(AppTheme.sage, lineWidth: 12)
                        Circle()
                            .trim(from: 0, to: store.progress)
                            .stroke(AppTheme.pine, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 5) {
                            Text(store.timeText)
                                .font(.system(size: 39, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(AppTheme.ink)
                            Text(store.isRunning ? "正在专注" : "准备开始")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppTheme.secondary)
                        }
                    }
                    .frame(width: 204, height: 204)
                    .padding(.vertical, 8)

                    HStack(spacing: 12) {
                        Button {
                            store.toggle()
                        } label: {
                            Label(store.isRunning ? "暂停" : "开始专注", systemImage: store.isRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .foregroundStyle(.white)
                                .background(AppTheme.pine, in: Capsule())
                        }

                        Button {
                            store.reset()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 48, height: 48)
                                .foregroundStyle(AppTheme.pine)
                                .background(AppTheme.sage, in: Circle())
                        }
                        .accessibilityLabel("重置计时")
                    }
                }
                .surfaceCard(padding: 20)

                HStack(spacing: 12) {
                    MiniInfoCard(title: "专注", value: "25 分钟", icon: "sun.max")
                    MiniInfoCard(title: "休息", value: "5 分钟", icon: "cup.and.saucer")
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkle").foregroundStyle(AppTheme.amber)
                    Text("先选一件最重要的小事。专注结束时，记得起身活动一下。")
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.secondary)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(AppTheme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(AppTheme.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct MiniInfoCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: icon).foregroundStyle(AppTheme.pine)
            Text(title).font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(padding: 16)
    }
}

struct ConverterView: View {
    @State private var amount = "2.5"
    @State private var milesToKilometers = false
    @FocusState private var inputFocused: Bool

    private var inputValue: Double {
        Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var convertedValue: Double {
        milesToKilometers
            ? UnitConverter.milesToKilometers(inputValue)
            : UnitConverter.kilometersToMiles(inputValue)
    }

    private var inputUnit: String { milesToKilometers ? "mi" : "km" }
    private var outputUnit: String { milesToKilometers ? "km" : "mi" }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                BrandHeader(
                    eyebrow: "SMALL THINGS, MADE SIMPLE",
                    title: "换算",
                    subtitle: "常用长度单位，轻轻一点就能换算。"
                )

                VStack(alignment: .leading, spacing: 18) {
                    Text("转换方向")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.secondary)
                    Picker("转换方向", selection: $milesToKilometers) {
                        Text("千米 → 英里").tag(false)
                        Text("英里 → 千米").tag(true)
                    }
                    .pickerStyle(.segmented)

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("输入数值").font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                TextField("0", text: $amount)
                                    .font(.system(size: 30, weight: .medium, design: .rounded))
                                    .keyboardType(.decimalPad)
                                    .focused($inputFocused)
                                Text(inputUnit)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(AppTheme.pine)
                            }
                        }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(AppTheme.amber)
                            .padding(.horizontal, 4)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("结果").font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                            Text(String(format: "%.2f", convertedValue))
                                .font(.system(size: 28, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(outputUnit)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.pine)
                        }
                    }
                    .padding(16)
                    .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 17))

                    Text("结果会随输入即时更新")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondary)
                }
                .surfaceCard()

                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(AppTheme.pine)
                    Text("1 英里约等于 1.61 千米")
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.secondary)
                    Spacer()
                }
                .surfaceCard(padding: 16)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppTheme.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct ChecklistView: View {
    @ObservedObject var store: ChecklistStore
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var finishedCount: Int {
        store.items.filter(\.isDone).count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                BrandHeader(
                    eyebrow: "A LITTLE ORDER",
                    title: "清单",
                    subtitle: "把脑海里的小事，放到一个安心的地方。"
                )

                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(AppTheme.sage, lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: store.items.isEmpty ? 0 : Double(finishedCount) / Double(store.items.count))
                            .stroke(AppTheme.pine, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppTheme.pine)
                    }
                    .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("今日进度")
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.secondary)
                        Text("\(finishedCount) / \(store.items.count) 项已完成")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.ink)
                    }
                    Spacer()
                    AccentLabel(title: "慢慢来", color: AppTheme.amber)
                }
                .surfaceCard()

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        TextField("添加一件小事…", text: $draft)
                            .focused($inputFocused)
                            .submitLabel(.done)
                            .onSubmit(addItem)
                        Button(action: addItem) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(AppTheme.pine, in: Circle())
                        }
                        .accessibilityLabel("添加清单项目")
                    }
                    .padding(.bottom, 14)
                    Divider().overlay(AppTheme.line)
                    ForEach(store.items) { item in
                        ChecklistRow(item: item) {
                            store.toggle(item)
                        } onDelete: {
                            store.remove(item)
                        }
                    }
                }
                .surfaceCard()

                HStack(spacing: 10) {
                    Image(systemName: "hand.raised").foregroundStyle(AppTheme.amber)
                    Text("完成一项就勾选它，清单会自动保存在本机。")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppTheme.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func addItem() {
        store.add(title: draft)
        draft = ""
        inputFocused = false
    }
}

private struct ChecklistRow: View {
    let item: ChecklistItem
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(item.isDone ? AppTheme.pine : AppTheme.line)
            }
            .buttonStyle(.plain)
            Text(item.title)
                .font(.system(size: 14))
                .foregroundStyle(item.isDone ? AppTheme.secondary : AppTheme.ink)
                .strikethrough(item.isDone, color: AppTheme.secondary)
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.secondary.opacity(0.7))
                    .padding(7)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除\(item.title)")
        }
        .padding(.vertical, 13)
    }
}

struct RemindersView: View {
    @ObservedObject var store: ReminderStore
    @State private var draft = ""
    @State private var dueAt = Date().addingTimeInterval(60 * 60)
    @FocusState private var inputFocused: Bool

    private var completedCount: Int {
        store.reminders.filter(\.isDone).count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                BrandHeader(
                    eyebrow: "GENTLE NUDGES",
                    title: "提醒",
                    subtitle: "记下重要的小事，也能在手腕上看见。"
                )

                VStack(alignment: .leading, spacing: 17) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("今天的准备度")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppTheme.secondary)
                            Text(store.reminders.isEmpty ? "还没有提醒" : "\(completedCount) / \(store.reminders.count) 项已完成")
                                .font(.system(size: 22, weight: .semibold, design: .serif))
                                .foregroundStyle(AppTheme.ink)
                        }
                        Spacer()
                        ZStack {
                            Circle().stroke(AppTheme.sage, lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: store.reminders.isEmpty ? 0 : Double(completedCount) / Double(store.reminders.count))
                                .stroke(AppTheme.pine, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(store.reminders.isEmpty ? "—" : "\(Int(Double(completedCount) / Double(store.reminders.count) * 100))%")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.pine)
                        }
                        .frame(width: 58, height: 58)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "applewatch").foregroundStyle(AppTheme.pine)
                        Text(store.syncMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.secondary)
                    }
                    .padding(.top, 2)
                }
                .surfaceCard()

                VStack(alignment: .leading, spacing: 13) {
                    Text("新提醒")
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                        .foregroundStyle(AppTheme.ink)
                    TextField("例如：散步、喝水…", text: $draft)
                        .focused($inputFocused)
                        .padding(13)
                        .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 14))
                    DatePicker("提醒时间", selection: $dueAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .font(.system(size: 13))
                        .tint(AppTheme.pine)
                    Button(action: addReminder) {
                        Label("保存提醒", systemImage: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .foregroundStyle(.white)
                            .background(AppTheme.pine, in: Capsule())
                    }
                }
                .surfaceCard()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("接下来")
                            .font(.system(size: 19, weight: .semibold, design: .serif))
                            .foregroundStyle(AppTheme.ink)
                        Spacer()
                        AccentLabel(title: "\(store.reminders.count) 条")
                    }
                    ForEach(store.reminders.sorted { $0.dueAt < $1.dueAt }) { item in
                        ReminderRow(item: item) {
                            store.toggle(item)
                        } onDelete: {
                            store.remove(item)
                        }
                    }
                }
                .surfaceCard()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkle").foregroundStyle(AppTheme.amber)
                    Text("手表与手机配对后，提醒会通过 Apple Watch 同步共享。")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppTheme.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func addReminder() {
        store.add(title: draft, dueAt: dueAt)
        draft = ""
        dueAt = Date().addingTimeInterval(60 * 60)
        inputFocused = false
    }
}

private struct ReminderRow: View {
    let item: ReminderItem
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(item.isDone ? AppTheme.pine : AppTheme.line)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(item.isDone ? AppTheme.secondary : AppTheme.ink)
                    .strikethrough(item.isDone)
                Text(item.dueAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.secondary)
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.secondary.opacity(0.7))
                    .padding(7)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除\(item.title)")
        }
        .padding(.vertical, 10)
    }
}
