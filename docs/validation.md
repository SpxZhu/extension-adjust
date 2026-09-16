# 验证记录

日期：2026-09-15。此文件记录已执行的检查，不将代码完成视为 SDK 集成验收完成。

## 已通过

| 检查 | 结果与边界 |
|---|---|
| Lua 行为测试 | Lua 5.3：18 passed / 0 failed |
| Lua 5.1 / LuaJIT 行为测试 | 使用本机 LuaJIT lua51.dll 执行同一套测试：18 passed / 0 failed |
| Lua 5.1 语法 | 通用层、业务层、配置、示例 gui_script、测试共 5 文件通过 |
| Android Java | javac 使用真实 Adjust 5.8.0 AAR 和 Android API 36 编译，target Java 8 |
| Android C++ | NDK 29.0.14033849、Defold 1.13.1 SDK 头文件，arm64 / armv7 两种目标编译为对象文件；-Wall -Wextra -Werror 通过；尚未完整链接 |
| 配置格式 | ext.manifest、script_api、CI YAML 可解析；Android XML 和填入文案后的 iOS plist 可解析 |
| 桌面 Lua / 资源 | 使用 Bob 1.13.1 构建不含原生 manifest 的隔离副本，成功 |
| 桌面实际运行 | Defold 1.13.1 Windows 引擎运行隔离示例，自动调用全部按钮与查询／公共参数接口，输出 ADJUST_RUNTIME_SMOKE_PASS，退出码 0 |
| HTML5 Lua / 资源 | Bob 1.13.1 wasm-web 隔离副本构建成功；尚未在浏览器运行完整扩展包 |

隔离副本位于 `.work/smoke`，只复制 Lua、示例和资源，不包含原生扩展 manifest。
该验证使用本地编译器和已有标准引擎，不上传源码；不能替代包含原生扩展的完整构建。

本地原生编译可通过下列脚本复现，路径按机器环境调整：

```sh
python tests/check_native.py --javac /path/to/javac --android-jar /path/to/android.jar --adjust-aar /path/to/adjust-android-5.8.0.aar --ndk /path/to/ndk --defold-sdk /path/to/defoldsdk
```

## 尚未通过验收的项目

- Android 完整链接、APK 打包、合并 manifest、混淆后 JNI、SDK 签名依赖与真机收数。
- iOS Objective-C++ 编译、CocoaPods 解析／链接、隐私资源打包、ATT 真机交互与收数。
- 完整 HTML5 扩展包编译及浏览器运行。
- 移动平台上的回调替换、脚本销毁、前后台切换与异步竞态验证。
- 真实 MAX RevenuePaid 数据与真实商店测试购买的端到端验证。

## 完整构建状态

尚未完成通过 Defold 构建服务进行的 Android、iOS、HTML5 完整构建。
Bob 远程构建会向指定服务发送扩展原生源码、平台 manifests 和所需构建数据。
构建步骤与自建服务选项见 `DEVELOPMENT.md`。示例配置中的 app token 和 event token 当前均为空。
完成构建与真机验证后，需更新上述验收状态。
