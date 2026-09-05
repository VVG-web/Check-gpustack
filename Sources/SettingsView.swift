import SwiftUI

/// Настройки: шлюз, сроки опроса и список скрытых моделей.
///
/// Раньше это был тесный системный диалог на четыре поля. Список исключений в него не
/// помещается: у каждой строки две галочки и кнопка возврата, и всё это надо видеть
/// разом — иначе непонятно, почему модель пропала из одного места и осталась в другом.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Шлюз") {
                    TextField("Адрес /v1", text: $model.url)
                    SecureField("Ключ", text: $model.key)
                }
                Section("Как часто спрашивать") {
                    HStack {
                        Text("Список моделей, секунд")
                        Spacer()
                        TextField("", value: $model.rosterSeconds, format: .number)
                            .frame(width: 70).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Настоящий запрос, секунд")
                        Spacer()
                        TextField("", value: $model.probeSeconds, format: .number)
                            .frame(width: 70).multilineTextAlignment(.trailing)
                    }
                    Text("Список — обычный GET, он ничего не стоит. Настоящий запрос "
                         + "занимает общий кластер: чем чаще, тем больше вы мешаете другим.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 250)

            Divider()
            HStack {
                Text("Скрытые модели").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.hidden.isEmpty ? "пусто"
                     : "\(model.hidden.count) · скрыть модель можно в меню значка")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)

            if model.hidden.isEmpty {
                Text("Ничего не скрыто. Чтобы скрыть модель, нажмите на неё в меню значка\n"
                     + "и выберите «Скрыть». Здесь можно будет уточнить, где именно.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            } else {
                HStack(spacing: 0) {
                    Text("Модель").frame(width: 230, alignment: .leading)
                    Text("в меню").frame(width: 74)
                    Text("в истории").frame(width: 84)
                    Spacer()
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 2)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.hidden, id: \.name) { row in
                            HStack(spacing: 0) {
                                Text(row.name).font(.system(size: 12))
                                    .frame(width: 230, alignment: .leading).lineLimit(1)
                                // Галочка стоит там, где модель СКРЫТА: так строка
                                // читается как «спрятана здесь», а не наоборот.
                                Toggle("", isOn: model.binding(row.name, \.menu))
                                    .labelsHidden().frame(width: 74)
                                Toggle("", isOn: model.binding(row.name, \.history))
                                    .labelsHidden().frame(width: 84)
                                Spacer()
                                Button("Вернуть") { model.restore(row.name) }
                                    .help("Убрать из исключений: модель снова появится и в "
                                          + "меню, и в истории")
                            }
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(minHeight: 90, maxHeight: 190)
            }

            Divider()
            HStack {
                Text(model.note).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { model.close?() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520)
    }
}

/// Состояние окна настроек. Пишет сразу: «Сохранить» здесь не нужно — все правки видны
/// в меню тут же, а лишняя кнопка только даёт повод забыть её нажать.
final class SettingsModel: ObservableObject {
    struct Row { let name: String }

    @Published var url: String { didSet { push() } }
    @Published var key: String { didSet { push() } }
    @Published var rosterSeconds: Int { didSet { push() } }
    @Published var probeSeconds: Int { didSet { push() } }
    @Published var hidden: [Row] = []
    @Published var note = ""
    var close: (() -> Void)?

    private let monitor: Monitor
    private let onChange: () -> Void

    init(monitor: Monitor, onChange: @escaping () -> Void) {
        self.monitor = monitor
        self.onChange = onChange
        let c = monitor.config
        url = c.url; key = c.key
        rosterSeconds = c.rosterSeconds; probeSeconds = c.probeSeconds
        reload()
    }

    func reload() {
        hidden = monitor.config.hidden.keys.sorted { $0.lowercased() < $1.lowercased() }
            .map { Row(name: $0) }
        note = hidden.isEmpty ? "" : "Скрытые модели опрашиваются как обычно — прячется "
            + "только показ. В счётчике значка они тоже учитываются."
    }

    func binding(_ name: String, _ path: WritableKeyPath<Hidden, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.monitor.config.hidden[name]?[keyPath: path] ?? false },
            set: { value in
                var c = self.monitor.config
                var h = c.hidden[name] ?? Hidden()
                h[keyPath: path] = value
                // Сняли обе галочки — модель больше нигде не спрятана, и держать её в
                // списке исключений незачем: пустая строка только сбивает с толку.
                if h.isEmpty { c.hidden.removeValue(forKey: name) } else { c.hidden[name] = h }
                self.monitor.apply(c)
                self.reload()
                self.onChange()
            })
    }

    func restore(_ name: String) {
        var c = monitor.config
        c.show(name)
        monitor.apply(c)
        reload()
        onChange()
    }

    private func push() {
        var c = monitor.config
        c.url = url.trimmingCharacters(in: .whitespaces)
        c.key = key
        c.rosterSeconds = max(15, rosterSeconds)
        c.probeSeconds = max(60, probeSeconds)
        monitor.apply(c)
        onChange()
    }
}
