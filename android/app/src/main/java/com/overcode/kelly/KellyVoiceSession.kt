package com.overcode.kelly

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.voice.VoiceInteractionSession
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

/** Cartão compacto exibido pelo Android quando Overcode é escolhido como assistente digital. */
class KellyVoiceSession(private val ctx: Context) : VoiceInteractionSession(ctx), TextToSpeech.OnInitListener {
    private val prefs = ctx.getSharedPreferences("overcode", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var recognizer: SpeechRecognizer? = null
    private lateinit var answer: TextView
    private lateinit var input: EditText
    private var sessionId = prefs.getString("assistant_session", "") ?: ""

    override fun onCreateContentView(): View {
        tts = TextToSpeech(ctx, this)
        val root = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 18, 20, 18)
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.rgb(35, 37, 44), Color.rgb(17, 19, 24))
            ).apply { cornerRadius = 34f; setStroke(1, Color.rgb(69, 73, 84)) }
        }
        val top = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val mark = TextView(ctx).apply {
            text = "✳"; textSize = 27f; setTextColor(Color.rgb(226, 139, 111)); setPadding(0, 0, 12, 0)
        }
        val titleWrap = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; layoutParams = LinearLayout.LayoutParams(0, -2, 1f) }
        val title = TextView(ctx).apply { text = "Kelly · Overcode"; textSize = 16f; typeface = Typeface.DEFAULT_BOLD; setTextColor(Color.WHITE) }
        val subtitle = TextView(ctx).apply { text = "Sua assistente de programação"; textSize = 10f; setTextColor(Color.LTGRAY) }
        titleWrap.addView(title); titleWrap.addView(subtitle)
        val close = Button(ctx).apply { text = "×"; setOnClickListener { finish() } }
        top.addView(mark); top.addView(titleWrap); top.addView(close)
        root.addView(top)

        answer = TextView(ctx).apply {
            text = "Oi! Sou a Kelly. O que vamos fazer?"
            textSize = 14f; setTextColor(Color.rgb(239, 240, 244)); setPadding(4, 18, 4, 16)
            minHeight = 74
        }
        root.addView(answer)
        input = EditText(ctx).apply {
            hint = "Fale ou escreva para a Kelly…"; setTextColor(Color.WHITE); setHintTextColor(Color.GRAY)
            textSize = 14f; setPadding(14, 10, 14, 10); background = rounded(Color.rgb(43, 46, 55), 16)
        }
        root.addView(input, LinearLayout.LayoutParams(-1, -2))
        val actions = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(0, 10, 0, 0) }
        val mic = Button(ctx).apply { text = "🎙 Falar"; setOnClickListener { listen() } }
        val send = Button(ctx).apply { text = "Enviar"; setOnClickListener { sendMessage(input.text.toString()) } }
        actions.addView(mic, LinearLayout.LayoutParams(0, -2, 1f)); actions.addView(send, LinearLayout.LayoutParams(0, -2, 1f))
        root.addView(actions)
        val full = TextView(ctx).apply {
            text = "Abrir painel completo  ↗"; textSize = 11f; gravity = Gravity.CENTER; setTextColor(Color.rgb(190, 199, 218))
            setPadding(8, 15, 8, 2)
            setOnClickListener {
                val i = Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                ctx.startActivity(i); finish()
            }
        }
        root.addView(full)
        return root
    }

    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color); cornerRadius = radius.toFloat(); setStroke(1, Color.rgb(66, 70, 81))
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        if (::answer.isInitialized) answer.text = "Oi! Sou a Kelly. O que vamos fazer?"
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            tts?.language = Locale("pt", "BR")
            val name = prefs.getString("voice_name", "") ?: ""
            if (name.isNotBlank()) tts?.voices?.firstOrNull { it.name == name }?.let { tts?.voice = it }
            tts?.setSpeechRate(prefs.getFloat("voice_rate", 1f))
        }
    }

    private fun listen() {
        if (!SpeechRecognizer.isRecognitionAvailable(ctx)) {
            answer.text = "O serviço de reconhecimento de voz não está disponível neste aparelho."; return
        }
        recognizer?.destroy()
        recognizer = SpeechRecognizer.createSpeechRecognizer(ctx).also { rec ->
            rec.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) { main.post { answer.text = "Estou ouvindo…" } }
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onError(error: Int) { main.post { answer.text = "Não consegui ouvir. Tente novamente ou digite sua mensagem." } }
                override fun onResults(results: Bundle?) {
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                    main.post { input.setText(text); if (text.isNotBlank()) sendMessage(text) }
                }
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "pt-BR")
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            }
            rec.startListening(intent)
        }
    }

    private fun sendMessage(text: String) {
        val msg = text.trim()
        if (msg.isEmpty()) return
        input.setText(""); answer.text = "Kelly está pensando…"
        Thread {
            var result = ""
            var model = ""
            try {
                val base = (prefs.getString("server_url", "http://127.0.0.1:8765") ?: "http://127.0.0.1:8765").removeSuffix("/")
                val conn = (URL("$base/api/v1/chat").openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"; connectTimeout = 7000; readTimeout = 180000
                    doOutput = true; setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    val token = prefs.getString("hub_auth_token", "") ?: ""
                    if (token.isNotBlank()) setRequestProperty("Authorization", "Bearer $token")
                }
                val payload = JSONObject().put("message", msg).put("session_id", sessionId).toString()
                conn.outputStream.use { it.write(payload.toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                val body = (if (code in 200..299) conn.inputStream else conn.errorStream).bufferedReader().use { it.readText() }
                val json = JSONObject(body)
                if (json.has("error")) throw IllegalStateException(json.optString("error"))
                result = json.optString("answer", "A Kelly concluiu a solicitação.")
                model = json.optString("model", "")
                sessionId = json.optString("session_id", sessionId)
                prefs.edit().putString("assistant_session", sessionId).apply()
                if (json.has("pending_command")) result += "\n\nHá um comando aguardando aprovação. Abra o painel completo para aprovar com segurança."
            } catch (e: Exception) {
                result = "Não consegui alcançar o motor Overcode. Verifique se o painel está rodando em ${prefs.getString("server_url", "127.0.0.1:8765")}.\n${e.message}"
            }
            main.post {
                if (::answer.isInitialized) answer.text = result
                if (result.isNotBlank() && prefs.getBoolean("voice_enabled", true)) {
                    tts?.setSpeechRate(prefs.getFloat("voice_rate", 1f))
                    tts?.setPitch(prefs.getFloat("voice_pitch", 1f))
                    val params = Bundle().apply {
                        putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, prefs.getFloat("voice_volume", 1f).coerceIn(0f, 1f))
                    }
                    tts?.speak(result.replace(Regex("```[\\s\\S]*?```"), "").take(1800), TextToSpeech.QUEUE_FLUSH, params, "kelly-response")
                }
            }
        }.start()
    }

    override fun onHide() { super.onHide(); recognizer?.cancel() }
    override fun onDestroy() {
        recognizer?.destroy(); recognizer = null
        tts?.stop(); tts?.shutdown(); tts = null
        super.onDestroy()
    }
}