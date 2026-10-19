# minimp3_cj API接口文档

本文档描述了minimp3_cj库的所有公开API接口。

## 已封装的高级API函数

### decodeMp3File
```
/*
* 解码MP3文件并输出为WAV文件
* 参数inputPath-输入MP3文件路径
* 参数outputPath-输出WAV文件路径
* 返回值-元组(PCM数据数组, 采样率, 声道数)
* 功能-完整的MP3到WAV转换，自动处理文件读取和WAV头生成
*/
func decodeMp3File(inputPath: String, outputPath: String): (Array<Int16>, Int64, Int64)
```

### decodeMp3Buffer
```
/*
* 解码MP3二进制数据返回PCM数据
* 参数mp3Data-MP3二进制数据数组
* 返回值-PCM音频数据数组
* 功能-纯解码功能，不涉及文件操作
*/
func decodeMp3Buffer(mp3Data: Array<UInt8>): Array<Int16>
```

## 底层解码API函数

### mp3dec_init
```
/*
* 初始化MP3解码器
* 参数decoder-解码器实例
* 功能-重置解码器状态，准备开始解码
*/
func mp3dec_init(decoder: mp3dec_t): Unit
```

### mp3dec_reset
```
/*
* 重置MP3解码器状态
* 参数decoder-解码器实例
* 功能-清除解码器内部缓冲区，重置到初始状态
*/
func mp3dec_reset(decoder: mp3dec_t): Unit
```

### mp3dec_decode_frame
```
/*
* 解码一帧MP3数据
* 参数decoder-解码器实例
* 参数mp3-MP3数据缓冲区
* 参数mp3_bytes-数据长度
* 参数pcm-PCM输出缓冲区
* 参数info-帧信息输出
* 返回值-解码的样本数
* 功能-核心解码函数，处理单帧MP3数据
*/
func mp3dec_decode_frame(decoder: mp3dec_t, mp3: Array<UInt8>, mp3_bytes: Int64, pcm: Array<Int16>, info: mp3dec_frame_info_t): Int64
```

## 公开常量

### MINIMP3_MAX_SAMPLES_PER_FRAME
```
/*
* 每帧最大样本数常量
* 值为2304，表示每帧最多可解码的样本数量
*/
let MINIMP3_MAX_SAMPLES_PER_FRAME: Int64 = 2304
```

## 公开类型

### mp3dec_t
```
/*
* MP3解码器实例类型
* 包含解码状态和内部缓冲区
* 用于存储解码过程中的状态信息
*/
class mp3dec_t
```

### mp3dec_frame_info_t
```
/*
* MP3帧信息结构类型
* 包含帧的详细信息：
* - frame_bytes: 帧字节数
* - channels: 声道数 (1=单声道, 2=立体声)
* - hz: 采样率
* - layer: MP3层 (1/2/3)
* - bitrate_kbps: 比特率
*/
class mp3dec_frame_info_t
```