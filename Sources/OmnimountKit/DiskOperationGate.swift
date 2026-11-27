import Foundation

public enum DiskOperationError: Error, LocalizedError, Equatable {
    case busy(String)

    public var errorDescription: String? {
        switch self {
        case .busy(let disk):
            return L10n.t("error.helper.busy", disk)
        }
    }
}

/// Operaciones que modifican un disco en el helper. Cada conexión XPC tiene
/// su propia cola, así que dos clientes pueden pedir operaciones a la vez:
/// solo se admite una por disco entero (disk4 y disk4s1 cuentan como el
/// mismo disco).
public final class DiskOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy: Set<String> = []

    public init() {}

    /// "disk4s1", "/dev/disk4s1" o "rdisk4" → "disk4". nil si no es un
    /// identificador BSD de disco.
    public static func wholeDiskIdentifier(_ identifier: String) -> String? {
        var rest = Substring(identifier)
        if rest.hasPrefix("/dev/") { rest = rest.dropFirst(5) }
        if rest.hasPrefix("r") { rest = rest.dropFirst() }
        guard rest.hasPrefix("disk") else { return nil }
        let afterPrefix = rest.dropFirst(4)
        let number = afterPrefix.prefix { $0.isASCII && $0.isNumber }
        guard !number.isEmpty else { return nil }
        // Resto: cero o más "s<número>".
        var tail = afterPrefix.dropFirst(number.count)
        while !tail.isEmpty {
            guard tail.first == "s" else { return nil }
            tail = tail.dropFirst()
            let slice = tail.prefix { $0.isASCII && $0.isNumber }
            guard !slice.isEmpty else { return nil }
            tail = tail.dropFirst(slice.count)
        }
        return "disk\(number)"
    }

    /// Ejecuta `body` con el disco reservado. Lanza `.busy` sin ejecutarlo
    /// si el disco ya tiene una operación en curso. Un identificador que no
    /// es de disco no se reserva: las comprobaciones de cada operación lo
    /// rechazan.
    public func run<T>(on identifier: String, _ body: () throws -> T) throws -> T {
        guard let disk = Self.wholeDiskIdentifier(identifier) else { return try body() }
        lock.lock()
        let inserted = busy.insert(disk).inserted
        lock.unlock()
        guard inserted else { throw DiskOperationError.busy(disk) }
        defer {
            lock.lock()
            busy.remove(disk)
            lock.unlock()
        }
        return try body()
    }
}
