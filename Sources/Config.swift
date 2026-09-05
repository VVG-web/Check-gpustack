import Foundation

/// Настройка монитора. Живёт в Application Support, правится в самом приложении —
/// человек, который не открывает терминал, не должен идти туда за одной строкой.
///
/// Приложение НЕ читает ничего за пределами своей папки, и это не аккуратность, а
/// вынужденный урок. Первая версия подхватывала адрес и ключ из настройки Авроры в
/// `~/Documents`. Запущенное из терминала оно работало, а собранное в `.app` — вставало
/// намертво: macOS спрашивает разрешение на «Документы», а спросить некого — значка в
/// доке нет, окна нет, и приложение висит в `__open` на главном потоке, не показав
/// ничего. Снаружи это выглядит как «не запускается».
///
/// Поэтому первую настройку кладёт `build.command`: он запускается из терминала, где
/// доступ к «Документам» уже есть. Приложению остаётся своя папка, куда пускают всегда.
/// Что у модели скрыто. Два места, где она попадается на глаза, — и прятать их надо
/// порознь: из меню убирают то, что мозолит глаза каждый день, а из истории — то, что
/// не хочется видеть в отчёте. Совпадают эти списки не всегда.
struct Hidden: Codable, Equatable {
    var menu: Bool = true
    var history: Bool = true

    /// Обе галочки сняты — модель не скрыта ниоткуда, и держать её в исключениях незачем.
    var isEmpty: Bool { !menu && !history }
}

struct Config: Codable {
    /// Адрес шлюза. Пусто — приложение ещё не настроено; своего адреса в исходниках нет
    /// нарочно, чтобы чужой контур не уезжал вместе с кодом.
    var url: String = ""
    var key: String = ""
    /// Список моделей — дёшево: обычный GET, генерации нет. Спрашиваем часто.
    var rosterSeconds: Int = 60
    /// Настоящий запрос к каждой модели — это работа на общем кластере. Спрашиваем редко.
    var probeSeconds: Int = 900
    var historyDays: Int = 90
    /// Скрытые модели: имя → где именно спрятана.
    var hidden: [String: Hidden] = [:]

    /// Разбор написан руками, а не выдан компилятором, и это не педантизм.
    ///
    /// Синтезированный разбор требует В ФАЙЛЕ все поля — даже те, у которых есть значение
    /// по умолчанию. Стоит добавить в настройку новое поле, и старый `config.json`
    /// перестаёт читаться; `load()` молча берёт настройку с нуля, и вместе с ней человек
    /// теряет ключ и адрес шлюза. Проверено на живом файле до того, как это случилось.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? d.key
        rosterSeconds = try c.decodeIfPresent(Int.self, forKey: .rosterSeconds) ?? d.rosterSeconds
        probeSeconds = try c.decodeIfPresent(Int.self, forKey: .probeSeconds) ?? d.probeSeconds
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays) ?? d.historyDays
        hidden = try c.decodeIfPresent([String: Hidden].self, forKey: .hidden) ?? d.hidden
    }

    // ------------------------------------------------------------ скрытие

    func hiddenFromMenu(_ model: String) -> Bool { hidden[model]?.menu ?? false }
    func hiddenFromHistory(_ model: String) -> Bool { hidden[model]?.history ?? false }

    mutating func hide(_ model: String) { hidden[model] = Hidden() }
    mutating func show(_ model: String) { hidden.removeValue(forKey: model) }

    static let dir: URL = {
        // Куда класть свои файлы. Обычно Application Support; переменная окружения
        // существует ради проверок и приложением никогда не задаётся.
        //
        // Заведена не для чистоты: тест правил скрытия писал настройку через тот же
        // `save()`, что и приложение, и первым же прогоном стёр живой ключ к шлюзу.
        // Отдельная папка отрезает тесту дорогу к настоящим файлам.
        let base: URL
        if let own = ProcessInfo.processInfo.environment["GPUSTACK_MONITOR_DIR"], !own.isEmpty {
            base = URL(fileURLWithPath: own, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
                .appendingPathComponent("GPUStackMonitor", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static var file: URL { dir.appendingPathComponent("config.json") }

    static func load() -> Config {
        if let data = try? Data(contentsOf: file),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            return c
        }
        let c = Config()
        c.save()
        return c
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? data.write(to: Config.file, options: .atomic)
        // Ключ — секрет: файл читает только владелец. По умолчанию было бы 0644.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Config.file.path)
    }
}
