package com.overcode.kelly

import android.Manifest
import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebResourceRequest
import android.webkit.PermissionRequest
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

class MainActivity : Activity(), TextToSpeech.OnInitListener {
    private lateinit var web: WebView
    private lateinit var urlInput: EditText
    private var tts: TextToSpeech? = null
    private var recognizer: SpeechRecognizer? = null
    private val prefs by lazy { getSharedPreferences("overcode", Context.MODE_PRIVATE) }
    private var pageLoaded = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        tts = TextToSpeech(this, this)
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 301)
        }
        buildScreen()
        if (savedInstanceState == null && intent?.action == Intent.ACTION_ASSIST) {
            // O Android pode abrir esta activity via ACTION_ASSIST em aparelhos que usem esse caminho.
            window.decorView.postDelayed({ web.evaluateJavascript("document.getElementById('messageInput')?.focus()", null) }, 900)
        }
    }

    private fun buildScreen() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(16, 17, 20))
            setPadding(10, 10, 10, 0)
        }
        val header = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(8, 6, 8, 8) }
        val title = TextView(this).apply {
            text = "Overcode · Kelly"
            textSize = 19f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        val subtitle = TextView(this).apply {
            text = "Conecte ao motor Overcode que roda no Termux ou no computador."
            textSize = 11f
            setTextColor(Color.LTGRAY)
            setPadding(0, 4, 0, 9)
        }
        urlInput = EditText(this).apply {
            setSingleLine(true)
            textSize = 13f
            setTextColor(Color.WHITE)
            setHintTextColor(Color.GRAY)
            hint = "http://127.0.0.1:8765"
            setText(prefs.getString("server_url", "http://127.0.0.1:8765"))
            setPadding(12, 9, 12, 9)
            background = rounded(Color.rgb(35, 38, 46), 12)
        }
        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val connect = Button(this).apply { text = "Abrir painel"; setOnClickListener { connectPanel() } }
        val assistant = Button(this).apply { text = "Definir como assistente"; setOnClickListener { requestAssistant() } }
        actions.addView(connect, LinearLayout.LayoutParams(0, -2, 1f))
        actions.addView(assistant, LinearLayout.LayoutParams(0, -2, 1f))
        header.addView(title); header.addView(subtitle); header.addView(urlInput); header.addView(actions)
        root.addView(header)
        web = WebView(this).apply {
            setBackgroundColor(Color.rgb(16, 17, 20))
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.allowFileAccess = false
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val trustedHost = Uri.parse(baseUrl()).host
                    if (request.url.host != trustedHost) {
                        try { startActivity(Intent(Intent.ACTION_VIEW, request.url)) }
                        catch (_: Exception) { Toast.makeText(this@MainActivity, "Não foi possível abrir o link.", Toast.LENGTH_SHORT).show() }
                        return true
                    }
                    return false
                }
            }
            webChromeClient = object : WebChromeClient() {
                override fun onPermissionRequest(request: PermissionRequest) {
                    runOnUiThread {
                        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED &&
                            request.resources.contains(PermissionRequest.RESOURCE_AUDIO_CAPTURE)) request.grant(request.resources)
                        else request.deny()
                    }
                }
            }
            addJavascriptInterface(Bridge(), "OvercodeNative")
        }
        root.addView(web, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
        connectPanel()
    }

    private fun rounded(color: Int, radius: Int): GradientDrawable = GradientDrawable().apply {
        setColor(color); cornerRadius = radius.toFloat(); setStroke(1, Color.rgb(58, 62, 72))
    }

    private fun baseUrl(): String {
        var value = urlInput.text.toString().trim().ifBlank { "http://127.0.0.1:8765" }
        value = value.removeSuffix("/")
        if (!value.startsWith("http://") && !value.startsWith("https://")) value = "http://$value"
        return value
    }

    private fun connectPanel() {
        val url = baseUrl()
        prefs.edit().putString("server_url", url).apply()
        web.loadUrl("$url/")
        pageLoaded = true
    }

    private fun requestAssistant() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val rm = getSystemService(RoleManager::class.java)
            if (rm != null && rm.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
                startActivityForResult(rm.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT), 302)
                return
            }
        }
        try { startActivity(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)) }
        catch (_: Exception) { Toast.makeText(this, "Abra Configurações e procure Aplicativo de assistente digital.", Toast.LENGTH_LONG).show() }
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            tts?.language = Locale("pt", "BR")
            val selected = prefs.getString("voice_name", "") ?: ""
            if (selected.isNotBlank()) tts?.voices?.firstOrNull { it.name == selected }?.let { tts?.voice = it }
            tts?.setSpeechRate(prefs.getFloat("voice_rate", 1f))
            tts?.setPitch(prefs.getFloat("voice_pitch", 1f))
        }
    }

    private fun speak(text: String, selected: String?) {
        val engine = tts ?: return
        if (!selected.isNullOrBlank()) engine.voices?.firstOrNull { it.name == selected }?.let { engine.voice = it }
        engine.setSpeechRate(prefs.getFloat("voice_rate", 1f))
        engine.setPitch(prefs.getFloat("voice_pitch", 1f))
        val params = Bundle().apply {
            putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, prefs.getFloat("voice_volume", 1f).coerceIn(0f, 1f))
        }
        engine.speak(text.take(3000), TextToSpeech.QUEUE_FLUSH, params, "kelly-${System.currentTimeMillis()}")
    }

    private fun startNativeListening() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 301); return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            Toast.makeText(this, "Serviço de reconhecimento de voz indisponível.", Toast.LENGTH_LONG).show(); return
        }
        recognizer?.destroy()
        recognizer = SpeechRecognizer.createSpeechRecognizer(this).also { r ->
            r.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onError(error: Int) { runOnUiThread { web.evaluateJavascript("document.getElementById('micBtn')?.classList.remove('voice-active')", null) } }
                override fun onResults(results: Bundle?) {
                    val result = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                    val js = "window.dispatchEvent(new CustomEvent('overcode-speech',{detail:${JSONObject.quote(result)}}))"
                    runOnUiThread { web.evaluateJavascript(js, null) }
                }
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "pt-BR")
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "pt-BR")
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            }
            r.startListening(intent)
        }
    }

    inner class Bridge {
        @JavascriptInterface fun getVoices(): String {
            val arr = JSONArray()
            (tts?.voices ?: emptySet<Voice>()).sortedBy { it.name }.forEach { v ->
                arr.put(JSONObject().put("name", v.name).put("locale", v.locale.toLanguageTag()))
            }
            return arr.toString()
        }
        @JavascriptInterface fun speak(text: String, voiceName: String) { runOnUiThread { this@MainActivity.speak(text, voiceName) } }
        @JavascriptInterface fun startListening() { runOnUiThread { startNativeListening() } }
        @JavascriptInterface fun openAssistantSettings() { runOnUiThread { requestAssistant() } }
        @JavascriptInterface fun setVoice(name: String, rate: Float, pitch: Float, volume: Float, enabled: Boolean) {
            prefs.edit().putString("voice_name", name).putFloat("voice_rate", rate)
                .putFloat("voice_pitch", pitch).putFloat("voice_volume", volume.coerceIn(0f, 1f))
                .putBoolean("voice_enabled", enabled).apply()
        }
        @JavascriptInterface fun setAuthToken(token: String) {
            prefs.edit().putString("hub_auth_token", token.trim()).apply()
        }
    }

    override fun onDestroy() {
        recognizer?.destroy(); recognizer = null
        tts?.stop(); tts?.shutdown(); tts = null
        super.onDestroy()
    }
}