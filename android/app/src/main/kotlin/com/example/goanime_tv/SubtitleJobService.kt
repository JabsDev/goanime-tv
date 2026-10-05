package com.example.goanime_tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Foreground service (tipo `dataSync`) do job de legenda IA.
///
/// O trabalho pesado continua no Dart (SubtitleJobManager) — o serviço não
/// conhece o pipeline; recebe estados pelo [SubtitleJobChannel] e serve para:
/// 1. **Prioridade de processo**: com `startForeground` o SO não mata/para o
///    processo quando o usuário sai do app (o isolate Dart segue rodando na
///    engine cacheada de [GoAnimeApp]).
/// 2. **Wake lock parcial**: mantém a CPU acordada com a tela apagada
///    (transcrição/tradução são trabalho de CPU; sem wake lock o aparelho
///    suspende e o job arrasta).
/// 3. **Notificação de progresso** (fase/detalhe/%) com ação "Cancelar" que
///    volta ao Dart via [JobBridge].
///
/// `stopWithTask="false"` no manifesto: deslizar o app dos recentes NÃO para
/// o serviço — é exatamente o caso de uso (fechar o app e continuar gerando).
class SubtitleJobService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    @Volatile private var stopping = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        stopping = false
        ensureChannel(this)
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG)
            .apply {
                setReferenceCounted(false)
                // Teto de 6h: um episódio nunca passa disso; evita wakelock
                // eterno se algo travar sem parar o serviço.
                acquire(MAX_WAKE_MS)
            }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForegroundAndSelf()
                return START_NOT_STICKY
            }
            ACTION_CANCEL -> {
                // Botão da notificação: cancela o job no Dart (o serviço segue
                // vivo até o Dart reportar o estado terminal "cancelado").
                JobBridge.postToDart("cancelRequested", null)
                return START_STICKY
            }
            null -> {
                // START_STICKY após morte do processo: o Dart reabriu do zero
                // (o job file em disco vira dica de crash ao abrir o app).
                // Não há job vivo para anunciar — encerra honestamente.
                postFinal(
                    "Geração da legenda interrompida",
                    "Reabra o app para tentar de novo",
                    success = false,
                )
                stopForegroundAndSelf()
                return START_NOT_STICKY
            }
            else -> {
                startAsForeground(
                    intent.getStringExtra(EXTRA_MESSAGE) ?: "Gerando legenda…",
                    intent.getStringExtra(EXTRA_DETAIL) ?: "",
                    intent.getDoubleExtra(EXTRA_PROGRESS, 0.0),
                )
                return START_STICKY
            }
        }
    }

    fun updateNotification(message: String, detail: String, progress: Double) {
        if (stopping) return
        post(ProgressNotification.build(this, message, detail, progress, ongoing = true))
    }

    /// Notificação final (Pronto/Falhou/Cancelado) e encerra o foreground.
    /// A notificação final fica no shade (não-ongoing) p/ o usuário que estava
    /// fora do app; o processo volta a prioridade normal em seguida.
    fun postFinalAndStop(message: String, detail: String, success: Boolean) {
        postFinal(message, detail, success)
        stopForegroundAndSelf()
    }

    fun stopForegroundAndSelf() {
        stopping = true
        runCatching { ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE) }
        releaseWakeLock()
        stopSelf()
    }

    override fun onDestroy() {
        instance = null
        releaseWakeLock()
        super.onDestroy()
    }

    private fun startAsForeground(message: String, detail: String, progress: Double) {
        val notif = ProgressNotification.build(this, message, detail, progress, ongoing = true)
        val type =
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        try {
            ServiceCompat.startForeground(this, NOTIF_ID, notif, type)
        } catch (e: Exception) {
            // Android 12+ pode bloquear start de FGS em background; sem
            // proteção o job segue igual (degrada só a garantia de vida).
            stopForegroundAndSelf()
        }
    }

    private fun postFinal(message: String, detail: String, success: Boolean) {
        post(
            ProgressNotification.build(
                this, message, detail, 1.0, ongoing = false, success = success))
    }

    private fun post(notif: Notification) {
        runCatching { NotificationManagerCompat.from(this).notify(NOTIF_ID, notif) }
    }

    private fun releaseWakeLock() {
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
    }

    companion object {
        const val CHANNEL_ID = "subtitle_jobs"
        const val NOTIF_ID = 0x5E17
        const val ACTION_START = "goanime_tv.subtitle.START"
        const val ACTION_STOP = "goanime_tv.subtitle.STOP"
        const val ACTION_CANCEL = "goanime_tv.subtitle.CANCEL"
        const val EXTRA_MESSAGE = "message"
        const val EXTRA_DETAIL = "detail"
        const val EXTRA_PROGRESS = "progress"
        private const val WAKELOCK_TAG = "goanime:subtitle_job"
        private const val MAX_WAKE_MS = 6 * 60 * 60 * 1000L

        @Volatile
        var instance: SubtitleJobService? = null
            private set

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Geração de legenda IA", NotificationManager.IMPORTANCE_LOW)
                    .apply {
                        description = "Progresso da geração de legenda em segundo plano"
                        setShowBadge(false)
                    })
        }

        /// Idempotente: com o serviço vivo só atualiza a notificação (sem
        /// novo start, imune à restrição de start em 2º plano p/ jobs na fila).
        fun startOrUpdate(context: Context, message: String, detail: String, progress: Double) {
            val svc = instance
            if (svc != null) {
                svc.updateNotification(message, detail, progress)
                return
            }
            val intent =
                Intent(context, SubtitleJobService::class.java)
                    .setAction(ACTION_START)
                    .putExtra(EXTRA_MESSAGE, message)
                    .putExtra(EXTRA_DETAIL, detail)
                    .putExtra(EXTRA_PROGRESS, progress)
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (e: Exception) {
                // Restrição de FGS em 2º plano: o job segue sem proteção.
            }
        }

        fun finish(context: Context, message: String, detail: String, success: Boolean) {
            val svc = instance
            if (svc != null) {
                svc.postFinalAndStop(message, detail, success)
                return
            }
            // Serviço não está vivo (raro): posta o final direto do contexto.
            ensureChannel(context)
            try {
                NotificationManagerCompat.from(context)
                    .notify(
                        NOTIF_ID,
                        ProgressNotification.build(
                            context, message, detail, 1.0, ongoing = false, success = success))
            } catch (e: Exception) {}
        }

        fun stop(context: Context) {
            instance?.stopForegroundAndSelf()
        }
    }
}

/// Canal Dart→nativo do job em 2º plano (registrado na engine cacheada).
class SubtitleJobChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    fun register() {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start", "update" -> {
                val msg = call.argument<String>("message") ?: "Gerando legenda…"
                val detail = call.argument<String>("detail") ?: ""
                val progress = call.argument<Double>("progress") ?: 0.0
                if (call.method == "start") requestNotificationPermissionIfNeeded()
                SubtitleJobService.startOrUpdate(context, msg, detail, progress)
                result.success(true)
            }
            "finish" -> {
                SubtitleJobService.finish(
                    context,
                    call.argument<String>("message") ?: "Legenda pronta",
                    call.argument<String>("detail") ?: "",
                    call.argument<Boolean>("success") ?: true,
                )
                result.success(true)
            }
            "stop" -> {
                SubtitleJobService.stop(context)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /// Android 13+: sem permissão a notificação não aparece (o serviço e o
    /// wake lock funcionam igual). Pede uma vez, quando o usuário dispara a
    /// 1ª geração com o app em foco.
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < 33) return
        try {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (nm.areNotificationsEnabled()) return
            val activity = MainActivity.live ?: return
            androidx.core.app.ActivityCompat.requestPermissions(
                activity,
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                MainActivity.REQ_NOTIFICATIONS,
            )
        } catch (e: Exception) {}
    }

    companion object {
        const val CHANNEL_NAME = "goanime_tv/sub_service"
    }
}

/// Montagem da notificação de progresso/resultado.
internal object ProgressNotification {
    fun build(
        context: Context,
        message: String,
        detail: String,
        progress: Double,
        ongoing: Boolean,
        success: Boolean = false,
    ): Notification {
        val text = if (detail.isEmpty()) message else "$message · $detail"
        val contentIntent =
            PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val builder =
            NotificationCompat.Builder(context, SubtitleJobService.CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(
                    if (success) "GoAnime TV · legenda pronta" else "GoAnime TV · legenda IA")
                .setContentText(text)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setOngoing(ongoing)
                .setAutoCancel(!ongoing)
                .setContentIntent(contentIntent)
        if (ongoing) {
            builder.setProgress(
                100,
                (progress.coerceIn(0.0, 1.0) * 100).toInt(),
                progress <= 0.0,
            )
            val cancelIntent =
                PendingIntent.getService(
                    context,
                    1,
                    Intent(context, SubtitleJobService::class.java)
                        .setAction(SubtitleJobService.ACTION_CANCEL),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            builder.addAction(
                NotificationCompat.Action.Builder(
                    IconCompat.createWithResource(context, R.mipmap.ic_launcher),
                    "Cancelar",
                    cancelIntent,
                ).build())
        }
        return builder.build()
    }
}
