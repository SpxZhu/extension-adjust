# 开发与验收

## 文件组织

```text
extension-adjust/
  adjust.lua               通用 Lua API、平台选择、校验、非移动平台空实现
  attribution.lua          可选业务辅助层
  api/                     Defold 编辑器提示
  src/adjust.cpp           Lua C API、主线程回调队列和初始化状态
  src/adjust_android.cpp   JNI（JSON 使用 UTF-8 byte[]）
  src/java/                Android SDK 调用，UI 线程执行
  src/adjust_ios.mm        iOS SDK 调用与 delegate，主队列执行
  manifests/               Gradle、CocoaPods、权限和 plist
example/                   独立 Lua 配置与可点击测试界面
tests/                     Lua 行为与原生静态检查脚本
```

平台依赖固定在 Gradle / Podfile。升级时同步原生初始化事件中的 sdk_version、文档和 CI 验证。
Android 5.8.0 AAR 的 `SystemLifecycleContentProvider` 自动注册生命周期；请勿额外转发 onResume/onPause。
扩展的 AndroidManifest.xml 必须保留 `package="com.defold.adjust"`，否则 Defold 清单合并会报 `Missing 'package' declaration`。这是扩展清单的包名；宿主应用包名仍由宿主 `game.project` 的 `[android] package` 配置。
iOS 生命周期由 SDK 内部通知监听处理。

## 本地测试

从根目录运行 `lua tests/test.lua`（Lua 5.1+）。测试原生接口以记录桩代替，
验证配置、输入校验、参数映射、业务状态和不支持平台行为，不替代 SDK 集成测试。

使用 `python tests/check_native.py --help` 查看本地 Android Java/C++ 检查的参数。
该检查使用真实 Android SDK、NDK、Adjust AAR 和 Defold SDK 头文件；只编译本地源码，不上传。
iOS 完整编译需要 Apple SDK／Defold 构建服务，本地 Windows 不能验证 Objective-C++ 链接结果。

## 完整构建

使用 Java 25 与 Defold Bob 1.13.1。Bob 的原生构建会将扩展源码及所需构建数据发送到所指定的构建服务。
可用官方服务，也可通过 `--build-server` 指向自建 Extender。构建无须填写真实 token。

```sh
java -jar bob.jar --platform=arm64-android --architectures=arm64-android --archive --output=build/android build
java -jar bob.jar --platform=arm64-ios --architectures=arm64-ios --archive --output=build/ios build
java -jar bob.jar --platform=wasm-web --archive --output=build/html5 build
```

仓库 `.github/workflows/build.yml` 提供 Lua CI 和手动触发的完整构建。
还需在宿主项目和启用混淆的 release 包中确认：

- Android 合并 manifest 保留 Adjust lifecycle provider、INTERNET、ACCESS_NETWORK_STATE 和 AD_ID。
- Gradle 已带入 installreferrer、广告标识依赖、Adjust 的签名依赖；APK 各 ABI 有对应库。
- Android 混淆后仍能加载 `com.defold.adjust.AdjustPlugin` 并解析 nativeOnEvent。
- iOS 包包含 Adjust CocoaPods 提供的隐私资源 bundle 及 AdjustSignature 依赖。
- 同时使用其它扩展时，ATT 文案只有一个确定来源；检查合并后的 Info.plist。

## 真机验收

1. 配置属于测试应用的 sandbox token，安装 Android / iOS 示例。
2. 点击初始化一次，观察 initialized 与真实 session_success；重复初始化应返回错误。
3. 自定义事件携带中文及 emoji，在 SDK 日志／后台核对参数。
4. 查询 adid 和归因；断网发送事件，再联网核实 SDK 重试。不要要求归因回调立即返回。
5. 从真实 MAX RevenuePaid 回调转发一笔收入；核对金额、币种、广告位，确认没有另一条重复上报链路。
6. 使用真实商店测试购买字段和独立 deduplication_id，验证重复调用、重新启动、去重容量边界。
7. 前后台切换、恢复和重新启动后验证 session 与每日活跃；不要把 SDK session 回调数量当作 dailyActivated 数量。
8. iOS 覆盖 ATT 未决定、允许、拒绝；也验证初始化前请求和等待超时。
9. 在回调内清除／替换回调，销毁注册脚本后让原生回调到达，检查没有崩溃或已销毁实例访问。
10. HTML5 和桌面点击全部示例按钮，应只有日志且不等待初始化成功事件。

示例收入与购买是明确的 sandbox 样例，不能作为真实收入测试结果。完整通过情况写入 `docs/validation.md`。

## 发布源码

发布前检查 `git status --short` 和待提交差异，确保示例 token 为空、测试数据为虚构值。
`.work/`、`.internal/`、`build/` 和 `dist/` 已被 `.gitignore` 排除；其中可能包含本机路径、
运行日志、下载的第三方源码和编译产物，不应随源码发布。

提交审核后的源码并创建版本标签，再从该标签生成发布包，例如：

```sh
git archive --format=zip --output=../extension-adjust-source.zip <tag>
```

在仓库外保存生成的发布包；不要直接压缩整个工作目录或包含 `.git/`。
保留本仓库的 `LICENSE`；Gradle / CocoaPods 下载的第三方依赖使用各自的许可证。
公开发布源码不代表已完成移动端集成验收，当前验证边界见 `docs/validation.md`。
