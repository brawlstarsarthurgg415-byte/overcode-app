package com.overcode.app;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.speech.RecognizerIntent;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

public class ChatActivity extends Activity {
    WebView wv;
    ValueCallback<Uri[]> fcb;
    SharedPreferences sp;
    final Map<Integer, HttpURLConnection> conns = new ConcurrentHashMap<>();
    final Set<Integer> cancelled = Collections.synchronizedSet(new HashSet<Integer>());

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        sp = getSharedPreferences("overcode", MODE_PRIVATE);
        wv = new WebView(this);
        setContentView(wv);
        WebSettings s = wv.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        wv.addJavascriptInterface(new Bridge(), "Android");
        wv.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView w, ValueCallback<Uri[]> cb, FileChooserParams p) {
                if (fcb != null) fcb.onReceiveValue(null);
                fcb = cb;
                try {
                    startActivityForResult(p.createIntent(), 8);
                } catch (Exception e) {
                    fcb = null;
                    return false;
                }
                return true;
            }
        });
        wv.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView v, String u) {
                if (isAssist(getIntent())) js("onAssist()");
            }
        });
        wv.loadUrl("file:///android_asset/index.html");
    }

    boolean isAssist(Intent i) {
        return i != null && (Intent.ACTION_ASSIST.equals(i.getAction()) || i.getBooleanExtra("assist", false));
    }

    @Override
    protected void onNewIntent(Intent i) {
        super.onNewIntent(i);
        setIntent(i);
        if (isAssist(i)) js("onAssist()");
    }

    void js(final String code) {
        wv.post(new Runnable() {
            public void run() {
                wv.evaluateJavascript(code, null);
            }
        });
    }

    @Override
    protected void onActivityResult(int rc, int res, Intent d) {
        super.onActivityResult(rc, res, d);
        if (rc == 7) {
            String t = "";
            if (res == RESULT_OK && d != null) {
                ArrayList<String> l = d.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS);
                if (l != null && !l.isEmpty()) t = l.get(0);
            }
            js("onVoice(" + JSONObject.quote(t) + ")");
        } else if (rc == 8 && fcb != null) {
            fcb.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(res, d));
            fcb = null;
        }
    }

    class Bridge {
        @JavascriptInterface
        public String getCfg() {
            return sp.getString("cfg", "{}");
        }

        @JavascriptInterface
        public void setCfg(String j) {
            sp.edit().putString("cfg", j).apply();
        }

        @JavascriptInterface
        public void mic() {
            runOnUiThread(new Runnable() {
                public void run() {
                    try {
                        Intent i = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
                        i.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
                        i.putExtra(RecognizerIntent.EXTRA_LANGUAGE, "pt-BR");
                        startActivityForResult(i, 7);
                    } catch (Exception e) {
                        js("onVoice('')");
                    }
                }
            });
        }

        @JavascriptInterface
        public void cancel(int id) {
            HttpURLConnection c = conns.get(id);
            if (c != null) {
                cancelled.add(id);
                c.disconnect();
            }
        }

        @JavascriptInterface
        public void http(final int id, final String method, final String url, final String hdrs, final String body) {
            new Thread(new Runnable() {
                public void run() {
                    HttpURLConnection c = null;
                    try {
                        c = (HttpURLConnection) new URL(url).openConnection();
                        conns.put(id, c);
                        c.setRequestMethod(method);
                        c.setConnectTimeout(20000);
                        c.setReadTimeout(180000);
                        JSONObject h = new JSONObject(hdrs);
                        Iterator<String> it = h.keys();
                        while (it.hasNext()) {
                            String k = it.next();
                            c.setRequestProperty(k, h.getString(k));
                        }
                        if (body != null && !body.isEmpty()) {
                            c.setDoOutput(true);
                            OutputStream o = c.getOutputStream();
                            o.write(body.getBytes("UTF-8"));
                            o.close();
                        }
                        int code = c.getResponseCode();
                        InputStream in = code >= 400 ? c.getErrorStream() : c.getInputStream();
                        if (in != null) {
                            BufferedReader r = new BufferedReader(new InputStreamReader(in, "UTF-8"));
                            String l;
                            while ((l = r.readLine()) != null) {
                                js("onLine(" + id + "," + JSONObject.quote(l) + ")");
                            }
                        }
                        js("onEnd(" + id + "," + code + ")");
                    } catch (Exception e) {
                        int code = cancelled.remove(id) ? -2 : -1;
                        if (code == -1) js("onLine(" + id + "," + JSONObject.quote(String.valueOf(e)) + ")");
                        js("onEnd(" + id + "," + code + ")");
                    } finally {
                        conns.remove(id);
                        if (c != null) c.disconnect();
                    }
                }
            }).start();
        }
    }
}
