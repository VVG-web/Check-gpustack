import Foundation

/// Разовый перенос данных на имена вида `шлюз/модель`.
///
/// До появления нескольких шлюзов модель звалась просто `qwen3.8-27b`, и так записаны
/// месяц замеров, найденные виды моделей и список скрытого. Оставить два написания
/// рядом нельзя: история разошлась бы с живыми данными ровно по тем моделям, которые
/// человек уже наблюдает.
///
/// Переносим один раз и помечаем, что перенесли. Старое имя принадлежит `gpustack` —
/// единственному шлюзу прежних версий.
enum Migration {
    static var marker: URL { Config.dir.appendingPathComponent("migrated-backends.txt") }

    static func run() {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        backup()
        let done = history() + keys("kinds.json") + keys("untested.json") + hidden()
        try? "перенесено на имена шлюз/модель\n".data(using: .utf8)?.write(to: marker)
        if done > 0 { Log.say("перенос имён на «\(Config.legacyName)/модель»: \(done) записей") }
    }

    /// Запасная копия истории перед разовой переписью.
    ///
    /// Перенос проверен прогоном и пишется атомарно, но переписывает он месяцы чужих
    /// замеров — то, чего не восстановить ничем. Копия стоит одного файла рядом, и
    /// делается она один раз, перед единственной такой переписью в жизни приложения.
    private static func backup() {
        let file = Config.dir.appendingPathComponent("history.jsonl")
        let copy = Config.dir.appendingPathComponent("history.jsonl.до-шлюзов")
        guard FileManager.default.fileExists(atPath: file.path),
              !FileManager.default.fileExists(atPath: copy.path) else { return }
        try? FileManager.default.copyItem(at: file, to: copy)
        Log.say("перед переносом имён сделана копия истории: \(copy.lastPathComponent)")
    }

    /// Переименование шлюза: имя входит в имя каждой модели, а значит и в историю.
    ///
    /// Без этого переименование молча обнуляло бы прошлое: модели уехали бы под новым
    /// именем, а месяц замеров остался бы под старым — и в окне появились бы двойники
    /// с пустой историей у каждого.
    static func rename(from old: String, to new: String) {
        guard old != new, !old.isEmpty, !new.isEmpty else { return }
        let swap: (String) -> String = { name in
            let parts = Backend.split(name)
            return parts.backend == old ? Backend.qualify(new, parts.model) : name
        }
        let moved = history(map: swap) + keys("kinds.json", map: swap)
            + keys("untested.json", map: swap) + hidden(map: swap)
        Log.say("шлюз «\(old)» переименован в «\(new)»: перенесено записей \(moved)")
    }

    /// Имя без косой черты — наследие. С косой — уже перенесено, не трогаем.
    private static func qualify(_ name: String) -> String {
        name.contains("/") ? name : Config.legacyName + "/" + name
    }

    /// Замеры. Файл большой (десятки тысяч строк), поэтому правим построчно и пишем
    /// рядом: оборваться посреди перезаписи истории — худшее, что тут может случиться.
    private static func history(map: ((String) -> String)? = nil) -> Int {
        let change = map ?? qualify
        let file = Config.dir.appendingPathComponent("history.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        let dec = JSONDecoder(), enc = Store.encoder
        var out: [String] = [], changed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8),
                  var s = try? dec.decode(Sample.self, from: d) else { continue }
            let full = change(s.m)
            if full != s.m {
                s = Sample(t: s.t, m: full, ok: s.ok, ms: s.ms, why: s.why, st: s.st)
                changed += 1
            }
            if let e = try? enc.encode(s), let str = String(data: e, encoding: .utf8) {
                out.append(str)
            }
        }
        guard changed > 0, let blob = (out.joined(separator: "\n") + "\n").data(using: .utf8)
        else { return 0 }
        // Атомарная запись и есть безопасная подмена: Foundation сам пишет рядом и
        // переименовывает. Делать это руками — лишний способ ошибиться, и первая версия
        // здесь как раз молча не подменила файл.
        do { try blob.write(to: file, options: .atomic) } catch {
            Log.say("перенос истории не удался: \(error.localizedDescription)")
            return 0
        }
        return changed
    }

    /// Словари «имя модели → что-то»: виды и причины «не проверяется».
    private static func keys(_ name: String, map: ((String) -> String)? = nil) -> Int {
        let change = map ?? qualify
        let file = Config.dir.appendingPathComponent(name)
        guard let d = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String: String].self, from: d)
        else { return 0 }
        var out: [String: String] = [:], changed = 0
        for (k, v) in stored {
            let full = change(k)
            if full != k { changed += 1 }
            out[full] = v
        }
        guard changed > 0, let e = try? Store.encoder.encode(out) else { return 0 }
        try? e.write(to: file, options: .atomic)
        return changed
    }

    /// Список скрытого лежит в настройке — её правим тем же правилом.
    private static func hidden(map: ((String) -> String)? = nil) -> Int {
        let change = map ?? qualify
        var cfg = Config.load()
        var out: [String: Hidden] = [:], changed = 0
        for (k, v) in cfg.hidden {
            let full = change(k)
            if full != k { changed += 1 }
            out[full] = v
        }
        guard changed > 0 else { return 0 }
        cfg.hidden = out
        cfg.save()
        return changed
    }
}
