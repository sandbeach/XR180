# XR180 Android 0.1.0

XR180 Android 把 VR180 视频送到通过 USB-C 连接的 XREAL 眼镜，手机保留触摸播放控件。首版 APK 面向 **Android 13 或更新版本的 arm64 手机**，已在 Galaxy S23+ 上安装并启动。

## 这一版改了什么

- **手机负责操作，眼镜显示视频。** 中文竖屏首页可以打开手机视频、NAS 共享或视频直链。播放页有进度条、播放和暂停、15 秒快进快退，以及一键回正。播放界面保持屏幕亮起。
- **头部追踪和触控板。** 支持静置校准与 3DoF 追踪。手机识别到外接屏时，即使头部传感器暂不可用，也可用触控板拖动调整视角、双指缩放。
- **VR180 投影。** 可在等距柱状、等距鱼眼和等立体角鱼眼之间切换，并分别调整观看视野和鱼眼镜头视野。
- **NAS 播放。** 支持 SMB 共享浏览和按需读取。账号保存默认关闭，勾选后在连接成功时保存，凭据由 Android Keystore 保护。长按已保存的账号可移除。

## 安装 APK

已有 `XR180-Android-0.1.0-arm64.apk` 时，将文件传到手机，用「我的文件」打开，按系统提示安装。通过 USB 选择「传输文件」可以复制 APK，安装仍需在手机上确认。

开发者也可以通过 [ADB](https://developer.android.com/tools/adb#install) 安装。开启 USB 调试后解锁手机，并允许当前电脑的调试请求。

```sh
adb devices
adb install -r XR180-Android-0.1.0-arm64.apk
```

如果三星手机提示 USB 调试被「自动拦截程序」阻止，请只在安装可信 APK 时临时关闭该功能。安装后可关闭 USB 调试，并恢复自动拦截。[三星自动拦截程序说明](https://www.samsung.com/us/support/answer/ANS10003636/)

## 连接眼镜并播放

1. 用支持视频和数据传输的 USB-C 线直连眼镜。如果 Galaxy 自动进入 Samsung DeX，退出 DeX，改用「屏幕镜像」。[三星显示模式说明](https://www.samsung.com/us/apps/dex/)
2. 在眼镜的 3D 菜单选择 **3D Full SBS（3840 × 1080）**。[XREAL 1 Pro+ 设置说明](https://tutorials.xreal.com/docs/glasses/pro-plus/spatial-screen/three-d/)
3. 打开 XR180 并选片。需要校准时把眼镜放稳，待校准完成后再戴上。看向正前方，点「回正」。
4. 播放 NAS 视频时，在「打开 NAS 视频」中分别填写服务器 IP 和共享名。例如 `smb://192.168.1.20/home` 对应服务器地址 `192.168.1.20`、共享名 `home`。填写 SMB 用户名和密码，域按 NAS 配置填写。

## 验证范围

| 环境 | 已验证 |
| --- | --- |
| Android 15 arm64 模拟器，使用 S23 系列屏幕尺寸 | APK 安装、中文首页、NAS 登录表单。通过模拟 3840 × 1080 外接屏播放合成双目视频，确认视频路由与手机播放控件。 |
| Galaxy S23+ 真机 | 已通过 USB 调试安装 0.1.0，确认应用启动。眼镜输出、头部追踪和实际 NAS 播放仍需在真机上验证。 |

## 技术与来源

Android 版使用 Kotlin、Media3 和 OpenGL ES。通过 Android 外接显示窗口向眼镜输出，使用 IMU 获取头部姿态。SMB 播放包含原生 libsmb2 和 jcifs-ng 兼容路径。构建环境为 JDK 17、Android SDK 35、Build Tools 36.0.0、NDK 29.0.14206865 和 CMake 3.22.1。

Android 版基于 [NeoNatural/vr2xr-neo](https://github.com/NeoNatural/vr2xr-neo)、[Skarian/vr2xr](https://github.com/Skarian/vr2xr) 和 [Skarian/one-xr](https://github.com/Skarian/one-xr)。Android 与 macOS 采用各自的构建流程。
