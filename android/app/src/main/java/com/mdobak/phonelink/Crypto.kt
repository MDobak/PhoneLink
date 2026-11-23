package com.mdobak.phonelink

import java.io.ByteArrayOutputStream
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Crypto for the link. The Mac side (Crypto.swift) must stay identical:
 *  - pairing: ECDH on P-256, keys sent as X.509 SubjectPublicKeyInfo (DER)
 *  - pairKey = HKDF-SHA256(shared, nonceMac || noncePhone, "phonelink pair v1")
 *  - SAS     = first 4 bytes of HKDF(shared, salt, "phonelink sas v1") mod 1e6
 *  - session = HKDF(pairKey, salt, "m2p" / "p2m"), AES-256-GCM, nonce = 4 zero bytes + 8-byte counter
 */
object Crypto {
    private val rng = SecureRandom()

    fun random(n: Int) = ByteArray(n).also { rng.nextBytes(it) }

    fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: String, len: Int): ByteArray {
        val prk = hmac(salt, ikm)
        val out = ByteArrayOutputStream()
        var t = ByteArray(0)
        var i = 1
        while (out.size() < len) {
            t = hmac(prk, t + info.toByteArray() + byteArrayOf(i.toByte()))
            out.write(t)
            i++
        }
        return out.toByteArray().copyOf(len)
    }

    fun newKeyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply {
        initialize(ECGenParameterSpec("secp256r1"))
    }.generateKeyPair()

    fun ecdh(priv: PrivateKey, peerSpki: ByteArray): ByteArray {
        val pub = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(peerSpki))
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(priv)
        ka.doPhase(pub, true)
        return ka.generateSecret()
    }

    fun sas(shared: ByteArray, salt: ByteArray): String {
        val b = hkdf(shared, salt, "phonelink sas v1", 4)
        val v = ((b[0].toLong() and 0xff) shl 24) or ((b[1].toLong() and 0xff) shl 16) or
            ((b[2].toLong() and 0xff) shl 8) or (b[3].toLong() and 0xff)
        return "%06d".format(v % 1_000_000)
    }
}

/** One direction of an encrypted stream. The counter makes replayed or reordered frames fail. */
class FrameCipher(key: ByteArray) {
    private val spec = SecretKeySpec(key, "AES")
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    private var counter = 0L

    private fun nonce(): ByteArray {
        val n = ByteArray(12)
        var c = counter++
        for (i in 11 downTo 4) { n[i] = (c and 0xff).toByte(); c = c shr 8 }
        return n
    }

    fun seal(plain: ByteArray): ByteArray {
        cipher.init(Cipher.ENCRYPT_MODE, spec, GCMParameterSpec(128, nonce()))
        return cipher.doFinal(plain)
    }

    fun open(sealed: ByteArray): ByteArray {
        cipher.init(Cipher.DECRYPT_MODE, spec, GCMParameterSpec(128, nonce()))
        return cipher.doFinal(sealed)
    }
}
