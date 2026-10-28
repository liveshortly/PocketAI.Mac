import SwiftUI
import PocketKit
import PocketUI

/// MAC-06 (residual): request / activity log for the Server screen.
///
/// The Core exposes no per-HTTP-request log (the audit ledger records only
/// lifecycle + security events: `server.on`, `model.loaded`, `device.paired`,
/// etc.), so instead of fabricating request rows we surface the two real
/// sources that answer "what is happening with my server": paired-device
/// sessions (`devices()` last-seen) and the audit event ledger (`auditLog`),
/// merged into one time-sorted table. Labeled honestly as such.
struct ServerActivityView: View {
    @Environment(AppModel.self) private var model

    @State private var rows: [ActivityRow] = []

    private struct ActivityRow: Identifiable {
        let id: String
        let ts: Int64
        let source: String
        let event: String
        let detail: String
        let icon: String
        let tint: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECENT ACTIVITY")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                    Text("Device sessions and server events. (The local server does not log individual HTTP requests.)")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                Spacer()

                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.pocket(.caption))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(spacing: 0) {
                if rows.isEmpty {
                    emptyState
                } else {
                    headerRow
                    ForEach(rows) { row in
                        Divider()
                        activityRow(row)
                    }
                }
            }
            .padding(PocketSpacing.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketColor.lineHairline, lineWidth: 0.8)
            )
        }
        .task { reload() }
    }

    private var headerRow: some View {
        HStack(spacing: PocketSpacing.s12) {
            Text("TIME")
                .frame(width: 150, alignment: .leading)
            Text("SOURCE")
                .frame(width: 120, alignment: .leading)
            Text("EVENT")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("DETAIL")
                .frame(width: 160, alignment: .leading)
        }
        .font(.pocket(.caption))
        .foregroundStyle(PocketColor.textTertiary)
        .padding(.horizontal, PocketSpacing.s8)
        .padding(.vertical, PocketSpacing.s8)
    }

    private func activityRow(_ row: ActivityRow) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Text(Self.formatTimestamp(row.ts))
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textSecondary)
                .frame(width: 150, alignment: .leading)

            HStack(spacing: 6) {
                Image(systemName: row.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(row.tint)
                Text(row.source)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)

            Text(row.event)
                .font(.pocket(.mono))
                .foregroundStyle(PocketColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.detail)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 160, alignment: .leading)
        }
        .padding(.horizontal, PocketSpacing.s8)
        .padding(.vertical, PocketSpacing.s8)
    }

    private var emptyState: some View {
        VStack(spacing: PocketSpacing.s8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(PocketColor.textTertiary)
            Text("No requests yet")
                .font(.pocket(.headline))
                .foregroundStyle(PocketColor.textPrimary)
            Text("Device sessions and server events will appear here as your Mac serves models.")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PocketSpacing.s32)
    }

    private func reload() {
        var merged: [ActivityRow] = []

        // Real source 1: paired-device sessions (closest thing to "who hit the
        // server") — a device's last-seen is its most recent contact.
        for device in model.core.devices() where device.revokedAt == nil {
            guard let seen = device.lastSeenAt else { continue }
            merged.append(ActivityRow(
                id: "device-\(device.id)",
                ts: seen,
                source: device.name,
                event: "device.session",
                detail: device.lastAddr ?? "Local Network",
                icon: "iphone",
                tint: PocketColor.statusOk
            ))
        }

        // Real source 2: the audit event ledger.
        for entry in model.core.auditLog(query: AuditQuery(limit: 50, sinceTs: nil)) {
            merged.append(ActivityRow(
                id: "audit-\(entry.id)",
                ts: entry.ts,
                source: entry.actor,
                event: entry.action,
                detail: entry.target,
                icon: "shield.lefthalf.filled",
                tint: PocketColor.accent
            ))
        }

        rows = merged.sorted { $0.ts > $1.ts }
    }

    // ts is epoch milliseconds (per Core fixtures + Rust store).
    private static func formatTimestamp(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: Double(ts) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}
