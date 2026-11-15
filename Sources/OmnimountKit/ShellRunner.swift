import Foundation

public struct ShellResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let terminatedBySignal: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, terminatedBySignal: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.terminatedBySignal = terminatedBySignal
    }

    public var succeeded: Bool { !terminatedBySignal && exitCode == 0 }
}

public enum ShellError: Error, LocalizedError {
    case launchFailed(String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let tool, let error):
            return "No se pudo ejecutar \(tool): \(error.localizedDescription)"
        }
    }
}

/// Ejecuta binarios externos de forma síncrona capturando stdout/stderr.
public enum ShellRunner {
    /// El lector de stderr escribe desde otra cola; el acceso a su resultado
    /// está protegido también para las comprobaciones de concurrencia de Swift.
    private final class OutputCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func store(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            storage = data
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(executable, underlying: error)
        }

        // Drenar ambos pipes a la vez: esperar al EOF de stdout antes de leer
        // stderr puede bloquear al hijo cuando se llena el buffer de stderr.
        let errCapture = OutputCapture()
        let readers = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: readers) {
            errCapture.store(errPipe.fileHandleForReading.readDataToEndOfFile())
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        readers.wait()
        let errData = errCapture.snapshot()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            terminatedBySignal: process.terminationReason == .uncaughtSignal
        )
    }

    /// Ejecuta un comando de shell con privilegios de administrador mediante
    /// el diálogo nativo de macOS (osascript "with administrator privileges").
    /// Pensado para la app de menú; el CLI asume que ya corre bajo sudo.
    @discardableResult
    public static func runPrivileged(_ command: String, prompt: String) throws -> ShellResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(escapedPrompt)\""
        return try run("/usr/bin/osascript", ["-e", script])
    }
}
