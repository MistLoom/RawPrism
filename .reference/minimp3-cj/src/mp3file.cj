package minimp3_cj

import std.fs.*
import std.collection.*

// WAV文件写入工具
class WavWriter {
    // 创建标准WAV文件头
    static func createWavHeader(sampleRate: Int64, channels: Int64, bitsPerSample: Int64, dataSize: Int64): Array<UInt8> {
        let header = ArrayList<UInt8>()
        let fileSize = dataSize + 36 // 文件大小 = 数据大小 + 36字节头
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        
        // RIFF头
        header.add(UInt8(82))  // 'R'
        header.add(UInt8(73))  // 'I'
        header.add(UInt8(70))  // 'F'
        header.add(UInt8(70))  // 'F'
        
        // 文件大小 - 8
        header.add(UInt8(fileSize & 0xFF))
        header.add(UInt8((fileSize >> 8) & 0xFF))
        header.add(UInt8((fileSize >> 16) & 0xFF))
        header.add(UInt8((fileSize >> 24) & 0xFF))
        
        // WAVE标识
        header.add(UInt8(87))  // 'W'
        header.add(UInt8(65))  // 'A'
        header.add(UInt8(86))  // 'V'
        header.add(UInt8(69))  // 'E'
        
        // fmt子块
        header.add(UInt8(102)) // 'f'
        header.add(UInt8(109)) // 'm'
        header.add(UInt8(116)) // 't'
        header.add(UInt8(32))  // ' '
        
        // fmt子块大小 (16字节)
        header.add(UInt8(16))
        header.add(UInt8(0))
        header.add(UInt8(0))
        header.add(UInt8(0))
        
        // 音频格式 (PCM = 1)
        header.add(UInt8(1))
        header.add(UInt8(0))
        
        // 声道数
        header.add(UInt8(channels & 0xFF))
        header.add(UInt8((channels >> 8) & 0xFF))
        
        // 采样率
        header.add(UInt8(sampleRate & 0xFF))
        header.add(UInt8((sampleRate >> 8) & 0xFF))
        header.add(UInt8((sampleRate >> 16) & 0xFF))
        header.add(UInt8((sampleRate >> 24) & 0xFF))
        
        // 字节率
        header.add(UInt8(byteRate & 0xFF))
        header.add(UInt8((byteRate >> 8) & 0xFF))
        header.add(UInt8((byteRate >> 16) & 0xFF))
        header.add(UInt8((byteRate >> 24) & 0xFF))
        
        // 块对齐
        header.add(UInt8(blockAlign & 0xFF))
        header.add(UInt8((blockAlign >> 8) & 0xFF))
        
        // 位深度
        header.add(UInt8(bitsPerSample & 0xFF))
        header.add(UInt8((bitsPerSample >> 8) & 0xFF))
        
        // data子块
        header.add(UInt8(100)) // 'd'
        header.add(UInt8(97))  // 'a'
        header.add(UInt8(116)) // 't'
        header.add(UInt8(97))  // 'a'
        
        // 数据大小
        header.add(UInt8(dataSize & 0xFF))
        header.add(UInt8((dataSize >> 8) & 0xFF))
        header.add(UInt8((dataSize >> 16) & 0xFF))
        header.add(UInt8((dataSize >> 24) & 0xFF))
        
        var result = Array<UInt8>(header.size, repeat: UInt8(0))
        var j: Int64 = 0
        while (j < header.size) {
            result[j] = header[Int64(j)]
            j = j + 1
        }
        return result
    }
    
    // 将Int16数组转换为字节数组
    static func pcmToBytes(pcm: Array<Int16>): Array<UInt8> {
        let bytes = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i < pcm.size) {
            let sample = Int64(pcm[Int64(i)])
            bytes.add(UInt8(sample & 0xFF))
            bytes.add(UInt8((sample >> 8) & 0xFF))
            i = i + 1
        }
        var result = Array<UInt8>(bytes.size, repeat: UInt8(0))
        var j: Int64 = 0
        while (j < bytes.size) {
            result[j] = bytes[Int64(j)]
            j = j + 1
        }
        return result
    }
}

// 解码MP3文件并输出WAV文件
public func decodeMp3File(inputPath: String, outputPath: String): (Array<Int16>, Int64, Int64) {
    println("正在读取MP3文件: " + inputPath)
    let mp3Bytes = File.readFrom(inputPath)
    let mp3 = Array<UInt8>(Int64(mp3Bytes.size), {k: Int64 => UInt8(mp3Bytes[k])})
    
    println("MP3文件大小: " + "${mp3Bytes.size}" + " 字节")
    
    var dec = mp3dec_t()
    mp3dec_init(dec)
    
    var off: Int64 = 0
    var pcmData = ArrayList<Int16>()
    var sampleRate: Int64 = 0
    var channels: Int64 = 0
    
    while (off < mp3.size) {
        var info = mp3dec_frame_info_t()
        var pcmBuf = Array<Int16>(MINIMP3_MAX_SAMPLES_PER_FRAME, repeat: Int16(0))
        
        let n = mp3dec_decode_frame(dec, mp3.slice(off, mp3.size - off), mp3.size - off, pcmBuf, info)
        
        if (n > 0) {
            let total = n * info.channels
            var i: Int64 = 0
            while (i < total) {
                pcmData.add(pcmBuf[Int64(i)])
                i = i + 1
            }
            
            if (sampleRate == 0) {
                sampleRate = info.hz
                channels = info.channels
            }
        }
        
        if (info.frame_bytes == 0) {
            break
        }
        
        off = off + info.frame_bytes
    }
    
    let pcmArray = Array<Int16>(pcmData.size, repeat: Int16(0))
    var p: Int64 = 0
    while (p < pcmData.size) {
        pcmArray[Int64(p)] = pcmData[Int64(p)]
        p = p + 1
    }
    
    // 生成WAV文件
    if (pcmArray.size > 0) {
        let wavData = WavWriter.createWavHeader(sampleRate, channels, 16, pcmArray.size * 2)
        let pcmBytes = WavWriter.pcmToBytes(pcmArray)
        
        var fullWavData = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i < wavData.size) {
            fullWavData.add(wavData[Int64(i)])
            i = i + 1
        }
        
        i = 0
        while (i < pcmBytes.size) {
            fullWavData.add(pcmBytes[Int64(i)])
            i = i + 1
        }
        
        var finalWavData = Array<UInt8>(fullWavData.size, repeat: UInt8(0))
        var idx: Int64 = 0
        while (idx < fullWavData.size) {
            finalWavData[idx] = fullWavData[Int64(idx)]
            idx = idx + 1
        }
        
        File.writeTo(outputPath, finalWavData)
        println("WAV文件已生成: " + outputPath)
    }
    
    return (pcmArray, sampleRate, channels)
}

// 解码MP3二进制数据返回PCM二进制数据
public func decodeMp3Buffer(mp3Data: Array<UInt8>): Array<Int16> {
    var dec = mp3dec_t()
    mp3dec_init(dec)
    
    var off: Int64 = 0
    var pcmData = ArrayList<Int16>()
    
    while (off < mp3Data.size) {
        var info = mp3dec_frame_info_t()
        var pcmBuf = Array<Int16>(MINIMP3_MAX_SAMPLES_PER_FRAME, repeat: Int16(0))
        
        let n = mp3dec_decode_frame(dec, mp3Data.slice(off, mp3Data.size - off), mp3Data.size - off, pcmBuf, info)
        
        if (n > 0) {
            let total = n * info.channels
            var i: Int64 = 0
            while (i < total) {
                pcmData.add(pcmBuf[Int64(i)])
                i = i + 1
            }
        }
        
        if (info.frame_bytes == 0) {
            break
        }
        
        off = off + info.frame_bytes
    }
    
    let pcmArray = Array<Int16>(pcmData.size, repeat: Int16(0))
    var p: Int64 = 0
    while (p < pcmData.size) {
        pcmArray[Int64(p)] = pcmData[Int64(p)]
        p = p + 1
    }
    
    return pcmArray
}
