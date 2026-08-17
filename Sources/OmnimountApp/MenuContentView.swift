import ServiceManagement
import SwiftUI
import OmnimountKit

struct MenuContentView: View {
    @EnvironmentObject private var monitor: DiskMonitor
    @EnvironmentObject private var mountController: MountController
    @Environment(\.openWindow) private var openWindow

    private var diagnosis: ToolLocator.Diagnosis { ToolLocator.diagnose() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Omnimount")
                .font(.headline)

            if let retro = monitor.retroMatch {
                Label {
                    Text("\(retro.firmware): \(retro.advice)")
                        .font(.caption)
                } icon: {
                    Text("🎮")
                }
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            if monitor.disks.isEmpty {
                Text(L10n.t("No hay discos externos conectados.", "No external disks connected."))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(monitor.disks) { disk in
                    DiskSection(disk: disk)
                }
            }

            if let message = mountController.lastMessage ?? monitor.lastError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }

            if let summary = mountController.lastFormatSummary {
                Label(summary, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(3)
            }

            Divider()

            helperStatus

            dependencyStatus

            HStack {
                Button(L10n.t("Actualizar", "Refresh")) { monitor.refresh() }
                Button(L10n.t("Actualizaciones…", "Updates…")) {
                    Updater.controller.checkForUpdates(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button(L10n.t("Configuración…", "Setup…")) {
                    openWindow(id: "setup")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button(L10n.t("Salir", "Quit")) { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { mountController.monitor = monitor }
        .sheet(item: $mountController.formatTarget) { partition in
            FormatSheet(partition: partition)
                .environmentObject(monitor)
                .environmentObject(mountController)
        }
    }

    @ViewBuilder
    private var helperStatus: some View {
        switch mountController.helper.state {
        case .enabled:
            Label(L10n.t("Helper activo: montaje sin contraseñas", "Helper active: password-free mounting"), systemImage: "bolt.badge.checkmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.t("Falta aprobar el helper en Ajustes → Elementos de inicio", "Approve the helper in Settings → Login Items"), systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(L10n.t("Abrir Ajustes", "Open Settings")) { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
            }
        case .notRegistered:
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.t("Activa el helper para montar sin contraseñas", "Enable the helper to mount without passwords"), systemImage: "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.t("Activar helper", "Enable helper")) {
                    mountController.helper.install()
                }
                .controlSize(.small)
            }
        case .unavailable(let reason):
            Label(L10n.t("Helper no disponible: \(reason)", "Helper unavailable: \(reason)"), systemImage: "xmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var dependencyStatus: some View {
        let d = diagnosis
        if d.canMountExt && d.canMountNTFS && mountController.isCLIInstalled {
            Label(L10n.t("Dependencias correctas", "All dependencies OK"), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if !d.hasFuseLayer {
                    Label(L10n.t("Falta la capa FUSE (abre Configuración…)", "FUSE layer missing (open Setup…)"), systemImage: "exclamationmark.triangle")
                }
                if d.fuse2fs == nil {
                    Label(L10n.t("Falta fuse2fs (scripts/build-fuse2fs.sh)", "fuse2fs missing (scripts/build-fuse2fs.sh)"), systemImage: "exclamationmark.triangle")
                }
                if d.ntfs3g == nil {
                    Label(L10n.t("Falta ntfs-3g (brew install gromgit/fuse/ntfs-3g-mac)", "ntfs-3g missing (brew install gromgit/fuse/ntfs-3g-mac)"), systemImage: "exclamationmark.triangle")
                }
                if !mountController.isCLIInstalled {
                    Label(L10n.t("Falta el CLI omnimount (make install)", "omnimount CLI missing (make install)"), systemImage: "exclamationmark.triangle")
                }
            }
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }
}

private struct DiskSection: View {
    let disk: ExternalDisk
    @EnvironmentObject private var monitor: DiskMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(disk.mediaName ?? disk.deviceIdentifier) · \(disk.humanSize)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(disk.partitions) { partition in
                PartitionRow(partition: partition)
            }
        }
    }
}

private struct PartitionRow: View {
    let partition: DiskPartition
    @EnvironmentObject private var monitor: DiskMonitor
    @EnvironmentObject private var mountController: MountController

    private var omnimountMountPoint: String? {
        monitor.mountedByOmnimount[partition.deviceIdentifier] ?? partition.mountPoint
    }

    private var isBusy: Bool {
        mountController.busyPartitions.contains(partition.deviceIdentifier)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(partition.volumeName ?? partition.deviceIdentifier)
                    .font(.body)
                Text("\(partition.deviceIdentifier) · \(partition.humanSize) · \(partition.contentHint)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if isBusy {
                ProgressView().controlSize(.small)
            } else if let mountPoint = omnimountMountPoint {
                Button {
                    mountController.revealInFinder(mountPoint)
                } label: {
                    Image(systemName: "folder")
                }
                .help(L10n.t("Mostrar en Finder", "Reveal in Finder"))
                Button(L10n.t("Expulsar", "Eject")) {
                    mountController.unmount(partition) { monitor.refresh() }
                }
            } else {
                Button(L10n.t("Montar", "Mount")) {
                    mountController.mount(partition) { monitor.refresh() }
                }
            }

            Menu {
                Button(L10n.t("Formatear…", "Format…"), role: .destructive) {
                    mountController.formatTarget = partition
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .help(L10n.t("Más acciones", "More actions"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
