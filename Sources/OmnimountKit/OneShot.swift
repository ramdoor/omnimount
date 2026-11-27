import Foundation

/// Entrega un valor como mucho una vez, aunque `fire` se llame desde varios
/// hilos a la vez (p. ej. la respuesta XPC, el manejador de error de la
/// conexión y un temporizador). Las llamadas posteriores a la primera se
/// descartan.
public final class OneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Value) -> Void)?

    public init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    /// Ejecuta el manejador con `value` si es la primera llamada.
    /// Devuelve true solo en esa primera llamada.
    @discardableResult
    public func fire(_ value: Value) -> Bool {
        lock.lock()
        let current = handler
        handler = nil
        lock.unlock()
        guard let current else { return false }
        current(value)
        return true
    }
}
