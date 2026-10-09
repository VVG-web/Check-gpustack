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
    /// До самого сервера не достучались: упал VPN, пропала сеть, шлюз выключен.
    ///
    /// Отдельно от `failed`, и это не придирка. Когда нет связи, молчат разом все
    /// модели, и записывать это каждой в отказ — значит винить их за чужую беду:
    /// доступность падает у двадцати моделей из-за одного оборванного туннеля, а потом
    /// по этим числам судят об инференсе. Мы про модель в этот момент не знаем ничего —
    /// так и показываем.
    case offline
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

/// Насколько медленно ответила модель.
///
/// Пороги абсолютные, а не «относительно своей нормы», и это вывод из замеров, а не
/// упрощение. За месяц (44 680 замеров, 23 модели) медианы всех моделей уложились в
/// узкую полосу — от 197 мс до 430 мс, разброс в 2.2 раза. Подгонять шкалу под каждую
/// модель там нечего. Зато хвосты расходятся: при медиане 264 мс и 90-м перцентиле
/// 526 мс максимумы доходят до 59.8 с — вплотную к таймауту. Интересное живёт в хвосте,
/// и именно его должна показывать полоса.
///
/// Абсолютная шкала ещё и сходится с меню: там у модели написано «464 мс», и цвет в
/// истории считается по тому же числу. Две шкалы для одного числа расходятся всегда.
enum Speed: Int, CaseIterable {
    case fast       // до 0.5 с — это 90-й перцентиль всех успешных замеров
    case slow       // 0.5–2 с
    case bad        // 2–10 с
    case edge       // больше 10 с: дальше таймаут, и такие замеры уже срываются

    static func of(_ ms: Int) -> Speed {
        switch ms {
        case ..<500: return .fast
        case ..<2000: return .slow
        case ..<10000: return .bad
        default: return .edge
        }
    }

    var title: String {
        switch self {
        case .fast: return "до 0.5 с"
        case .slow: return "0.5–2 с"
        case .bad: return "2–10 с"
        case .edge: return "больше 10 с"
        }
    }
}

/// Отрезок полосы истории: что было в корзине времени и насколько медленно.
///
/// Кроме цвета отрезок хранит и то, из чего цвет получился. Цвет отвечает на «насколько
/// плохо», но не на «часто ли» и «насколько разбросано»: за час бывает четыре замера, и
/// один медленный среди трёх быстрых — совсем не то же самое, что четыре медленных.
/// Сводка нужна при наведении, и считать её потом второй раз по тем же замерам значит
/// завести второй проход и второй повод разойтись с первым.
struct Mark {
    var health: Health = .unknown
    /// Самый долгий успешный ответ в корзине. 0 — успешных не было.
    var ms: Int = 0

    var ok = 0
    var failed = 0
    var refused = 0
    var offline = 0
    /// Время всех удачных ответов корзины — для разброса.
    var times: [Int] = []

    var total: Int { ok + failed + refused + offline }
    var speed: Speed? { health == .ok && ms > 0 ? Speed.of(ms) : nil }

    /// Промежуток времени, который занимает корзина. Именно промежуток, а не момент:
    /// сектор покрывает пятнадцать минут, час или шесть часов, и «17:30» вместо
    /// «17:30–17:45» заставляет гадать, что в него вошло.
    static func span(from: Date, step: TimeInterval, index: Int) -> String {
        let a = from.addingTimeInterval(step * Double(index))
        let b = a.addingTimeInterval(step)
        let ru = Locale(identifier: "ru_RU")
        let head = DateFormatter(); head.locale = ru
        head.dateFormat = step < 86400 ? "d MMM, HH:mm" : "d MMM"
        let tail = DateFormatter(); tail.locale = ru
        // Корзина в шесть часов легко переваливает за полночь, и «19:22–01:22» читается
        // как промежуток внутри одного вечера. Если день сменился, его надо назвать.
        let sameDay = Calendar.current.isDate(a, inSameDayAs: b)
        tail.dateFormat = step >= 86400 ? "d MMM" : (sameDay ? "HH:mm" : "d MMM, HH:mm")
        return head.string(from: a) + " – " + tail.string(from: b)
    }

    /// Сводка по корзине для подсказки. Текст живёт здесь, а не в окне: его надо уметь
    /// проверить прогоном, а не глазами по наведению мыши.
    func summary(span: String) -> String {
        var lines = [span]
        if total == 0 {
            // Корзина без замеров. Красной она бывает только одна — дорисованная между
            // двумя отказами; об этом и надо сказать, а не делать вид, что замер был.
            lines.append(health == .failed
                         ? "замеров не было — связь молчала и до, и после"
                         : "не спрашивали")
            return lines.joined(separator: "\n")
        }
        var what: [String] = []
        if ok > 0 { what.append("ответов \(ok)") }
        if failed > 0 { what.append("молчания \(failed)") }
        if refused > 0 { what.append("отказов \(refused)") }
        if offline > 0 { what.append("без связи \(offline)") }
        lines.append(Mark.samplesWord(total) + ": " + what.joined(separator: ", "))
        if let s = spread {
            lines.append(s.min == s.max
                         ? "время ответа: " + Mark.human(s.mid)
                         : "время ответа: \(Mark.human(s.min)) · \(Mark.human(s.mid)) · "
                           + "\(Mark.human(s.max))  (мин · медиана · макс)")
        }
        return lines.joined(separator: "\n")
    }

    /// «1 замер», «2 замера», «5 замеров» — иначе подсказка читается как машинный вывод.
    static func samplesWord(_ n: Int) -> String {
        let ten = n % 100
        if ten >= 11, ten <= 14 { return "\(n) замеров" }
        switch n % 10 {
        case 1: return "\(n) замер"
        case 2, 3, 4: return "\(n) замера"
        default: return "\(n) замеров"
        }
    }

    static func human(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) мс" : String(format: "%.1f с", Double(ms) / 1000)
    }

    /// Мин / медиана / макс по удачным ответам. Пусто — удачных не было.
    var spread: (min: Int, mid: Int, max: Int)? {
        guard !times.isEmpty else { return nil }
        let v = times.sorted()
        let mid = v.count % 2 == 1 ? v[v.count / 2]
                                   : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
        return (v[0], mid, v[v.count - 1])
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
        if st == Health.refused.rawValue { return .refused }
        if st == Health.offline.rawValue { return .offline }
        return .failed
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

    /// Имена моделей теперь содержат косую черту (`шлюз/модель`), а JSONEncoder по
    /// умолчанию пишет её как `\/`. Историю читают глазами и grep'ом — пусть читается.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    func append(_ s: Sample) {
        queue.sync {
            loadLocked()
            cache.append(s)
            guard let line = try? Store.encoder.encode(s) else { return }
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
    ///
    /// Замеры без связи с сервером в счёт не идут вовсе — ни в числитель, ни в
    /// знаменатель. Оборванный туннель не делает модель хуже, а при прежнем счёте сутки
    /// без VPN уводили доступность всех моделей разом к нулю.
    func uptime(_ model: String, since: Date) -> Double? {
        let from = Int(since.timeIntervalSince1970)
        let rows = samples().filter { $0.m == model && $0.t >= from && $0.health != .offline }
        guard !rows.isEmpty else { return nil }
        return Double(rows.filter { $0.ok }.count) / Double(rows.count)
    }

    /// Отрезки для полосы истории: период делится на `buckets` равных корзин.
    ///
    /// В корзине побеждает худшее — и по состоянию, и по времени. Единственный сбой за
    /// час и есть то, что ищут; спрятать его за девятью удачными замерами значит сделать
    /// полосу бесполезной ровно там, где она нужна. По той же причине из успешных
    /// замеров берётся самый долгий, а не средний: средний гасит всплеск.
    func strip(_ model: String, from: Date, to: Date, buckets: Int) -> [Mark] {
        let a = Int(from.timeIntervalSince1970), b = Int(to.timeIntervalSince1970)
        let span = max(1, b - a)
        var out = [Mark](repeating: Mark(), count: buckets)
        for s in samples() where s.m == model && s.t >= a && s.t <= b {
            let i = min(buckets - 1, (s.t - a) * buckets / span)
            let h = s.health
            switch h {
            case .ok: out[i].ok += 1; out[i].times.append(s.ms)
            case .failed: out[i].failed += 1
            case .refused: out[i].refused += 1
            case .offline: out[i].offline += 1
            case .listed, .unknown: break
            }
            if h == .ok {
                // Время запоминаем всегда, даже если корзина уже красная: тогда при
                // наведении видно и отказ, и каким был последний удачный ответ.
                out[i].ms = max(out[i].ms, s.ms)
                // Удачный ответ вытесняет и пустоту, и «связи не было»: раз модель
                // ответила, про связь в этой корзине говорить уже нечего.
                if out[i].health == .unknown || out[i].health == .offline {
                    out[i].health = .ok
                }
            } else if h == .failed {
                out[i].health = .failed
            } else if h == .refused, out[i].health != .failed {
                out[i].health = .refused
            } else if h == .offline, out[i].health == .unknown {
                // Ниже всех: любой настоящий замер о модели важнее, чем «связи не было».
                out[i].health = .offline
            }
        }
        return bridgeOutage(out)
    }

    /// Короткий провал между двумя отказами — тоже отказ.
    ///
    /// Когда шлюз молчит, круг опроса растягивается: каждая модель ждёт свой таймаут, и
    /// замеров приходит меньше, чем корзин. На живой истории обрыв поэтому рисовался
    /// пунктиром `·✗·✗·✗` — именно там, где важнее всего увидеть сплошную полосу.
    /// Пустота между двумя отказами объясняется самим отказом, и честнее показать её
    /// отказом, чем дырой.
    ///
    /// Но только короткая. Длинный пропуск — это уже «не знаем»: закрытый ноутбук,
    /// выключенное приложение, отпуск. Дорисовывать там час за часом значило бы выдумать
    /// историю, которой не было.
    private func bridgeOutage(_ marks: [Mark]) -> [Mark] {
        var out = marks
        let maxGap = 4                    // корзины подряд; при 96 корзинах в сутках — час
        var i = 0
        while i < out.count {
            guard out[i].health == .unknown else { i += 1; continue }
            var j = i
            while j < out.count, out[j].health == .unknown { j += 1 }
            let before = i > 0 ? out[i - 1].health : .unknown
            let after = j < out.count ? out[j].health : .unknown
            if before == .failed, after == .failed, j - i <= maxGap {
                for k in i..<j { out[k].health = .failed }
            }
            i = j
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
            let enc = Store.encoder
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
