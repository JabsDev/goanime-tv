package com.example.goanime_tv

import android.media.MediaCodecList
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Canal de capacidades de decodificação do aparelho.
///
/// Uso atual: episódios AnimeFire só em AV1 num box sem decoder AV1 tocam
/// áudio sobre tela preta — o player consulta `supportsAv1` e mostra um
/// aviso honesto (sugere outra fonte H.264) em vez da tela preta.
/// Erro interno responde `true` (fail-open: melhor tentar tocar).
class CodecsChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    fun register() {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "supportsAv1" -> result.success(supportsMime("video/av01"))
            else -> result.notImplemented()
        }
    }

    private fun supportsMime(mime: String): Boolean {
        return try {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any {
                !it.isEncoder && it.supportedTypes.contains(mime)
            }
        } catch (_: Exception) {
            true
        }
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/codecs"
    }
}
