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
    /// Почему и когда модель попала в «не проверяются»: `"404@<unix>"`, `"молчание@<unix>"`.
    ///
    /// Время здесь не для отчётности. Первая версия считала такую отметку вечной, и на
    /// живом шлюзе это вышло боком: `deepseek-v4-flash` — обычная чат-модель — ответила
    /// 404 на все три маршрута ровно в минуту разбора (GPUStack выгружает простаивающие
    /// модели и на запрос к невыгруженной отвечает 404, пока её ставит обратно). Модель
    /// осталась в «не проверяется» навсегда, хотя через минуту отвечала за треть секунды.
    ///
    /// Вывод: «не проверяется» не бывает вечным. Отметка пересматривается раз в сутки.
    private var untestedWhy: [String: String] = [:]

    /// Через сколько перепроверять тех, кого записали в «не проверяются».
    private let recheckUntested: TimeInterval = 24 * 3600
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

    /// Очередь только для сети. Общего состояния она не касается — см. раздел «сеть».
    private let io = DispatchQueue(label: "gpustack.io", qos: .utility)
    /// Идёт ли опрос прямо сейчас: второй поверх первого удвоил бы нагрузку.
    private var probing = false
    /// Спрашивали ли модели хоть раз с запуска.
    private(set) var probedOnce = false

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

    func apply(_ c: Config) {
        dispatchPrecondition(condition: .onQueue(.main))
        config = c
        c.save()
    }
    // ------------------------------------------------------------------ сеть
    //
    // Разделение труда здесь не стилистическое, а вынужденное.
    //
    // Приложение падало примерно раз в сутки — четыре отчёта, все одинаковые: SIGABRT в
    // `Monitor.probe` на записи в словарь, `swift_deallocClassInstance`. Это подпись
    // гонки данных: сетевой поток правил `models`, а главный в ту же секунду читал их,
    // собирая меню. Словари Swift к такому не готовы, и ломается не логика, а счётчик
    // ссылок — то есть падает не там, где ошибка, и не сразу.
    //
    // Правило теперь одно: **состояние живёт на главном потоке**. Очередь `io` умеет
    // только ходить в сеть и возвращать результат; ничего общего она не трогает.
    // `dispatchPrecondition` в местах записи делает нарушение этого правила громким и
    // немедленным, а не тихим и отложенным на сутки.

    /// Один запрос к шлюзу. → (код, тело, ошибка, секунды).
    ///
    /// Статический нарочно: у него нет доступа к состоянию, и добавить туда чтение
    /// `config` мимоходом уже не выйдет — адрес и ключ приходят снимком.
    ///
    /// Через `curl`, а не через URLSession. При отладке на живой машине URLSession и
    /// Network.framework не достучались никуда — ни до apple.com, ни до сервера в
    /// собственной подсети, — тогда как `curl` и обычный сокет получали от обоих 200 за
    /// десятые доли секунды. Монитор на таком транспорте показывал бы «недоступно всё»
    /// при исправной сети, то есть врал бы ровно там, ради чего его заводят.
    private static func request(url: String, key: String, body: [String: Any]?,
                                timeout: TimeInterval)
        -> (status: Int?, data: Data?, error: String, seconds: Double) {
        let t0 = Date()
        // Ключ и тело не уходят в аргументы команды: `ps` показывает их всей машине.
        // Настройки curl читает со стандартного ввода, тело — из файла с правами 0600.
        var options = """
        url = "\(url)"
        silent
        show-error
        max-time = \(Int(timeout))
        write-out = "\\n%{http_code}"
        header = "Content-Type: application/json"

        """
        if !key.isEmpty {
            options += "header = \"Authorization: Bearer \(key)\"\n"
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

    /// Версия GPUStack лежит вне `/v1` — на корне хоста.
    private static func fetchVersion(url: String, key: String) -> String? {
        guard var base = URL(string: url) else { return nil }
        while base.lastPathComponent == "v1" || base.lastPathComponent == "v1-openai" {
            base = base.deletingLastPathComponent()
        }
        let (st, data, _, _) = request(url: base.appendingPathComponent("version").absoluteString,
                                       key: key, body: nil, timeout: 10)
        guard st == 200, let data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return j["version"] as? String
    }

    // ------------------------------------------------------- список моделей

    /// Кто числится на шлюзе. Дёшево: обычный GET, генерации нет.
    ///
    /// Вызывается с главного потока: снимок настройки берётся здесь, запрос уходит в
    /// `io`, результат возвращается сюда же.
    func refreshRoster() {
        dispatchPrecondition(condition: .onQueue(.main))
        let cfg = config
        // Свежая установка: адреса ещё нет. Молчать нельзя — иначе значок покажет «✗»,
        // и человек пойдёт искать обрыв связи вместо пустого поля в настройках.
        guard !cfg.url.trimmingCharacters(in: .whitespaces).isEmpty else {
            gatewayOK = false
            gatewayWhy = "шлюз не указан — впишите адрес в «Настройках…»"
            onChange?()
            return
        }
        let needVersion = version.isEmpty
        io.async { [weak self] in
            let (st, data, err, _) = Self.request(url: cfg.url + "/models", key: cfg.key,
                                                  body: nil, timeout: 15)
            let ver = (st == 200 && needVersion)
                ? Self.fetchVersion(url: cfg.url, key: cfg.key) : nil
            DispatchQueue.main.async {
                self?.applyRoster(status: st, data: data, error: err, version: ver, cfg: cfg)
            }
        }
    }

    private func applyRoster(status st: Int?, data: Data?, error err: String,
                             version ver: String?, cfg: Config) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let ver { version = ver }
        if st != 200 {
            Log.say("список моделей не получен: " + (st == nil ? err : "HTTP \(st!)"))
            gatewayOK = false
            gatewayWhy = st == nil ? err : "HTTP \(st!)"
            // У молчания внутреннего адреса две частые причины, и обе не очевидны.
            // Называем обе, а не одну: при отладке этого монитора я уверенно объявил
            // виновным разрешение macOS, а на деле пропал маршрут в корпоративную сеть —
            // обычный сокет из терминала молчал точно так же.
            if st == nil, Self.isPrivate(host: cfg.url) {
                gatewayWhy += " · адрес внутренний: проверьте, есть ли сеть до него "
                    + "(VPN), и разрешён ли приложению доступ к локальной сети "
                    + "(Системные настройки → Конфиденциальность)"
            }
            // Шлюз молчит — значит, ни одна модель сейчас не доступна, и показывать
            // прошлые зелёные галочки нельзя: они соврут ровно тогда, когда важны.
            // Шлюз молчит — значит мы сейчас не знаем о моделях ничего. Красить их
            // отказом нельзя: это чужая беда, и в их доступности её быть не должно.
            for name in order { models[name]?.health = .offline; models[name]?.why = gatewayWhy }
            onChange?()
            return
        }
        gatewayOK = true
        gatewayWhy = ""
        guard let data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["data"] as? [[String: Any]] else { onChange?(); return }

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
        let first = lastRoster == nil
        if first { Log.say("список моделей: \(order.count)") }
        lastRoster = Date()
        onChange?()
        // Первый настоящий опрос идёт сразу за первым списком, а не по расписанию.
        // Раньше он звался следом за `refreshRoster()`, но список теперь приходит из
        // сети асинхронно — и опрос уходил в пустоту, а результатов пришлось бы ждать
        // пятнадцать минут.
        if first, !order.isEmpty, !probedOnce { probeAll() }
    }

    // ---------------------------------------------------- настоящий запрос

    /// Что вышло из опроса одной модели. Считается в `io`, применяется на главном.
    private struct Outcome {
        var kind: Kind
        var health: Health
        var ms: Int
        var why: String
        var untestedReason: String?
        /// Связи с сервером не было: остаток круга спрашивать бессмысленно.
        var offline: Bool = false
    }

    /// Отвечает ли сам шлюз. Один дешёвый GET без генерации.
    ///
    /// Спрашиваем только тогда, когда модель уже молчит: надо понять, чья это беда.
    /// Молчат разом все — значит упала связь (VPN, сеть, выключенный шлюз), и вины
    /// модели в этом нет. Отвечает шлюз, а модель нет — вот это её отказ.
    private static func gatewayAlive(_ cfg: Config) -> Bool {
        request(url: cfg.url + "/models", key: cfg.key, body: nil, timeout: 10).status == 200
    }

    /// Спросить каждую модель по-настоящему. Идёт долго и нагружает кластер — поэтому
    /// вызывается редко и последовательно, а не всеми двадцатью четырьмя разом.
    ///
    /// `rediscover` — забыть вид у тех, кого записали в «не проверяются» по молчанию.
    /// Честный 404 не пересматриваем: у эмбеддингов чата не появится.
    func probeAll(rediscover: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Второй проход поверх первого удвоил бы нагрузку на общий кластер и перемешал
        // бы записи в истории. Один опрос за раз.
        guard !probing else { Log.say("опрос уже идёт — второй не начинаю"); return }
        probing = true
        // Кого пересматриваем. По кнопке — всех: человек нажал её именно потому, что
        // сомневается. По расписанию — тех, чья отметка старше суток, и тех, у кого
        // времени нет вовсе (отметки прежних версий: они и были вечными).
        let now = Date().timeIntervalSince1970
        for (name, mark) in untestedWhy {
            let stamped = mark.split(separator: "@").last.flatMap { Double($0) }
            let stale = stamped.map { now - $0 > recheckUntested } ?? true
            guard rediscover || stale else { continue }
            kinds.removeValue(forKey: name)
            untestedWhy.removeValue(forKey: name)
            models[name]?.kind = .unknown
            Log.say("пересматриваю «не проверяется» у \(name)"
                    + (rediscover ? " — по кнопке" : " — отметке больше суток"))
        }
        let cfg = config
        let plan: [(String, Kind)] = order.compactMap {
            guard let s = models[$0] else { return nil }
            return ($0, s.kind)
        }
        io.async { [weak self] in
            for (index, (name, kind)) in plan.enumerated() {
                guard let self else { return }
                let outcome = Self.probeOne(name: name, kind: kind, cfg: cfg,
                                            discoverTimeout: self.discoverTimeout,
                                            probeTimeout: self.probeTimeout,
                                            store: self.store,
                                            knownReason: nil)
                DispatchQueue.main.async { self.applyProbe(name: name, outcome: outcome) }
                guard outcome.offline else { continue }
                // Связи нет — остальных не спрашиваем. Каждый из них всё равно дождётся
                // своего таймаута, и круг растянется на четверть часа пустого ожидания:
                // на живой истории обрыв поэтому и шёл редкими отметками. Остаток круга
                // отмечаем тем же «связи не было» — это про сеть, а не про модели.
                Log.say("нет связи со шлюзом — остаток круга пропускаю "
                        + "(\(plan.count - index - 1) моделей)")
                let rest = plan.dropFirst(index + 1)
                let now = Int(Date().timeIntervalSince1970)
                for (other, otherKind) in rest where otherKind != .untested {
                    self.store.append(Sample(t: now, m: other, ok: false, ms: 0,
                                             why: "нет связи с сервером",
                                             st: Health.offline.rawValue))
                    let o = Outcome(kind: otherKind, health: .offline, ms: 0,
                                    why: "сервера не было — связь оборвана",
                                    untestedReason: nil, offline: true)
                    DispatchQueue.main.async { self.applyProbe(name: other, outcome: o) }
                }
                break
            }
            DispatchQueue.main.async { self?.finishProbe() }
        }
    }

    private func applyProbe(name: String, outcome: Outcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var s = models[name] else { return }   // модель сняли со шлюза, пока спрашивали
        s.kind = outcome.kind
        s.health = outcome.health
        s.ms = outcome.ms
        s.why = outcome.why
        s.checked = Date()
        models[name] = s
        kinds[name] = outcome.kind
        if let reason = outcome.untestedReason { untestedWhy[name] = reason }
        onChange?()
    }

    private func finishProbe() {
        dispatchPrecondition(condition: .onQueue(.main))
        probing = false
        probedOnce = true
        lastProbe = Date()
        let bad = failing
        Log.say("опрос: отвечают \(answering) из \(testable)"
                + (bad.isEmpty ? "" : " · не в порядке: "
                   + bad.map { "\($0.name) (\($0.why))" }.joined(separator: "; ")))
        saveKinds()
        writeSnapshot()
        onChange?()
    }

    /// Снимок того, что монитор показывает прямо сейчас: значок, меню и таблица истории
    /// одним текстовым файлом.
    ///
    /// Нужен затем, что окно и меню нельзя приложить к письму. Когда человек говорит
    /// «показывает не то», в ответ обычно просят описать экран словами — а здесь этот
    /// экран уже записан, вместе с числами, из которых он собран.
    private func writeSnapshot() {
        dispatchPrecondition(condition: .onQueue(.main))
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var L: [String] = ["# Что показывает монитор — \(f.string(from: Date()))", ""]
        let ok = answering, all = testable
        L.append("Значок: " + (gatewayOK ? (ok == all ? "\(ok)/\(all)" : "⚠ \(ok)/\(all)")
                                         : "GPUStack ✗"))
        L.append("Шлюз: \(config.url)" + (version.isEmpty ? "" : " · GPUStack \(version)")
                 + (gatewayOK ? "" : " · \(gatewayWhy)"))
        L.append("Моделей на шлюзе: \(order.count) · проверяем \(all) · скрыто "
                 + "\(config.hidden.count)")
        L.append("")

        L.append("## Меню значка")
        let broken = failing.filter { !config.hiddenFromMenu($0.name) }
        if !broken.isEmpty {
            L.append("### Требуют внимания")
            for s in broken { L.append(menuLine(s)) }
        }
        for kind in [Kind.chat, .embedding, .rerank, .untested, .unknown] {
            let list = order.compactMap { models[$0] }
                .filter { $0.kind == kind && $0.health != .failed && $0.health != .refused
                          && !config.hiddenFromMenu($0.name) }
            guard !list.isEmpty else { continue }
            L.append("### \(kind.title)")
            for s in list { L.append(menuLine(s)) }
        }
        let hiddenMenu = order.filter { config.hiddenFromMenu($0) }
        if !hiddenMenu.isEmpty {
            L.append("### Скрыто из меню: \(hiddenMenu.count)")
            L.append("  " + hiddenMenu.joined(separator: ", "))
        }

        L.append("")
        L.append("## Окно истории (за сутки)")
        L.append("| модель | вид | состояние | доступность |")
        L.append("|---|---|---|---|")
        let since = Date().addingTimeInterval(-86400)
        for name in order where !config.hiddenFromHistory(name) {
            guard let s = models[name] else { continue }
            let up = store.uptime(name, since: since)
            let text = up.map { String(format: "%.1f %%", $0 * 100) } ?? "нет замеров"
            L.append("| \(name) | \(s.kind.title) | \(word(s.health)) | \(text) |")
        }
        let hiddenHist = order.filter { config.hiddenFromHistory($0) }
        if !hiddenHist.isEmpty {
            L.append("")
            L.append("Скрыто из истории: \(hiddenHist.count) — "
                     + hiddenHist.joined(separator: ", "))
        }
        try? (L.joined(separator: "\n") + "\n")
            .data(using: .utf8)?
            .write(to: Config.dir.appendingPathComponent("snapshot.txt"), options: .atomic)
    }

    private func menuLine(_ s: ModelState) -> String {
        let mark: String
        switch s.health {
        case .ok: mark = "✅"
        case .failed: mark = "✗"
        case .offline: mark = "⋯"
        case .refused: mark = "⚠️"
        case .listed: mark = "•"
        case .unknown: mark = "…"
        }
        return "  \(mark) \(s.name)" + (s.health == .ok ? "  \(s.ms) мс" : "")
            + (s.why.isEmpty ? "" : "  — \(s.why)")
    }

    private func word(_ h: Health) -> String {
        switch h {
        case .ok: return "отвечает"
        case .failed: return "не отвечает"
        case .offline: return "нет связи с сервером"
        case .refused: return "отвечает и отказывает"
        case .listed: return "не проверяется"
        case .unknown: return "ещё не спрашивали"
        }
    }

    /// Опрос одной модели. Чистая работа: сеть и запись в историю, ничего общего.
    private static func probeOne(name: String, kind: Kind, cfg: Config,
                                 discoverTimeout: TimeInterval, probeTimeout: TimeInterval,
                                 store: Store, knownReason: String?) -> Outcome {
        if kind == .untested {
            return Outcome(kind: .untested, health: .listed, ms: 0,
                           why: "проверка стоила бы генерации — не спрашиваем",
                           untestedReason: nil)
        }
        let discovering = kind == .unknown
        let tries: [Kind] = discovering ? [.chat, .embedding, .rerank] : [kind]
        var silent = false

        for try_ in tries {
            guard let path = try_.path else { continue }
            let (st, data, err, dt) = request(url: cfg.url + path, key: cfg.key,
                                              body: payload(try_, model: name),
                                              timeout: discovering ? discoverTimeout : probeTimeout)
            let ms = Int(dt * 1000)
            if st == 200 {
                store.append(Sample(t: Int(Date().timeIntervalSince1970), m: name,
                                    ok: true, ms: ms, why: nil))
                return Outcome(kind: try_, health: .ok, ms: ms, why: "", untestedReason: nil)
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

            // Модель молчит — но прежде чем винить её, спросим сам шлюз. Если и он не
            // отвечает, виновата связь, а не модель, и записывать ей отказ нельзя.
            if st == nil, !gatewayAlive(cfg) {
                store.append(Sample(t: Int(Date().timeIntervalSince1970), m: name,
                                    ok: false, ms: ms, why: "нет связи с сервером",
                                    st: Health.offline.rawValue))
                return Outcome(kind: kind, health: .offline, ms: 0,
                               why: "сервера не было — связь оборвана",
                               untestedReason: nil, offline: true)
            }

            // Сервер ответил и отказал: сломанный шаблон чата, ключ, неверный запрос.
            // Ожиданием это не лечится, и одним красным с молчанием показывать нельзя.
            let why = st == nil ? err : "HTTP \(st!)" + shortBody(data)
            let refused = st != nil
            store.append(Sample(t: Int(Date().timeIntervalSince1970), m: name,
                                ok: false, ms: ms, why: why,
                                st: refused ? Health.refused.rawValue : nil))
            return Outcome(kind: try_, health: refused ? .refused : .failed, ms: ms,
                           why: why, untestedReason: nil)
        }

        // Ни чат, ни эмбеддинги, ни реранк — это генератор картинок, распознавание речи
        // или OCR. Настоящая проверка там стоит целой генерации, и монитор её не делает:
        // показать «в списке» честнее, чем красное «недоступна» на ровном месте.
        return Outcome(kind: .untested, health: .listed, ms: 0,
                       why: silent
                           ? "молчание на пробный запрос — похоже на генератор картинок "
                             + "или речи; настоящая проверка стоила бы генерации"
                           : "не чат, не эмбеддинги и не реранк — речь, картинки или OCR; "
                             + "настоящая проверка стоила бы генерации",
                       untestedReason: (silent ? "молчание@" : "404@")
                           + String(Int(Date().timeIntervalSince1970)))
    }

    private static func payload(_ kind: Kind, model: String) -> [String: Any] {
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

    private static func shortBody(_ data: Data?) -> String {
        guard let data, let s = String(data: data, encoding: .utf8) else { return "" }
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? "" : ": " + String(flat.prefix(90))
    }

    private func saveKinds() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let d = try? JSONEncoder().encode(kinds) { try? d.write(to: kindsFile, options: .atomic) }
        if let d = try? JSONEncoder().encode(untestedWhy) { try? d.write(to: whyFile, options: .atomic) }
    }

    /// Адрес шлюза во внутренней сети? Тогда у молчания есть частая и неочевидная
    /// причина — разрешение macOS, а не связь.
    private static func isPrivate(host url: String) -> Bool {
        guard let host = URL(string: url)?.host else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let direct = host.split(separator: ".").compactMap { Int($0) }
        if direct.count == 4 { return isPrivate(direct) }
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
        return isPrivate(String(cString: buf).split(separator: ".").compactMap { Int($0) })
    }

    private static func isPrivate(_ p: [Int]) -> Bool {
        guard p.count == 4 else { return false }
        if p[0] == 10 || p[0] == 127 { return true }
        if p[0] == 192, p[1] == 168 { return true }
        if p[0] == 172, (16...31).contains(p[1]) { return true }
        if p[0] == 169, p[1] == 254 { return true }
        return false
    }

    // ------------------------------------------------------------- сводка

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
