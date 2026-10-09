import Foundation

/// Проверка переноса на имена `шлюз/модель`.
///
/// Перенос трогает месяц живых замеров и делается один раз. Ошибиться тут значит либо
/// потерять историю, либо получить два написания одной модели — и расхождение вылезет
/// не сразу, а когда человек откроет окно и не узнает своих данных.
///
///   swiftc -o /tmp/check_migration Sources/Config.swift Sources/Store.swift \
///       Sources/Migration.swift Tests/check_migration.swift
///   GPUSTACK_MONITOR_DIR=/tmp/gsm-перенос /tmp/check_migration
@main
struct CheckMigration {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "  ✅ " : "  ❌ ") + what)
        if !ok { failures += 1 }
    }

    static func main() {
        guard let dir = ProcessInfo.processInfo.environment["GPUSTACK_MONITOR_DIR"] else {
            print("Нужна своя папка: GPUSTACK_MONITOR_DIR=/tmp/gsm-перенос /tmp/check_migration")
            exit(2)
        }
        let d = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)

        // Данные, как их писала прежняя версия: голые имена и один шлюз в настройке.
        let old = """
        {"t":1,"m":"qwen3.8-27b","ok":true,"ms":210}
        {"t":2,"m":"bge-m3","ok":false,"ms":0,"why":"молчит"}
        {"t":3,"m":"другой/уже-с-именем","ok":true,"ms":100}
        """
        try! old.write(to: d.appendingPathComponent("history.jsonl"), atomically: true,
                       encoding: .utf8)
        try! #"{"qwen3.8-27b":"chat","bge-m3":"embedding"}"#
            .write(to: d.appendingPathComponent("kinds.json"), atomically: true, encoding: .utf8)
        try! #"{"large-v3":"404"}"#
            .write(to: d.appendingPathComponent("untested.json"), atomically: true, encoding: .utf8)
        try! #"{"url":"https://шлюз/v1","key":"секрет","rosterSeconds":60,"probeSeconds":900,"historyDays":90,"hidden":{"berta":{"menu":true,"history":false}}}"#
            .write(to: d.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        // Настройка переезжает сама, ещё до переноса файлов.
        let cfg = Config.load()
        check(cfg.backends.count == 1 && cfg.backends[0].name == "gpustack",
              "единственный прежний шлюз стал «gpustack»")
        check(cfg.backends[0].url == "https://шлюз/v1" && cfg.backends[0].key == "секрет",
              "адрес и ключ при переезде целы")
        check(cfg.ready, "монитор считается настроенным")

        Migration.run()

        // Проверяем разбором, а не поиском подстроки: как именно записана косая черта —
        // дело кодировщика, и первая версия этой проверки на том и обожглась.
        let after = try! String(contentsOf: d.appendingPathComponent("history.jsonl"),
                                encoding: .utf8)
        let rows = after.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(Sample.self, from: Data($0.utf8))
        }
        check(rows.count == 3, "ни один замер не потерян: \(rows.count)")
        let names = Set(rows.map(\.m))
        check(names.contains("gpustack/qwen3.8-27b") && names.contains("gpustack/bge-m3"),
              "замеры переехали под имя gpustack: \(names.sorted())")
        check(names.contains("другой/уже-с-именем"), "чужое имя со шлюзом не тронуто")
        check(rows.first(where: { $0.m == "gpustack/qwen3.8-27b" })?.ms == 210,
              "поля замера сохранены, а не обнулены")
        check(rows.first(where: { $0.m == "gpustack/bge-m3" })?.why == "молчит",
              "причина отказа сохранена")
        check(!after.contains("\\/"), "косая черта в истории не экранирована — файл читаем")

        let kinds = try! JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: d.appendingPathComponent("kinds.json")))
        check(kinds["gpustack/qwen3.8-27b"] == "chat" && kinds["qwen3.8-27b"] == nil,
              "виды моделей переехали и старых ключей не осталось")
        let why = try! JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: d.appendingPathComponent("untested.json")))
        check(why["gpustack/large-v3"] == "404", "отметки «не проверяется» переехали")
        check(Config.load().hidden["gpustack/berta"]?.history == false,
              "скрытое переехало вместе с галочками")

        // Повторный запуск ничего не портит: перенос одноразовый.
        let snapshot = try! String(contentsOf: d.appendingPathComponent("history.jsonl"),
                                   encoding: .utf8)
        Migration.run()
        check(try! String(contentsOf: d.appendingPathComponent("history.jsonl"),
                          encoding: .utf8) == snapshot,
              "второй запуск переноса ничего не меняет")

        print(failures == 0 ? "\nВсё сошлось." : "\nПровалов: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
