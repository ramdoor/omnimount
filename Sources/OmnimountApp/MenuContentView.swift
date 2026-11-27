import ServiceManagement
import SwiftUI
import OmnimountKit

struct MenuContentView: View {
    @EnvironmentObject private var monitor: DiskMonitor
    @EnvironmentObject private var mountController: MountController
    @AppStorage("menuTextSize") private var menuTextSizeRaw = MenuTextSize.normal.rawValue

    private var diagnosis: ToolLocator.Diagnosis { ToolLocator.diagnose() }

    /// Abre la ventana de Configuración vía AppDelegate (funciona en 12 y 13+;
    /// evita openWindow / la escena Window, que son de macOS 13+).
    private func openSetup() {
        NotificationCenter.default.post(name: .omnimountOpenSetup, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Omnimount")
                    .font(.headline)
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

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
                Text(L10n.t("disk.list.empty"))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(monitor.disks) { disk in
                    DiskSection(disk: disk)
                }
            }

            if let target = mountController.quotaFixTarget {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("app.menu.quota", target.deviceIdentifier))
                        .font(.caption)
                    HStack {
                        Button(L10n.t("app.menu.disableQuotas")) {
                            mountController.fixQuotaAndMount(target) { monitor.refresh() }
                        }
                        .controlSize(.small)
                        .disabled(mountController.busy.isDiskBusy(target.parentWholeDisk))
                        Button(L10n.t("app.common.cancel")) { mountController.quotaFixTarget = nil }
                            .controlSize(.small)
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            if let message = mountController.lastMessage ?? monitor.lastError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }

            if let label = mountController.cloneLabel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.caption)
                    if let value = mountController.cloneProgress {
                        ProgressView(value: value)
                        Text(String(format: "%.0f %%", value * 100))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n.t("app.menu.refresh"))
                Button(L10n.t("app.menu.updates")) {
                    Updater.controller.checkForUpdates(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button(L10n.t("app.menu.setup")) {
                    openSetup()
                }
                Spacer()
                Button(L10n.t("app.menu.quit")) { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 340)
        .dynamicTypeSize((MenuTextSize(rawValue: menuTextSizeRaw) ?? .normal).dynamicTypeSize)
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
            Label(L10n.t("app.menu.helperOn"), systemImage: "bolt.badge.checkmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.t("app.menu.approveHelper"), systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(L10n.t("app.menu.openSettings")) {
                    if #available(macOS 13.0, *) { SMAppService.openSystemSettingsLoginItems() }
                }
                    .controlSize(.small)
            }
        case .notRegistered:
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.t("app.menu.enableHelperHint"), systemImage: "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.t("app.common.enableHelper")) {
                    mountController.helper.install()
                }
                .controlSize(.small)
            }
        case .unavailable(let reason):
            Label(L10n.t("app.menu.helperUnavailable", reason), systemImage: "xmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var dependencyStatus: some View {
        let d = diagnosis
        if d.canMountExt && d.canMountNTFS && mountController.isCLIInstalled {
            Label(L10n.t("app.menu.dependenciesOk"), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if !d.hasFuseLayer {
                    Label(L10n.t("app.menu.fuseMissing"), systemImage: "exclamationmark.triangle")
                }
                if d.fuse2fs == nil {
                    Label(L10n.t("app.menu.fuse2fsMissing"), systemImage: "exclamationmark.triangle")
                }
                if d.ntfs3g == nil {
                    Label(L10n.t("app.menu.ntfsMissing"), systemImage: "exclamationmark.triangle")
                }
                if !mountController.isCLIInstalled {
                    Label(L10n.t("app.menu.cliMissing"), systemImage: "exclamationmark.triangle")
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
    @EnvironmentObject private var mountController: MountController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(disk.mediaName ?? disk.deviceIdentifier) · \(disk.humanSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button(L10n.t("app.menu.cloneDisk")) {
                        mountController.cloneToImage(
                            identifier: disk.deviceIdentifier,
                            wholeDisk: disk.deviceIdentifier,
                            suggestedName: disk.mediaName ?? disk.deviceIdentifier,
                            totalBytes: disk.size) { monitor.refresh() }
                    }
                    Button(L10n.t("app.menu.restoreDisk"), role: .destructive) {
                        mountController.restoreImage(disk: disk) { monitor.refresh() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .disabled(mountController.cloneLabel != nil
                          || mountController.busy.isDiskBusy(disk.deviceIdentifier))
                .help(L10n.t("app.menu.cloneHelp"))
            }
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

    /// Esta partición es el destino de la operación en curso.
    private var isBusy: Bool {
        mountController.busy.isTarget(partition.deviceIdentifier)
    }

    /// Hay una operación en curso en este disco (en esta u otra partición,
    /// o sobre el disco entero): las acciones quedan desactivadas.
    private var isDiskBusy: Bool {
        mountController.busy.isDiskBusy(partition.parentWholeDisk)
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
                if mountController.readOnlyPartitions.contains(partition.deviceIdentifier)
                    || monitor.readOnlyByMacOS.contains(partition.deviceIdentifier) {
                    Button(L10n.t("app.common.makeWritable")) {
                        mountController.makeWritable(partition) { monitor.refresh() }
                    }
                    .tint(.orange)
                    .disabled(isDiskBusy)
                    .help(L10n.t("app.menu.readOnlyHelp"))
                }
                Button {
                    mountController.revealInFinder(mountPoint)
                } label: {
                    Image(systemName: "folder")
                }
                .help(L10n.t("app.menu.reveal"))
                Button(L10n.t("app.menu.eject")) {
                    mountController.unmount(partition) { monitor.refresh() }
                }
                .disabled(isDiskBusy)
            } else {
                Button(L10n.t("app.menu.mount")) {
                    mountController.mount(partition) { monitor.refresh() }
                }
                .disabled(isDiskBusy)
            }

            Menu {
                Button(L10n.t("app.menu.clonePartition")) {
                    mountController.cloneToImage(
                        identifier: partition.deviceIdentifier,
                        wholeDisk: partition.parentWholeDisk,
                        suggestedName: partition.volumeName ?? partition.deviceIdentifier,
                        totalBytes: partition.size) { monitor.refresh() }
                }
                .disabled(mountController.cloneLabel != nil)
                Button(L10n.t("app.menu.format"), role: .destructive) {
                    mountController.formatTarget = partition
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .disabled(isDiskBusy)
            .help(L10n.t("app.menu.more"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
