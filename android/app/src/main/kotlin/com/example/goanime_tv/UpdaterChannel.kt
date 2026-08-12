package com.example.goanime_tv

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.StatFs
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Canal nativo do auto-update.
///
/// - `installApk(path)` — sessão `PackageInstaller` (commit atômico, sem wipe)
///   com resultado voltando por `installResult` via [UpdateResultReceiver].
/// - `getFreeBytes()` — espaço livre do volume externo (pre-flight D5-b).
/// - `openInstaller(path)` — fallback `ACTION_VIEW` com FileProvider.
class UpdaterChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private var resultReceiver: UpdateResultReceiver? = null
    private var resultRegistered = false

    fun register() {
        channel.setMethodCallHandler(this)
        ensureReceiver()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installApk" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_args", "path ausente", null)
                    return
                }
                installApk(File(path), result)
            }
            "openInstaller" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_args", "path ausente", null)
                    return
                }
                openSystemInstaller(File(path), result)
            }
            "getFreeBytes" -> result.success(freeBytes())
            else -> result.notImplemented()
        }
    }

    /// Inicia a instalação. `result.success(true)` significa "commit iniciado"
    /// — o desfecho real chega por `installResult` (o commit é assíncrono e o
    /// SO pode pedir confirmação antes).
    private fun installApk(file: File, result: MethodChannel.Result) {
        if (!file.exists()) {
            result.error("no_file", "APK baixado não encontrado em disco", null)
            return
        }
        try {
            val installer = context.packageManager.packageInstaller
            val params =
                PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            params.setSize(file.length())
            val sessionId = installer.createSession(params)
            val session = installer.openSession(sessionId)
            try {
                session.openWrite("goanime", 0, file.length()).use { sink ->
                    file.inputStream().use { ins ->
                        val buf = ByteArray(DEFAULT_BUFFER_SIZE)
                        var n = ins.read(buf)
                        while (n >= 0) {
                            sink.write(buf, 0, n)
                            n = ins.read(buf)
                        }
                    }
                }
                session.commit(resultIntent().intentSender)
            } finally {
                session.close()
            }
            result.success(true)
        } catch (e: Exception) {
            channel.invokeMethod(
                "installResult",
                mapOf("success" to false, "message" to friendlyMessage(e)),
            )
            result.error("install_failed", e.message, null)
        }
    }

    private fun openSystemInstaller(file: File, result: MethodChannel.Result) {
        try {
            val uri = FileProvider.getUriForFile(
                context, "${context.packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("no_activity", "Nenhum instalador disponível", null)
        }
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

    private fun resultIntent(): PendingIntent {
        val intent =
            Intent(context, UpdateResultReceiver::class.java)
                .setAction(UpdateResultReceiver.ACTION_RESULT)
        return PendingIntent.getBroadcast(
            context,
            1001,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
    }

    /// Registrado enquanto a Activity vive. `singleTop` + registro único em
    /// `configureFlutterEngine` evita duplicatas (D6). O commit do
    /// PackageInstaller costuma encerrar o processo: neste caso o receiver
    /// morre junto e o usuário simplesmente reabre o app (nova versão).
    private fun ensureReceiver() {
        if (resultRegistered) return
        resultRegistered = true
        resultReceiver = UpdateResultReceiver { success, message ->
            channel.invokeMethod(
                "installResult",
                mapOf("success" to success, "message" to message),
            )
        }
        context.registerReceiver(
            resultReceiver,
            UpdateResultReceiver.filter(),
            Context.RECEIVER_EXPORTED,
        )
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/updater"
    }

    class UpdateResultReceiver(
        private val onResult: (Boolean, String?) -> Unit,
    ) : BroadcastReceiver() {

        override fun onReceive(context: Context, intent: Intent) {
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
            when (status) {
                // Confirmação do sistema em andamento — o resultado final vem depois.
                PackageInstaller.STATUS_PENDING_USER_ACTION -> return
                PackageInstaller.STATUS_SUCCESS -> onResult(true, null)
                else -> onResult(false, messageFor(status))
            }
        }

        companion object {
            const val ACTION_RESULT = "com.example.goanime_tv.UPDATE_RESULT"

            fun filter() =
                android.content.IntentFilter(ACTION_RESULT)
        }
    }
}

private fun messageFor(status: Int): String = when (status) {
    PackageInstaller.STATUS_FAILURE_ABORTED ->
        "A instalação foi cancelada na tela do Android."
    PackageInstaller.STATUS_FAILURE_BLOCKED ->
        "Instalação bloqueada. Habilite \"Fontes desconhecidas\" e tente de novo."
    PackageInstaller.STATUS_FAILURE_CONFLICT -> "Assinatura divergente: esta versão " +
        "não pode atualizar a instalada sem desinstalar (perderia seus dados)."
    PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
        "O APK é incompatível com este dispositivo."
    PackageInstaller.STATUS_FAILURE_INVALID -> "O APK está inválido ou corrompido."
    PackageInstaller.STATUS_FAILURE_STORAGE ->
        "Espaço em disco insuficiente para instalar."
    else -> "A instalação falhou com o status $status."
}

private fun friendlyMessage(e: Exception): String = when {
    e.message?.lowercase()?.contains("sign") == true -> "Assinatura divergente: a " +
        "versão instalada e a nova usam chaves diferentes."
    e.message?.lowercase()?.contains("space") == true -> "Espaço em disco insuficiente."
    else -> e.message ?: "Falha ao iniciar a instalação."
}