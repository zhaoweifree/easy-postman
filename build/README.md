# Build Scripts

`build/` 目录只负责发行打包，不放插件开发和验证脚本。

当前脚本：

- `mac.sh`: macOS DMG
- `win-exe.bat`: Windows EXE / portable
- `linux-deb.sh`: Debian / Ubuntu DEB（产物架构跟随当前打包机器，例如 `amd64` / `arm64`）
- `linux-rpm.sh`: RPM（产物架构跟随当前打包机器）
- `repack-deb-to-xz.sh`: 把已有 DEB 的 `control.tar` / `data.tar` 统一重压为 `xz`（或 `gzip`）
- `deb-repack.py`: 同一功能的跨平台版本（Windows / macOS 上修复已生成的 DEB）

## DEB 压缩格式（老系统兼容）

`jpackage --type deb` 会调用系统 `dpkg-deb`，而 dpkg >= 1.21.18（Ubuntu 24.04+）默认用 **zstd**
压缩 `control.tar` / `data.tar`。Debian 11、Ubuntu 20.04、openEuler、麒麟等较老系统的 dpkg
不认识 zstd，安装时会直接失败：

```text
dpkg-deb: 错误: 归档 xxx.deb 对成员 control.tar.zst 使用了未知的压缩，放弃操作
dpkg: 处理归档 xxx.deb (--install)时出错: 子进程返回错误状态 2
```

因此打包流程统一在 jpackage 之后重压为 **xz**（dpkg >= 1.17，2013 年起即支持），并在脚本末尾
用 `ar t` 自检，一旦发现 `.zst` 成员直接失败，避免把不兼容的包发出去。

```bash
# 本地打包（默认 xz）
bash build/linux-deb.sh

# 需要兼容极老 dpkg 时用 gzip
DEB_COMPRESSION=gzip bash build/linux-deb.sh

# 只修复一个已经打好的 DEB（Linux）
bash build/repack-deb-to-xz.sh EasyPostman-6.3.6-linux-arm64.deb xz

# 只修复一个已经打好的 DEB（Windows / macOS，需要 pip install zstandard）
python build/deb-repack.py EasyPostman-6.3.6-linux-arm64.deb
```

重压只替换压缩器，tar 负载按原始字节往返，文件权限、时间戳、maintainer 脚本都不变，可用
`sha256` 对比解压后的 `data.tar` 校验一致性。

统一约定：

- Maven 先产出带版本号的 jar：
  `easy-postman-app/target/easy-postman-${version}.jar`
- 打包脚本再复制成固定名：
  `easy-postman.jar`
- `jpackage` 和安装包内部始终引用固定文件名
- `jpackage` 通过 `easy-postman-mcp-launcher.properties` 额外生成 `EasyPostmanMCP`；它与桌面启动器共享主 JAR 和内置 JRE，Windows 版本使用 console launcher

Windows `app-image` 和便携版 ZIP 的核心结构是：

```text
EasyPostman/
├── EasyPostman.exe
├── EasyPostmanMCP.exe
├── app/
├── runtime/
└── .portable        # 仅便携版存在
```

便携版是完整 `app-image` 加 `.portable` 标记，不需要另装 Java。`EasyPostmanMCP.exe` 依赖同目录中的 `app/` 和 `runtime/`，不能单独发布或拷贝。

打包后可先执行 `EasyPostmanMCP.exe --help` 验证 MCP 启动器和内置 JRE，再打开 `EasyPostman.exe` 验证桌面端。

这样做的好处：

- 打包脚本不需要跟着版本号改
- 安装包内部 classpath 固定
- 自动更新和替换主 jar 更简单

如果你要做的是：

- 发行包构建：看 `build/`
- 插件本地开发/安装验证：看 `scripts/plugin-dev.sh`
- 插件架构与使用说明：看 `docs/PLUGINS_zh.md`
