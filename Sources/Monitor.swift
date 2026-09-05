import Foundation

/// Опрос шлюза: кто числится в списке и кто на самом деле отвечает.
///
/// Это разные вопросы, и путать их дорого: модель может числиться в `/models` и не
/// отвечать ни на один запрос. Поэтому список берётся часто и бесплатно, а настоящий
/// запрос уходит редко — он занимает общий кластер.
final class Monitor {
    private(set) var config: Config
    let store = Store()
    private(set) var models: [String: ModelState] = [:]
    private(set) var order: [String] = []
    private(set) var gatewayOK = false
    private(set) var gatewayWhy = ""
    private(set) var version = ""
    private(set) var lastRoster: Date?
    private(set) var lastProbe: Date?
    /// Найденный вид модели переживает перезапуск: искать его заново значит слать на
    /// кластер лишние запросы каждый раз, когда человек перезагрузил ноутбук.
    private var kinds: [String: Kind] = [:]
    /// Почему модель попала в «не проверяются». Молчание и честный 404 — разные поводы,
    /// и первый стоит перепроверить по просьбе человека, а второй нет.
    private var untestedWhy: [String: String] = [:]
    private let kindsFile = Config.dir.appendingPathComponent("kinds.json")
    private let whyFile = Config.dir.appendingPathComponent("untested.json")

    /// Срок на пробный запрос, пока вид модели неизвестен.
    ///
    /// Короткий нарочно. Самая медленная чат-модель контура отвечает на `max_tokens: 1`
    /// за три секунды, а генератор картинок запрос ПРИНИМАЕТ и рисует: на живом шлюзе
    /// `z-image-turbo` держал соединение все шестьдесят секунд. Столько же он занимал бы
    /// видеокарту — и так на каждом опросе. Пятнадцать секунд отделяют «модель думает»
    /// от «мы попали не туда».
    private let discoverTimeout: TimeInterval = 15
    /// Срок для модели, чей вид уже известен: тут спешить некуда, под нагрузкой отвечают
    /// и по полминуты.
    private let probeTimeout: TimeInterval = 60

    var onChange: (() -> Void)?

    init(config: Config) {
        self.config = config
        if let d = try? Data(contentsOf: kindsFile),
           let k = try? JSONDecoder().decode([String: Kind].self, from: d) { kinds = k }
        if let d = try? Data(contentsOf: whyFile),
           let w = try? JSONDecoder().decode([String: String].self, from: d) { untestedWhy = w }
        store.prune(days: config.historyDays)
        Log.trim()
        Log.say("запуск · адрес \(config.url) · ключ \(config.key.isEmpty ? "не задан" : "есть")")
    }

    func apply(_ c: Config) { config = c; c.save() }

    // ------------------------------------------------------------------ сеть

    /// Один запрос к шлюзу. → (код, тело, ошибка, секунды).
    ///
    /// Через `curl`, а не через URLSession — и это не вкусовщина.
    ///
    /// При отладке этого монитора на живой машине URLSession и Network.framework не
    /// достучались НИКУДА: ни до apple.com, ни до сервера в собственной подсети. В ту же
    /// секунду `curl` и обычный сокет получали от обоих 200 за десятые доли секунды.
    /// Монитор на таком транспорте показал бы «недоступно всё» при исправной сети — то
    /// есть соврал бы ровно там, ради чего его и заводят.
    ///
    /// `curl` есть на каждом маке, ходит теми же сокетами, что и остальные программы, и
    /// отвечает за сервер, а не за мнение сетевого стека о самом себе.
    private func request(_ path: String, body: [String: Any]?, timeout: TimeInterval)
        -> (status: Int?, data: Data?, error: String, seconds: Double) {
        let t0 = Date()
        // Ключ и тело не уходят в аргументы команды: `ps` показывает их всей машине.
        // Настройки curl читает со стандартного ввода, тело — из файла с правами 0600.
        var options = """
        url = "\(config.url + path)"
        silent
        show-error
        max-time = \(Int(timeout))
        write-out = "\\n%{http_code}"
        header = "Content-Type: application/json"

        """
        if !config.key.isEmpty {
            options += "header = \"Authorization: Bearer \(config.key)\"\n"
        }
        var bodyFile: URL?
        if let body, let data = try? JSONSerialization.data(withJSONObject: body) {
            let f = FileManager.default.temporaryDirectory
                .appendingPathComponent("gsm-\(UUID().uuidString).json")
            try? data.write(to: f, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: f.path)
            bodyFile = f
            options += "data-binary = \"@\(f.path)\"\n"
        }
        defer { if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) } }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["--config", "-"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr
        do { try task.run() } catch {
            return (nil, nil, "не удалось запустить curl: \(error.localizedDescription)", 0)
        }
        stdin.fileHandleForWriting.write(options.data(using: .utf8) ?? Data())
        try? stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        task.waitUntilExit()
        let dt = Date().timeIntervalSince(t0)

        if task.terminationStatus != 0 {
            // 28 — вышло время. Отделяем его от «не доехали»: первое лечится сроком,
            // второе — сетью, и человеку это разные новости.
            let why = task.terminationStatus == 28
                ? "не уложился в \(Int(timeout)) с"
                : (errText.split(separator: "\n").last.map(String.init)
                   ?? "curl завершился с кодом \(task.terminationStatus)")
            return (nil, nil, why, dt)
        }
        // Последняя строка — код ответа, всё до неё — тело.
        guard let text = String(data: out, encoding: .utf8),
              let nl = text.lastIndex(of: "\n") else {
            return (nil, nil, "пустой ответ curl", dt)
        }
        let code = Int(text[text.index(after: nl)...].trimmingCharacters(in: .whitespaces))
        let payload = String(text[text.startIndex..<nl])
        return (code, payload.data(using: .utf8), "", dt)
    }

    /// Версия GPUStack лежит вне `/v1` — на корне хоста. Спрашиваем один раз: она не
    /// меняется между опросами, а лишний запрос в минуту ради неизменной строки лишний.
    private func refreshVersion() {
        guard var base = URL(string: config.url) else { return }
        while base.lastPathComponent == "v1" || base.lastPathComponent == "v1-openai" {
            base = base.deletingLastPathComponent()
        }
        let saved = config.url
        config.url = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast()) : base.absoluteString
        let (st, data, _, _) = request("/version", body: nil, timeout: 10)
        config.url = saved
        if st == 200, let data,
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = j["version"] as? String { version = v }
    }

    // ------------------------------------------------------- список моделей

    /// Кто числится на шлюзе. Дёшево: обычный GET, генерации нет.
    func refreshRoster() {
        // Свежая установка: адреса ещё нет. Молчать нельзя — иначе значок покажет «✗»,
        // и человек пойдёт искать обрыв связи вместо пустого поля в настройках.
        guard !config.url.trimmingCharacters(in: .whitespaces).isEmpty else {
            gatewayOK = false
            gatewayWhy = "шлюз не указан — впишите адрес в «Настройках…»"
            notify()
            return
        }
        let (st, data, err, _) = request("/models", body: nil, timeout: 15)
        if st != 200 {
            Log.say("список моделей не получен: " + (st == nil ? err : "HTTP \(st!)"))
            gatewayOK = false
            gatewayWhy = st == nil ? err : "HTTP \(st!)"
            // У молчания внутреннего адреса две частые причины, и обе не очевидны.
            // Называем обе, а не одну: при отладке этого монитора я уверенно объявил
            // виновным разрешение macOS, а на деле пропал маршрут в корпоративную сеть —
            // обычный сокет из терминала молчал точно так же.
            if st == nil, isPrivateHost {
                gatewayWhy += " · адрес внутренний: проверьте, есть ли сеть до него "
                    + "(VPN), и разрешён ли приложению доступ к локальной сети "
                    + "(Системные настройки → Конфиденциальность)"
            }
            // Шлюз молчит — значит, ни одна модель сейчас не доступна, и показывать
            // прошлые зелёные галочки нельзя: они соврут ровно тогда, когда важны.
            for name in order { models[name]?.health = .failed; models[name]?.why = gatewayWhy }
            notify()
            return
        }
        gatewayOK = true
        gatewayWhy = ""
        if version.isEmpty { refreshVersion() }

        guard let data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["data"] as? [[String: Any]] else { notify(); return }

        var fresh: [String] = []
        for item in list {
            guard let id = item["id"] as? String else { continue }
            fresh.append(id)
            if models[id] == nil {
                var s = ModelState(name: id)
                s.kind = kinds[id] ?? .unknown
                s.seen = (item["created"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }
                models[id] = s
            }
        }
        // Модель, пропавшая из списка, не «стала недоступной» — её сняли со шлюза.
        // Держать её в перечне значит копить мусор и пугать красным тем, чего уже нет.
        for gone in order where !fresh.contains(gone) { models.removeValue(forKey: gone) }
        order = fresh.sorted { $0.lowercased() < $1.lowercased() }
        if lastRoster == nil { Log.say("список моделей: \(order.count)") }
        lastRoster = Date()
        notify()
    }

    // ---------------------------------------------------- настоящий запрос

    /// Спросить каждую модель по-настоящему. Идёт долго и нагружает кластер — поэтому
    /// вызывается редко и последовательно, а не всеми двадцатью четырьмя разом.
    /// `rediscover` — забыть вид у тех, кого записали в «не проверяются» по молчанию.
    /// Честный 404 не пересматриваем: у эмбеддингов чата не появится.
    func probeAll(rediscover: Bool = false) {
        if rediscover {
            for (name, why) in untestedWhy where why.hasPrefix("молчание") {
                kinds.removeValue(forKey: name)
                untestedWhy.removeValue(forKey: name)
                models[name]?.kind = .unknown
            }
        }
        for name in order {
            probe(name)
            notify()
        }
        lastProbe = Date()
        let bad = failing
        Log.say("опрос: отвечают \(answering) из \(testable)"
                + (bad.isEmpty ? "" : " · не в порядке: "
                   + bad.map { "\($0.name) (\($0.why))" }.joined(separator: "; ")))
        saveKinds()
        notify()
    }

    private func probe(_ name: String) {
        guard var s = models[name] else { return }
        // Вид уже известен — спрашиваем сразу по адресу. Неизвестен — ищем перебором,
        // но один раз за всё время жизни модели.
        let tries: [Kind] = s.kind == .unknown ? [.chat, .embedding, .rerank] : [s.kind]
        if s.kind == .untested {
            s.health = .listed
            s.why = untestedWhy[name] ?? "проверка стоила бы генерации — не спрашиваем"
            s.checked = Date()
            models[name] = s
            return
        }
        let discovering = s.kind == .unknown
        var silent = false
        for kind in tries {
            guard let path = kind.path else { continue }
            let (st, data, err, dt) = request(path, body: payload(kind, model: name),
                                              timeout: discovering ? discoverTimeout : probeTimeout)
            let ms = Int(dt * 1000)
            if st == 200 {
                s.kind = kind; kinds[name] = kind
                s.health = .ok; s.ms = ms; s.why = ""; s.checked = Date()
                models[name] = s
                store.append(Sample(t: Int(Date().timeIntervalSince1970), m: name,
                                    ok: true, ms: ms, why: nil))
                return
            }
            // 404 значит «этого маршрута для этой модели нет» — у эмбеддингов не бывает
            // чата. Ищем дальше по списку видов.
            //
            // Сначала здесь разбирались тела ответов: `detail` против `error`. Живой
            // шлюз выдал третью форму — `{"message":"API endpoint not found"}` от
            // whisper, — и распознавание речи попало в «недоступна». Разбирать тела
            // значит гнаться за формулировками сервера; правило по коду одно и не
            // ломается. Модель, которой правда нет, уйдёт из списка на следующем опросе:
            // перечень мы берём с самого шлюза.
            if st == 404 { continue }

            // Пока вид неизвестен, молчание — не отказ, а знак, что мы стучимся не туда:
            // генератор картинок запрос принял и рисует. Идём дальше по видам.
            if st == nil, discovering { silent = true; continue }

            // Сервер ответил и отказал: сломанный шаблон чата, ключ, неверный запрос.
            // Ожиданием это не лечится, и одним красным с молчанием показывать нельзя.
            let why = st == nil ? err : "HTTP \(st!)" + shortBody(data)
            let refused = st != nil
            s.health = refused ? .refused : .failed
            s.ms = ms; s.why = why; s.checked = Date()
            s.kind = kind; kinds[name] = kind
            models[name] = s
            store.append(Sample(t: Int(Date().timeIntervalSince1970), m: name,
                                ok: false, ms: ms, why: why,
                                st: refused ? Health.refused.rawValue : nil))
            return
        }
        // Ни чат, ни эмбеддинги, ни реранк — это генератор картинок, распознавание речи
        // или OCR. Настоящая проверка там стоит целой генерации, и монитор её не делает:
        // показать «в списке» честнее, чем красное «недоступна» на ровном месте.
        s.kind = .untested; kinds[name] = .untested
        s.health = .listed
        // Повод записываем: по молчанию — перепроверим по кнопке, по 404 — нет.
        s.why = silent
            ? "молчание на пробный запрос — похоже на генератор картинок или речи; "
              + "настоящая проверка стоила бы генерации"
            : "не чат, не эмбеддинги и не реранк — речь, картинки или OCR; "
              + "настоящая проверка стоила бы генерации"
        untestedWhy[name] = silent ? "молчание" : "404"
        s.checked = Date()
        models[name] = s
    }

    private func payload(_ kind: Kind, model: String) -> [String: Any] {
        switch kind {
        case .chat:
            return ["model": model, "max_tokens": 1,
                    "messages": [["role": "user", "content": "ping"]]]
        case .embedding:
            return ["model": model, "input": "ping"]
        case .rerank:
            return ["model": model, "query": "ping", "documents": ["a", "b"]]
        case .untested, .unknown:
            return [:]
        }
    }

    private func shortBody(_ data: Data?) -> String {
        guard let data, let s = String(data: data, encoding: .utf8) else { return "" }
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? "" : ": " + String(flat.prefix(90))
    }

    private func saveKinds() {
        if let d = try? JSONEncoder().encode(kinds) { try? d.write(to: kindsFile, options: .atomic) }
        if let d = try? JSONEncoder().encode(untestedWhy) { try? d.write(to: whyFile, options: .atomic) }
    }

    private func notify() { DispatchQueue.main.async { self.onChange?() } }

    // ------------------------------------------------------------- сводка

    /// Адрес шлюза во внутренней сети? Тогда у молчания есть частая и неочевидная
    /// причина — разрешение macOS, а не связь.
    private var isPrivateHost: Bool {
        guard let host = URL(string: config.url)?.host else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else {
            // Имя, а не адрес: разрешаем его сами — внутренние шлюзы часто прячутся за
            // обычным доменным именем, как здесь.
            var info = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                                ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                                ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &info, &res) == 0, let first = res else { return false }
            defer { freeaddrinfo(res) }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen,
                              &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0
            else { return false }
            let ip = String(cString: buf)
            let q = ip.split(separator: ".").compactMap { Int($0) }
            return isPrivate(q)
        }
        return isPrivate(p)
    }

    private func isPrivate(_ p: [Int]) -> Bool {
        guard p.count == 4 else { return false }
        if p[0] == 10 || p[0] == 127 { return true }
        if p[0] == 192, p[1] == 168 { return true }
        if p[0] == 172, (16...31).contains(p[1]) { return true }
        if p[0] == 169, p[1] == 254 { return true }
        return false
    }

    var answering: Int { models.values.filter { $0.health == .ok }.count }
    /// Знаменатель — только те, кого мы правда спрашиваем. Считать в нём картинки и
    /// речь значит вечно показывать «21/24» на исправном шлюзе.
    var testable: Int {
        models.values.filter { $0.health == .ok || $0.health == .failed
                               || $0.health == .refused }.count
    }
    var failing: [ModelState] {
        models.values.filter { $0.health == .failed || $0.health == .refused }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
