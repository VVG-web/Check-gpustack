import SwiftUI

/// Окно истории: полоса состояний по каждой модели и доступность за период.
///
/// Одно текущее «доступна/нет» отвечает на вопрос «работает сейчас», но не на тот, ради
/// которого монитор и заводят: «на неё вообще можно рассчитывать». Ответ на второй виден
/// только в истории — и именно поэтому она здесь, а не в логе.
struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $model.period) {
                    ForEach(Period.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                if !model.hiddenNote.isEmpty {
                    Text(model.hiddenNote).foregroundStyle(.secondary).font(.system(size: 11))
                    Text("·").foregroundStyle(.secondary).font(.system(size: 11))
                }
                Text(model.subtitle).foregroundStyle(.secondary).font(.system(size: 11))
            }
            .padding(12)
            Divider()
            if model.rows.isEmpty {
                VStack(spacing: 6) {
                    Text("Замеров пока нет").font(.title3)
                    Text("Первый настоящий опрос моделей идёт после запуска, дальше — по\n"
                         + "расписанию. Полосы появятся, как только он пройдёт.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows) { row in
                            HistoryRow(row: row)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Legend(color: .green, text: "отвечала")
                Legend(color: .red, text: "не ответила")
                Legend(color: .orange, text: "отвечала и отказала")
                Legend(color: Color.secondary.opacity(0.22), text: "не спрашивали")
                Spacer()
                Text("Картинки, речь и OCR настоящим запросом не проверяются: это стоило бы генерации")
                    .foregroundStyle(.secondary).font(.system(size: 10))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(minWidth: 720, minHeight: 420)
    }
}

private struct Legend: View {
    let color: Color; let text: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 10, height: 10)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct HistoryRow: View {
    let row: HistoryModel.Row
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 12, weight: .medium))
                Text(row.kind).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 210, alignment: .leading)

            // Полоса: одна корзина времени — один прямоугольник. Красный виден, даже
            // если в корзине он один: единственный сбой за час и есть то, что ищут.
            GeometryReader { geo in
                let n = max(row.strip.count, 1)
                let w = geo.size.width / CGFloat(n)
                HStack(spacing: 0.5) {
                    ForEach(Array(row.strip.enumerated()), id: \.offset) { _, h in
                        Rectangle().fill(color(h)).frame(width: max(1, w - 0.5))
                    }
                }
                .frame(height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 22)

            Text(row.uptime).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(row.uptimeColor)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
    private func color(_ h: Health) -> Color {
        switch h {
        case .ok: return .green
        case .failed: return .red
        case .refused: return .orange
        case .listed: return .blue.opacity(0.35)
        case .unknown: return Color.secondary.opacity(0.18)
        }
    }
}

enum Period: CaseIterable {
    case day, week, month
    var title: String {
        switch self {
        case .day: return "24 часа"
        case .week: return "7 дней"
        case .month: return "30 дней"
        }
    }
    var seconds: Double {
        switch self {
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }
    var buckets: Int {
        switch self {
        case .day: return 96        // по 15 минут
        case .week: return 168      // по часу
        case .month: return 120     // по 6 часов
        }
    }
}

final class HistoryModel: ObservableObject {
    struct Row: Identifiable {
        let id: String
        let name: String
        let kind: String
        let strip: [Health]
        let uptime: String
        let uptimeColor: Color
    }
    @Published var period: Period = .day { didSet { reload() } }
    @Published var rows: [Row] = []
    @Published var subtitle = ""
    @Published var hiddenNote = ""

    private let monitor: Monitor
    init(monitor: Monitor) { self.monitor = monitor; reload() }

    func reload() {
        let to = Date(), from = to.addingTimeInterval(-period.seconds)
        var out: [Row] = []
        for name in monitor.order {
            guard let s = monitor.models[name] else { continue }
            if monitor.config.hiddenFromHistory(name) { continue }
            let strip = monitor.store.strip(name, from: from, to: to, buckets: period.buckets)
            let up = monitor.store.uptime(name, since: from)
            // «Нет замеров» и «ноль процентов» — разные вещи, и одинаковой строкой их
            // показывать нельзя: первое значит «не спрашивали», второе — «всё время лежала».
            let text = up.map { String(format: "%.1f %%", $0 * 100) } ?? "—"
            let color: Color
            switch up {
            case .none: color = .secondary
            case .some(let v) where v >= 0.99: color = .green
            case .some(let v) where v >= 0.90: color = .orange
            default: color = .red
            }
            out.append(Row(id: name, name: name, kind: s.kind.title,
                           strip: strip, uptime: text, uptimeColor: color))
        }
        rows = out
        // Про спрятанное говорим вслух: пустая строка в отчёте без объяснения выглядит
        // как потерянная модель.
        let tucked = monitor.order.filter { monitor.config.hiddenFromHistory($0) }.count
        hiddenNote = tucked == 0 ? "" : "скрыто моделей: \(tucked)"
        subtitle = monitor.lastProbe.map {
            "последний настоящий опрос: " + DateFormatter.localizedString(
                from: $0, dateStyle: .none, timeStyle: .medium)
        } ?? "настоящего опроса ещё не было"
    }
}
