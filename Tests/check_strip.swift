import Foundation

/// Проверка раскраски полосы: пороги скорости и правило корзины.
///
/// Глазами это не проверишь: отрезок шириной в два пикселя выглядит одинаково при 0.4 с
/// и при 9 с, а разница между ними — вся суть шкалы. И правило «в корзине побеждает
/// худшее» ломается молча: стоит перепутать знак сравнения, и единственный сбой за час
/// исчезнет за девятью удачными замерами ровно там, где его ищут.
///
///   swiftc -o /tmp/check_strip Sources/Config.swift Sources/Store.swift Tests/check_strip.swift
///   GPUSTACK_MONITOR_DIR=/tmp/gsm-полоса /tmp/check_strip
@main
struct CheckStrip {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "  ✅ " : "  ❌ ") + what)
        if !ok { failures += 1 }
    }

    static func main() {
        guard ProcessInfo.processInfo.environment["GPUSTACK_MONITOR_DIR"] != nil else {
            print("Проверка пишет историю и должна идти со своей папкой:\n"
                  + "  GPUSTACK_MONITOR_DIR=/tmp/gsm-полоса /tmp/check_strip")
            exit(2)
        }

        // --- пороги: взяты из месяца замеров, менять их случайно нельзя
        check(Speed.of(1) == .fast && Speed.of(499) == .fast, "до 0.5 с — норма")
        check(Speed.of(500) == .slow && Speed.of(1999) == .slow, "0.5–2 с — медленнее")
        check(Speed.of(2000) == .bad && Speed.of(9999) == .bad, "2–10 с — плохо")
        check(Speed.of(10000) == .edge && Speed.of(59000) == .edge, "больше 10 с — на грани")
        check(Set(Speed.allCases.map(\.title)).count == Speed.allCases.count,
              "у каждой ступени своя подпись — легенда не повторяется")

        // --- корзина
        let store = Store()
        let now = Int(Date().timeIntervalSince1970)
        let from = Date(timeIntervalSince1970: Double(now - 400))
        let to = Date(timeIntervalSince1970: Double(now))

        // корзина 0: два успеха, быстрый и медленный
        store.append(Sample(t: now - 390, m: "А", ok: true, ms: 120, why: nil))
        store.append(Sample(t: now - 385, m: "А", ok: true, ms: 7000, why: nil))
        // корзина 1: успех и отказ сервера
        store.append(Sample(t: now - 290, m: "А", ok: true, ms: 150, why: nil))
        store.append(Sample(t: now - 285, m: "А", ok: false, ms: 90, why: "HTTP 400",
                            st: Health.refused.rawValue))
        // корзина 2: отказ и полное молчание
        store.append(Sample(t: now - 190, m: "А", ok: false, ms: 80, why: "HTTP 400",
                            st: Health.refused.rawValue))
        store.append(Sample(t: now - 185, m: "А", ok: false, ms: 60000, why: "не уложился"))
        // корзина 3: пусто

        let marks = store.strip("А", from: from, to: to, buckets: 4)
        check(marks.count == 4, "корзин столько, сколько просили")

        check(marks[0].health == .ok && marks[0].ms == 7000,
              "из успешных берётся самый долгий, а не средний: всплеск не гасится")
        check(marks[0].speed == .bad, "7 с показывается как «плохо», а не как норма")

        check(marks[1].health == .refused,
              "отказ побеждает успех в той же корзине")
        check(marks[2].health == .failed,
              "молчание побеждает отказ: это худшее, что может быть")
        check(marks[3].health == .unknown && marks[3].speed == nil,
              "пустая корзина остаётся пустой, а не зелёной")

        // Чужая модель в чужую полосу не попадает.
        store.append(Sample(t: now - 390, m: "Б", ok: false, ms: 0, why: "молчит"))
        let again = store.strip("А", from: from, to: to, buckets: 4)
        check(again[0].health == .ok, "замер другой модели не красит чужую полосу")

        // --- короткий провал между двумя отказами закрашивается, длинный нет
        let b = Store()
        let t0 = now - 10000
        // два отказа с дырой в одну корзину между ними
        b.append(Sample(t: t0 + 10, m: "Б", ok: false, ms: 0, why: "молчит"))
        b.append(Sample(t: t0 + 310, m: "Б", ok: false, ms: 0, why: "молчит"))
        let near = b.strip("Б", from: Date(timeIntervalSince1970: Double(t0)),
                           to: Date(timeIntervalSince1970: Double(t0 + 400)), buckets: 4)
        check(near.allSatisfy { $0.health == .failed },
              "обрыв рисуется сплошным, а не пунктиром: пустота между отказами — тоже отказ")

        // дыра длиннее предела остаётся «не знаем»
        let c = Store()
        c.append(Sample(t: t0 + 10, m: "В", ok: false, ms: 0, why: "молчит"))
        c.append(Sample(t: t0 + 9900, m: "В", ok: false, ms: 0, why: "молчит"))
        let far = c.strip("В", from: Date(timeIntervalSince1970: Double(t0)),
                          to: Date(timeIntervalSince1970: Double(t0 + 10000)), buckets: 20)
        check(far.contains { $0.health == .unknown },
              "длинный пропуск не выдумывается: там могли закрыть ноутбук")

        // дыра между успехом и отказом не закрашивается ни тем, ни другим
        let d = Store()
        d.append(Sample(t: t0 + 10, m: "Г", ok: true, ms: 100, why: nil))
        d.append(Sample(t: t0 + 310, m: "Г", ok: false, ms: 0, why: "молчит"))
        let mixed = d.strip("Г", from: Date(timeIntervalSince1970: Double(t0)),
                            to: Date(timeIntervalSince1970: Double(t0 + 400)), buckets: 4)
        check(mixed[1].health == .unknown || mixed[2].health == .unknown,
              "между успехом и отказом пустота остаётся пустотой")

        // --- «нет связи» не должно превращаться в плохую модель
        let e = Store()
        let base = now - 5000
        // сутки без связи плюс два удачных замера
        for k in 0..<20 {
            e.append(Sample(t: base + k * 100, m: "Д", ok: false, ms: 0,
                            why: "нет связи", st: Health.offline.rawValue))
        }
        e.append(Sample(t: base + 2100, m: "Д", ok: true, ms: 150, why: nil))
        e.append(Sample(t: base + 2200, m: "Д", ok: true, ms: 160, why: nil))
        let up = e.uptime("Д", since: Date(timeIntervalSince1970: Double(base - 10)))
        check(up == 1.0,
              "оборванная связь не роняет доступность модели: 100 %, а не 9 % — "
              + "получилось \(up.map { String(format: "%.0f %%", $0 * 100) } ?? "нет")")

        // только отсутствие связи и ничего больше — числа нет, а не ноль
        let f = Store()
        f.append(Sample(t: base, m: "Е", ok: false, ms: 0, why: "нет связи",
                        st: Health.offline.rawValue))
        check(f.uptime("Е", since: Date(timeIntervalSince1970: Double(base - 10))) == nil,
              "без единого настоящего замера доступности нет, а не ноль процентов")

        // в полосе: любой настоящий замер важнее, чем «связи не было»
        let g = Store()
        g.append(Sample(t: base + 10, m: "Ж", ok: false, ms: 0, why: "нет связи",
                        st: Health.offline.rawValue))
        let only = g.strip("Ж", from: Date(timeIntervalSince1970: Double(base)),
                           to: Date(timeIntervalSince1970: Double(base + 100)), buckets: 1)
        check(only[0].health == .offline, "обрыв связи виден как обрыв связи")
        g.append(Sample(t: base + 20, m: "Ж", ok: true, ms: 120, why: nil))
        let mixed2 = g.strip("Ж", from: Date(timeIntervalSince1970: Double(base)),
                             to: Date(timeIntervalSince1970: Double(base + 100)), buckets: 1)
        check(mixed2[0].health == .ok,
              "в той же корзине удачный ответ перевешивает «связи не было»")
        g.append(Sample(t: base + 30, m: "Ж", ok: false, ms: 0, why: "молчит"))
        let worst = g.strip("Ж", from: Date(timeIntervalSince1970: Double(base)),
                            to: Date(timeIntervalSince1970: Double(base + 100)), buckets: 1)
        check(worst[0].health == .failed, "настоящий отказ модели по-прежнему главнее всего")

        print(failures == 0 ? "\nВсё сошлось." : "\nПровалов: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
