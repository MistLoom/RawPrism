package minimp3_cj

import std.core.*
import std.collection.*
import minimp3_cj.macros.*

public let MINIMP3_MAX_SAMPLES_PER_FRAME: Int64 = 1152 * 2

public class mp3dec_frame_info_t {
    var frame_bytes: Int64 = 0
    var channels: Int64 = 0
    var hz: Int64 = 0
    var layer: Int64 = 0
    var bitrate_kbps: Int64 = 0
    init() {}
}

public class mp3dec_t {
    var mdct_overlap: Array<Array<Float64>>
    var qmf_state: Array<Float64>
    var reserv: Int64
    var free_format_bytes: Int64
    var header: Array<UInt8>
    var reserv_buf: Array<UInt8>

    init() {
        mdct_overlap = Array<Array<Float64>>(2, {_: Int64 => Array<Float64>(9 * 32, repeat: 0.0)})
        qmf_state = Array<Float64>(15 * 2 * 32, repeat: 0.0)
        reserv = 0
        free_format_bytes = 0
        header = Array<UInt8>(4, repeat: 0)
        reserv_buf = Array<UInt8>(511, repeat: 0)
    }
}

let MAX_FREE_FORMAT_FRAME_SIZE: Int64 = 2304
let MAX_FRAME_SYNC_MATCHES: Int64 = 10
let MAX_L3_FRAME_PAYLOAD_BYTES: Int64 = MAX_FREE_FORMAT_FRAME_SIZE
let MAX_BITRESERVOIR_BYTES: Int64 = 511
let SHORT_BLOCK_TYPE: Int64 = 2
let STOP_BLOCK_TYPE: Int64 = 3
let MODE_MONO: Int64 = 3
let MODE_JOINT_STEREO: Int64 = 1
let HDR_SIZE: Int64 = 4

class bs_t {
    var buf: Array<UInt8>
    var pos: Int64
    var limit: Int64
    init() {
        buf = Array<UInt8>(0, repeat: 0)
        pos = 0
        limit = 0
    }
}

func bs_init(bs: bs_t, data: Array<UInt8>, bytes: Int64): Unit {
    bs.buf = data
    bs.pos = 0
    bs.limit = bytes * 8
}

func get_bits(bs: bs_t, n_in: Int64): Int64 {
    var n = n_in
    var next: Int64 = 0
    var cache: Int64 = 0
    let s = bs.pos & 7
    var shl = n + s

    var p = bs.pos >> 3
    bs.pos = bs.pos + n
    if (bs.pos > bs.limit) {
        return 0
    }

    p = p + 1
    next = Int64(bs.buf[p - 1]) & (255 >> s)
    while (shl > 8) {
        shl = shl - 8
        cache = cache | (next << shl)
        next = Int64(bs.buf[p])
        p = p + 1
    }

    let result = cache | (next >> (8 - shl))
    return result
}

func hdr_valid(h: Array<UInt8>): Bool {
    if (!(h[0] == 0xFF)) {
        return false
    }

    let h1 = h[1]
    let cond1 = ((h1 & 0xf0) == 0xf0) || ((h1 & 0xfe) == 0xe2)
    if (!cond1) {
        return false
    }
    if (@HDR_GET_LAYER(h) == 0) {
        return false
    }
    if (@HDR_GET_BITRATE(h) == 15) {
        return false
    }
    if (@HDR_GET_SAMPLE_RATE(h) == 3) {
        return false
    }
    return true
}

func hdr_compare(h1: Array<UInt8>, h2: Array<UInt8>): Bool {
    if (!hdr_valid(h2)) {
        return false
    }
    if (((h1[1] ^ h2[1]) & 0xFE) != 0) {
        return false
    }
    if (((h1[2] ^ h2[2]) & 0x0C) != 0) {
        return false
    }
    if ((@HDR_IS_FREE_FORMAT(h1) && !@HDR_IS_FREE_FORMAT(h2)) || (!@HDR_IS_FREE_FORMAT(h1) && @HDR_IS_FREE_FORMAT(h2))) {
        return false
    }
    return true
}

func hdr_bitrate_kbps(h: Array<UInt8>): Int64 {
    let halfrate: Array<Array<Array<Int64>>> = [
        [[0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80], [0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72,
            80], [0, 16, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 112, 128]],
        [[0, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160],
            [0, 16, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192],
            [0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224]]
    ]
    var mpeg1: Int64 = 0
    if (@HDR_TEST_MPEG1(h)) {
        mpeg1 = 1
    } else {
        mpeg1 = 0
    }
    let layer_index = @HDR_GET_LAYER(h) - 1
    let br_index = @HDR_GET_BITRATE(h)
    return 2 * halfrate[mpeg1][layer_index][br_index]
}

func hdr_sample_rate_hz(h: Array<UInt8>): Int64 {
    let g_hz: Array<Int64> = [44100, 48000, 32000]

    let sample_rate_idx: Int64 = @HDR_GET_SAMPLE_RATE(h)
    var v = g_hz[sample_rate_idx]

    if (!@HDR_TEST_MPEG1(h)) {
        v = v >> 1
    }
    if (!@HDR_TEST_NOT_MPEG25(h)) {
        v = v >> 1
    }
    return v
}

func hdr_frame_samples(h: Array<UInt8>): Int64 {
    if (@HDR_IS_LAYER_1(h)) {
        return 384
    }
    var sh: Int64 = 0
    if (@HDR_IS_FRAME_576(h)) {
        sh = 1
    } else {
        sh = 0
    }
    return 1152 >> sh
}

func hdr_frame_bytes(h: Array<UInt8>, free_format_size: Int64): Int64 {
    var frame_bytes = hdr_frame_samples(h) * hdr_bitrate_kbps(h) * 125 / hdr_sample_rate_hz(h)
    if (@HDR_IS_LAYER_1(h)) {
        frame_bytes = frame_bytes & !3
    }
    if (frame_bytes != 0) {
        return frame_bytes
    }
    return free_format_size
}

func hdr_padding(h: Array<UInt8>): Int64 {
    if (@HDR_TEST_PADDING(h)) {
        if (@HDR_IS_LAYER_1(h)) {
            return 4
        } else {
            return 1
        }
    }
    return 0
}

public func mp3dec_init(dec: mp3dec_t): Unit {
    dec.header[0] = 0
}

public func mp3dec_reset(dec: mp3dec_t): Unit {
    dec.reserv = 0
    dec.free_format_bytes = 0

    dec.header.fill(0)
    dec.reserv_buf.fill(0)

    for (ch in Range<Int64>(0, 2, 1, true, true, false)) {
        dec.mdct_overlap[ch].fill(0.0)
    }

    dec.qmf_state.fill(0.0)
}

type mp3d_sample_t = Int16

func mp3d_scale_pcm(sample: Float64): Int16 {
    if (sample >= 32766.5) {
        return Int16(32767)
    }
    if (sample <= -32767.5) {
        return Int16(-32768)
    }

    var s: Int64 = Int64(sample + 0.5)
    if (s < 0) {
        s = s - 1
    }
    return Int16(s)
}

// ===== MP3帧解码主函数 =====
public func mp3dec_decode_frame(dec: mp3dec_t, mp3: Array<UInt8>, mp3_bytes: Int64, pcm: Array<Int16>,
    info: mp3dec_frame_info_t): Int64 {
    var hdr: Array<UInt8> = []

    var i: Int64 = 0
    var frame_size: Int64 = 0
    if (mp3_bytes > 4 && dec.header[0] == 0xFF && hdr_compare(dec.header, mp3.slice(0, 4))) {
        frame_size = hdr_frame_bytes(mp3.slice(0, 4), dec.free_format_bytes) + hdr_padding(mp3.slice(0, 4))
        if (!(frame_size == mp3_bytes || (frame_size + HDR_SIZE <= mp3_bytes && hdr_compare(mp3.slice(0, 4),
            mp3.slice(frame_size, mp3_bytes - frame_size))))) {
            frame_size = 0
        }
    }
    if (frame_size == 0) {
        mp3dec_reset(dec)
        var res = mp3d_find_frame2(mp3, mp3_bytes, dec.free_format_bytes)
        i = res.offset
        frame_size = res.frame_bytes
        dec.free_format_bytes = res.free_format_bytes
        if (frame_size == 0 || i + frame_size > mp3_bytes) {
            info.frame_bytes = i
            return 0
        }
    }
    hdr = mp3.slice(i, 4)
    dec.header = hdr.clone()
    info.frame_bytes = i + frame_size
    if (@HDR_IS_MONO(hdr)) {
        info.channels = 1
    } else {
        info.channels = 2
    }
    info.hz = hdr_sample_rate_hz(hdr)
    info.layer = 4 - @HDR_GET_LAYER(hdr)
    info.bitrate_kbps = hdr_bitrate_kbps(hdr)
    if (pcm.size == 0) {
        return hdr_frame_samples(hdr)
    }
    var bs_frame = bs_t()

    bs_frame.buf = mp3.slice(i + HDR_SIZE, frame_size - HDR_SIZE)
    bs_frame.pos = 0
    bs_frame.limit = (frame_size - HDR_SIZE) * 8
    if (@HDR_IS_CRC(hdr)) {
        _ = get_bits(bs_frame, 16)
    }
    if (info.layer == 3) {
        var scratch = mp3dec_scratch_t()
        let main_data_begin = L3_read_side_info(bs_frame, scratch.gr_info, hdr)
        if (main_data_begin < 0 || bs_frame.pos > bs_frame.limit) {
            mp3dec_init(dec);
            return 0
        }
        let ok = L3_restore_reservoir(dec, bs_frame, scratch, main_data_begin)
        if (ok != 0) {
            var ngr: Int64 = 1
            if (@HDR_TEST_MPEG1(hdr)) {
                ngr = 2
            } else {
                ngr = 1
            }
            var igr: Int64 = 0
            while (igr < ngr) {
                var pcm_off = 576 * info.channels * igr

                scratch.grbuf.fill(0.0)
                L3_decode(dec, scratch,
                    scratch.gr_info.slice(igr * info.channels, scratch.gr_info.size - (igr * info.channels)),
                    info.channels)
                dec.qmf_state = mp3d_synth_granule(dec.qmf_state, scratch.grbuf, 18, info.channels,
                    pcm.slice(pcm_off, pcm.size - pcm_off), scratch.syn)
                igr = igr + 1
            }
        }
        L3_save_reservoir(dec, scratch)
        return ok * hdr_frame_samples(dec.header)
    } else {
        var scratch = mp3dec_scratch_t()
        var sci = L12_scale_info()
        L12_read_scale_info(hdr, bs_frame, sci)
        var iacc: Int64 = 0
        var igr: Int64 = 0
        var pcm_local = pcm
        while (igr < 3) {
            if (12 == (iacc + L12_dequantize_granule(scratch.grbuf.slice(iacc, scratch.grbuf.size - iacc), bs_frame, sci,
                info.layer | 1))) {
                iacc = 0
                L12_apply_scf_384(sci, sci.scf.slice(igr, sci.scf.size - igr), scratch.grbuf)
                dec.qmf_state = mp3d_synth_granule(dec.qmf_state, scratch.grbuf, 12, info.channels, pcm_local,
                    scratch.syn)

                scratch.grbuf.fill(0.0)
                pcm_local = pcm_local.slice(384 * info.channels, pcm_local.size - 384 * info.channels)
            }
            if (bs_frame.pos > bs_frame.limit) {
                mp3dec_init(dec);
                return 0
            }
            igr = igr + 1
        }
        return hdr_frame_samples(dec.header)
    }
}

class L12_scale_info {
    var scf: Array<Float64>
    var total_bands: Int64
    var stereo_bands: Int64
    var bitalloc: Array<Int64>
    var scfcod: Array<Int64>
    init() {
        scf = Array<Float64>(3 * 64, repeat: 0.0)
        total_bands = 0
        stereo_bands = 0
        bitalloc = Array<Int64>(64, repeat: 0)
        scfcod = Array<Int64>(64, repeat: 6)
    }
}

struct L12_subband_alloc_t {
    var tab_offset: Int64 = 0
    var code_tab_width: Int64 = 0
    var band_count: Int64 = 0
    init() {}
    init(tab_offset: Int64, code_tab_width: Int64, band_count: Int64) {
        this.tab_offset = tab_offset
        this.code_tab_width = code_tab_width
        this.band_count = band_count
    }
}

func build_g_deq_L12(): Array<Float64> {
    let c0: Float64 = 9.53674316e-07
    let c1: Float64 = 7.56931807e-07
    let c2: Float64 = 6.00777173e-07

    var dq = ArrayList<Float64>()
    func dq_append(dst: ArrayList<Float64>, x: Float64): Unit {
        dst.add(c0 / x)
        dst.add(c1 / x)
        dst.add(c2 / x)
    }

    let xs: Array<Int64> = [3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535, 3, 5, 9]
    for (v in xs) {
        dq_append(dq, Float64(v))
    }

    return dq.toArray()
}

func L12_subband_alloc_table(hdr: Array<UInt8>, sci: L12_scale_info): Array<L12_subband_alloc_t> {
    let mode = @HDR_GET_STEREO_MODE(hdr)
    var alloc: Array<L12_subband_alloc_t> = []
    var nbands: Int64 = 0
    var stereo_bands: Int64 = 0
    if (mode == MODE_MONO) {
        stereo_bands = 0
    } else {
        if (mode == MODE_JOINT_STEREO) {
            stereo_bands = (@HDR_GET_STEREO_MODE_EXT(hdr) << 2) + 4
        } else {
            stereo_bands = 32
        }
    }
    if (@HDR_IS_LAYER_1(hdr)) {
        alloc = Array<L12_subband_alloc_t>(1, {_: Int64 => L12_subband_alloc_t(76, 4, 32)})
        nbands = 32
    } else if (!@HDR_TEST_MPEG1(hdr)) {
        alloc = Array<L12_subband_alloc_t>(3, {
            i: Int64 => if (i == 0) {
                L12_subband_alloc_t(60, 4, 4)
            } else if (i == 1) {
                L12_subband_alloc_t(44, 3, 7)
            } else {
                L12_subband_alloc_t(44, 2, 19)
            }
        })
        nbands = 30
    } else {
        var sample_rate_idx = @HDR_GET_SAMPLE_RATE(hdr)
        var kbps = hdr_bitrate_kbps(hdr)
        if (mode != MODE_MONO) {
            kbps = kbps >> 1
        }
        if (kbps == 0) {
            kbps = 192
        }
        alloc = Array<L12_subband_alloc_t>(4, {
            i: Int64 => if (i == 0) {
                L12_subband_alloc_t(0, 4, 3)
            } else if (i == 1) {
                L12_subband_alloc_t(16, 4, 8)
            } else if (i == 2) {
                L12_subband_alloc_t(32, 3, 12)
            } else {
                L12_subband_alloc_t(40, 2, 7)
            }
        })
        nbands = 27
        if (kbps < 56) {
            alloc = Array<L12_subband_alloc_t>(2, {
                i: Int64 => if (i == 0) {
                    L12_subband_alloc_t(44, 4, 2)
                } else {
                    L12_subband_alloc_t(44, 3, 10)
                }
            })
            if (sample_rate_idx == 2) {
                nbands = 12
            } else {
                nbands = 8
            }
        } else if (kbps >= 96 && sample_rate_idx != 1) {
            nbands = 30
        }
    }
    sci.total_bands = nbands
    sci.stereo_bands = min(stereo_bands, nbands)
    return alloc
}

func L12_read_scalefactors(bs: bs_t, pba: Array<Int64>, scfcod: Array<Int64>, bands: Int64, scf: Array<Float64>): Unit {
    let g_deq = build_g_deq_L12()

    var i: Int64 = 0
    var m: Int64 = 0
    var scf_idx: Int64 = 0
    while (i < bands) {
        var s: Float64 = 0.0
        let ba = pba[i]
        var mask: Int64 = 0
        if (ba != 0) {
            mask = 4 + ((19 >> scfcod[i]) & 3)
        } else {
            mask = 0
        }
        m = 4
        while (m > 0) {
            if ((mask & m) != 0) {
                let b = get_bits(bs, 6)
                let idx = ba * 3 - 6 + (b % 3)
                let sh = (1 << 21) >> (b / 3)
                s = g_deq[idx] * Float64(sh)
            }
            scf[scf_idx] = s
            scf_idx = scf_idx + 1
            m = m >> 1
        }
        i = i + 1
    }
}

func L12_read_scale_info(hdr: Array<UInt8>, bs: bs_t, sci: L12_scale_info): Unit {
    let g_bitalloc_code_tab: Array<Int64> = [
        0,
        17,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        0,
        17,
        18,
        3,
        19,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        16,
        0,
        17,
        18,
        3,
        19,
        4,
        5,
        16,
        0,
        17,
        18,
        16,
        0,
        17,
        18,
        19,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        0,
        17,
        18,
        3,
        19,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        0,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16
    ]
    let subband_alloc = L12_subband_alloc_table(hdr, sci)

    var i: Int64 = 0
    var k: Int64 = 0
    var ba_bits: Int64 = 0
    var ba_code_tab_offset: Int64 = 0
    var sub_idx: Int64 = 0
    while (i < sci.total_bands) {
        if (i == k) {
            k = k + subband_alloc[sub_idx].band_count
            ba_bits = subband_alloc[sub_idx].code_tab_width
            ba_code_tab_offset = subband_alloc[sub_idx].tab_offset
            sub_idx = sub_idx + 1
        }
        let code = get_bits(bs, ba_bits)
        sci.bitalloc[2 * i] = g_bitalloc_code_tab[ba_code_tab_offset + code]
        if (i < sci.stereo_bands) {
            let code2 = get_bits(bs, ba_bits)
            sci.bitalloc[2 * i + 1] = g_bitalloc_code_tab[ba_code_tab_offset + code2]
        } else {
            if (sci.stereo_bands != 0) {
                sci.bitalloc[2 * i + 1] = sci.bitalloc[2 * i]
            } else {
                sci.bitalloc[2 * i + 1] = 0
            }
        }
        i = i + 1
    }

    i = 0
    while (i < 2 * sci.total_bands) {
        let ba = sci.bitalloc[i]
        if (ba != 0) {
            if (@HDR_IS_LAYER_1(hdr)) {
                sci.scfcod[i] = 2
            } else {
                sci.scfcod[i] = get_bits(bs, 2)
            }
        } else {
            sci.scfcod[i] = 6
        }
        i = i + 1
    }

    L12_read_scalefactors(bs, sci.bitalloc, sci.scfcod, sci.total_bands * 2, sci.scf)

    i = sci.stereo_bands
    while (i < sci.total_bands) {
        sci.bitalloc[2 * i + 1] = 0
        i = i + 1
    }
}

// ===== Layer I/II 反量化 =====
func L12_dequantize_granule(grbuf: Array<Float64>, bs: bs_t, sci: L12_scale_info, group_size: Int64): Int64 {
    var j: Int64 = 0
    var choff: Int64 = 576
    while (j < 4) {
        var dst_base = group_size * j
        var i: Int64 = 0
        while (i < 2 * sci.total_bands) {
            let ba = sci.bitalloc[i]
            if (ba != 0) {
                if (ba < 17) {
                    let half = (1 << (ba - 1)) - 1
                    var k: Int64 = 0
                    while (k < group_size) {
                        let bits = get_bits(bs, ba)
                        grbuf[dst_base + k] = Float64(bits - half)
                        k = k + 1
                    }
                } else {
                    let modv = (2 << (ba - 17)) + 1
                    var k: Int64 = 0
                    var c = get_bits(bs, modv + 2 - (modv >> 3))
                    while (k < group_size) {
                        let m = c % modv
                        grbuf[dst_base + k] = Float64(m - modv / 2)
                        c = c / modv
                        k = k + 1
                    }
                }
            }
            dst_base = dst_base + choff
            choff = 18 - choff
            i = i + 1
        }
        j = j + 1
    }
    return group_size * 4
}

func L12_apply_scf_384(sci: L12_scale_info, scf: Array<Float64>, dst: Array<Float64>): Unit {
    let copy_len = (sci.total_bands - sci.stereo_bands) * 18

    var t: Int64 = 0
    while (t < copy_len) {
        dst[576 + sci.stereo_bands * 18 + t] = dst[sci.stereo_bands * 18 + t]
        t = t + 1
    }
    var i: Int64 = 0
    var scf_idx: Int64 = 0
    while (i < sci.total_bands) {
        var k: Int64 = 0
        var base = i * 18
        let s0 = scf[scf_idx + 0]
        let s3 = scf[scf_idx + 3]
        while (k < 12) {
            dst[base + k + 0] = dst[base + k + 0] * s0
            dst[base + k + 576] = dst[base + k + 576] * s3
            k = k + 1
        }
        i = i + 1
        scf_idx = scf_idx + 6
    }
}

let BITS_DEQUANTIZER_OUT: Int64 = -1
let MAX_SCF: Int64 = (255 + BITS_DEQUANTIZER_OUT * 4 - 210)
let MAX_SCFI: Int64 = (((MAX_SCF + 3) >> 2) << 2)

class L3_gr_info_t {
    var sfbtab: Array<Int64>
    var part_23_length: Int64
    var big_values: Int64
    var scalefac_compress: Int64
    var global_gain: Int64
    var block_type: Int64
    var mixed_block_flag: Int64
    var n_long_sfb: Int64
    var n_short_sfb: Int64
    var table_select: Array<Int64>
    var region_count: Array<Int64>
    var subblock_gain: Array<Int64>
    var preflag: Int64
    var scalefac_scale: Int64
    var count1_table: Int64
    var scfsi: Int64
    init() {
        sfbtab = []
        part_23_length = 0
        big_values = 0
        scalefac_compress = 0
        global_gain = 0
        block_type = 0
        mixed_block_flag = 0
        n_long_sfb = 0
        n_short_sfb = 0
        table_select = [0, 0, 0]
        region_count = [0, 0, 255]
        subblock_gain = [0, 0, 0]
        preflag = 0
        scalefac_scale = 0
        count1_table = 0
        scfsi = 0
    }
}

class mp3dec_scratch_t {
    var bs: bs_t
    var maindata: Array<UInt8>
    var gr_info: Array<L3_gr_info_t>
    var grbuf: Array<Float64>
    var scf: Array<Float64>
    var syn: Array<Float64>
    var ist_pos: Array<Array<UInt8>>
    init() {
        bs = bs_t()
        bs.buf = Array<UInt8>(0, repeat: 0)
        bs.pos = 0
        bs.limit = 0

        maindata = Array<UInt8>(MAX_BITRESERVOIR_BYTES + MAX_L3_FRAME_PAYLOAD_BYTES, repeat: 0)
        gr_info = Array<L3_gr_info_t>(4, {_: Int64 => L3_gr_info_t()})
        grbuf = Array<Float64>(576 * 2, repeat: 0.0)
        scf = Array<Float64>(40, repeat: 0.0)
        syn = Array<Float64>((18 + 15) * 64, repeat: 0.0)

        ist_pos = Array<Array<UInt8>>(2, {
            _: Int64 => Array<UInt8>(39, repeat: UInt8(0))
        })
    }
}

func L3_read_side_info(bs: bs_t, gr: Array<L3_gr_info_t>, hdr: Array<UInt8>): Int64 {
    let g_scf_long: Array<Array<Int64>> = [
        [6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0],
        [12, 12, 12, 12, 12, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 76, 90, 2, 2, 2, 2, 2, 0],
        [6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0],
        [6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 18, 22, 26, 32, 38, 46, 54, 62, 70, 76, 36, 0],
        [6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16, 20, 24, 28, 34, 42, 50, 54, 76, 158, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16, 18, 22, 28, 34, 40, 46, 54, 54, 192, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20, 24, 30, 38, 46, 56, 68, 84, 102, 26, 0]
    ]
    let g_scf_short: Array<Array<Int64>> = [
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30,
            30, 40, 40, 40, 18, 18, 18, 0],
        [8, 8, 8, 8, 8, 8, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2, 2,
            2, 2, 2, 2, 2, 26, 26, 26, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32,
            32, 42, 42, 42, 18, 18, 18, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32,
            32, 44, 44, 44, 12, 12, 12, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30,
            30, 40, 40, 40, 18, 18, 18, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22,
            22, 30, 30, 30, 56, 56, 56, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20,
            20, 26, 26, 26, 66, 66, 66, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34,
            34, 42, 42, 42, 12, 12, 12, 0]
    ]
    let g_scf_mixed: Array<Array<Int64>> = [
        [6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40,
            40, 40, 18, 18, 18, 0],
        [12, 12, 12, 4, 4, 4, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2,
            2, 2, 2, 2, 2, 2, 26, 26, 26, 0],
        [6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32, 32, 42, 42,
            42, 18, 18, 18, 0],
        [6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32, 32, 44,
            44, 44, 12, 12, 12, 0],
        [6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40,
            40, 40, 18, 18, 18, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22, 22,
            30, 30, 30, 56, 56, 56, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20, 20,
            26, 26, 26, 66, 66, 66, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34, 34,
            42, 42, 42, 12, 12, 12, 0]
    ]
    var tables: Int64 = 0
    var scfsi: Int64 = 0
    var main_data_begin: Int64 = 0
    var part_23_sum: Int64 = 0
    var sr_idx = @HDR_GET_MY_SAMPLE_RATE(hdr)
    if (sr_idx != 0) {
        sr_idx = sr_idx - 1
    }
    var gr_count: Int64 = 2
    if (@HDR_IS_MONO(hdr)) {
        gr_count = 1
    } else {
        gr_count = 2
    }
    if (@HDR_TEST_MPEG1(hdr)) {
        gr_count = gr_count * 2
        main_data_begin = get_bits(bs, 9)
        scfsi = get_bits(bs, 7 + gr_count)
    } else {
        main_data_begin = get_bits(bs, 8 + gr_count) >> gr_count
    }
    var gi_idx: Int64 = 0
    while (gr_count > 0) {
        gr[gi_idx].part_23_length = get_bits(bs, 12)
        part_23_sum = part_23_sum + gr[gi_idx].part_23_length
        gr[gi_idx].big_values = get_bits(bs, 9)
        if (gr[gi_idx].big_values > 288) {
            return -1
        }

        gr[gi_idx].global_gain = get_bits(bs, 8)
        if (@HDR_TEST_MPEG1(hdr)) {
            gr[gi_idx].scalefac_compress = get_bits(bs, 4)
        } else {
            gr[gi_idx].scalefac_compress = get_bits(bs, 9)
        }
        gr[gi_idx].sfbtab = g_scf_long[sr_idx]
        gr[gi_idx].n_long_sfb = 22
        gr[gi_idx].n_short_sfb = 0
        if (get_bits(bs, 1) != 0) {
            gr[gi_idx].block_type = get_bits(bs, 2)
            if (gr[gi_idx].block_type == 0) {
                return -1
            }
            gr[gi_idx].mixed_block_flag = get_bits(bs, 1)
            gr[gi_idx].region_count[0] = 7
            gr[gi_idx].region_count[1] = 255
            if (gr[gi_idx].block_type == SHORT_BLOCK_TYPE) {
                scfsi = scfsi & 0x0F0F
                if (gr[gi_idx].mixed_block_flag == 0) {
                    gr[gi_idx].region_count[0] = 8
                    gr[gi_idx].sfbtab = g_scf_short[sr_idx]
                    gr[gi_idx].n_long_sfb = 0
                    gr[gi_idx].n_short_sfb = 39
                } else {
                    gr[gi_idx].sfbtab = g_scf_mixed[sr_idx]
                    if (@HDR_TEST_MPEG1(hdr)) {
                        gr[gi_idx].n_long_sfb = 8
                    } else {
                        gr[gi_idx].n_long_sfb = 6
                    }
                    gr[gi_idx].n_short_sfb = 30
                }
            }
            tables = get_bits(bs, 10)
            tables = tables << 5
            gr[gi_idx].subblock_gain[0] = get_bits(bs, 3)
            gr[gi_idx].subblock_gain[1] = get_bits(bs, 3)
            gr[gi_idx].subblock_gain[2] = get_bits(bs, 3)
        } else {
            gr[gi_idx].block_type = 0
            gr[gi_idx].mixed_block_flag = 0
            tables = get_bits(bs, 15)
            gr[gi_idx].region_count[0] = get_bits(bs, 4)
            gr[gi_idx].region_count[1] = get_bits(bs, 3)
            gr[gi_idx].region_count[2] = 255
        }
        gr[gi_idx].table_select[0] = (tables >> 10) & 31
        gr[gi_idx].table_select[1] = (tables >> 5) & 31
        gr[gi_idx].table_select[2] = (tables) & 31
        if (@HDR_TEST_MPEG1(hdr)) {
            gr[gi_idx].preflag = get_bits(bs, 1)
        } else {
            if (gr[gi_idx].scalefac_compress >= 500) {
                gr[gi_idx].preflag = 1
            } else {
                gr[gi_idx].preflag = 0
            }
        }
        gr[gi_idx].scalefac_scale = get_bits(bs, 1)
        gr[gi_idx].count1_table = get_bits(bs, 1)
        if (@HDR_IS_MONO(hdr)) {
            if (gi_idx == 0) {
                gr[gi_idx].scfsi = 0
            } else {
                gr[gi_idx].scfsi = (scfsi & 15)
            }
        } else {
            gr[gi_idx].scfsi = ((scfsi >> 12) & 15)
            scfsi = scfsi << 4
        }
        gi_idx = gi_idx + 1
        gr_count = gr_count - 1
    }
    if (part_23_sum + bs.pos > bs.limit + main_data_begin * 8) {
        return -1
    }
    return main_data_begin
}

func L3_read_scalefactors(scf: Array<Int64>, ist_pos: Array<UInt8>, scf_size: Array<Int64>, scf_count: Array<Int64>,
    bitbuf: bs_t, scfsi: Int64): Unit {
    var i: Int64 = 0
    var k: Int64 = 0
    var scf_off: Int64 = 0
    var ist_off: Int64 = 0
    var scfsi_val = scfsi

    while (i < 4 && scf_count[i] != 0) {
        let cnt = scf_count[i]

        if ((scfsi_val & 8) != 0) {
            var t: Int64 = 0
            while (t < cnt) {
                let ist_val: Int64 = Int64(ist_pos[ist_off + t])
                scf[scf_off + t] = ist_val
                t = t + 1
            }
        } else {
            let bits = scf_size[i]
            if (bits == 0) {
                var t: Int64 = 0
                while (t < cnt) {
                    scf[scf_off + t] = 0
                    ist_pos[ist_off + t] = UInt8(0)
                    t = t + 1
                }
            } else {
                var max_scf: Int64 = -1
                if (scfsi_val < 0) {
                    max_scf = (1 << bits) - 1
                } else {
                    max_scf = -1
                }
                k = 0
                while (k < cnt) {
                    let s = get_bits(bitbuf, bits)
                    if (s == max_scf) {
                        ist_pos[ist_off + k] = UInt8(255)
                    } else {
                        ist_pos[ist_off + k] = UInt8(s)
                    }
                    scf[scf_off + k] = s
                    k = k + 1
                }
            }
        }

        ist_off = ist_off + cnt
        scf_off = scf_off + cnt
        i = i + 1
        scfsi_val = scfsi_val * 2
    }
    if ((scf_off + 2) < scf.size) {
        scf[scf_off + 0] = 0
        scf[scf_off + 1] = 0
        scf[scf_off + 2] = 0
    }
}

let g_expfrac: Array<Float64> = [
    9.313225746155e-10,
    7.831458259666e-10,
    6.585444967122e-10,
    5.537676983636e-10
]

func L3_ldexp_q2(y_in: Float64, exp_q2_in: Int64): Float64 {
    var y = y_in
    var exp_q2 = exp_q2_in
    var e: Int64 = 0

    do {
        e = min(120, exp_q2)
        let frac = g_expfrac[e & 3]
        let shift_val = Float64(1 << 30 >> (e >> 2))
        y = y * frac * shift_val
        exp_q2 = exp_q2 - e
    } while (exp_q2 > 0)

    return y
}

func L3_decode_scalefactors(hdr: Array<UInt8>, ist_pos: Array<UInt8>, bs: bs_t, gr: L3_gr_info_t, scf: Array<Float64>,
    ch: Int64): Unit {
    var reset_i: Int64 = 0
    while (reset_i < ist_pos.size) {
        ist_pos[reset_i] = UInt8(0)
        reset_i = reset_i + 1
    }
    let g_scf_partitions: Array<Array<Int64>> = [
        [6, 5, 5, 5, 6, 5, 5, 5, 6, 5, 7, 3, 11, 10, 0, 0, 7, 7, 7, 0, 6, 6, 6, 3, 8, 8, 5, 0],
        [8, 9, 6, 12, 6, 9, 9, 9, 6, 9, 12, 6, 15, 18, 0, 0, 6, 15, 12, 0, 6, 12, 9, 6, 6, 18, 9, 0],
        [9, 9, 6, 12, 9, 9, 9, 9, 9, 9, 12, 6, 18, 18, 0, 0, 12, 12, 12, 0, 12, 9, 9, 6, 15, 12, 9, 0]
    ]
    var idx_val: Int64 = 0
    if (gr.n_short_sfb != 0) {
        idx_val = idx_val + 1
    }
    if (gr.n_long_sfb == 0) {
        idx_val = idx_val + 1
    }
    var scf_partition = g_scf_partitions[idx_val]
    var scf_size = [0, 0, 0, 0]
    var iscf = Array<Int64>(40, repeat: 0)

    var i: Int64 = 0
    let scf_shift = gr.scalefac_scale + 1
    var scfsi = gr.scfsi
    var gain_exp: Int64 = 0
    var gain: Float64 = 0.0
    if (@HDR_TEST_MPEG1(hdr)) {
        let g_scfc_decode: Array<Int64> = [0, 1, 2, 3, 12, 5, 6, 7, 9, 10, 11, 13, 14, 15, 18, 19]
        let part = g_scfc_decode[gr.scalefac_compress]
        scf_size[0] = (part >> 2)
        scf_size[1] = (part >> 2)
        scf_size[2] = part & 3
        scf_size[3] = part & 3
    } else {
        let g_mod: Array<Int64> = [5, 5, 4, 4, 5, 5, 4, 1, 4, 3, 1, 1, 5, 6, 6, 1, 4, 4, 4, 1, 4, 3, 1, 1]
        var k: Int64 = 0
        if (@HDR_TEST_I_STEREO(hdr) && (ch != 0)) {
            k = 12
        } else {
            k = 0
        }
        var modprod: Int64 = 0
        var sfc = gr.scalefac_compress
        if (@HDR_TEST_I_STEREO(hdr) && (ch != 0)) {
            sfc = sfc >> 1
        }
        while (sfc >= 0) {
            modprod = 1
            for (i in [3, 2, 1, 0]) {
                scf_size[i] = (sfc / modprod) % g_mod[k + i]
                modprod = modprod * g_mod[k + i]
            }
            sfc = sfc - modprod
            k = k + 4
        }
        let scf_base = g_scf_partitions[idx_val]
        scf_partition = scf_base.slice(k, scf_base.size - k)
        scfsi = -16
    }
    L3_read_scalefactors(iscf, ist_pos, scf_size, scf_partition, bs, scfsi)

    if (gr.n_short_sfb != 0) {
        let sh = 3 - scf_shift
        var ii: Int64 = 0
        while (ii < gr.n_short_sfb) {
            iscf[gr.n_long_sfb + ii + 0] = iscf[gr.n_long_sfb + ii + 0] + (gr.subblock_gain[0] << sh)
            iscf[gr.n_long_sfb + ii + 1] = iscf[gr.n_long_sfb + ii + 1] + (gr.subblock_gain[1] << sh)
            iscf[gr.n_long_sfb + ii + 2] = iscf[gr.n_long_sfb + ii + 2] + (gr.subblock_gain[2] << sh)
            ii = ii + 3
        }
    } else if (gr.preflag != 0) {
        let g_preamp: Array<Int64> = [1, 1, 1, 1, 2, 2, 3, 3, 3, 2]
        var t: Int64 = 0
        while (t < 10) {
            iscf[11 + t] = iscf[11 + t] + g_preamp[t]
            t = t + 1
        }
    }
    var ms_sub: Int64 = 0
    if (@HDR_TEST_MS_STEREO(hdr)) {
        ms_sub = 2
    } else {
        ms_sub = 0
    }
    gain_exp = gr.global_gain + BITS_DEQUANTIZER_OUT * 4 - 210 - ms_sub
    gain = L3_ldexp_q2(Float64(1 << (MAX_SCFI / 4)), MAX_SCFI - gain_exp)

    i = 0
    while (i < (gr.n_long_sfb + gr.n_short_sfb)) {
        let iscf_val = iscf[i]
        let shifted_val = iscf_val << scf_shift
        let new_scf = L3_ldexp_q2(gain, shifted_val)
        scf[i] = new_scf
        i = i + 1
    }
}

let g_pow43: Array<Float64> = [
    0.0,
    -1.0,
    -2.519842,
    -4.326749,
    -6.349604,
    -8.549880,
    -10.902724,
    -13.390518,
    -16.000000,
    -18.720754,
    -21.544347,
    -24.463781,
    -27.473142,
    -30.567351,
    -33.741992,
    -36.993181,
    0.0,
    1.0,
    2.519842,
    4.326749,
    6.349604,
    8.549880,
    10.902724,
    13.390518,
    16.000000,
    18.720754,
    21.544347,
    24.463781,
    27.473142,
    30.567351,
    33.741992,
    36.993181,
    40.317474,
    43.711787,
    47.173345,
    50.699631,
    54.288352,
    57.937408,
    61.644865,
    65.408941,
    69.227979,
    73.100443,
    77.024898,
    81.000000,
    85.024491,
    89.097188,
    93.216975,
    97.382800,
    101.593667,
    105.848633,
    110.146801,
    114.487321,
    118.869381,
    123.292209,
    127.755065,
    132.257246,
    136.798076,
    141.376907,
    145.993119,
    150.646117,
    155.335327,
    160.060199,
    164.820202,
    169.614826,
    174.443577,
    179.305980,
    184.201575,
    189.129918,
    194.090580,
    199.083145,
    204.107210,
    209.162385,
    214.248292,
    219.364564,
    224.510845,
    229.686789,
    234.892058,
    240.126328,
    245.389280,
    250.680604,
    256.000000,
    261.347174,
    266.721841,
    272.123723,
    277.552547,
    283.008049,
    288.489971,
    293.998060,
    299.532071,
    305.091761,
    310.676898,
    316.287249,
    321.922592,
    327.582707,
    333.267377,
    338.976394,
    344.709550,
    350.466646,
    356.247482,
    362.051866,
    367.879608,
    373.730522,
    379.604427,
    385.501143,
    391.420496,
    397.362314,
    403.326427,
    409.312672,
    415.320884,
    421.350905,
    427.402579,
    433.475750,
    439.570269,
    445.685987,
    451.822757,
    457.980436,
    464.158883,
    470.357960,
    476.577530,
    482.817459,
    489.077615,
    495.357868,
    501.658090,
    507.978156,
    514.317941,
    520.677324,
    527.056184,
    533.454404,
    539.871867,
    546.308458,
    552.764065,
    559.238575,
    565.731879,
    572.243870,
    578.774440,
    585.323483,
    591.890898,
    598.476581,
    605.080431,
    611.702349,
    618.342238,
    625.000000,
    631.675540,
    638.368763,
    645.079578
]

func L3_pow_43(x_in: Int64): Float64 {
    var x = x_in
    var frac: Float64 = 0.0
    var sign: Int64 = 0
    var mult: Int64 = 256

    if (x < 129) {
        let idx = 16 + x
        if (idx >= g_pow43.size) {
            return 0.0
        }
        let result = g_pow43[idx]
        return result
    }
    if (x < 1024) {
        mult = 16
        x = x << 3
    }
    sign = (2 * x) & 64

    let mask63 = -64
    let numerator = (x & 63) - sign
    let denominator = (x & mask63) + sign
    frac = Float64(numerator) / Float64(denominator)

    let idx2 = 16 + ((x + sign) >> 6)
    if (idx2 >= g_pow43.size) {
        return 0.0
    }
    let base_value = g_pow43[idx2]
    let interpolation = 1.0 + frac * ((4.0 / 3.0) + frac * (2.0 / 9.0))
    let result = base_value * interpolation * Float64(mult)
    return result
}

// ===== Layer III 霍夫曼解码 =====
func L3_huffman(dst: Array<Float64>, bs: bs_t, gr_info: L3_gr_info_t, scf: Array<Float64>, layer3gr_limit: Int64): Unit {
    let tabs: Array<Int64> = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 785, 785, 785, 785, 784, 784, 784, 784, 513, 513, 513, 513, 513, 513, 513, 513, 256, 256, 256, 256, 256,
        256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -255, 1313, 1298, 1282, 785, 785, 785, 785, 784, 784, 784,
        784, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 290,
        288, -255, 1313, 1298, 1282, 769, 769, 769, 769, 529, 529, 529, 529, 529, 529, 529, 529, 528, 528, 528, 528, 528,
        528, 528, 528, 512, 512, 512, 512, 512, 512, 512, 512, 290, 288, -253, -318, -351, -367, 785, 785, 785, 785, 784,
        784, 784, 784, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
        256, 819, 818, 547, 547, 275, 275, 275, 275, 561, 560, 515, 546, 289, 274, 288, 258, -254, -287, 1329, 1299,
        1314, 1312, 1057, 1057, 1042, 1042, 1026, 1026, 784, 784, 784, 784, 529, 529, 529, 529, 529, 529, 529, 529, 769,
        769, 769, 769, 768, 768, 768, 768, 563, 560, 306, 306, 291, 259, -252, -413, -477, -542, 1298, -575, 1041, 1041,
        784, 784, 784, 784, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
        256, 256, -383, -399, 1107, 1092, 1106, 1061, 849, 849, 789, 789, 1104, 1091, 773, 773, 1076, 1075, 341, 340,
        325, 309, 834, 804, 577, 577, 532, 532, 516, 516, 832, 818, 803, 816, 561, 561, 531, 531, 515, 546, 289, 289,
        288, 258, -252, -429, -493, -559, 1057, 1057, 1042, 1042, 529, 529, 529, 529, 529, 529, 529, 529, 784, 784, 784,
        784, 769, 769, 769, 769, 512, 512, 512, 512, 512, 512, 512, 512, -382, 1077, -415, 1106, 1061, 1104, 849, 849,
        789, 789, 1091, 1076, 1029, 1075, 834, 834, 597, 581, 340, 340, 339, 324, 804, 833, 532, 532, 832, 772, 818, 803,
        817, 787, 816, 771, 290, 290, 290, 290, 288, 258, -253, -349, -414, -447, -463, 1329, 1299, -479, 1314, 1312,
        1057, 1057, 1042, 1042, 1026, 1026, 785, 785, 785, 785, 784, 784, 784, 784, 769, 769, 769, 769, 768, 768, 768,
        768, -319, 851, 821, -335, 836, 850, 805, 849, 341, 340, 325, 336, 533, 533, 579, 579, 564, 564, 773, 832, 578,
        548, 563, 516, 321, 276, 306, 291, 304, 259, -251, -572, -733, -830, -863, -879, 1041, 1041, 784, 784, 784, 784,
        769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -511, -527,
        -543, 1396, 1351, 1381, 1366, 1395, 1335, 1380, -559, 1334, 1138, 1138, 1063, 1063, 1350, 1392, 1031, 1031, 1062,
        1062, 1364, 1363, 1120, 1120, 1333, 1348, 881, 881, 881, 881, 375, 374, 359, 373, 343, 358, 341, 325, 791, 791,
        1123, 1122, -703, 1105, 1045, -719, 865, 865, 790, 790, 774, 774, 1104, 1029, 338, 293, 323, 308, -799, -815,
        833, 788, 772, 818, 803, 816, 322, 292, 307, 320, 561, 531, 515, 546, 289, 274, 288, 258, -251, -525, -605, -685,
        -765, -831, -846, 1298, 1057, 1057, 1312, 1282, 785, 785, 785, 785, 784, 784, 784, 784, 769, 769, 769, 769, 512,
        512, 512, 512, 512, 512, 512, 512, 1399, 1398, 1383, 1367, 1382, 1396, 1351, -511, 1381, 1366, 1139, 1139, 1079,
        1079, 1124, 1124, 1364, 1349, 1363, 1333, 882, 882, 882, 882, 807, 807, 807, 807, 1094, 1094, 1136, 1136, 373,
        341, 535, 535, 881, 775, 867, 822, 774, -591, 324, 338, -671, 849, 550, 550, 866, 864, 609, 609, 293, 336, 534,
        534, 789, 835, 773, -751, 834, 804, 308, 307, 833, 788, 832, 772, 562, 562, 547, 547, 305, 275, 560, 515, 290,
        290, -252, -397, -477, -557, -622, -653, -719, -735, -750, 1329, 1299, 1314, 1057, 1057, 1042, 1042, 1312, 1282,
        1024, 1024, 785, 785, 785, 785, 784, 784, 784, 784, 769, 769, 769, 769, -383, 1127, 1141, 1111, 1126, 1140, 1095,
        1110, 869, 869, 883, 883, 1079, 1109, 882, 882, 375, 374, 807, 868, 838, 881, 791, -463, 867, 822, 368, 263, 852,
        837, 836, -543, 610, 610, 550, 550, 352, 336, 534, 534, 865, 774, 851, 821, 850, 805, 593, 533, 579, 564, 773,
        832, 578, 578, 548, 548, 577, 577, 307, 276, 306, 291, 516, 560, 259, 259, -250, -2107, -2507, -2764, -2909,
        -2974, -3007, -3023, 1041, 1041, 1040, 1040, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256,
        256, 256, 256, 256, 256, 256, 256, -767, -1052, -1213, -1277, -1358, -1405, -1469, -1535, -1550, -1582, -1614,
        -1647, -1662, -1694, -1726, -1759, -1774, -1807, -1822, -1854, -1886, 1565, -1919, -1935, -1951, -1967, 1731,
        1730, 1580, 1717, -1983, 1729, 1564, -1999, 1548, -2015, -2031, 1715, 1595, -2047, 1714, -2063, 1610, -2079,
        1609, -2095, 1323, 1323, 1457, 1457, 1307, 1307, 1712, 1547, 1641, 1700, 1699, 1594, 1685, 1625, 1442, 1442,
        1322, 1322, -780, -973, -910, 1279, 1278, 1277, 1262, 1276, 1261, 1275, 1215, 1260, 1229, -959, 974, 974, 989,
        989, -943, 735, 478, 478, 495, 463, 506, 414, -1039, 1003, 958, 1017, 927, 942, 987, 957, 431, 476, 1272, 1167,
        1228, -1183, 1256, -1199, 895, 895, 941, 941, 1242, 1227, 1212, 1135, 1014, 1014, 490, 489, 503, 487, 910, 1013,
        985, 925, 863, 894, 970, 955, 1012, 847, -1343, 831, 755, 755, 984, 909, 428, 366, 754, 559, -1391, 752, 486,
        457, 924, 997, 698, 698, 983, 893, 740, 740, 908, 877, 739, 739, 667, 667, 953, 938, 497, 287, 271, 271, 683,
        606, 590, 712, 726, 574, 302, 302, 738, 736, 481, 286, 526, 725, 605, 711, 636, 724, 696, 651, 589, 681, 666,
        710, 364, 467, 573, 695, 466, 466, 301, 465, 379, 379, 709, 604, 665, 679, 316, 316, 634, 633, 436, 436, 464,
        269, 424, 394, 452, 332, 438, 363, 347, 408, 393, 448, 331, 422, 362, 407, 392, 421, 346, 406, 391, 376, 375,
        359, 1441, 1306, -2367, 1290, -2383, 1337, -2399, -2415, 1426, 1321, -2431, 1411, 1336, -2447, -2463, -2479,
        1169, 1169, 1049, 1049, 1424, 1289, 1412, 1352, 1319, -2495, 1154, 1154, 1064, 1064, 1153, 1153, 416, 390, 360,
        404, 403, 389, 344, 374, 373, 343, 358, 372, 327, 357, 342, 311, 356, 326, 1395, 1394, 1137, 1137, 1047, 1047,
        1365, 1392, 1287, 1379, 1334, 1364, 1349, 1378, 1318, 1363, 792, 792, 792, 792, 1152, 1152, 1032, 1032, 1121,
        1121, 1046, 1046, 1120, 1120, 1030, 1030, -2895, 1106, 1061, 1104, 849, 849, 789, 789, 1091, 1076, 1029, 1090,
        1060, 1075, 833, 833, 309, 324, 532, 532, 832, 772, 818, 803, 561, 561, 531, 560, 515, 546, 289, 274, 288, 258,
        -250, -1179, -1579, -1836, -1996, -2124, -2253, -2333, -2413, -2477, -2542, -2574, -2607, -2622, -2655, 1314,
        1313, 1298, 1312, 1282, 785, 785, 785, 785, 1040, 1040, 1025, 1025, 768, 768, 768, 768, -766, -798, -830, -862,
        -895, -911, -927, -943, -959, -975, -991, -1007, -1023, -1039, -1055, -1070, 1724, 1647, -1103, -1119, 1631,
        1767, 1662, 1738, 1708, 1723, -1135, 1780, 1615, 1779, 1599, 1677, 1646, 1778, 1583, -1151, 1777, 1567, 1737,
        1692, 1765, 1722, 1707, 1630, 1751, 1661, 1764, 1614, 1736, 1676, 1763, 1750, 1645, 1598, 1721, 1691, 1762, 1706,
        1582, 1761, 1566, -1167, 1749, 1629, 767, 766, 751, 765, 494, 494, 735, 764, 719, 749, 734, 763, 447, 447, 748,
        718, 477, 506, 431, 491, 446, 476, 461, 505, 415, 430, 475, 445, 504, 399, 460, 489, 414, 503, 383, 474, 429,
        459, 502, 502, 746, 752, 488, 398, 501, 473, 413, 472, 486, 271, 480, 270, -1439, -1455, 1357, -1471, -1487,
        -1503, 1341, 1325, -1519, 1489, 1463, 1403, 1309, -1535, 1372, 1448, 1418, 1476, 1356, 1462, 1387, -1551, 1475,
        1340, 1447, 1402, 1386, -1567, 1068, 1068, 1474, 1461, 455, 380, 468, 440, 395, 425, 410, 454, 364, 467, 466,
        464, 453, 269, 409, 448, 268, 432, 1371, 1473, 1432, 1417, 1308, 1460, 1355, 1446, 1459, 1431, 1083, 1083, 1401,
        1416, 1458, 1445, 1067, 1067, 1370, 1457, 1051, 1051, 1291, 1430, 1385, 1444, 1354, 1415, 1400, 1443, 1082, 1082,
        1173, 1113, 1186, 1066, 1185, 1050, -1967, 1158, 1128, 1172, 1097, 1171, 1081, -1983, 1157, 1112, 416, 266, 375,
        400, 1170, 1142, 1127, 1065, 793, 793, 1169, 1033, 1156, 1096, 1141, 1111, 1155, 1080, 1126, 1140, 898, 898, 808,
        808, 897, 897, 792, 792, 1095, 1152, 1032, 1125, 1110, 1139, 1079, 1124, 882, 807, 838, 881, 853, 791, -2319,
        867, 368, 263, 822, 852, 837, 866, 806, 865, -2399, 851, 352, 262, 534, 534, 821, 836, 594, 594, 549, 549, 593,
        593, 533, 533, 848, 773, 579, 579, 564, 578, 548, 563, 276, 276, 577, 576, 306, 291, 516, 560, 305, 305, 275,
        259, -251, -892, -2058, -2620, -2828, -2957, -3023, -3039, 1041, 1041, 1040, 1040, 769, 769, 769, 769, 256, 256,
        256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -511, -527, -543, -559, 1530, -575, -591,
        1528, 1527, 1407, 1526, 1391, 1023, 1023, 1023, 1023, 1525, 1375, 1268, 1268, 1103, 1103, 1087, 1087, 1039, 1039,
        1523, -604, 815, 815, 815, 815, 510, 495, 509, 479, 508, 463, 507, 447, 431, 505, 415, 399, -734, -782, 1262,
        -815, 1259, 1244, -831, 1258, 1228, -847, -863, 1196, -879, 1253, 987, 987, 748, -767, 493, 493, 462, 477, 414,
        414, 686, 669, 478, 446, 461, 445, 474, 429, 487, 458, 412, 471, 1266, 1264, 1009, 1009, 799, 799, -1019, -1276,
        -1452, -1581, -1677, -1757, -1821, -1886, -1933, -1997, 1257, 1257, 1483, 1468, 1512, 1422, 1497, 1406, 1467,
        1496, 1421, 1510, 1134, 1134, 1225, 1225, 1466, 1451, 1374, 1405, 1252, 1252, 1358, 1480, 1164, 1164, 1251, 1251,
        1238, 1238, 1389, 1465, -1407, 1054, 1101, -1423, 1207, -1439, 830, 830, 1248, 1038, 1237, 1117, 1223, 1148,
        1236, 1208, 411, 426, 395, 410, 379, 269, 1193, 1222, 1132, 1235, 1221, 1116, 976, 976, 1192, 1162, 1177, 1220,
        1131, 1191, 963, 963, -1647, 961, 780, -1663, 558, 558, 994, 993, 437, 408, 393, 407, 829, 978, 813, 797, 947,
        -1743, 721, 721, 377, 392, 844, 950, 828, 890, 706, 706, 812, 859, 796, 960, 948, 843, 934, 874, 571, 571, -1919,
        690, 555, 689, 421, 346, 539, 539, 944, 779, 918, 873, 932, 842, 903, 888, 570, 570, 931, 917, 674, 674, -2575,
        1562, -2591, 1609, -2607, 1654, 1322, 1322, 1441, 1441, 1696, 1546, 1683, 1593, 1669, 1624, 1426, 1426, 1321,
        1321, 1639, 1680, 1425, 1425, 1305, 1305, 1545, 1668, 1608, 1623, 1667, 1592, 1638, 1666, 1320, 1320, 1652, 1607,
        1409, 1409, 1304, 1304, 1288, 1288, 1664, 1637, 1395, 1395, 1335, 1335, 1622, 1636, 1394, 1394, 1319, 1319, 1606,
        1621, 1392, 1392, 1137, 1137, 1137, 1137, 345, 390, 360, 375, 404, 373, 1047, -2751, -2767, -2783, 1062, 1121,
        1046, -2799, 1077, -2815, 1106, 1061, 789, 789, 1105, 1104, 263, 355, 310, 340, 325, 354, 352, 262, 339, 324,
        1091, 1076, 1029, 1090, 1060, 1075, 833, 833, 788, 788, 1088, 1028, 818, 818, 803, 803, 561, 561, 531, 531, 816,
        771, 546, 546, 289, 274, 288, 258, -253, -317, -381, -446, -478, -509, 1279, 1279, -811, -1179, -1451, -1756,
        -1900, -2028, -2189, -2253, -2333, -2414, -2445, -2511, -2526, 1313, 1298, -2559, 1041, 1041, 1040, 1040, 1025,
        1025, 1024, 1024, 1022, 1007, 1021, 991, 1020, 975, 1019, 959, 687, 687, 1018, 1017, 671, 671, 655, 655, 1016,
        1015, 639, 639, 758, 758, 623, 623, 757, 607, 756, 591, 755, 575, 754, 559, 543, 543, 1009, 783, -575, -621,
        -685, -749, 496, -590, 750, 749, 734, 748, 974, 989, 1003, 958, 988, 973, 1002, 942, 987, 957, 972, 1001, 926,
        986, 941, 971, 956, 1000, 910, 985, 925, 999, 894, 970, -1071, -1087, -1102, 1390, -1135, 1436, 1509, 1451, 1374,
        -1151, 1405, 1358, 1480, 1420, -1167, 1507, 1494, 1389, 1342, 1465, 1435, 1450, 1326, 1505, 1310, 1493, 1373,
        1479, 1404, 1492, 1464, 1419, 428, 443, 472, 397, 736, 526, 464, 464, 486, 457, 442, 471, 484, 482, 1357, 1449,
        1434, 1478, 1388, 1491, 1341, 1490, 1325, 1489, 1463, 1403, 1309, 1477, 1372, 1448, 1418, 1433, 1476, 1356, 1462,
        1387, -1439, 1475, 1340, 1447, 1402, 1474, 1324, 1461, 1371, 1473, 269, 448, 1432, 1417, 1308, 1460, -1711, 1459,
        -1727, 1441, 1099, 1099, 1446, 1386, 1431, 1401, -1743, 1289, 1083, 1083, 1160, 1160, 1458, 1445, 1067, 1067,
        1370, 1457, 1307, 1430, 1129, 1129, 1098, 1098, 268, 432, 267, 416, 266, 400, -1887, 1144, 1187, 1082, 1173,
        1113, 1186, 1066, 1050, 1158, 1128, 1143, 1172, 1097, 1171, 1081, 420, 391, 1157, 1112, 1170, 1142, 1127, 1065,
        1169, 1049, 1156, 1096, 1141, 1111, 1155, 1080, 1126, 1154, 1064, 1153, 1140, 1095, 1048, -2159, 1125, 1110,
        1137, -2175, 823, 823, 1139, 1138, 807, 807, 384, 264, 368, 263, 868, 838, 853, 791, 867, 822, 852, 837, 866,
        806, 865, 790, -2319, 851, 821, 836, 352, 262, 850, 805, 849, -2399, 533, 533, 835, 820, 336, 261, 578, 548, 563,
        577, 532, 532, 832, 772, 562, 562, 547, 547, 305, 275, 560, 515, 290, 290, 288, 258]
    let tab32: Array<Int64> = [130, 162, 193, 209, 44, 28, 76, 140, 9, 9, 9, 9, 9, 9, 9, 9, 190, 254, 222, 238, 126, 94,
        157, 157, 109, 61, 173, 205]
    let tab33: Array<Int64> = [252, 236, 220, 204, 188, 172, 156, 140, 124, 108, 92, 76, 60, 44, 28, 12]
    let tabindex: Array<Int64> = [0, 32, 64, 98, 0, 132, 180, 218, 292, 364, 426, 538, 648, 746, 0, 1126, 1460, 1460,
        1460, 1460, 1460, 1460, 1460, 1460, 1842, 1842, 1842, 1842, 1842, 1842, 1842, 1842]
    let g_linbits: Array<Int64> = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 6, 8, 10, 13, 4, 5, 6, 7,
        8, 9, 11, 13]
    var ireg: Int64 = 0
    var big_val_cnt = gr_info.big_values
    var sfb = gr_info.sfbtab
    var next_index = bs.pos / 8

    var bs_cache: Int64 = (((Int64(bs.buf[next_index]) * 256 + Int64(bs.buf[next_index + 1])) * 256 + Int64(bs.buf[next_index +
            2])) * 256 + Int64(bs.buf[next_index + 3])) << (bs.pos & 7)
    bs_cache = bs_cache & 0xFFFFFFFF
    var bs_sh: Int64 = (bs.pos & 7) - 8
    next_index = next_index + 4
    var dst_off: Int64 = 0
    var cur_one: Float64 = 0.0
    var scf_idx: Int64 = 0

    while (big_val_cnt > 0) {
        let tab_num = gr_info.table_select[ireg]
        var sfb_cnt = gr_info.region_count[ireg]
        ireg = ireg + 1
        let codebook_off = tabindex[tab_num]
        let linbits = g_linbits[tab_num]

        do {
            if (sfb.size == 0) {
                break
            }

            let np = sfb[0] / 2

            sfb = sfb.slice(1, sfb.size - 1)

            cur_one = scf[scf_idx]
            scf_idx = scf_idx + 1

            var pairs_to_decode = min(big_val_cnt, np)

            do {
                var w: Int64 = 5
                let raw_peek = @PEEK_BITS(w)
                var idx1 = codebook_off + raw_peek
                if (idx1 < 0 || idx1 >= tabs.size) {
                    big_val_cnt = 0
                    break
                }

                var leaf = tabs[idx1]
                while (leaf < 0) {
                    @FLUSH_BITS(w)
                    w = leaf & 7
                    let peek2 = @PEEK_BITS(w)
                    var idx2 = codebook_off + (peek2 - (leaf >> 3))
                    if (idx2 < 0 || idx2 >= tabs.size) {
                        big_val_cnt = 0
                        break
                    }
                    leaf = tabs[idx2]
                }
                if (leaf < 0) {
                    break
                }
                @FLUSH_BITS(leaf >> 8)
                var j: Int64 = 0
                while (j < 2) {
                    let lsb = leaf & 0x0F
                    if (lsb == 15 && linbits != 0) {
                        let ext = @PEEK_BITS(linbits)
                        @FLUSH_BITS(linbits)
                        @CHECK_BITS()

                        let signneg = ((bs_cache & 0x80000000) != 0)
                        var sgn: Float64 = 1.0
                        if (signneg) {
                            sgn = -1.0
                        } else {
                            sgn = 1.0
                        }
                        let pow_val = L3_pow_43(lsb + ext)
                        let val = cur_one * pow_val * sgn
                        dst[dst_off] = val
                    } else {
                        var signbit: Int64 = 0
                        if ((bs_cache & 0x80000000) != 0) {
                            signbit = 1
                        } else {
                            signbit = 0
                        }
                        let gi = 16 + lsb - 16 * signbit
                        let pow_val = g_pow43[gi]
                        let val = pow_val * cur_one
                        dst[dst_off] = val
                    }
                    if (lsb != 0) {
                        @FLUSH_BITS(1)
                    } else {
                        @FLUSH_BITS(0)
                    }
                    @CHECK_BITS()
                    if (dst_off >= dst.size) {
                        break
                    }
                    dst_off = dst_off + 1
                    leaf = leaf >> 4
                    j = j + 1
                }
                pairs_to_decode = pairs_to_decode - 1
            } while (pairs_to_decode > 0)

            big_val_cnt = big_val_cnt - np
            sfb_cnt = sfb_cnt - 1
        } while (big_val_cnt > 0 && sfb_cnt >= 0)
    }

    var np: Int64 = 1 - big_val_cnt
    while (true) {
        var codebook_count1 = tab32
        if (gr_info.count1_table != 0) {
            codebook_count1 = tab33
        } else {
            codebook_count1 = tab32
        }

        let idx0 = @PEEK_BITS(4)
        if (idx0 < 0 || idx0 >= codebook_count1.size) {
            break
        }
        var leaf = codebook_count1[idx0]
        if ((leaf & 8) == 0) {
            @CHECK_BITS()
            let idx1 = (leaf >> 3) + (((bs_cache & 0xFFFFFFFF) << 4) >> (32 - (leaf & 3)))
            if (idx1 < 0 || idx1 >= codebook_count1.size) {
                break
            }
            leaf = codebook_count1[idx1]
        }
        @FLUSH_BITS(leaf & 7)

        if (@BSPOS() > layer3gr_limit) {
            break
        }

        let masks = [128, 64, 32, 16]
        var sample_idx: Int64 = 0
        while (sample_idx < 4) {
            np = np - 1
            if (np <= 0) {
                if (sfb.size == 0) {
                    break
                }
                let np_local = sfb[0] / 2
                sfb = sfb.slice(1, sfb.size - 1)
                if (np_local == 0) {
                    break
                }
                np = np_local
                cur_one = scf[scf_idx]
                scf_idx = scf_idx + 1
            }

            if ((leaf & masks[sample_idx]) != 0) {
                if (dst_off + sample_idx >= dst.size) {
                    break
                }
                let signneg = ((bs_cache & 0x80000000) != 0)
                let val = if (signneg) {
                    -cur_one
                } else {
                    cur_one
                }
                dst[dst_off + sample_idx] = val
                @FLUSH_BITS(1)
            }
            sample_idx = sample_idx + 1
        }
        @CHECK_BITS()
        if (dst_off + 3 >= dst.size) {
            break
        }
        dst_off = dst_off + 4

        if (np <= 0 && sfb.size == 0) {
            break
        }
    }
    bs.pos = layer3gr_limit
}

func L3_midside_stereo(left: Array<Float64>, n: Int64): Unit {
    var i: Int64 = 0
    let right_off = 576
    while (i < n) {
        let a = left[i]
        let b = left[right_off + i]
        left[i] = a + b
        left[right_off + i] = a - b
        i = i + 1
    }
}

func L3_intensity_stereo_band(left: Array<Float64>, n: Int64, kl: Float64, kr: Float64): Unit {
    var i: Int64 = 0
    while (i < n) {
        left[576 + i] = left[i] * kr
        left[i] = left[i] * kl
        i = i + 1
    }
}

func L3_stereo_top_band(right: Array<Float64>, sfb: Array<Int64>, nbands: Int64, max_band: Array<Int64>): Unit {
    var i: Int64 = 0
    var k: Int64 = 0
    max_band[0] = -1
    max_band[1] = -1
    max_band[2] = -1
    var off: Int64 = 0
    while (i < nbands) {
        k = 0
        while (k < sfb[i]) {
            if (!(right[off + k] == 0.0 && right[off + k + 1] == 0.0)) {
                max_band[i % 3] = i
                break
            }
            k = k + 2
        }
        off = off + sfb[i]
        i = i + 1
    }
}

func L3_stereo_process(left: Array<Float64>, ist_pos: Array<UInt8>, sfb: Array<Int64>, hdr: Array<UInt8>,
    max_band: Array<Int64>, mpeg2_sh: Int64): Unit {
    let g_pan: Array<Float64> = [0.0, 1.0, 0.21132487, 0.78867513, 0.36602540, 0.63397460, 0.5, 0.5, 0.63397460,
        0.36602540, 0.78867513, 0.21132487, 1.0, 0.0]

    var i: Int64 = 0
    var max_pos: Int64 = 64
    if (@HDR_TEST_MPEG1(hdr)) {
        max_pos = 7
    } else {
        max_pos = 64
    }
    var off: Int64 = 0
    while (sfb[i] != 0) {
        let ipos: Int64 = Int64(ist_pos[i])
        if (i > max_band[i % 3] && ipos < max_pos) {
            var kl: Float64 = 1.0
            var kr: Float64 = 1.0
            var s: Float64 = 1.0
            if (@HDR_TEST_MS_STEREO(hdr)) {
                s = 1.41421356
            } else {
                s = 1.0
            }
            if (@HDR_TEST_MPEG1(hdr)) {
                kl = g_pan[2 * ipos]
                kr = g_pan[2 * ipos + 1]
            } else {
                kl = 1.0
                kr = L3_ldexp_q2(1.0, ((ipos + 1) >> 1) << mpeg2_sh)
                if ((ipos & 1) != 0) {
                    let tmp = kl;
                    kl = kr
                    kr = tmp
                }
            }
            L3_intensity_stereo_band(left.slice(off, left.size), sfb[i], kl * s, kr * s)
        } else {
            if (@HDR_TEST_MS_STEREO(hdr)) {
                L3_midside_stereo(left.slice(off, left.size), sfb[i])
            }
        }
        off = off + sfb[i]
        i = i + 1
    }
}

func L3_intensity_stereo(left: Array<Float64>, ist_pos: Array<UInt8>, grs: Array<L3_gr_info_t>, hdr: Array<UInt8>): Unit {
    let gr = grs[0]
    var max_band = [0, 0, 0]
    let n_sfb = gr.n_long_sfb + gr.n_short_sfb
    L3_stereo_top_band(left.slice(576, left.size), gr.sfbtab, n_sfb, max_band)
    if (gr.n_long_sfb != 0) {
        let m = max(max(max_band[0], max_band[1]), max_band[2])
        max_band[0] = m
        max_band[1] = m
        max_band[2] = m
    }

    var i: Int64 = 0
    var max_blocks: Int64 = 1
    if (gr.n_short_sfb != 0) {
        max_blocks = 3
    } else {
        max_blocks = 1
    }
    while (i < max_blocks) {
        var default_pos: Int64 = 0
        if (@HDR_TEST_MPEG1(hdr)) {
            default_pos = 3
        } else {
            default_pos = 0
        }
        let itop = n_sfb - max_blocks + i
        let prev = itop - max_blocks
        if (max_band[i] >= prev) {
            ist_pos[itop] = UInt8(default_pos)
        } else {
            ist_pos[itop] = ist_pos[prev]
        }
        i = i + 1
    }
    var mpeg2_sh: Int64 = 0
    if (grs.size > 1) {
        mpeg2_sh = (grs[1].scalefac_compress & 1)
    } else {
        mpeg2_sh = 0
    }
    L3_stereo_process(left, ist_pos, gr.sfbtab, hdr, max_band, mpeg2_sh)
}

func L3_reorder(grbuf: Array<Float64>, scratch: Array<Float64>, sfb: Array<Int64>): Unit {
    var src_off: Int64 = 0
    var dst_off: Int64 = 0
    var len: Int64 = 0
    var sfb_idx: Int64 = 0
    while (true) {
        if (sfb_idx >= sfb.size) {
            break
        }
        len = sfb[sfb_idx]
        if (len == 0) {
            break
        }
        var i: Int64 = 0
        while (i < len) {
            scratch[dst_off + 0] = grbuf[src_off + 0 * len]
            scratch[dst_off + 1] = grbuf[src_off + 1 * len]
            scratch[dst_off + 2] = grbuf[src_off + 2 * len]
            dst_off = dst_off + 3
            src_off = src_off + 1
            i = i + 1
        }
        sfb_idx = sfb_idx + 3
        src_off = src_off + 2 * len
    }

    scratch.slice(0, dst_off).copyTo(grbuf.slice(0, dst_off))
}

func L3_antialias(grbuf: Array<Float64>, nbands: Int64): Unit {
    let g_aa: Array<Array<Float64>> = [
        [0.85749293, 0.88174200, 0.94962865, 0.98331459, 0.99551782, 0.99916056, 0.99989920, 0.99999316],
        [0.51449576, 0.47173197, 0.31337745, 0.18191320, 0.09457419, 0.04096558, 0.01419856, 0.00369997]
    ]

    var b: Int64 = 0
    var base: Int64 = 0
    while (b < nbands) {
        var i: Int64 = 0
        while (i < 8) {
            let u = grbuf[base + 18 + i]
            let d = grbuf[base + 17 - i]
            grbuf[base + 18 + i] = u * g_aa[0][i] - d * g_aa[1][i]
            grbuf[base + 17 - i] = u * g_aa[1][i] + d * g_aa[0][i]
            i = i + 1
        }
        b = b + 1
        base = base + 18
    }
}

func L3_dct3_9(y: Array<Float64>): Unit {
    var s0 = y[0];
    var s2 = y[2];
    var s4 = y[4];
    var s6 = y[6];
    var s8 = y[8]
    var t0 = s0 + s6 * 0.5
    s0 = s0 - s6
    var t4 = (s4 + s2) * 0.93969262
    var t2 = (s8 + s2) * 0.76604444
    s6 = (s4 - s8) * 0.17364818
    s4 = s4 + s8 - s2
    var s1 = y[1];
    var s3 = y[3];
    var s5 = y[5];
    var s7 = y[7]
    s2 = s0 - s4 * 0.5
    y[4] = s4 + s0
    var s8n = t0 - t2 + s6
    s0 = t0 - t4 + t2
    s4 = t0 + t4 - s6
    s3 = s3 * 0.86602540
    t0 = (s5 + s1) * 0.98480775
    t4 = (s5 - s7) * 0.34202014
    t2 = (s1 + s7) * 0.64278761
    s1 = (s1 - s5 - s7) * 0.86602540
    var s5n = t0 - s3 - t2
    var s7n = t4 - s3 - t0
    s3 = t4 + s3 - t2
    y[0] = s4 - s7n
    y[1] = s2 + s1
    y[2] = s0 - s3
    y[3] = s8n + s5n
    y[5] = s8n - s5n
    y[6] = s0 + s3
    y[7] = s2 - s1
    y[8] = s4 + s7n
}

func L3_imdct36(grbuf: Array<Float64>, overlap: Array<Float64>, window: Array<Float64>, nbands: Int64): Unit {
    let g_twid9: Array<Float64> = [
        0.73727734,
        0.79335334,
        0.84339145,
        0.88701083,
        0.92387953,
        0.95371695,
        0.97629601,
        0.99144486,
        0.99904822,
        0.67559021,
        0.60876143,
        0.53729961,
        0.46174861,
        0.38268343,
        0.30070580,
        0.21643961,
        0.13052619,
        0.04361938
    ]

    var j: Int64 = 0
    var gr_off: Int64 = 0
    var ovl_off: Int64 = 0
    while (j < nbands) {
        var co = Array<Float64>(9, repeat: 0.0)
        var si = Array<Float64>(9, repeat: 0.0)
        co[0] = -grbuf[gr_off + 0]
        si[0] = grbuf[gr_off + 17]
        var i: Int64 = 0
        while (i < 4) {
            si[8 - 2 * i] = grbuf[gr_off + 4 * i + 1] - grbuf[gr_off + 4 * i + 2]
            co[1 + 2 * i] = grbuf[gr_off + 4 * i + 1] + grbuf[gr_off + 4 * i + 2]
            si[7 - 2 * i] = grbuf[gr_off + 4 * i + 4] - grbuf[gr_off + 4 * i + 3]
            co[2 + 2 * i] = -(grbuf[gr_off + 4 * i + 3] + grbuf[gr_off + 4 * i + 4])
            i = i + 1
        }
        L3_dct3_9(co)
        L3_dct3_9(si)
        si[1] = -si[1]
        si[3] = -si[3]
        si[5] = -si[5]
        si[7] = -si[7]

        var k: Int64 = 0

        while (k < 8) {
            let ovl = overlap[ovl_off + k]
            let sum = co[k] * g_twid9[9 + k] + si[k] * g_twid9[k]
            overlap[ovl_off + k] = co[k] * g_twid9[k] - si[k] * g_twid9[9 + k]
            grbuf[gr_off + k] = ovl * window[k] - sum * window[9 + k]
            grbuf[gr_off + 17 - k] = ovl * window[9 + k] + sum * window[k]

            k = k + 1
        }

        let ovl = overlap[ovl_off + 8]
        let sum = co[8] * g_twid9[17] + si[8] * g_twid9[8]
        overlap[ovl_off + 8] = co[8] * g_twid9[8] - si[8] * g_twid9[17]
        grbuf[gr_off + 8] = ovl * window[8] - sum * window[17]
        grbuf[gr_off + 17 - 8] = ovl * window[17] + sum * window[8]

        j = j + 1
        gr_off = gr_off + 18
        ovl_off = ovl_off + 9
    }
}

func L3_idct3(x0: Float64, x1: Float64, x2: Float64, dst: Array<Float64>): Unit {
    let m1 = x1 * 0.86602540
    let a1 = x0 - x2 * 0.5
    dst[1] = x0 + x2
    dst[0] = a1 + m1
    dst[2] = a1 - m1
}

func L3_imdct12(x: Array<Float64>, dst: Array<Float64>, overlap: Array<Float64>): Unit {
    if (dst.size < 6 || overlap.size < 6) {
        return
    }
    let g_twid3: Array<Float64> = [0.79335334, 0.92387953, 0.99144486, 0.60876143, 0.38268343, 0.13052619]
    var co = Array<Float64>(3, repeat: 0.0)
    var si = Array<Float64>(3, repeat: 0.0)
    L3_idct3(-x[0], x[6] + x[3], x[12] + x[9], co)
    L3_idct3(x[15], x[12] - x[9], x[6] - x[3], si)
    si[1] = -si[1]

    for (i in Range<Int64>(0, 3, 1, true, true, false)) {
        let ovl = overlap[i]
        let sum = co[i] * g_twid3[3 + i] + si[i] * g_twid3[i]
        overlap[i] = co[i] * g_twid3[i] - si[i] * g_twid3[3 + i]
        dst[i] = ovl * g_twid3[2 - i] - sum * g_twid3[5 - i]
        dst[5 - i] = ovl * g_twid3[5 - i] + sum * g_twid3[2 - i]
    }
}

func L3_imdct_short(grbuf: Array<Float64>, overlap: Array<Float64>, nbands: Int64): Unit {
    var off_g: Int64 = 0
    var off_o: Int64 = 0
    var n = nbands
    while (n > 0) {
        var tmp = Array<Float64>(18, repeat: 0.0)
        grbuf.slice(off_g, 18).copyTo(tmp)

        overlap.slice(off_o, 6).copyTo(grbuf.slice(off_g, 6))

        if (off_g + 6 < grbuf.size && off_o + 6 < overlap.size) {
            L3_imdct12(tmp, grbuf.slice(off_g + 6, min(6, grbuf.size - (off_g + 6))),
                overlap.slice(off_o + 6, min(6, overlap.size - (off_o + 6))))
        }
        if (off_g + 12 < grbuf.size && off_o + 6 < overlap.size) {
            L3_imdct12(tmp.slice(1, 17), grbuf.slice(off_g + 12, min(6, grbuf.size - (off_g + 12))),
                overlap.slice(off_o + 6, min(6, overlap.size - (off_o + 6))))
        }
        if (off_o < overlap.size && off_o + 6 < overlap.size) {
            L3_imdct12(tmp.slice(2, 16), overlap.slice(off_o, min(6, overlap.size - off_o)),
                overlap.slice(off_o + 6, min(6, overlap.size - (off_o + 6))))
        }

        off_g = off_g + 18
        off_o = off_o + 9
        n = n - 1
    }
}

func L3_change_sign_range(grbuf: Array<Float64>, baseOff: Int64, bands: Int64): Unit {
    var b: Int64 = 0
    var base: Int64 = baseOff + 18
    while (b < 32 && b < bands) {
        var i: Int64 = 1
        while (i < 18) {
            let idx = base + i
            if (idx < grbuf.size) {
                grbuf[idx] = -grbuf[idx]
            }
            i = i + 2
        }
        b = b + 2
        base = base + 36
    }
}

// ===== Layer III IMDCT变换 =====
func L3_imdct_gr(grbuf: Array<Float64>, overlap: Array<Float64>, block_type: Int64, n_long_bands: Int64): Unit {
    let g_mdct_window: Array<Array<Float64>> = [
        [0.99904822, 0.99144486, 0.97629601, 0.95371695, 0.92387953, 0.88701083, 0.84339145, 0.79335334, 0.73727734,
            0.04361938, 0.13052619, 0.21643961, 0.30070580, 0.38268343, 0.46174861, 0.53729961, 0.60876143, 0.67559021],
        [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.99144486, 0.92387953, 0.79335334, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.13052619,
            0.38268343, 0.60876143]
    ]

    if (n_long_bands != 0) {
        L3_imdct36(grbuf, overlap, g_mdct_window[0], n_long_bands)
    }
    let rem = 32 - n_long_bands
    if (rem > 0) {
        let grbuf_rest = grbuf.slice(18 * n_long_bands, grbuf.size - 18 * n_long_bands)
        let overlap_rest = overlap.slice(9 * n_long_bands, overlap.size - 9 * n_long_bands)
        if (block_type == SHORT_BLOCK_TYPE) {
            L3_imdct_short(grbuf_rest, overlap_rest, rem)
        } else {
            let win = g_mdct_window[if (block_type == STOP_BLOCK_TYPE) {
                    1
                } else {
                    0
                }]
            L3_imdct36(grbuf_rest, overlap_rest, win, rem)
        }
    }
}

func L3_save_reservoir(h: mp3dec_t, s: mp3dec_scratch_t): Unit {
    let pos = (s.bs.pos + 7) / 8
    var remains = s.bs.limit / 8 - pos
    var start = pos
    if (remains > MAX_BITRESERVOIR_BYTES) {
        start = start + (remains - MAX_BITRESERVOIR_BYTES)
        remains = MAX_BITRESERVOIR_BYTES
    }

    var i: Int64 = 0
    while (i < remains) {
        h.reserv_buf[i] = s.maindata[start + i]
        i = i + 1
    }
    h.reserv = remains
}

func L3_restore_reservoir(h: mp3dec_t, bs: bs_t, s: mp3dec_scratch_t, main_data_begin: Int64): Int64 {
    let frame_bytes = (bs.limit - bs.pos) / 8
    let bytes_have = min(h.reserv, main_data_begin)

    var i: Int64 = 0
    while (i < min(h.reserv, main_data_begin)) {
        s.maindata[i] = h.reserv_buf[max(0, h.reserv - main_data_begin) + i]
        i = i + 1
    }
    i = 0
    while (i < frame_bytes) {
        s.maindata[bytes_have + i] = bs.buf[bs.pos / 8 + i]
        i = i + 1
    }
    bs_init(s.bs, s.maindata, bytes_have + frame_bytes)
    if (h.reserv >= main_data_begin) {
        return 1
    } else {
        return 0
    }
}

// ===== Layer III 解码主函数 =====
func L3_decode(h: mp3dec_t, s: mp3dec_scratch_t, gr_info: Array<L3_gr_info_t>, nch: Int64): Unit {
    var ch: Int64 = 0
    while (ch < nch) {
        let layer3gr_limit = s.bs.pos + gr_info[ch].part_23_length

        L3_decode_scalefactors(h.header, s.ist_pos[ch], s.bs, gr_info[ch], s.scf, ch)

        let grbuf_for_huffman = s.grbuf.slice(576 * ch, s.grbuf.size - 576 * ch)
        L3_huffman(grbuf_for_huffman, s.bs, gr_info[ch], s.scf, layer3gr_limit)

        ch = ch + 1
    }
    if (@HDR_TEST_I_STEREO(h.header)) {
        L3_intensity_stereo(s.grbuf, s.ist_pos[1], gr_info, h.header)
    } else if (@HDR_TEST_MS_STEREO(h.header)) {
        L3_midside_stereo(s.grbuf, 576)
    }
    ch = 0
    while (ch < nch) {
        var aa_bands: Int64 = 31
        var n_long_bands: Int64 = 0
        if (gr_info[ch].mixed_block_flag != 0) {
            n_long_bands = 2
        } else {
            n_long_bands = 0
        }
        if (@HDR_GET_MY_SAMPLE_RATE(h.header) == 2) {
            n_long_bands = n_long_bands << 1
        }

        if (gr_info[ch].n_short_sfb != 0) {
            aa_bands = n_long_bands - 1

            let grbuf_for_reorder = s.grbuf.slice(576 * ch + n_long_bands * 18,
                s.grbuf.size - (576 * ch + n_long_bands * 18))
            L3_reorder(grbuf_for_reorder, s.syn,
                gr_info[ch].sfbtab.slice(gr_info[ch].n_long_sfb, gr_info[ch].sfbtab.size - gr_info[ch].n_long_sfb))
        }

        let grbuf_for_aa = s.grbuf.slice(576 * ch, s.grbuf.size - 576 * ch)
        L3_antialias(grbuf_for_aa, aa_bands)

        let grbuf_slice = s.grbuf.slice(576 * ch, s.grbuf.size - 576 * ch)
        L3_imdct_gr(grbuf_slice, h.mdct_overlap[ch], gr_info[ch].block_type, n_long_bands)

        L3_change_sign_range(s.grbuf, 576 * ch, 32)

        ch = ch + 1
    }
}

// ===== DCT-II变换 =====
func mp3d_DCT_II(grbuf: Array<Float64>, n: Int64): Unit {
    let g_sec: Array<Float64> = [
        10.19000816,
        0.50060302,
        0.50241929,
        3.40760851,
        0.50547093,
        0.52249861,
        2.05778098,
        0.51544732,
        0.56694406,
        1.48416460,
        0.53104258,
        0.64682180,
        1.16943991,
        0.55310392,
        0.78815460,
        0.97256821,
        0.58293498,
        1.06067765,
        0.83934963,
        0.62250412,
        1.72244716,
        0.74453628,
        0.67480832,
        5.10114861
    ]

    var t = Array<Float64>(32, repeat: 0.0)

    var k: Int64 = 0
    while (k < n) {
        for (i in Range<Int64>(0, 8, 1, true, true, false)) {
            let x0 = grbuf[k + i * 18]
            let x1 = grbuf[k + (15 - i) * 18]
            let x2 = grbuf[k + (16 + i) * 18]
            let x3 = grbuf[k + (31 - i) * 18]
            let t0 = x0 + x3
            let t1 = x1 + x2
            let t2 = (x1 - x2) * g_sec[3 * i + 0]
            let t3 = (x0 - x3) * g_sec[3 * i + 1]
            t[0 * 8 + i] = t0 + t1
            t[1 * 8 + i] = (t0 - t1) * g_sec[3 * i + 2]
            t[2 * 8 + i] = t3 + t2
            t[3 * 8 + i] = (t3 - t2) * g_sec[3 * i + 2]
        }

        var ti: Int64 = 0
        while (ti < 4) {
            let x_off = ti * 8
            var x0 = t[x_off + 0]
            var x1 = t[x_off + 1]
            var x2 = t[x_off + 2]
            var x3 = t[x_off + 3]
            var x4 = t[x_off + 4]
            var x5 = t[x_off + 5]
            var x6 = t[x_off + 6]
            var x7 = t[x_off + 7]
            var xt: Float64

            xt = x0 - x7
            x0 = x0 + x7
            x7 = x1 - x6
            x1 = x1 + x6
            x6 = x2 - x5
            x2 = x2 + x5
            x5 = x3 - x4
            x3 = x3 + x4
            x4 = x0 - x3
            x0 = x0 + x3
            x3 = x1 - x2
            x1 = x1 + x2
            t[x_off + 0] = x0 + x1
            t[x_off + 4] = (x0 - x1) * 0.70710677
            x5 = x5 + x6
            x6 = (x6 + x7) * 0.70710677
            x7 = x7 + xt
            x3 = (x3 + x4) * 0.70710677
            x5 = x5 - x7 * 0.198912367
            x7 = x7 + x5 * 0.382683432
            x5 = x5 - x7 * 0.198912367
            x0 = xt - x6
            xt = xt + x6
            t[x_off + 1] = (xt + x7) * 0.50979561
            t[x_off + 2] = (x4 + x3) * 0.54119611
            t[x_off + 3] = (x0 - x5) * 0.60134488
            t[x_off + 5] = (x0 + x5) * 0.89997619
            t[x_off + 6] = (x4 - x3) * 1.30656302
            t[x_off + 7] = (xt - x7) * 2.56291556

            ti = ti + 1
        }

        var y_off: Int64 = k
        var j: Int64 = 0
        while (j < 7) {
            grbuf[y_off + 0 * 18] = t[0 * 8 + j]
            grbuf[y_off + 1 * 18] = t[2 * 8 + j] + t[3 * 8 + j] + t[3 * 8 + j + 1]
            grbuf[y_off + 2 * 18] = t[1 * 8 + j] + t[1 * 8 + j + 1]
            grbuf[y_off + 3 * 18] = t[2 * 8 + j + 1] + t[3 * 8 + j] + t[3 * 8 + j + 1]
            y_off = y_off + 4 * 18
            j = j + 1
        }
        grbuf[y_off + 0 * 18] = t[0 * 8 + 7]
        grbuf[y_off + 1 * 18] = t[2 * 8 + 7] + t[3 * 8 + 7]
        grbuf[y_off + 2 * 18] = t[1 * 8 + 7]
        grbuf[y_off + 3 * 18] = t[3 * 8 + 7]
        k = k + 1
    }
}

func mp3d_synth_pair(pcm: Array<Int16>, nch: Int64, lins: Array<Float64>, z_off: Int64): Unit {
    let Z0 = lins[z_off + 0 * 64]
    let Z1 = lins[z_off + 1 * 64]
    let Z2 = lins[z_off + 2 * 64]
    let Z3 = lins[z_off + 3 * 64]
    let Z4 = lins[z_off + 4 * 64]
    let Z5 = lins[z_off + 5 * 64]
    let Z6 = lins[z_off + 6 * 64]
    let Z7 = lins[z_off + 7 * 64]
    let Z8 = lins[z_off + 8 * 64]
    let Z9 = lins[z_off + 9 * 64]
    let Z10 = lins[z_off + 10 * 64]
    let Z11 = lins[z_off + 11 * 64]
    let Z12 = lins[z_off + 12 * 64]
    let Z13 = lins[z_off + 13 * 64]
    let Z14 = lins[z_off + 14 * 64]

    var a: Float64 = 0.0

    a = (Z14 - Z0) * 29.0
    a = a + (Z1 + Z13) * 213.0
    a = a + (Z12 - Z2) * 459.0
    a = a + (Z3 + Z11) * 2037.0
    a = a + (Z10 - Z4) * 5153.0
    a = a + (Z5 + Z9) * 6574.0
    a = a + (Z8 - Z6) * 37489.0
    a = a + Z7 * 75038.0
    pcm[0] = mp3d_scale_pcm(a)

    let Y0 = lins[z_off + 2 + 0 * 64]
    let Y2 = lins[z_off + 2 + 2 * 64]
    let Y4 = lins[z_off + 2 + 4 * 64]
    let Y6 = lins[z_off + 2 + 6 * 64]
    let Y8 = lins[z_off + 2 + 8 * 64]
    let Y10 = lins[z_off + 2 + 10 * 64]
    let Y12 = lins[z_off + 2 + 12 * 64]
    let Y14 = lins[z_off + 2 + 14 * 64]
    a = Y14 * 104.0
    a = a + Y12 * 1567.0
    a = a + Y10 * 9727.0
    a = a + Y8 * 64019.0
    a = a + Y6 * -9975.0
    a = a + Y4 * -45.0
    a = a + Y2 * 146.0
    a = a + Y0 * -5.0
    pcm[16 * nch] = mp3d_scale_pcm(a)
}

func mp3d_synth(xl: Array<Float64>, dstl: Array<Int16>, nch: Int64, lins: Array<Float64>): Array<Float64> {
    let xr = xl.slice(576 * (nch - 1), xl.size - 576 * (nch - 1))
    let dstr_off = (nch - 1)
    let zlin = 15 * 64
    let g_win: Array<Float64> = [
        -1.0,
        26.0,
        -31.0,
        208.0,
        218.0,
        401.0,
        -519.0,
        2063.0,
        2000.0,
        4788.0,
        -5517.0,
        7134.0,
        5959.0,
        35640.0,
        -39336.0,
        74992.0,
        -1.0,
        24.0,
        -35.0,
        202.0,
        222.0,
        347.0,
        -581.0,
        2080.0,
        1952.0,
        4425.0,
        -5879.0,
        7640.0,
        5288.0,
        33791.0,
        -41176.0,
        74856.0,
        -1.0,
        21.0,
        -38.0,
        196.0,
        225.0,
        294.0,
        -645.0,
        2087.0,
        1893.0,
        4063.0,
        -6237.0,
        8092.0,
        4561.0,
        31947.0,
        -43006.0,
        74630.0,
        -1.0,
        19.0,
        -41.0,
        190.0,
        227.0,
        244.0,
        -711.0,
        2085.0,
        1822.0,
        3705.0,
        -6589.0,
        8492.0,
        3776.0,
        30112.0,
        -44821.0,
        74313.0,
        -1.0,
        17.0,
        -45.0,
        183.0,
        228.0,
        197.0,
        -779.0,
        2075.0,
        1739.0,
        3351.0,
        -6935.0,
        8840.0,
        2935.0,
        28289.0,
        -46617.0,
        73908.0,
        -1.0,
        16.0,
        -49.0,
        176.0,
        228.0,
        153.0,
        -848.0,
        2057.0,
        1644.0,
        3004.0,
        -7271.0,
        9139.0,
        2037.0,
        26482.0,
        -48390.0,
        73415.0,
        -2.0,
        14.0,
        -53.0,
        169.0,
        227.0,
        111.0,
        -919.0,
        2032.0,
        1535.0,
        2663.0,
        -7597.0,
        9389.0,
        1082.0,
        24694.0,
        -50137.0,
        72835.0,
        -2.0,
        13.0,
        -58.0,
        161.0,
        224.0,
        72.0,
        -991.0,
        2001.0,
        1414.0,
        2330.0,
        -7910.0,
        9592.0,
        70.0,
        22929.0,
        -51853.0,
        72169.0,
        -2.0,
        11.0,
        -63.0,
        154.0,
        221.0,
        36.0,
        -1064.0,
        1962.0,
        1280.0,
        2006.0,
        -8209.0,
        9750.0,
        -998.0,
        21189.0,
        -53534.0,
        71420.0,
        -2.0,
        10.0,
        -68.0,
        147.0,
        215.0,
        2.0,
        -1137.0,
        1919.0,
        1131.0,
        1692.0,
        -8491.0,
        9863.0,
        -2122.0,
        19478.0,
        -55178.0,
        70590.0,
        -3.0,
        9.0,
        -73.0,
        139.0,
        208.0,
        -29.0,
        -1210.0,
        1870.0,
        970.0,
        1388.0,
        -8755.0,
        9935.0,
        -3300.0,
        17799.0,
        -56778.0,
        69679.0,
        -3.0,
        8.0,
        -79.0,
        132.0,
        200.0,
        -57.0,
        -1283.0,
        1817.0,
        794.0,
        1095.0,
        -8998.0,
        9966.0,
        -4533.0,
        16155.0,
        -58333.0,
        68692.0,
        -4.0,
        7.0,
        -85.0,
        125.0,
        189.0,
        -83.0,
        -1356.0,
        1759.0,
        605.0,
        814.0,
        -9219.0,
        9959.0,
        -5818.0,
        14548.0,
        -59838.0,
        67629.0,
        -4.0,
        7.0,
        -91.0,
        117.0,
        177.0,
        -106.0,
        -1428.0,
        1698.0,
        402.0,
        545.0,
        -9416.0,
        9916.0,
        -7154.0,
        12980.0,
        -61289.0,
        66494.0,
        -5.0,
        6.0,
        -97.0,
        111.0,
        163.0,
        -127.0,
        -1498.0,
        1634.0,
        185.0,
        288.0,
        -9585.0,
        9838.0,
        -8540.0,
        11455.0,
        -62684.0,
        65290.0
    ]

    lins[zlin + 4 * 15 + 0] = xl[18 * 16]
    lins[zlin + 4 * 15 + 1] = xr[18 * 16]
    lins[zlin + 4 * 15 + 2] = xl[0]
    lins[zlin + 4 * 15 + 3] = xr[0]
    lins[zlin + 4 * 31 + 0] = xl[1 + 18 * 16]
    lins[zlin + 4 * 31 + 1] = xr[1 + 18 * 16]
    lins[zlin + 4 * 31 + 2] = xl[1]
    lins[zlin + 4 * 31 + 3] = xr[1]

    mp3d_synth_pair(dstl, nch, lins, 4 * 15 + 1)
    let dstl_slice1 = dstl.slice(32 * nch, dstl.size - 32 * nch)
    mp3d_synth_pair(dstl_slice1, nch, lins, 4 * 15 + 64 + 1)

    mp3d_synth_pair(dstl, nch, lins, 4 * 15)
    let dstl_slice2 = dstl.slice(32 * nch, dstl.size - 32 * nch)
    mp3d_synth_pair(dstl_slice2, nch, lins, 4 * 15 + 64)

    var i: Int64 = 14
    while (i >= 0) {
        lins[zlin + 4 * i + 0] = xl[18 * (31 - i)]
        lins[zlin + 4 * i + 1] = xr[18 * (31 - i)]
        lins[zlin + 4 * i + 2] = xl[1 + 18 * (31 - i)]
        lins[zlin + 4 * i + 3] = xr[1 + 18 * (31 - i)]
        lins[zlin + 4 * (i + 16) + 0] = xl[1 + 18 * (1 + i)]
        lins[zlin + 4 * (i + 16) + 1] = xr[1 + 18 * (1 + i)]
        lins[zlin + 4 * (i - 16) + 2] = xl[18 * (1 + i)]
        lins[zlin + 4 * (i - 16) + 3] = xr[18 * (1 + i)]
        var a = [0.0, 0.0, 0.0, 0.0]
        var b = [0.0, 0.0, 0.0, 0.0]

        let w_base = (14 - i) * 16
        var k: Int64 = 0
        while (k < 8) {
            let w0 = g_win[w_base + 2 * k + 0]
            let w1 = g_win[w_base + 2 * k + 1]
            let vz = zlin + 4 * i - 64 * k
            let vy = zlin + 4 * i - 64 * (15 - k)

            var j: Int64 = 0
            if (k == 0) {
                while (j < 4) {
                    b[j] = lins[vz + j] * w1 + lins[vy + j] * w0
                    a[j] = lins[vz + j] * w0 - lins[vy + j] * w1
                    j = j + 1
                }
            } else if ((k & 1) == 1) {
                while (j < 4) {
                    b[j] += lins[vz + j] * w1 + lins[vy + j] * w0
                    a[j] += lins[vy + j] * w1 - lins[vz + j] * w0
                    j = j + 1
                }
            } else {
                while (j < 4) {
                    b[j] += lins[vz + j] * w1 + lins[vy + j] * w0
                    a[j] += lins[vz + j] * w0 - lins[vy + j] * w1
                    j = j + 1
                }
            }
            k = k + 1
        }

        dstl[(15 - i) * nch + dstr_off] = mp3d_scale_pcm(a[1])
        dstl[(17 + i) * nch + dstr_off] = mp3d_scale_pcm(b[1])
        dstl[(15 - i) * nch + 0] = mp3d_scale_pcm(a[0])
        dstl[(17 + i) * nch + 0] = mp3d_scale_pcm(b[0])
        dstl[(47 - i) * nch + dstr_off] = mp3d_scale_pcm(a[3])
        dstl[(49 + i) * nch + dstr_off] = mp3d_scale_pcm(b[3])
        dstl[(47 - i) * nch + 0] = mp3d_scale_pcm(a[2])
        dstl[(49 + i) * nch + 0] = mp3d_scale_pcm(b[2])
        i = i - 1
    }

    return lins
}

// ===== PCM合成输出 =====
func mp3d_synth_granule(qmf_state: Array<Float64>, grbuf: Array<Float64>, nbands: Int64, nch: Int64, pcm: Array<Int16>,
    lins: Array<Float64>): Array<Float64> {
    var pcm_size = 1152 * nch
    var pcm_buffer = Array<Int16>(pcm_size, repeat: 0)

    var ch: Int64 = 0
    while (ch < nch) {
        let dct_slice = grbuf.slice(576 * ch, 576 * (ch + 1) - 576 * ch)
        mp3d_DCT_II(dct_slice, nbands)
        ch = ch + 1
    }

    qmf_state.copyTo(lins, 0, 0, 15 * 64)

    var band: Int64 = 0
    while (band < nbands) {
        let grbuf_slice = grbuf.slice(band, grbuf.size - band)
        let pcm_slice = pcm_buffer.slice(32 * nch * band, pcm_buffer.size - 32 * nch * band)
        let lins_slice = lins.slice(band * 64, lins.size - band * 64)
        mp3d_synth(grbuf_slice, pcm_slice, nch, lins_slice)

        band = band + 2
    }

    let copy_size = min(pcm_size, pcm.size)
    pcm_buffer.copyTo(pcm, 0, 0, copy_size)

    if (nch == 1) {
        for (qi in Range<Int64>(0, 15 * 64, 2, true, true, false)) {
            qmf_state[qi] = lins[nbands * 64 + qi]
        }
    } else {
        for (qi in Range<Int64>(0, 15 * 64, 1, true, true, false)) {
            qmf_state[qi] = lins[nbands * 64 + qi]
        }
    }

    return qmf_state
}

func mp3d_match_frame(hdr: Array<UInt8>, mp3_bytes: Int64, frame_bytes: Int64): Int64 {
    var i: Int64 = 0
    var nmatch: Int64 = 0
    while (nmatch < MAX_FRAME_SYNC_MATCHES) {
        i = i + hdr_frame_bytes(hdr.slice(i, mp3_bytes - i), frame_bytes) + hdr_padding(hdr.slice(i, mp3_bytes - i))
        if (i + HDR_SIZE > mp3_bytes) {
            if (nmatch > 0) {
                return 1
            } else {
                return 0
            }
        }
        if (!hdr_compare(hdr, hdr.slice(i, mp3_bytes - i))) {
            return 0
        }
        nmatch = nmatch + 1
    }
    return 1
}

struct FindFrameResult {
    var offset: Int64 = 0
    var frame_bytes: Int64 = 0
    var free_format_bytes: Int64 = 0
}

func mp3d_find_frame2(mp3: Array<UInt8>, mp3_bytes: Int64, free_format_bytes_in: Int64): FindFrameResult {
    var res = FindFrameResult()
    res.free_format_bytes = free_format_bytes_in
    var i: Int64 = 0
    var k: Int64 = 0
    var mp3p = mp3
    while (i < mp3_bytes - HDR_SIZE) {
        if (hdr_valid(mp3p)) {
            var frame_bytes = hdr_frame_bytes(mp3p, res.free_format_bytes)
            var frame_and_padding = frame_bytes + hdr_padding(mp3p)
            k = HDR_SIZE
            while (frame_bytes == 0 && k < MAX_FREE_FORMAT_FRAME_SIZE && i + 2 * k < mp3_bytes - HDR_SIZE) {
                if (hdr_compare(mp3p, mp3p.slice(k, (mp3_bytes - i) - k))) {
                    let fb = k - hdr_padding(mp3p)
                    let nextfb = fb + hdr_padding(mp3p.slice(k, (mp3_bytes - i) - k))
                    if (i + k + nextfb + HDR_SIZE > mp3_bytes ||
                        !hdr_compare(mp3p, mp3p.slice(k + nextfb, (mp3_bytes - i) - (k + nextfb)))) {
                        k = k + 1
                        continue
                    }
                    frame_and_padding = k
                    frame_bytes = fb
                    res.free_format_bytes = fb
                }
                k = k + 1
            }
            if ((frame_bytes != 0 && i + frame_and_padding <= mp3_bytes &&
                mp3d_match_frame(mp3p, mp3_bytes - i, frame_bytes) != 0) || (i == 0 && frame_and_padding == mp3_bytes)) {
                res.offset = i
                res.frame_bytes = frame_and_padding
                return res
            }
            res.free_format_bytes = 0
        }
        i = i + 1
        mp3p = mp3p.slice(1, mp3p.size - 1)
    }
    res.offset = i
    res.frame_bytes = 0
    return res
}
