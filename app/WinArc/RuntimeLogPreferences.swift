import Foundation

enum WinArcRuntimeLogMode: String, CaseIterable, Identifiable {
    case always
    case gameLoading

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always:
            return "一直日志"
        case .gameLoading:
            return "仅游戏加载日志"
        }
    }

    var detail: String {
        switch self {
        case .always:
            return "从 WinArc 打开开始持续记录，适合排查随机问题。"
        case .gameLoading:
            return "只在启动 Wine/游戏时记录；出现首个画面后自动停止，减少 I/O 和性能影响。"
        }
    }
}

enum WinArcRuntimeLog {
    static let enabledKey = "winarc.runtimeLog.enabled"
    static let modeKey = "winarc.runtimeLog.mode"
    static let showLiveKey = "winarc.runtimeLog.showLive"

    private static let defaultMaxBytes = 16 * 1024 * 1024

    static var directoryURL: URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("WinArcLogs", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("winarc-runtime.log")
    }

    static var previousFileURL: URL {
        directoryURL.appendingPathComponent("winarc-runtime.previous.log")
    }

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: enabledKey) == nil {
            /* Dev-stage default: enabled, but only during game loading. */
            defaults.set(true, forKey: enabledKey)
            defaults.set(
                WinArcRuntimeLogMode.gameLoading.rawValue,
                forKey: modeKey
            )
            defaults.set(false, forKey: showLiveKey)
        }

        return defaults.bool(forKey: enabledKey)
    }

    static var mode: WinArcRuntimeLogMode {
        let raw = UserDefaults.standard.string(forKey: modeKey)
        return WinArcRuntimeLogMode(rawValue: raw ?? "")
            ?? .gameLoading
    }

    static var showLive: Bool {
        UserDefaults.standard.bool(forKey: showLiveKey)
    }

    static var isCapturing: Bool {
        winarc_runtime_log_is_active() != 0
    }

    static func configureForAppLaunch() {
        ensurePreferencesExist()
        ensureLogFileExists()

        guard isEnabled else {
            winarc_runtime_log_stop()
            return
        }

        if mode == .always {
            startCapture(stopOnFirstPresent: false)
            mark("LOG", "always-on mode restored at app launch")
        }
    }

    static func applyPreferencesNow() {
        ensurePreferencesExist()
        ensureLogFileExists()

        guard isEnabled else {
            if isCapturing {
                mark("LOG", "logging disabled in Settings")
                winarc_runtime_log_stop()
            }
            return
        }

        switch mode {
        case .always:
            startCapture(stopOnFirstPresent: false)
            mark("LOG", "mode changed to always-on")

        case .gameLoading:
            /*
             * If the user changes from always -> game-loading, stop the
             * current continuous capture. The next game launch starts a fresh
             * launch-only session.
             */
            if isCapturing {
                mark("LOG", "mode changed to game-loading")
                winarc_runtime_log_stop()
            }
        }
    }

    static func beginGameLoadingCapture() {
        ensurePreferencesExist()

        guard isEnabled else { return }

        switch mode {
        case .always:
            if !isCapturing {
                startCapture(stopOnFirstPresent: false)
            }
            mark("GameLoad", "game/Wine launch capture entered")

        case .gameLoading:
            if isCapturing {
                winarc_runtime_log_stop()
            }

            startCapture(stopOnFirstPresent: true)
            mark("GameLoad", "launch-only capture entered")

            /*
             * Safety valve for a title that never creates a surface and keeps
             * running indefinitely. Three minutes is intentionally generous:
             * crashes/hangs during loading still leave useful logs, while a
             * successful long session cannot generate an unbounded file.
             */
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                guard isEnabled,
                      mode == .gameLoading,
                      isCapturing else {
                    return
                }

                mark(
                    "LOG",
                    "game-loading capture reached 180s safety limit"
                )
                winarc_runtime_log_stop()
            }
        }
    }

    static func mark(_ subsystem: String, _ message: String) {
        guard isCapturing else { return }

        subsystem.withCString { subsystemCString in
            message.withCString { messageCString in
                winarc_runtime_log_mark(
                    subsystemCString,
                    messageCString
                )
            }
        }
    }

    static func tail(maxBytes: Int = 512 * 1024) -> String {
        ensureLogFileExists()

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return "还没有运行日志。"
        }

        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(maxBytes)
            ? end - UInt64(maxBytes)
            : 0

        try? handle.seek(toOffset: start)

        guard let data = try? handle.readToEnd(),
              !data.isEmpty else {
            return "日志文件为空。"
        }

        var text = String(decoding: data, as: UTF8.self)

        if start > 0 {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }

            text =
                "……仅显示最后 \(maxBytes / 1024) KB……\n"
                + text
        }

        return text
    }

    static func clear() {
        let shouldResumeAlways =
            isEnabled && mode == .always

        if isCapturing {
            winarc_runtime_log_stop()
        }

        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: previousFileURL)

        ensureLogFileExists()

        if shouldResumeAlways {
            startCapture(stopOnFirstPresent: false)
            mark("LOG", "log cleared; always-on capture resumed")
        }
    }

    static func ensureLogFileExists() {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            if !FileManager.default.fileExists(
                atPath: fileURL.path
            ) {
                FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: Data()
                )
            }
        } catch {
            /* Settings will simply show an empty/unavailable log. */
        }
    }

    private static func ensurePreferencesExist() {
        _ = isEnabled
    }

    private static func startCapture(
        stopOnFirstPresent: Bool
    ) {
        ensureLogFileExists()

        if !isCapturing {
            rotateIfNeeded(maxBytes: defaultMaxBytes)
        }

        fileURL.path.withCString { pathCString in
            _ = winarc_runtime_log_start(
                pathCString,
                stopOnFirstPresent ? 1 : 0
            )
        }
    }

    private static func rotateIfNeeded(maxBytes: Int) {
        guard
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? NSNumber,
            size.intValue >= maxBytes
        else {
            return
        }

        try? FileManager.default.removeItem(
            at: previousFileURL
        )

        try? FileManager.default.moveItem(
            at: fileURL,
            to: previousFileURL
        )

        ensureLogFileExists()
    }
}
