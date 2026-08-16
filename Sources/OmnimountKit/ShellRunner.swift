import Foundation

public struct ShellResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }
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

        // Leer en paralelo para no bloquear si un pipe se llena.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
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
