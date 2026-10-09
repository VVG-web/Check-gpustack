import AppKit

/// Проверка обновления: неудача не должна стоить работающего приложения.
///
/// Это единственное свойство, ради которого здесь вообще есть проверка. Всё остальное
/// человек увидит сам, а вот «обновился и остался без монитора» он увидит ровно один
/// раз и в самый неподходящий момент.
///
///   swiftc -o /tmp/check_update Sources/Config.swift Sources/Store.swift \
///       Sources/Updater.swift Tests/check_update.swift
///   GPUSTACK_SOURCE_PATH=<клон> /tmp/check_update
@main
struct CheckUpdate {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "  ✅ " : "  ❌ ") + what)
        if !ok { failures += 1 }
    }

    static func main() {
        guard let repo = ProcessInfo.processInfo.environment["GPUSTACK_SOURCE_PATH"] else {
            print("Нужен клон репозитория: GPUSTACK_SOURCE_PATH=<путь> /tmp/check_update")
            exit(2)
        }
        let app = repo + "/GPUStack Монитор.app"
        let binary = app + "/Contents/MacOS/GPUStackMonitor"

        func hash() -> String {
            Updater.run("/sbin/md5", ["-q", binary]).out
        }

        check(Updater.sourcePath() == repo, "папка с исходниками найдена")
        let before = hash()
        check(!before.isEmpty, "собранное приложение на месте до начала")

        // Ломаем исходник и просим обновиться.
        let victim = repo + "/Sources/Store.swift"
        let good = try! String(contentsOfFile: victim, encoding: .utf8)
        try! (good + "\nэто не swift\n").write(toFile: victim, atomically: true,
                                               encoding: .utf8)
        let broken = Updater.update()
        check(!broken.restart, "после неудачной сборки перезапуск не предлагается")
        check(broken.text.contains("сборка не прошла"),
              "сказано прямо, что сломалось: \(broken.text.prefix(60))")
        check(broken.text.contains("не тронуто"),
              "человеку сказано, что установленное цело")
        check(hash() == before,
              "ГЛАВНОЕ: двоичный файл не подменён — неудачная сборка не стоила приложения")

        // Чиним и обновляемся по-настоящему.
        try! good.write(toFile: victim, atomically: true, encoding: .utf8)
        let okRun = Updater.update()
        check(okRun.restart, "на исправном коде обновление доходит до перезапуска")
        check(!hash().isEmpty, "после удачной сборки приложение на месте")

        print(failures == 0 ? "\nВсё сошлось." : "\nПровалов: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
