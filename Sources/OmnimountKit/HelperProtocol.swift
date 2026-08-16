import Foundation

/// Constantes compartidas entre la app y el helper privilegiado.
public enum HelperConstants {
    /// Nombre del servicio Mach del daemon (debe coincidir con MachServices
    /// en el plist de LaunchDaemons embebido en la app).
    public static let machServiceName = "org.omnimount.helper"
    /// Nombre del plist dentro de Contents/Library/LaunchDaemons/.
    public static let plistName = "org.omnimount.helper.plist"
    /// Versión del protocolo; la app la comprueba al conectar para detectar
    /// helpers antiguos tras una actualización.
    public static let protocolVersion = "1"
}

/// Operaciones privilegiadas que el daemon expone por XPC.
/// Todos los tipos deben ser representables en Objective-C.
@objc public protocol OmnimountHelperProtocol {
    /// Devuelve la versión del protocolo del helper instalado.
    func version(reply: @escaping (String) -> Void)

    /// Detecta el FS de una partición leyendo magic bytes.
    /// reply(éxito, nombreFS o mensaje de error, etiqueta o nil)
    func detect(deviceIdentifier: String,
                reply: @escaping (Bool, String, String?) -> Void)

    /// Monta una partición con el backend adecuado.
    /// reply(éxito, punto de montaje o mensaje de error)
    func mount(deviceIdentifier: String, readOnly: Bool,
               reply: @escaping (Bool, String) -> Void)

    /// Desmonta una partición (por identificador o punto de montaje).
    func unmount(target: String,
                 reply: @escaping (Bool, String) -> Void)

    /// Formatea una partición. DESTRUCTIVO — la app debe haber confirmado
    /// explícitamente con el usuario antes de llamar.
    /// filesystem: rawValue de TargetFormat (ext4, ntfs, fat32, exfat…).
    func format(deviceIdentifier: String, filesystem: String, label: String,
                reply: @escaping (Bool, String) -> Void)

    /// Autotest: ¿tiene el helper Acceso total al disco (TCC)?
    /// Sin él, todas las operaciones de disco fallarán con EPERM.
    func checkFullDiskAccess(reply: @escaping (Bool) -> Void)
}
