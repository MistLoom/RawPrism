# MP3解码器 - 仓颉语言实现

[![License: CC0-1.0](https://img.shields.io/badge/License-CC0%201.0-lightgrey.svg)](http://creativecommons.org/publicdomain/zero/1.0/)
[![Cangjie](https://img.shields.io/badge/Language-Cangjie-blue.svg)](https://gitcode.com/Cangjie)

一个完全由仓颉语言实现的高性能MP3解码器，参照著名的[minimp3](https://github.com/lieff/minimp3) C库重新实现。该项目提供了完整的MP3音频解码功能，支持将MP3文件转换为PCM音频数据。

并在其基础上增加输出为WAV音频文件支持(含文件IO)。

本项目开发时测试使用仓颉SDK1.0.0版本

---

⭐ 如果这个项目对你有帮助，请给它一个星标！


---
## 重新实现后的部分说明
尽可能减少了不必要的内存复制操作

由于仓颉语言对于数组索引类型要求Int64，而原C项目中大量使用32位的整型，为避免大量的显性类型转换，部分数据类型有一定适应性变更

对于部分数学运算和高内存IO的地方，尽可能使用了基本库的实现，考虑到仓颉未来可能进行的基本库或者编译器优化，删除了原本造的轮子
（这里没有太具体的对比与原版性能，有兴趣的朋友可以尝试一下，相关的建议也可以在issue中提出或者提交代码）




### 核心组件

- **minimp3.cj**: 核心解码引擎，包含完整的MP3解码算法和底层API
- **mp3file.cj**: 便捷API函数，为方便直接使用，提供文件操作和WAV输出功能
- **macros/header_macros.cj**: 宏定义和常量声明
- **tests/**: 单元测试套件


## 🚀 快速开始


### 安装与运行

1. **在您项目的 `cjpm.toml` 文件中添加以下内容**
```shell
[dependencies]
 minimp3_cj = {git = "https://gitcode.com/Cangjie-SIG/minimp3-cj.git", branch = "main"}
```

2. **先跑一边构建**
```bash
cjpm build
```

### 基本使用

#### 使用封装的方法（推荐）

```cangjie
import minimp3_cj.*

// 方法1: 直接解码MP3文件为WAV文件
let (pcmData, sampleRate, channels) = decodeMp3File("input.mp3", "output.wav")
println("解码完成！采样率: ${sampleRate} Hz, 声道数: ${channels}")

// 方法2: 解码MP3二进制数据
let mp3Data = File.readFrom("sample/demo.mp3")
let mp3Bytes = Array<UInt8>(Int64(mp3Data.size), {k: Int64 => UInt8(mp3Data[k])})
let pcmData = decodeMp3Buffer(mp3Bytes)
println("解码得到 ${pcmData.size} 个PCM样本")
```

#### 使用底层函数

```cangjie
import minimp3_cj.*

// 初始化解码器
var decoder = mp3dec_t()
mp3dec_init(decoder)

// 读取MP3文件
let mp3Data = File.readFrom("sample/demo.mp3")
let mp3Bytes = Array<UInt8>(Int64(mp3Data.size), {k: Int64 => UInt8(mp3Data[k])})

// 解码音频帧
var frameInfo = mp3dec_frame_info_t()
var pcmBuffer = Array<Int16>(MINIMP3_MAX_SAMPLES_PER_FRAME, repeat: Int16(0))
let samples = mp3dec_decode_frame(decoder, mp3Bytes, mp3Bytes.size, pcmBuffer, frameInfo)

// 获取音频信息
println("采样率: ${frameInfo.hz} Hz")
println("声道数: ${frameInfo.channels}")
println("比特率: ${frameInfo.bitrate_kbps} kbps")
```

## 📖函数说明

### 公开可用函数

本库提供以下公开函数供外部调用：

#### 已封装的操作函数

##### `decodeMp3File(inputPath: String, outputPath: String): (Array<Int16>, Int64, Int64)`
解码MP3文件并输出为WAV文件。
- **参数**:
  - `inputPath`: 输入MP3文件路径
  - `outputPath`: 输出WAV文件路径
- **返回值**: `(PCM数据, 采样率, 声道数)`
- **功能**: 完整的MP3到WAV转换，自动处理文件读取和WAV头生成

##### `decodeMp3Buffer(mp3Data: Array<UInt8>): Array<Int16>`
解码MP3二进制数据返回PCM数据。
- **参数**:
  - `mp3Data`: MP3二进制数据数组
- **返回值**: PCM音频数据数组
- **功能**: 纯解码功能，不涉及文件操作

#### 内部解码的主要函数

##### `mp3dec_init(decoder: mp3dec_t): Unit`
初始化MP3解码器。
- **参数**: `decoder` - 解码器实例
- **功能**: 重置解码器状态，准备开始解码

##### `mp3dec_reset(decoder: mp3dec_t): Unit`
重置MP3解码器状态。
- **参数**: `decoder` - 解码器实例
- **功能**: 清除解码器内部缓冲区，重置到初始状态

##### `mp3dec_decode_frame(decoder: mp3dec_t, mp3: Array<UInt8>, mp3_bytes: Int64, pcm: Array<Int16>, info: mp3dec_frame_info_t): Int64`
解码一帧MP3数据。
- **参数**:
  - `decoder`: 解码器实例
  - `mp3`: MP3数据缓冲区
  - `mp3_bytes`: 数据长度
  - `pcm`: PCM输出缓冲区
  - `info`: 帧信息输出
- **返回值**: 解码的样本数
- **功能**: 核心解码函数，处理单帧MP3数据

### 公开常量和类型

#### 常量
- `MINIMP3_MAX_SAMPLES_PER_FRAME: Int64 = 2304` - 每帧最大样本数

#### 类型
- `mp3dec_t` - 解码器实例类型
- `mp3dec_frame_info_t` - 帧信息结构类型

### 核心结构

#### `mp3dec_t`
解码器实例，包含解码状态和缓冲区。

#### `mp3dec_frame_info_t`
帧信息结构，包含：
- `frame_bytes`: 帧字节数
- `channels`: 声道数 (1=单声道, 2=立体声)
- `hz`: 采样率
- `layer`: MP3层 (1/2/3)
- `bitrate_kbps`: 比特率

## 🧪 测试

```bash
# 运行所有测试
cjpm test

# 运行特定测试
# 二进制解码测试
cjpm test --filter=MP3PCMTests.testDecodeMp3Buffer

# 文件解码为wav输出测试
cjpm test --filter=MP3PCMTests.testDecodeMp3File
```


## 📁 项目结构

```
mp3Decode4cj/
├── src/
│   ├── minimp3.cj              # 核心解码引擎
│   ├── mp3file.cj              # 高级API函数（文件操作）
│   ├── macros/
│   │   └── header_macros.cj    # 宏定义
│   └── tests/
│       └── mp3file_test.cj     # 单元测试
├── cjpm.toml                   # 项目配置
└── README.md                   # 项目说明
```


## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📞 联系方式

如有问题或建议，请通过以下方式联系：

- 提交 [Issue](../../issues)
- 发送邮件至项目维护者：admin@aiepoch.cn

