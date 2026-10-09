import AppKit

/// Обновление из репозитория: забрать свежий код, собрать и подменить себя.
///
/// Порядок шагов здесь — главное, и он выбран так, чтобы неудача никогда не оставляла
/// человека без работающего монитора. Сначала сборка в папке проекта, и только если она
/// дала рабочий двоичный файл — подмена установленного. Собери мы прямо поверх
/// «Программ», любая опечатка в коде оставила бы вместо приложения развалины.
///
/// Честно о природе этого пункта: приложение собирает и запускает то, что лежит в
/// репозитории. Обновление ровно настолько заслуживает доверия, насколько сам репозиторий.
enum Updater {

    struct Status {
        var behind: Int = 0           // сколько коммитов мы позади
        var latest: String = ""       // чем кончается ветка
        var problem: String = ""      // почему проверить не вышло
        var hasUpdate: Bool { problem.isEmpty && behind > 0 }
    }

    /// Папка с исходниками, записанная сборкой. Пусто — приложение собрано старой
    /// версией `build.command` либо перенесено без неё.
    static func sourcePath() -> String? {
        // Подмена пути существует ради проверок: главное свойство обновления — что
        // неудачная сборка не трогает установленное приложение, — иначе проверяется
        // только на живом приложении, то есть ценой самого приложения.
        if let own = ProcessInfo.processInfo.environment["GPUSTACK_SOURCE_PATH"],
           !own.isEmpty { return own }
        guard let f = Bundle.main.url(forResource: "source-path", withExtension: "txt"),
              let s = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &dir)
        else { return nil }
        return path
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], at dir: String? = nil)
        -> (code: Int32, out: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        if let dir { task.currentDirectoryURL = URL(fileURLWithPath: dir) }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, "не удалось запустить \(tool)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (task.terminationStatus,
                text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Есть ли что забирать. Сеть трогаем, рабочее дерево — нет.
    static func check() -> Status {
        guard let repo = sourcePath() else {
            return Status(problem: "неизвестно, откуда собрано приложение: пересоберите "
                          + "его через build.command")
        }
        let fetch = run("/usr/bin/git", ["fetch", "--quiet", "origin"], at: repo)
        if fetch.code != 0 {
            return Status(problem: "не достучались до репозитория: "
                          + String(fetch.out.prefix(200)))
        }
        let branch = run("/usr/bin/git", ["rev-parse", "--abbrev-ref", "HEAD"], at: repo).out
        let count = run("/usr/bin/git",
                        ["rev-list", "--count", "HEAD..origin/" + branch], at: repo)
        guard count.code == 0, let n = Int(count.out) else {
            return Status(problem: "не удалось сравнить с репозиторием: "
                          + String(count.out.prefix(200)))
        }
        let top = run("/usr/bin/git",
                      ["log", "-1", "--format=%h %s", "origin/" + branch], at: repo).out
        return Status(behind: n, latest: top)
    }

    /// Забрать, собрать, подменить. → описание результата и нужен ли перезапуск.
    static func update() -> (text: String, restart: Bool) {
        guard let repo = sourcePath() else {
            return ("Неизвестно, откуда собрано приложение. Соберите его заново через "
                    + "build.command — тогда оно запомнит папку с исходниками.", false)
        }
        // Чужие правки не трогаем и поверх них не тянем: --ff-only откажется, и человек
        // узнает об этом, а не обнаружит потом конфликт в своих файлах.
        let pull = run("/usr/bin/git", ["pull", "--ff-only"], at: repo)
        if pull.code != 0 {
            return ("Не удалось забрать свежий код:\n\n" + String(pull.out.prefix(500)), false)
        }
        let build = run("/bin/bash", [repo + "/build.command"], at: repo)
        if build.code != 0 {
            return ("Код забран, но сборка не прошла — установленное приложение не "
                    + "тронуто:\n\n" + String(build.out.suffix(600)), false)
        }
        let fresh = repo + "/GPUStack Монитор.app"
        let binary = fresh + "/Contents/MacOS/GPUStackMonitor"
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return ("Сборка отчиталась об успехе, но готового приложения в папке проекта "
                    + "нет. Установленное не тронуто.", false)
        }
        let version = run("/usr/bin/git", ["log", "-1", "--format=%h %s"], at: repo).out
        let here = Bundle.main.bundlePath
        if here == fresh {
            // Запущены прямо из папки проекта: сборка уже подменила нас на диске.
            return ("Обновлено до:\n\(version)\n\nПерезапустить, чтобы заработала новая "
                    + "версия?", true)
        }
        return ("Обновлено до:\n\(version)\n\nОсталось заменить установленное приложение — "
                + "для этого нужно перезапуститься. Сделать сейчас?", true)
    }

    /// Подменить установленное приложение и перезапуститься.
    ///
    /// Делает это отдельный скрипт: заменить свою же папку, пока она открыта, нельзя —
    /// сначала надо выйти. Скрипт ждёт нашей смерти, подменяет и запускает новое.
    static func restartIntoFresh() {
        guard let repo = sourcePath() else { NSApp.terminate(nil); return }
        let fresh = repo + "/GPUStack Монитор.app"
        let here = Bundle.main.bundlePath
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        if [ "\(here)" != "\(fresh)" ]; then
          rm -rf "\(here)"
          /usr/bin/ditto "\(fresh)" "\(here)"
        fi
        /usr/bin/open "\(here)"
        """
        let path = NSTemporaryDirectory() + "gsm-update-\(UUID().uuidString).sh"
        guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            NSApp.terminate(nil); return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: path)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [path]
        try? task.run()          // живёт дольше нас — потому и отдельный процесс
        Log.say("обновление: выхожу, подмена и запуск за скриптом")
        NSApp.terminate(nil)
    }
}
