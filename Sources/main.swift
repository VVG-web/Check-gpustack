import AppKit
import SwiftUI

/// Монитор доступности моделей GPUStack — значок в строке меню.
///
/// Зачем вообще: «модель числится на шлюзе» и «модель отвечает» — разные вещи, и узнают
/// об этом обычно посреди работы, когда запрос уже упал. Значок отвечает на первый
/// вопрос постоянно, а история — на второй: можно ли на неё рассчитывать.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var monitor: Monitor!
    private var rosterTimer: Timer?
    private var probeTimer: Timer?
    private var historyWindow: NSWindow?
    private var historyModel: HistoryModel?
    private var settingsWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var updateStatus = Updater.Status()
    private var updating = false
    private var firstEver = false
    private var shownOnce = false
    private var settingsModel: SettingsModel?
    // Своей очереди у приложения больше нет: монитор сам уводит сеть в фон и возвращает
    // результат на главный поток. Раньше приложение звало его из фоновой очереди — и
    // именно оттуда росла гонка, из-за которой оно падало раз в сутки.

    func applicationDidFinishLaunching(_ note: Notification) {
        // Вторая копия — это вдвое больше запросов к общему кластеру и две руки, пишущие
        // в один файл истории. Ловится это только опытом: я запустил две и получил
        // задвоенные замеры, прежде чем понял, откуда они.
        //
        // Но просто выйти нельзя, и это тоже урок с живой машины: человек кликает по
        // приложению — и НЕ ВИДИТ НИЧЕГО. Значка в доке нет, окно на передний план у
        // такого приложения само не выходит, и снаружи это выглядит как «не
        // открывается». Поэтому второй запуск не спорит, а просит первый показаться:
        // открывается история, и клик делает ровно то, чего от него ждут.
        guard !alreadyRunning() else {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showRequest, object: nil, deliverImmediately: true)
            // Выходим не сразу: уведомление должно успеть дойти до первой копии.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
            return
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showFromOtherLaunch),
            name: Self.showRequest, object: nil)
        // Перенос старых имён на «шлюз/модель» — до того, как кто-либо прочтёт данные.
        Migration.run()
        monitor = Monitor(config: Config.load())
        monitor.onChange = { [weak self] in self?.redraw() }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "GPUStack …"
        item.menu = NSMenu()
        item.menu?.delegate = self
        redraw()

        schedule()
        firstEver = !FileManager.default.fileExists(
            atPath: Config.dir.appendingPathComponent("history.jsonl").path)
        monitor.refreshRoster()
        checkForUpdate()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    /// Самый первый запуск на машине — единственный раз, когда окно показывается само.
    /// Без этого человек не узнает, что приложение работает: значка в доке нет, а значок
    /// в строке меню среди двух десятков других не бросается в глаза.
    private func showOnFirstEverLaunch() {
        guard firstEver, !shownOnce, monitor.probedOnce else { return }
        shownOnce = true
        // Свежая установка без адреса — человеку нужны настройки, а не пустая история:
        // показывать таблицу без единой строки и молчать о причине значит отправить его
        // искать, что он сделал не так.
        if !monitor.config.ready {
            openSettings()
            Log.say("первый запуск без адреса — открыл настройки")
        } else {
            openHistory()
            Log.say("первый запуск — показал историю один раз")
        }
    }

    private func schedule() {
        rosterTimer?.invalidate(); probeTimer?.invalidate()
        let c = monitor.config
        rosterTimer = Timer.scheduledTimer(withTimeInterval: Double(c.rosterSeconds),
                                           repeats: true) { [weak self] _ in
            self?.monitor.refreshRoster()
        }
        probeTimer = Timer.scheduledTimer(withTimeInterval: Double(c.probeSeconds),
                                          repeats: true) { [weak self] _ in
            self?.monitor.probeAll()
        }
    }

    // ------------------------------------------------------------- значок

    private func redraw() {
        // В строке меню помещается несколько знаков, и они должны говорить главное:
        // сколько моделей отвечает из тех, что вообще проверяются. Полное «24» здесь
        // соврало бы — часть моделей мы не спрашиваем принципиально.
        guard let button = item.button else { return }
        button.title = monitor.badge
        button.toolTip = monitor.config.backends.isEmpty
            ? "Укажите адрес шлюза: значок → «Настройки…»"
            : monitor.config.backends.map { b in
                let g = monitor.gateways[b.name]
                return "\(b.name): " + (g?.ok == true ? "отвечает" : (g?.why ?? "ещё не спрашивали"))
            }.joined(separator: "\n")
        showOnFirstEverLaunch()
        // Меню здесь НЕ пересобирается. Оно строится в `menuWillOpen`, то есть ровно
        // тогда, когда на него смотрят. Перестраивать его каждую минуту — это работа на
        // главном потоке ради того, чего никто не видит, а если меню в этот момент
        // открыто, оно ещё и дёргается под рукой. Обновление обязано быть незаметным.
    }

    private func build(_ menu: NSMenu) {
        menu.removeAllItems()
        if monitor.config.backends.isEmpty {
            head(menu, "Шлюзы не заданы — откройте «Настройки…»")
        }
        for b in monitor.config.backends {
            let g = monitor.gateways[b.name]
            let host = URL(string: b.url)?.host ?? b.url
            head(menu, g?.ok == true
                ? "\(b.name) · \(host)"
                    + ((g?.version.isEmpty ?? true) ? "" : " · GPUStack \(g!.version)")
                : "\(b.name) · \(host) — не отвечает: \(g?.why ?? "ещё не спрашивали")")
        }
        head(menu, times())
        menu.addItem(.separator())

        // Сначала то, что сломано. Список из двадцати четырёх строк читают сверху, и
        // упавшая модель, стоящая между зелёными по алфавиту, теряется.
        let broken = monitor.failing.filter { !monitor.config.hiddenFromMenu($0.name) }
        if !broken.isEmpty {
            head(menu, "Требуют внимания")
            for s in broken { menu.addItem(row(s)) }
            menu.addItem(.separator())
        }
        // Группируем по шлюзу, а внутри — по виду. Пока шлюз один, заголовок с его
        // именем не мешает; когда их несколько, без него список не прочесть: модели на
        // разных контурах называются одинаково.
        let many = monitor.config.backends.count > 1
        for b in monitor.config.backends {
            let mine = monitor.order.filter { Backend.split($0).backend == b.name }
            guard !mine.isEmpty else { continue }
            if many { head(menu, "Шлюз \(b.name)") }
            for kind in [Kind.chat, .embedding, .rerank, .untested, .unknown] {
                let list = mine.compactMap { monitor.models[$0] }
                    .filter { $0.kind == kind && $0.health != .failed
                              && $0.health != .refused
                              && !monitor.config.hiddenFromMenu($0.name) }
                guard !list.isEmpty else { continue }
                head(menu, many ? "  " + kind.title : kind.title)
                for s in list { menu.addItem(row(s)) }
            }
        }
        let hiddenCount = monitor.config.hidden.count
        if hiddenCount > 0 {
            // Молча пропавшие строки — плохая память: через неделю человек будет искать
            // модель, не помня, что сам её убрал. Счётчик ведёт прямо в настройки.
            menu.addItem(.separator())
            let it = NSMenuItem(title: "Скрыто моделей: \(hiddenCount) — настроить…",
                                action: #selector(openSettings), keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }
        menu.addItem(.separator())
        add(menu, "История доступности…", #selector(openHistory), key: "h")
        add(menu, "Проверить сейчас", #selector(checkNow), key: "r")
        add(menu, "Настройки…", #selector(openSettings), key: ",")
        add(menu, "Справка", #selector(openHelp), key: "?")
        // Пункт сам говорит, есть ли что забирать: «Обновить» без новостей заставляет
        // человека жать его наугад и ждать впустую.
        let up = NSMenuItem(title: updateTitle(), action: #selector(doUpdate),
                            keyEquivalent: "u")
        up.target = self
        up.isEnabled = !updating
        if updateStatus.hasUpdate { up.attributedTitle = NSAttributedString(
            string: updateTitle(), attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]) }
        if !updateStatus.problem.isEmpty { up.toolTip = updateStatus.problem }
        menu.addItem(up)
        menu.addItem(.separator())
        add(menu, "Выйти", #selector(quit), key: "q")
    }

    private func times() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let list = monitor.lastRoster.map { "список: " + f.string(from: $0) } ?? "список: —"
        let probe = monitor.lastProbe.map { "опрос: " + f.string(from: $0) } ?? "опрос: ещё не было"
        return list + " · " + probe
    }

    private func row(_ s: ModelState) -> NSMenuItem {
        let mark: String
        switch s.health {
        case .ok: mark = "✅"
        case .failed: mark = "✗"
        case .offline: mark = "⋯"
        case .refused: mark = "⚠️"
        case .listed: mark = "•"
        case .unknown: mark = "…"
        }
        var tail = ""
        if s.health == .ok { tail = "  \(s.ms) мс" }
        // Имя шлюза уже стоит заголовком группы — в каждой строке оно лишнее.
        let it = NSMenuItem(title: "\(mark) \(Backend.split(s.name).model)\(tail)",
                            action: nil, keyEquivalent: "")
        it.toolTip = s.why.isEmpty
            ? (s.health == .ok ? "Ответила за \(s.ms) мс" : nil) : s.why
        // Скрытие живёт в подменю, а не на самой строке. Строка — это состояние модели,
        // и случайный клик по ней не должен убирать её с глаз: возвращать придётся из
        // настроек, а человек ещё не будет знать, что она вообще там.
        let sub = NSMenu()
        let hide = NSMenuItem(title: "Скрыть эту модель", action: #selector(hideModel(_:)),
                              keyEquivalent: "")
        hide.target = self
        hide.representedObject = s.name
        hide.toolTip = "Убрать из этого меню и из окна истории. Вернуть — в «Настройках…»"
        sub.addItem(hide)
        it.submenu = sub
        return it
    }

    @objc private func hideModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var c = monitor.config
        c.hide(name)
        monitor.apply(c)
        Log.say("скрыта модель \(name)")
        settingsModel?.reload()
        redraw()
    }

    private func head(_ menu: NSMenu, _ text: String) {
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        it.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor])
        it.isEnabled = false
        menu.addItem(it)
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
    }

    // ------------------------------------------------------------ действия

    @objc private func checkNow() {
        // Ручная проверка — повод пересмотреть и тех, кого записали в «не проверяются»
        // по молчанию: человек нажал кнопку, значит сомневается именно в этом.
        monitor.refreshRoster()
        monitor.probeAll(rediscover: true)
    }

    @objc private func openHistory() {
        if let w = historyWindow {
            historyModel?.reload()
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            Log.say("окно истории поднято")
            return
        }
        let m = HistoryModel(monitor: monitor)
        historyModel = m
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Доступность моделей GPUStack"
        // Без этого окно приложения без значка в доке не получает движений мыши, и
        // наведение на сектор не срабатывает вовсе — ни своей подсказкой, ни системной.
        w.acceptsMouseMovedEvents = true
        w.contentViewController = NSHostingController(rootView: HistoryView(model: m))
        w.center(); w.isReleasedWhenClosed = false
        historyWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.say("окно истории открыто · строк: \(m.rows.count)")
    }

    @objc private func openSettings() {
        if let w = settingsWindow {
            settingsModel?.reload()
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let m = SettingsModel(monitor: monitor, onChange: { [weak self] in
            self?.schedule()
            self?.redraw()
            self?.historyModel?.reload()
        })
        settingsModel = m
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Настройки монитора"
        w.minSize = NSSize(width: 560, height: 420)
        w.contentViewController = NSHostingController(rootView: SettingsView(model: m))
        w.center(); w.isReleasedWhenClosed = false
        m.close = { [weak w] in w?.close() }
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateTitle() -> String {
        if updating { return "Обновляю…" }
        if !updateStatus.problem.isEmpty { return "Обновить" }
        if updateStatus.behind > 0 {
            return "Обновить — есть новая версия"
        }
        return "Обновить (у вас последняя)"
    }

    /// Проверка идёт в фоне и сама по себе ничего не меняет: только подписывает пункт.
    private func checkForUpdate() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let s = Updater.check()
            DispatchQueue.main.async {
                self?.updateStatus = s
                if s.hasUpdate { Log.say("доступна новая версия: \(s.latest)") }
                else if !s.problem.isEmpty { Log.say("проверка обновления: \(s.problem)") }
            }
        }
    }

    @objc private func doUpdate() {
        guard !updating else { return }
        // Сборка идёт секунды, и всё это время человек не должен гадать, нажалось ли.
        updating = true
        item.button?.toolTip = "Обновление: забираю код и собираю…"
        Log.say("обновление: начал")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Updater.update()
            DispatchQueue.main.async {
                guard let self else { return }
                self.updating = false
                Log.say("обновление: " + result.text.split(separator: "\n").first.map(String.init)!)
                let a = NSAlert()
                a.messageText = result.restart ? "Обновление готово" : "Обновить не вышло"
                a.informativeText = result.text
                if result.restart {
                    a.addButton(withTitle: "Перезапустить")
                    a.addButton(withTitle: "Позже")
                } else {
                    a.addButton(withTitle: "Понятно")
                }
                NSApp.activate(ignoringOtherApps: true)
                let answer = a.runModal()
                if result.restart, answer == .alertFirstButtonReturn {
                    Updater.restartIntoFresh()
                } else {
                    self.checkForUpdate()
                }
            }
        }
    }

    @objc private func openHelp() {
        if let w = helpWindow {
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Справка"
        w.contentViewController = NSHostingController(rootView: HelpView())
        w.center(); w.isReleasedWhenClosed = false
        helpWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Приложение «открыли заново»: клик по нему в Finder, запуск второй копии, а иногда
    /// и просто активация — macOS шлёт это событие щедрее, чем кажется.
    ///
    /// Раньше отсюда открывалось окно истории: так решалась жалоба «не открывается» —
    /// клик по приложению без окон не давал ничего. Но плата оказалась хуже болезни:
    /// окно всплывало само, посреди чужой работы, без спроса. Окно, которое появляется
    /// не по просьбе, — это не помощь, а помеха.
    ///
    /// Теперь событие поднимает окно, только если оно УЖЕ открыто. Закрытое остаётся
    /// закрытым: открыть его можно из меню значка, и это единственный путь.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if let w = historyWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
        }
        return true
    }

    @objc private func showFromOtherLaunch() {
        if let w = historyWindow, w.isVisible { w.makeKeyAndOrderFront(nil) }
    }

    /// Имя просьбы «покажись». Своё, а не общесистемное: чужие приложения тут ни при чём.
    static let showRequest = Notification.Name("local.gpustack.monitor.show")

    /// Уже ли работает другая копия. Смотрим на сам процесс, а не на файл-замок: замок
    /// переживает падение и запирает приложение навсегда, а список процессов не врёт.
    private func alreadyRunning() -> Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        let id = Bundle.main.bundleIdentifier ?? "local.gpustack.monitor"
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == id && $0.processIdentifier != mine
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { build(menu) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // без значка в доке: место такому — в строке меню
app.run()
