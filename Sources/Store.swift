import Foundation

/// Журнал. У значка в строке меню нет места для объяснений, и когда он молчит, человеку
/// некуда посмотреть — а поводов молчать много: сеть, ключ, адрес, разрешения macOS.
/// Строка в файле стоит дёшево и отвечает на «почему пусто» без чтения кода.
enum Log {
    static let file = Config.dir.appendingPathComponent("monitor.log")
    private static let queue = DispatchQueue(label: "gpustack.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static func say(_ text: String) {
        queue.async {
            let line = stamp.string(from: Date()) + "  " + text + "\n"
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: file) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// Журнал не должен расти вечно: обрезаем при запуске, оставляя хвост.
    static func trim(lines: Int = 2000) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard rows.count > lines else { return }
        let tail = rows.suffix(lines).joined(separator: "\n")
        try? tail.data(using: .utf8)?.write(to: file, options: .atomic)
    }
}

/// Как модель ответила на последний опрос.
enum Health: String, Codable {
    case ok          // ответила
    case failed      // не ответила вовсе: сеть, таймаут, шлюз молчит
    /// Сервер ответил и отказал: сломанный шаблон чата, ключ, неверный запрос.
    ///
    /// Это отдельное состояние, а не разновидность отказа. Молчание лечится ожиданием,
    /// внятный отказ — нет: он держится месяцами, пока кто-нибудь не поправит настройку
    /// модели на кластере. Показывать их одним красным значит отправлять человека ждать
    /// того, что само не пройдёт.
    case refused
    case listed      // числится в списке, но настоящим запросом её не проверяют
    case unknown     // ещё не спрашивали
}

/// Вид модели — определяется опросом, а не угадыванием по имени.
///
/// Имена врут: `bge-m3` это эмбеддинги, и внутренний дообученный чекпоинт с ничего не
/// говорящим именем — тоже. Зато шлюз отвечает однозначно: на чужом эндпоинте он даёт
/// `404 {"detail":"Not Found"}`, а на «нет такой модели» — `404 {"error":...}`. Разница
/// в теле и есть надёжный признак; найденный вид запоминается и больше не ищется.
enum Kind: String, Codable {
    case chat, embedding, rerank, untested, unknown

    var path: String? {
        switch self {
        case .chat: return "/chat/completions"
        case .embedding: return "/embeddings"
        case .rerank: return "/rerank"
        case .untested, .unknown: return nil
        }
    }
    var title: String {
        switch self {
        case .chat: return "Чат"
        case .embedding: return "Эмбеддинги"
        case .rerank: return "Реранкеры"
        case .untested: return "Не проверяются"
        case .unknown: return "Вид неизвестен"
        }
    }
}

/// Одна точка истории. Пишется строкой JSON — файл дописывается, а не переписывается:
/// монитор работает месяцами, и перезапись всей истории на каждый опрос это лишний
/// износ диска и окно, в котором её можно потерять целиком.
struct Sample: Codable {
    let t: Int          // время, unix-секунды
    let m: String       // модель
    let ok: Bool        // годилась ли к работе в этот момент
    let ms: Int         // сколько отвечала
    let why: String?    // чем именно не ответила
    /// Отказ отличается от молчания, и в истории это видно цветом. Поле необязательное:
    /// старые записи его не знают и читаются как раньше.
    var st: String? = nil

    var health: Health {
        if ok { return .ok }
        return st == Health.refused.rawValue ? .refused : .failed
    }
}

/// Текущее состояние модели — то, что видно в строке меню прямо сейчас.
struct ModelState {
    var name: String
    var kind: Kind = .unknown
    var health: Health = .unknown
    var ms: Int = 0
    var why: String = ""
    var checked: Date?
    /// Время, когда модель впервые появилась в списке шлюза.
    var seen: Date?
}

/// История: дописываемый JSONL плюс подсчёт доступности за период.
final class Store {
    private let file = Config.dir.appendingPathComponent("history.jsonl")
    private let queue = DispatchQueue(label: "gpustack.store")
    private var cache: [Sample] = []
    private var loaded = false

    func append(_ s: Sample) {
        queue.sync {
            loadLocked()
            cache.append(s)
            guard let line = try? JSONEncoder().encode(s) else { return }
            var data = line
            data.append(0x0A)
            if let h = try? FileHandle(forWritingTo: file) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    func samples() -> [Sample] {
        queue.sync { loadLocked(); return cache }
    }

    /// Доля успешных опросов за период. `nil` — за это время модель не спрашивали ни
    /// разу: показать «0 %» было бы враньём, это не отказ, а отсутствие замеров.
    func uptime(_ model: String, since: Date) -> Double? {
        let from = Int(since.timeIntervalSince1970)
        let rows = samples().filter { $0.m == model && $0.t >= from }
        guard !rows.isEmpty else { return nil }
        return Double(rows.filter { $0.ok }.count) / Double(rows.count)
    }

    /// Отрезки для полосы истории: период делится на `buckets` равных корзин, и корзина
    /// краснеет, если в ней был хоть один отказ. Прятать единственный сбой внутри
    /// зелёного часа нельзя — искать будут именно его.
    func strip(_ model: String, from: Date, to: Date, buckets: Int) -> [Health] {
        let a = Int(from.timeIntervalSince1970), b = Int(to.timeIntervalSince1970)
        let span = max(1, b - a)
        var out = [Health](repeating: .unknown, count: buckets)
        for s in samples() where s.m == model && s.t >= a && s.t <= b {
            let i = min(buckets - 1, (s.t - a) * buckets / span)
            // Худшее в корзине побеждает: единственный сбой за час и есть то, что ищут.
            let h = s.health
            if h == .failed { out[i] = .failed }
            else if h == .refused, out[i] != .failed { out[i] = .refused }
            else if out[i] == .unknown { out[i] = .ok }
        }
        return out
    }

    /// Старое из истории вычищается при запуске: файл растёт вечно, а смотрят в него
    /// на месяц назад.
    func prune(days: Int) {
        queue.sync {
            loadLocked()
            let edge = Int(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)
            let kept = cache.filter { $0.t >= edge }
            guard kept.count != cache.count else { return }
            cache = kept
            let enc = JSONEncoder()
            let body = kept.compactMap { try? enc.encode($0) }
                .map { String(data: $0, encoding: .utf8) ?? "" }
                .joined(separator: "\n")
            try? (body + "\n").data(using: .utf8)?.write(to: file, options: .atomic)
        }
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        cache = text.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? dec.decode(Sample.self, from: d)
        }
    }
}
