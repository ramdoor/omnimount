import Foundation

/// Operaciones en curso, agrupadas por disco entero. Mientras una operación
/// trabaja sobre un disco o cualquiera de sus particiones, ese disco entero
/// cuenta como ocupado y no admite otra operación.
public struct DiskBusyRegistry: Equatable, Sendable {
    /// Destino de la operación (partición o disco) → disco entero al que pertenece.
    private var targets: [String: String] = [:]

    public init() {}

    /// Registra una operación sobre `target` (que pertenece a `wholeDisk`).
    /// Devuelve false, sin registrar nada, si ese disco ya está ocupado.
    public mutating func begin(target: String, wholeDisk: String) -> Bool {
        guard !isDiskBusy(wholeDisk) else { return false }
        targets[target] = wholeDisk
        return true
    }

    /// Marca como terminada la operación sobre `target`.
    public mutating func end(target: String) {
        targets.removeValue(forKey: target)
    }

    /// true si `identifier` es el destino de una operación en curso.
    public func isTarget(_ identifier: String) -> Bool {
        targets[identifier] != nil
    }

    /// true si hay una operación en curso sobre `wholeDisk` o sus particiones.
    public func isDiskBusy(_ wholeDisk: String) -> Bool {
        targets.values.contains(wholeDisk)
    }

    /// true si no hay ninguna operación en curso.
    public var isEmpty: Bool { targets.isEmpty }
}
