package config_io

import std.fs.{File, Path, exists, OpenMode}
import std.io.readToEnd

/// 读取配置文件全文；stream 为真时经 File 流式读入再拼串（仍整体解析，适合与 readFrom 实现路径区分）
public func readConfigFileText(path: Path, stream: Bool): String {
    if (!exists(path)) {
        throw Exception("配置文件不存在: ${path.toString()}")
    }
    if (!stream) {
        String.fromUtf8(File.readFrom(path))
    } else {
        var content: String = ""
        try (f = File(path, OpenMode.Read)) {
            content = String.fromUtf8(readToEnd(f))
        }
        content
    }
}
