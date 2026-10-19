macro package minimp3_cj.macros

import std.ast.*

// 头部解析宏
public macro HDR_IS_MONO(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[3]) & 0xC0) == 0xC0)
    )
}

public macro HDR_IS_FREE_FORMAT(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[2]) & 0xF0) == 0)
    )
}

public macro HDR_IS_CRC(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        !((Int64($(hExpr)[1]) & 1) == 1)
    )
}

public macro HDR_TEST_PADDING(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[2]) & 0x2) != 0)
    )
}

public macro HDR_TEST_MPEG1(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[1]) & 0x8) != 0)
    )
}

public macro HDR_TEST_NOT_MPEG25(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[1]) & 0x10) != 0)
    )
}

public macro HDR_TEST_I_STEREO(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[3]) & 0x10) != 0)
    )
}

public macro HDR_TEST_MS_STEREO(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[3]) & 0x20) != 0)
    )
}

public macro HDR_GET_STEREO_MODE(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[3]) >> 6) & 3)
    )
}

public macro HDR_GET_STEREO_MODE_EXT(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[3]) >> 4) & 3)
    )
}

public macro HDR_GET_LAYER(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[1]) >> 1) & 3)
    )
}

public macro HDR_GET_BITRATE(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[2]) >> 4) & 15)
    )
}

public macro HDR_GET_SAMPLE_RATE(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        (((Int64($(hExpr)[2]) >> 2) & 3))
    )
}

public macro HDR_GET_MY_SAMPLE_RATE(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        (((Int64($(hExpr)[2]) >> 2) & 3)) + (((Int64($(hExpr)[1]) >> 3) & 1) + ((Int64($(hExpr)[1]) >> 4) & 1)) * 3
    )
}

public macro HDR_IS_FRAME_576(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[1]) & 14) == 2)
    )
}

public macro HDR_IS_LAYER_1(input: Tokens): Tokens {
    let (hExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((Int64($(hExpr)[1]) & 6) == 6)
    )
}

// 位流操作宏
public macro PEEK_BITS(input: Tokens): Tokens {
    let (nExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        ((bs_cache & 0xFFFFFFFF) >> (32 - $(nExpr))) & ((1 << $(nExpr)) - 1)
    )
}

public macro FLUSH_BITS(input: Tokens): Tokens {
    let (nExpr, _) = parseExprFragment(input, startFrom: 0)
    return quote(
        bs_cache = (bs_cache << (($(nExpr)) & 31)) & 0xFFFFFFFF; bs_sh = bs_sh + ($(nExpr))
    )
}

public macro CHECK_BITS(_: Tokens): Tokens {
    return quote(
        while (bs_sh >= 0) { 
            if (next_index >= bs.buf.size) {
                break
            }
            bs_cache = (bs_cache | (Int64(bs.buf[next_index]) << bs_sh)) & 0xFFFFFFFF
            next_index = next_index + 1
            bs_sh = bs_sh - 8 
        }
    )
}

public macro BSPOS(_: Tokens): Tokens {
    return quote(
        next_index * 8 - 24 + bs_sh
    )
}

