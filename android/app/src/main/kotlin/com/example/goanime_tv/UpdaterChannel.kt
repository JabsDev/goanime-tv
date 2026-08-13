package com.example.goanime_tv

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.StatFs
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Canal nativo do auto-update.
///
/// Instala via `ACTION_INSTALL_PACKAGE` (FileProvider + EXTRA_RETURN_RESULT),
/// delegando a confirmação ao instalador do sistema. Este é o caminho
/// primário de propósito: a sessão `PackageInstaller` (commit + confirmação
/// via `STATUS_PENDING_USER_ACTION`) é quebrada em MIUI/HyperOS (Xiaomi) e
/// Fire OS — a tela de confirmação nunca aparece e o fluxo fica preso em
/// "Instalando...". `ACTION_INSTALL_PACKAGE` é o mesmo caminho usado por
/// gerenciadores de arquivos/navegadores, que mostra a confirmação de forma
/// confiável em todas as ROMs.
///
/// O resultado da instalação volta por `onActivityResult` da Activity e é
/// repassado ao Dart por `installResult`. No caso de sucesso o processo é
/// encerrado pelo sistema durante a instalação; o usuário reabre o app na
/// versão nova.
class UpdaterChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val context = activity.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    fun register() {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installApk" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_args", "path ausente", null)
                    return
                }
                launchSystemInstaller(File(path), result)
            }
            "openInstaller" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_args", "path ausente", null)
                    return
                }
                launchSystemInstaller(File(path), result)
            }
            "getFreeBytes" -> result.success(freeBytes())
            else -> result.notImplemented()
        }
    }

    /// Abre o instalador do sistema (`ACTION_INSTALL_PACKAGE`) para o APK.
    /// `result.success(true)` significa "instalador aberto" — o desfecho real
    /// chega por `onActivityResult` → `installResult`.
    private fun launchSystemInstaller(file: File, result: MethodChannel.Result) {
        if (!file.exists()) {
            result.error("no_file", "APK baixado não encontrado em disco", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(
                context, "${context.packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_INSTALL_PACKAGE)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                .putExtra(Intent.EXTRA_RETURN_RESULT, true)
            activity.startActivityForResult(intent, REQUEST_INSTALL)
            result.success(true)
        } catch (e: Exception) {
            result.error("no_activity", "Nenhum instalador disponível", null)
        }
    }

    /// Recebido da Activity (`MainActivity.onActivityResult`) quando o
    /// instalador do sistema termina. Repassa o desfecho ao Dart.
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_INSTALL) return
        if (resultCode == Activity.RESULT_OK) {
            channel.invokeMethod(
                "installResult",
                mapOf("success" to true, "message" to null),
            )
            return
        }
        if (resultCode == Activity.RESULT_CANCELED) {
            channel.invokeMethod(
                "installResult",
                mapOf(
                    "success" to false,
                    "message" to "A instalação foi cancelada na tela do Android.",
                ),
            )
            return
        }
        channel.invokeMethod(
            "installResult",
            mapOf("success" to false, "message" to installResultMessage(resultCode)),
        )
    }

    private fun freeBytes(): Long {
        return try {
            val ext = context.getExternalFilesDir(null)
                ?: return Long.MAX_VALUE
            StatFs(ext.path).availableBytes
        } catch (e: Exception) {
            Long.MAX_VALUE
        }
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/updater"
        private const val REQUEST_INSTALL = 1102
    }
}

private fun installResultMessage(resultCode: Int): String = when (resultCode) {
    // O instalador do sistema devolve RESULT_FIRST_USER em qualquer falha; o
    // motivo detalhado ia em `Intent.EXTRA_INSTALL_RESULT` (ocultado na API
    // 36). Sem o extra, a mensagem é genérica — o diálogo do Dart já oferece
    // "Abrir instalador do sistema" e "Tentar novamente" como ações.
    else -> "A instalação falhou na tela do Android."
}
