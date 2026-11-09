package com.example.goanime_tv

import android.app.ActivityManager
import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import android.os.Process
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Perfil de hardware do aparelho (canal `goanime_tv/hardware`).
///
/// O modo lite antigo olhava só `MemAvailable`: um Fire Stick (A53 @1,7 GHz)
/// e um projetor H713 (A53 @1,3 GHz) caíam no MESMO balde só por terem 1 GB
/// de RAM, apesar do primeiro tocar HD com folga e o segundo não. Este canal
/// expõe CPU (núcleos/clock/ABI/NEON) e decoders de vídeo de hardware para o
/// Dart separar "pouca RAM" de "CPU/decoder insuficiente".
///
/// Tudo é fail-soft: campo que o aparelho não expõe volta nulo/zero e o Dart
/// decide com o que sobrou.
class HardwareChannel(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    fun register() {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "profile" -> result.success(profile())
            else -> result.notImplemented()
        }
    }

    private fun profile(): Map<String, Any?> {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val mi = ActivityManager.MemoryInfo()
        runCatching { am?.getMemoryInfo(mi) }
        val features = cpuFeatures()
        return mapOf(
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "hardware" to Build.HARDWARE,
            "androidRelease" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "is64Bit" to is64Bit(),
            "neon" to (features.contains("asimd") || features.contains("neon")),
            "cores" to Runtime.getRuntime().availableProcessors(),
            "cpuMaxFreqMhz" to maxCpuFreqMhz(),
            "totalRamMb" to (mi.totalMem / MB),
            "availableRamMb" to (mi.availMem / MB),
            "lowRamDevice" to (am?.isLowRamDevice ?: false),
            "memoryClassMb" to (am?.memoryClass ?: 0),
            "codecs" to codecMap(),
        )
    }

    private fun is64Bit(): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Process.is64Bit()
        } else {
            Build.SUPPORTED_64_BIT_ABIS.isNotEmpty()
        }
    } catch (_: Throwable) {
        Build.SUPPORTED_64_BIT_ABIS.isNotEmpty()
    }

    /// Lê a linha `Features` do /proc/cpuinfo. Em arm64 o NEON aparece como
    /// `asimd`; em armv7 como `neon`.
    private fun cpuFeatures(): Set<String> = try {
        val line = File("/proc/cpuinfo").readLines()
            .firstOrNull { it.trimStart().startsWith("Features") }
        line?.substringAfter(':')?.trim()
            ?.split(Regex("\\s+"))
            ?.filter { it.isNotEmpty() }
            ?.toSet()
            ?: emptySet()
    } catch (_: Throwable) {
        emptySet()
    }

    /// Maior clock entre os núcleos, em MHz. O `/sys` pode negar leitura em
    /// alguns firmwares — nesse caso devolve null (o Dart usa o benchmark).
    private fun maxCpuFreqMhz(): Int? {
        var maxKhz = 0L
        for (i in 0 until 32) {
            val base = "/sys/devices/system/cpu/cpu$i/cpufreq"
            val khz = readLong("$base/cpuinfo_max_freq")
                ?: readLong("$base/scaling_max_freq")
                ?: continue
            if (khz > maxKhz) maxKhz = khz
        }
        return if (maxKhz > 0) (maxKhz / 1000L).toInt() else null
    }

    private fun readLong(path: String): Long? = try {
        File(path).readText().trim().toLongOrNull()
    } catch (_: Throwable) {
        null
    }

    /// Mapa mime → { hardware, maxWidth, maxHeight }.
    ///
    /// A resolução considera só decoders de HARDWARE quando existe algum:
    /// um decoder de software 4K não torna o aparelho capaz de tocar 4K.
    /// Sem nenhum decoder de hardware, reporta o melhor de software mesmo
    /// (`hardware=false`) para o Dart saber que aquele codec não tem aceleração.
    private fun codecMap(): Map<String, Map<String, Any>> {
        val mimes = listOf(MIME_H264, MIME_HEVC, MIME_VP9, MIME_AV1)
        val out = mutableMapOf<String, Map<String, Any>>()
        val infos = try {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
        } catch (_: Throwable) {
            return out
        }
        for (mime in mimes) {
            var hasHw = false
            var hwW = 0
            var hwH = 0
            var anyW = 0
            var anyH = 0
            for (info in infos) {
                if (info.isEncoder) continue
                if (!info.supportedTypes.any { it.equals(mime, ignoreCase = true) }) continue
                val caps = try {
                    info.getCapabilitiesForType(mime).videoCapabilities
                } catch (_: Throwable) {
                    null
                }
                val (w, h) = maxSize(caps)
                if (w * h > anyW * anyH) {
                    anyW = w
                    anyH = h
                }
                if (isHardware(info)) {
                    hasHw = true
                    if (w * h > hwW * hwH) {
                        hwW = w
                        hwH = h
                    }
                }
            }
            if (hasHw) {
                // Alguns decoders não expõem VideoCapabilities: assume 1080p.
                if (hwW == 0) {
                    hwW = 1920
                    hwH = 1080
                }
                out[mime] = mapOf(
                    "hardware" to true,
                    "maxWidth" to hwW,
                    "maxHeight" to hwH,
                )
            } else if (anyW > 0) {
                out[mime] = mapOf(
                    "hardware" to false,
                    "maxWidth" to anyW,
                    "maxHeight" to anyH,
                )
            }
        }
        return out
    }

    private fun maxSize(caps: MediaCodecInfo.VideoCapabilities?): Pair<Int, Int> {
        if (caps == null) return 0 to 0
        var bestW = 0
        var bestH = 0
        for ((w, h) in CODEC_SIZES) {
            val ok = try {
                caps.isSizeSupported(w, h)
            } catch (_: Throwable) {
                false
            }
            if (ok && w * h > bestW * bestH) {
                bestW = w
                bestH = h
            }
        }
        return bestW to bestH
    }

    /// API 29+ responde de verdade; antes disso o nome é a única pista.
    private fun isHardware(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return try {
                info.isHardwareAccelerated
            } catch (_: Throwable) {
                false
            }
        }
        val n = info.name.lowercase()
        if (n.contains("software") || n.contains("google") || n.contains("android")) {
            return false
        }
        return n.startsWith("omx.") || n.startsWith("c2.")
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/hardware"

        private const val MB = 1024L * 1024L
        private const val MIME_H264 = "video/avc"
        private const val MIME_HEVC = "video/hevc"
        private const val MIME_VP9 = "video/x-vnd.on2.vp9"
        private const val MIME_AV1 = "video/av01"

        private val CODEC_SIZES = listOf(
            3840 to 2160,
            2560 to 1440,
            1920 to 1080,
            1280 to 720,
        )
    }
}
