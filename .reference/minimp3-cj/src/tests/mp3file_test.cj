package minimp3_cj.tests

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import minimp3_cj.*

// 测试MP3文件处理功能
@Test
class MP3FileTests {
    
    @TestCase
    func testDecodeMp3Buffer(): Unit {
        println("=== 测试decodeMp3Buffer方法 ===")
        
        // 读取MP3文件数据
        let mp3Bytes = File.readFrom("sample/demo.mp3")
        let mp3Data = Array<UInt8>(Int64(mp3Bytes.size), {k: Int64 => UInt8(mp3Bytes[k])})
        
        println("MP3文件大小: ${mp3Bytes.size} 字节")
        
        // 使用decodeMp3Buffer解码
        let pcmData = decodeMp3Buffer(mp3Data)
        
        // 验证结果
        if (pcmData.size == 0) {
            fail("PCM数据不应为空")
        }
        println("PCM采样数: ${pcmData.size}")
        
       
    }
    
    @TestCase
    func testDecodeMp3File(): Unit {
        println("=== 测试decodeMp3File方法 ===")
        
        // 检查输入文件是否存在
        let inputFile = "sample/demo.mp3"  // 直接使用存在的文件
        let outputFile = "sample/output.wav"
        
        println("使用输入文件: ${inputFile}" )
        
        // 使用decodeMp3File解码并生成WAV文件
        let (pcmData, sampleRate, channels) = decodeMp3File(inputFile, outputFile)
        
        // 验证解码结果
        if (pcmData.size == 0) {
            fail("PCM数据不应为空")
        }
        if (sampleRate <= 0) {
            fail("采样率应大于0")
        }
        if (channels != 1 && channels != 2) {
            fail("声道数应为1或2")
        }
        
        // 验证输出文件是否生成
        let outputBytes = File.readFrom(outputFile)
        // 此处减去wav文件头大小
        if (outputBytes.size <= 44) {
            fail("输出WAV文件不应为空")
        }
        
        println("解码结果:")
        println("- 采样率: " + "${sampleRate}" + " Hz")
        println("- 声道数: " + "${channels}")
        println("- PCM采样数: " + "${pcmData.size}")
        println("- 时长: " + "${Float64(pcmData.size) / Float64(sampleRate * channels)}" + " 秒")
        println("- 输出文件大小: " + "${outputBytes.size}" + " 字节")
        
    }
}
