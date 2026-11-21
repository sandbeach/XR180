# XR180

**在 Mac 上播放 VR180 双目视频，把画面送到 XREAL 眼镜，播放控件留在 Mac 上。**

XR180 是一个原生 macOS 播放器。它读取本地文件或 NAS 上的 VR180 视频，根据眼镜的头部姿态实时渲染左右眼画面，然后通过 USB-C 把两幅画面以 **Full SBS（3840 × 1080）** 输出到眼镜。转头可以浏览 180° 片源的不同方向。

Android 0.1.0 的功能、Galaxy S23+ 安装和连接方式见[安卓版说明](docs/android.md)。

## 功能

- **眼镜全屏播放**。识别到处于 Full SBS 模式的 XREAL 扩展屏后，打开影片或点「播放」会自动输出。Mac 上保留暂停、进度条和回正控件。
- **3DoF 头部追踪**。支持转头、抬头和歪头，可静止校准、回正或调整追踪方向。
- **多种片源格式**。支持等距柱状 VR180、等距鱼眼、等立体角鱼眼和平面 3D，可选左右并排、上下排列或单眼，支持交换左右眼、上下翻转和旋转。
- **本地与 NAS 播放**。打开本地 MP4 / MOV、从 SMB 共享按需读取，或使用 HTTPS 视频直链。SMB 登录成功后可选择把账号和密码保存在 macOS 钥匙串。

## 兼容性

| 项目 | 说明 |
| --- | --- |
| 当前版本 | 0.4.0 |
| macOS | 最低部署版本为 macOS 13。预编译应用适用于 Apple Silicon，Intel 构建尚未验证。 |
| 眼镜 | 已在 XREAL 1 Pro+ 上实测播放。项目最初面向 XREAL One Pro 开发，其他机型和固件组合的兼容性待验证。 |
| 连接 | 使用支持视频和数据的 USB-C 线直连 Mac。眼镜需开启 Full SBS，并设为独立的扩展显示器。 |
| 视频编码 | 取决于 AVFoundation 的解码能力。建议先用 H.264 或 HEVC 编码的 MP4 / MOV 测试。 |

## 快速开始

1. **连接眼镜。** 如果 macOS 问要在眼镜上显示什么，选「扩展显示器」。也可在「系统设置 → 显示器」中设置。
2. **开启 Full SBS。** 双击眼镜的 X 键打开菜单，在 3D 模式中选择 **3D Full SBS**。确认 Mac 将眼镜识别为 **3840 × 1080** 扩展屏。眼镜若在固定虚拟屏幕，可切到 Follow（跟随）。[XREAL 1 Pro+ 的 3D 模式](https://tutorials.xreal.com/docs/glasses/pro-plus/spatial-screen/three-d/) · [XREAL One 系列的 3D 模式](https://tutorials.xreal.com/docs/glasses/one-series/osd/3d-mode/)
3. **检查左右眼和姿态。** 打开 XR180，点「测试图」和「输出到眼镜」。左眼左上角应看到青色块，右眼右上角应看到橙色块。启用「使用眼镜头部追踪」，静置眼镜直到校准完成，戴上后看向正前方，点「回正」。macOS 若请求本地网络权限，选择允许。
4. **打开影片。** 默认按「VR180 等距柱状 + 左右并排」播放。如果片源里有两个鱼眼圆形画面，切换到对应的鱼眼投影，再按镜头参数调整视野。按 **Esc** 可以暂停并停止眼镜输出。

未连接眼镜时，Mac 窗口提供左眼预览，可拖动改变视角。声音由 macOS 当前选中的音频设备播放。

## 播放 NAS 视频

1. 确认 NAS 已启用 SMB，且账号有共享目录的读取权限。
2. 在 XR180 点「NAS 视频」，输入共享地址，例如 `smb://nas.local/Video`。如果主机名无法解析，可填写 NAS 的 IP，例如 `smb://192.168.1.20/Video`。填写 SMB 用户名和密码后点「连接」，然后从共享文件夹选择视频。[Apple 的 SMB 地址说明](https://support.apple.com/guide/mac-help/servers-shared-computers-connect-mac-mchlp3015/mac)
3. 如需记住账号，勾选「登录成功后保存到钥匙串」。下次打开同一个共享地址时，选「已保存的登录 → 使用已保存的登录」。也可以在这里移除记录。

Finder 已连接的共享可从「浏览已连接的共享」打开。外出时可先连上已有的家庭 VPN，再访问 NAS。HTTPS 链接应指向可直接读取的 MP4 或 MOV 文件，NAS 管理页和网盘分享页无法直接播放。

## 从源码构建

在 macOS 上安装 Xcode Command Line Tools，然后在仓库根目录执行：

```sh
./build.sh
open build/XR180.app
```

构建脚本使用系统 SDK，并按当前 Mac 的架构生成应用。应用使用本机临时签名，未做 Apple 公证。

运行 `./validate.sh` 可生成合成双目片源，检查 AVPlayer 解码、Metal 左右眼渲染和模拟 IMU 数据处理。

## 实现与限制

- **界面与输出**由 SwiftUI 和 AppKit 提供。播放器创建全屏输出窗口，并将其放到眼镜的扩展屏上。
- **播放与投影**使用 AVFoundation 和 Metal。GPU 根据当前姿态从视频纹理采样，再组成输出给眼镜的左右眼画面。
- **头部姿态**来自眼镜 USB Ethernet 上的 IMU。当前支持三轴旋转。若眼镜能显示画面但追踪连不上，请检查眼镜的 Ethernet 选项、USB-C 线的数据功能和 macOS 本地网络权限。
- **片源限制**包括自定义 VR180 投影网格、逐帧相机姿态、分层 MV-HEVC 和 HLS，这些格式或元数据暂未支持。高分辨率片源是否流畅取决于编码、Mac 解码能力和 NAS 网络速度。[Google VR180 规范](https://github.com/google/spatial-media/blob/master/docs/vr180.md)

## 致谢

- [Skarian/vr2xr](https://github.com/Skarian/vr2xr) 提供了 Android 上 VR180 播放及头部追踪的参考。
- [comxtohr/xreal-one-mac-probe](https://github.com/comxtohr/xreal-one-mac-probe) 和 [Skarian/one-xr](https://github.com/Skarian/one-xr) 提供了 XREAL IMU 协议和姿态处理参考。

XR180 是独立项目，与 XREAL 官方无关联。
