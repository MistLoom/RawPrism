package config_io.crypto

import std.collection.ArrayList
import std.random.Random
import stdx.crypto.digest.*
import stdx.encoding.base64.{fromBase64String, toBase64String}

/// 本地密钥封装：SHA256 派生流密钥（分块 XOR）+ HMAC-SHA256（Encrypt-then-MAC），依赖 stdx 摘要实现，无需 OpenSSL。
/// 密文格式：nonce(16) || ciphertext || mac(32)，整体 Base64，前缀 ENC:v1:
public class SecretSealer {
    private let key32: Array<UInt8>
    private static let NONCE_LEN: Int64 = 16
    private static let MAC_LEN: Int64 = 32
    private static let KEY_LEN: Int64 = 32
    private static let BLOCK: Int64 = 32

    public init(masterKey: Array<UInt8>) {
        if (masterKey.size != KEY_LEN) {
            throw Exception("SecretSealer 需要 32 字节密钥")
        }
        this.key32 = masterKey
    }

    public func sealString(plaintext: String): String {
        let pt = plaintext.toArray()
        let sealed = sealBytes(pt)
        "ENC:v1:" + toBase64String(sealed)
    }

    public func openString(stored: String): String {
        if (!stored.startsWith("ENC:v1:")) {
            return stored
        }
        let b64 = stored[7..stored.size]
        let raw = match (fromBase64String(b64)) {
            case Some(bytes) => bytes
            case None => throw Exception("Base64 解码失败")
        }
        let pt = openBytes(raw)
        String.fromUtf8(pt)
    }

    public func isSealedValue(stored: String): Bool {
        stored.startsWith("ENC:v1:")
    }

    private func sealBytes(plaintext: Array<UInt8>): Array<UInt8> {
        let nonce = randomBytes(NONCE_LEN)
        let macKey = deriveMacKey()
        let stream = xorKeystream(nonce, plaintext.size)
        let ct = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i < plaintext.size) {
            ct.add(plaintext[i] ^ stream[i])
            i = i + 1
        }
        let ctArr = ct.toArray()
        let macInput = ArrayList<UInt8>()
        appendAll(macInput, nonce)
        appendAll(macInput, ctArr)
        let mac = hmacSha256(macKey, macInput.toArray())
        let out = ArrayList<UInt8>()
        appendAll(out, nonce)
        appendAll(out, ctArr)
        appendAll(out, mac)
        out.toArray()
    }

    private func openBytes(sealed: Array<UInt8>): Array<UInt8> {
        if (sealed.size < NONCE_LEN + MAC_LEN) {
            throw Exception("密文长度无效")
        }
        let nonce = sealed[0..NONCE_LEN]
        let macStart = sealed.size - MAC_LEN
        let ct = sealed[NONCE_LEN..macStart]
        let macExpected = sealed[macStart..sealed.size]
        let macKey = deriveMacKey()
        let macInput = ArrayList<UInt8>()
        appendAll(macInput, nonce)
        appendAll(macInput, ct)
        let macActual = hmacSha256(macKey, macInput.toArray())
        if (!constantTimeEq(macActual, macExpected)) {
            throw Exception("MAC 校验失败")
        }
        let stream = xorKeystream(nonce, ct.size)
        let pt = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i < ct.size) {
            pt.add(ct[i] ^ stream[i])
            i = i + 1
        }
        pt.toArray()
    }

    private func deriveMacKey(): Array<UInt8> {
        // 与历史密文兼容，勿改标签串
        let label = "AIepoch:mac:v1".toArray()
        let h = SHA256()
        h.write(key32)
        h.write(label)
        finishU8(h)
    }

    private func xorKeystream(nonce: Array<UInt8>, nbytes: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        var counter: Int64 = 0
        while (out.size < nbytes) {
            let block = sha256Block(counter, nonce)
            var j: Int64 = 0
            while (j < BLOCK && out.size < nbytes) {
                out.add(block[j])
                j = j + 1
            }
            counter = counter + 1
        }
        out.toArray()
    }

    private func sha256Block(counter: Int64, nonce: Array<UInt8>): Array<UInt8> {
        let h = SHA256()
        h.write(key32)
        h.write(nonce)
        h.write(encodeBe64(counter))
        finishU8(h)
    }

    private func encodeBe64(v: Int64): Array<UInt8> {
        [
            UInt8((v >> 56) & 0xff),
            UInt8((v >> 48) & 0xff),
            UInt8((v >> 40) & 0xff),
            UInt8((v >> 32) & 0xff),
            UInt8((v >> 24) & 0xff),
            UInt8((v >> 16) & 0xff),
            UInt8((v >> 8) & 0xff),
            UInt8(v & 0xff)
        ]
    }

    private func hmacSha256(key: Array<UInt8>, data: Array<UInt8>): Array<UInt8> {
        let hm = HMAC(key, { => SHA256()})
        hm.write(data)
        finishU8(hm)
    }

    private func randomBytes(n: Int64): Array<UInt8> {
        let r = Random()
        let a = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i < n) {
            a.add(r.nextUInt8())
            i = i + 1
        }
        a.toArray()
    }

    private func appendAll(dst: ArrayList<UInt8>, src: Array<UInt8>): Unit {
        for (b in src) {
            dst.add(b)
        }
    }

    private func constantTimeEq(a: Array<UInt8>, b: Array<UInt8>): Bool {
        if (a.size != b.size) {
            return false
        }
        var diff: UInt8 = 0u8
        var i: Int64 = 0
        while (i < a.size) {
            diff = diff | (a[i] ^ b[i])
            i = i + 1
        }
        diff == 0u8
    }
}

private func finishU8(d: SHA256): Array<UInt8> {
    return d.finish()
}

private func finishU8(d: HMAC): Array<UInt8> {
    return d.finish()
}
