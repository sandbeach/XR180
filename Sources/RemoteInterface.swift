import SwiftUI

struct RemoteInterface: View {
    @StateObject private var connection = RemoteConnection()
    let onSelect: (RemoteSelection) -> Void
    let onCancel: () -> Void

    private var address: String { connection.address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isWebLink: Bool { address.lowercased().hasPrefix("https://") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("打开 NAS 视频", systemImage: "externaldrive.connected.to.line.below")
                .font(.title3.weight(.semibold))
            Text("输入 SMB 共享地址来浏览文件，或粘贴 HTTPS 视频直链。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("smb://nas.local/Video", text: $connection.address)
                .accessibilityLabel("共享地址或视频直链")
                .disabled(connection.connecting)
                .onChange(of: connection.address) { _ in connection.clearMessage() }
            if !isWebLink { loginFields }
            if connection.connecting {
                ProgressView("正在连接共享…").controlSize(.small)
            } else if let error = connection.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let notice = connection.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 10) {
                Button("浏览已连接的共享") {
                    onSelect(.browse(URL(fileURLWithPath: "/Volumes", isDirectory: true)))
                }
                .disabled(connection.connecting)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button(isWebLink ? "播放" : "连接") { connection.open(onSelect: onSelect) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connection.connecting || address.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 510)
        .onDisappear { connection.cancel() }
    }

    private var loginFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("SMB 用户名", text: $connection.username)
                    .autocorrectionDisabled()
                SecureField("SMB 密码", text: $connection.password)
            }
            HStack {
                Toggle("登录成功后保存到钥匙串", isOn: $connection.remember)
                Spacer()
                Menu("已保存的登录") {
                    Button("使用已保存的登录") { connection.useSavedLogin(onSelect: onSelect) }
                    Button("从钥匙串移除") { connection.forgetLogin() }
                }
                .fixedSize()
                .disabled(address.isEmpty)
            }
            Text("账号和密码留空时，macOS 会在需要时提示登录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(connection.connecting)
    }
}
