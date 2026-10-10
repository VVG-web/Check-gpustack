import Foundation
import SwiftUI

/// Проверка правил скрытия — без окон и кликов.
///
/// Окно смотрят глазами один раз, а правила ломаются молча и потом: галочка пишется не
/// туда, снятие обеих оставляет пустую строку в исключениях, «Вернуть» чистит только
/// одно место. Здесь это ловится за секунду.
///
///   swiftc -o /tmp/check_hidden Sources/Config.swift Sources/Store.swift \
///       Sources/Monitor.swift Sources/SettingsView.swift Tests/check_hidden.swift
///   GPUSTACK_MONITOR_DIR=/tmp/gsm-проверка /tmp/check_hidden
///
/// Своя папка подменяется НЕ для красоты. Настройка сохраняется при каждом изменении, и
/// первый же прогон этого теста записал в настоящий `config.json` пустышку — вместе с
/// ключом к шлюзу.
@main
struct Check {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "  ✅ " : "  ❌ ") + what)
        if !ok { failures += 1 }
    }

    static func main() {
        // Страховка на случай, если тест запустят без подменённого HOME: писать в живую
        // настройку он не должен ни при каких обстоятельствах.
        guard ProcessInfo.processInfo.environment["GPUSTACK_MONITOR_DIR"] != nil else {
            print("Тест пишет настройку и должен идти со своей папкой:\n"
                  + "  GPUSTACK_MONITOR_DIR=/tmp/gsm-проверка /tmp/check_hidden")
            exit(2)
        }

        // Старая настройка без поля `hidden` обязана читаться: иначе обновление
        // приложения молча уносит ключ и адрес шлюза.
        let old = #"{"url":"http://шлюз/v1","key":"секрет","rosterSeconds":60,"probeSeconds":900,"historyDays":90}"#
        let decoded = try? JSONDecoder().decode(Config.self, from: Data(old.utf8))
        check(decoded?.backends.first?.key == "секрет"
              && decoded?.backends.first?.url == "http://шлюз/v1"
              && decoded?.backends.first?.name == Config.legacyName,
              "настройка без поля hidden читается, ключ и адрес целы, шлюз стал gpustack")
        check(decoded?.hidden.isEmpty == true,
              "у старой настройки список скрытых пуст, а не сломан")
        check(decoded?.historyPinned == false,
              "новое поле берётся по умолчанию, а не ломает чтение старого файла")

        // Выбор «закрепить окно» обязан пережить запись и чтение.
        var pinned = Config()
        pinned.historyPinned = true
        pinned.backends = [Backend(name: "ш", url: "http://ш/v1", key: "к")]
        let back = try? JSONDecoder().decode(Config.self,
                                             from: JSONEncoder().encode(pinned))
        check(back?.historyPinned == true && back?.backends.first?.key == "к",
              "закрепление и ключ переживают запись настройки")

        var cfg = Config()
        cfg.hide("модель-А")
        check(cfg.hiddenFromMenu("модель-А") && cfg.hiddenFromHistory("модель-А"),
              "«Скрыть» из меню прячет сразу в обоих местах")
        check(!cfg.hiddenFromMenu("модель-Б") && !cfg.hiddenFromHistory("модель-Б"),
              "чужая модель не задета")

        let monitor = Monitor(config: cfg)
        var pushed = 0
        let sm = SettingsModel(monitor: monitor, onChange: { pushed += 1 })
        check(sm.hidden.count == 1, "в настройках видна одна скрытая модель")

        // Снимаем «в меню»: модель возвращается в меню, но остаётся скрытой в истории.
        sm.binding("модель-А", \.menu).wrappedValue = false
        check(!monitor.config.hiddenFromMenu("модель-А"), "галочка «в меню» снята")
        check(monitor.config.hiddenFromHistory("модель-А"), "галочка «в истории» не задета")
        check(sm.hidden.count == 1, "модель осталась в списке исключений")

        // Снимаем вторую: исключение исчезает целиком, а не остаётся пустой строкой.
        sm.binding("модель-А", \.history).wrappedValue = false
        check(monitor.config.hidden["модель-А"] == nil,
              "обе галочки сняты — модель ушла из исключений, пустая строка не осталась")
        check(sm.hidden.isEmpty, "список исключений в настройках опустел")

        // «Вернуть» чистит оба места разом.
        var again = monitor.config
        again.hide("модель-В")
        monitor.apply(again)
        sm.reload()
        check(sm.hidden.count == 1, "модель-В попала в исключения")
        sm.restore("модель-В")
        check(monitor.config.hidden["модель-В"] == nil
              && !monitor.config.hiddenFromMenu("модель-В")
              && !monitor.config.hiddenFromHistory("модель-В"),
              "«Вернуть» возвращает и в меню, и в историю")
        check(pushed > 0, "изменения доходят до приложения, а не остаются в окне")

        print(failures == 0 ? "\nВсё сошлось." : "\nПровалов: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
