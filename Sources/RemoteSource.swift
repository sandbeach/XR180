import AppKit
import Combine
import NetFS

enum RemoteSource {
    case share(URL)
    case video(URL)

    enum AddressError: LocalizedError {
        case invalid, missingShare, credentials, shareOptions

        var errorDescription: String? {
            switch self {
            case .invalid: return "请输入 SMB 共享地址或 HTTPS 视频直链。"
            case .missingShare: return "请补上共享文件夹名，例如 smb://nas.local/Video。"
            case .credentials: return "请从地址中移除账号和密码。连接 SMB 时请使用下方的登录字段。"
            case .shareOptions: return "SMB 地址应止于共享文件夹名，连接后再浏览子文件夹。"
            }
        }
    }

    init(_ text: String) throws {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Encode unescaped whitespace and Unicode without changing an existing % escape.
        let urlCharacters = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        guard !address.contains(where: \.isNewline),
              let escaped = address.addingPercentEncoding(withAllowedCharacters: urlCharacters),
              let parts = URLComponents(string: escaped),
              let scheme = parts.scheme?.lowercased(), ["smb", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              !host.contains(where: \.isWhitespace), let url = parts.url else {
            throw AddressError.invalid
        }
        guard parts.user == nil, parts.password == nil else { throw AddressError.credentials }

        if scheme == "smb" {
            let path = parts.percentEncodedPath.split(separator: "/")
            guard !path.isEmpty else { throw AddressError.missingShare }
            guard path.count == 1, let name = path[0].removingPercentEncoding,
                  !name.contains("/"), name != ".", name != "..",
                  parts.query == nil, parts.fragment == nil else { throw AddressError.shareOptions }
            var share = parts
            share.scheme = "smb"
            share.host = host.lowercased()
            share.percentEncodedPath = "/" + path[0]
            guard let root = share.url else { throw AddressError.invalid }
            self = .share(root)
        } else {
            guard !parts.path.isEmpty, parts.path != "/" else { throw AddressError.invalid }
            self = .video(url)
        }
    }
}

enum RemoteSelection {
    case browse(URL, notice: String? = nil)
    case play(URL)
}

/// UI state and cancellation are owned by the main thread. NetFS owns the SMB
/// session and returns the mount point on the main queue.
final class RemoteConnection: ObservableObject {
    private static let addressKey = "lastSMBShare"
    private static let mountedVolumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)

    @Published var address = UserDefaults.standard.string(forKey: addressKey) ?? ""
    @Published var username = ""
    @Published var password = ""
    @Published var remember = false
    @Published private(set) var connecting = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private var requestID: AsyncRequestID?
    private var activeAttempt: UUID?

    func open(onSelect: @escaping (RemoteSelection) -> Void) {
        guard !connecting else { return }
        clearMessage()
        do {
            switch try RemoteSource(address) {
            case .video(let url):
                password = ""
                onSelect(.play(url))
            case .share(let url):
                let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty && !password.isEmpty {
                    error = "请填写 NAS 的 SMB 用户名。"
                    return
                }
                if remember && (name.isEmpty || password.isEmpty) {
                    error = "要保存登录，请填写用户名和密码。"
                    return
                }
                let login = name.isEmpty ? nil : SMBLogin(username: name, password: password)
                password = ""
                mount(url, login: login, remember: remember, onSelect: onSelect)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func useSavedLogin(onSelect: @escaping (RemoteSelection) -> Void) {
        guard !connecting else { return }
        clearMessage()
        do {
            guard let share = try shareAddress() else { return }
            guard let login = try SMBKeychain.login(for: share) else {
                error = "此共享还没有保存的登录。"
                return
            }
            password = ""
            mount(share, login: login, remember: false, onSelect: onSelect)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func forgetLogin() {
        guard !connecting else { return }
        clearMessage()
        do {
            guard let share = try shareAddress() else { return }
            notice = try SMBKeychain.remove(for: share) ? "已从钥匙串移除此共享的登录。" : "此共享还没有保存的登录。"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearMessage() {
        error = nil
        notice = nil
    }

    func cancel() {
        activeAttempt = nil
        if let requestID { NetFSMountURLCancel(requestID) }
        requestID = nil
        password = ""
        connecting = false
    }

    private func shareAddress() throws -> URL? {
        guard case .share(let share) = try RemoteSource(address) else {
            error = "请输入要管理登录的 SMB 共享地址。"
            return nil
        }
        return share
    }

    private func mount(_ url: URL, login: SMBLogin?, remember: Bool,
                       onSelect: @escaping (RemoteSelection) -> Void) {
        var request: AsyncRequestID?
        let attempt = UUID()
        let explicitPassword = login.flatMap { $0.password.isEmpty ? nil : $0.password }
        // With an explicit password, require a new authentication session before saving.
        let options = CFDictionaryCreateMutableCopy(nil, 0, [
            "ForceNewSession": true, "UIOption": "NoUI"
        ] as CFDictionary)
        activeAttempt = attempt
        connecting = true
        let result = NetFSMountURLAsync(
            url as CFURL, nil, login.map { $0.username as CFString },
            explicitPassword.map { $0 as CFString }, explicitPassword == nil ? nil : options,
            nil, &request, .main
        ) { [weak self] status, _, locations in
            guard let self, self.activeAttempt == attempt else { return }
            self.requestID = nil
            self.activeAttempt = nil
            self.connecting = false

            if status == 0 {
                UserDefaults.standard.set(url.absoluteString, forKey: Self.addressKey)
                var notice: String?
                if remember, let login {
                    do { try SMBKeychain.save(login, for: url) }
                    catch { notice = "共享已连接，但未能保存登录。\(error.localizedDescription)" }
                }
                let path = (locations as? [String])?.first(where: { $0.hasPrefix("/") })
                let folder = path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.mountedVolumes
                onSelect(.browse(folder, notice: notice))
            } else {
                self.handleMountError(status, explicit: explicitPassword != nil, onSelect: onSelect)
            }
        }
        if result == 0 {
            requestID = request
        } else {
            activeAttempt = nil
            connecting = false
            handleMountError(result, explicit: explicitPassword != nil, onSelect: onSelect)
        }
    }

    private func handleMountError(_ code: Int32, explicit: Bool,
                                  onSelect: (RemoteSelection) -> Void) {
        switch code {
        case -128:
            break
        case EEXIST:
            if explicit {
                error = "此共享已连接。要用这个账号重新登录，请先在 Finder 弹出共享。"
            } else {
                onSelect(.browse(Self.mountedVolumes))
            }
        case EACCES, EPERM, EAUTH, -5999:
            error = "SMB 登录失败。请检查 NAS 用户名、密码及该账号对共享文件夹的读取权限。"
        case ENOENT:
            error = "找不到共享文件夹。请确认地址末尾是 NAS 上的 SMB 共享名称。"
        default:
            error = "连接失败（\(code)）。请检查 NAS 地址、SMB 服务，以及当前网络或 VPN。"
        }
    }
}
