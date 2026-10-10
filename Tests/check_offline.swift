import Foundation

/// Чья беда: модели или связи.
///
/// С живого контура: при двух шлюзах один упал, и опрос встал на нём целиком — до
/// второго очередь не доходила, а «Проверить сейчас» не помогала. Причина была в
/// порядке двух проверок: у модели с НЕИЗВЕСТНЫМ видом молчание принималось за «ищем
/// не тот эндпоинт» раньше, чем кто-либо спрашивал сам шлюз. Мёртвый шлюз выглядел
/// как набор ненайденных моделей: три эндпоинта по пятнадцать секунд на каждую.
///
///   swiftc -o /tmp/check_offline Sources/Config.swift Sources/Store.swift \
///       Sources/Migration.swift Sources/Monitor.swift Tests/check_offline.swift
///   GPUSTACK_MONITOR_DIR=/tmp/gsm-обрыв /tmp/check_offline
@main
struct CheckOffline {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "  ✅ " : "  ❌ ") + what)
        if !ok { failures += 1 }
    }

    static func main() {
        guard ProcessInfo.processInfo.environment["GPUSTACK_MONITOR_DIR"] != nil else {
            print("Нужна своя папка: GPUSTACK_MONITOR_DIR=/tmp/gsm-обрыв /tmp/check_offline")
            exit(2)
        }
        let store = Store()
        // Порт, на котором заведомо никто не слушает: соединение отвергается сразу.
        let dead = Backend(name: "мёртвый", url: "http://127.0.0.1:9/v1", key: "")

        let t0 = Date()
        let unknown = Monitor.probeOne(name: "мёртвый/новая-модель", kind: .unknown,
                                       backend: dead, discoverTimeout: 5, probeTimeout: 5,
                                       store: store)
        let spent = Date().timeIntervalSince(t0)

        check(unknown.health == .offline,
              "модель с неизвестным видом на мёртвом шлюзе — это обрыв связи, "
              + "а не ненайденная модель (получили \(unknown.health))")
        check(unknown.offline,
              "ГЛАВНОЕ: помечено «оборвать остаток круга» — иначе опрос застрянет на "
              + "этом шлюзе и до следующих не дойдёт")
        check(unknown.untestedReason == nil,
              "модель не записана в «не проверяется»: её вид мы так и не узнали, "
              + "и выдумывать его нельзя")
        check(spent < 20,
              String(format: "решение принято быстро: %.1f с, а не три таймаута подряд",
                     spent))

        // У модели с известным видом поведение прежнее.
        let known = Monitor.probeOne(name: "мёртвый/чат", kind: .chat, backend: dead,
                                     discoverTimeout: 5, probeTimeout: 5, store: store)
        check(known.health == .offline && known.offline,
              "у модели с известным видом обрыв распознаётся как раньше")

        // В историю записан обрыв, а не отказ модели.
        let rows = store.samples().filter { $0.m.hasPrefix("мёртвый/") }
        check(!rows.isEmpty && rows.allSatisfy { $0.health == .offline },
              "в историю лёг обрыв связи, а не отказ модели: "
              + "\(Set(rows.map { "\($0.health)" }).sorted())")
        check(rows.allSatisfy { !$0.ok },
              "обрыв не засчитан за удачный ответ")

        print(failures == 0 ? "\nВсё сошлось." : "\nПровалов: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
