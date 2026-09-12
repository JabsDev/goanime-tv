package com.example.goanime_tv

import android.app.UiModeManager
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Expõe UiModeManager.getCurrentModeType ao Dart (canal `goanime_tv/uimode`).
/// Erro interno responde null (Dart faz fallback para celular).
class UiModeChannel(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    fun register() {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getUiModeType" -> result.success(currentModeType())
            else -> result.notImplemented()
        }
    }

    private fun currentModeType(): Int? {
        return try {
            val uiMode = context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
            uiMode.currentModeType
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/uimode"
    }
}
