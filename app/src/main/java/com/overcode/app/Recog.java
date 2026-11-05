package com.overcode.app;

import android.content.Intent;
import android.speech.RecognitionService;
import android.speech.SpeechRecognizer;

public class Recog extends RecognitionService {
    @Override
    protected void onStartListening(Intent intent, Callback cb) {
        try { cb.error(SpeechRecognizer.ERROR_CLIENT); } catch (Exception e) { }
    }

    @Override
    protected void onCancel(Callback cb) { }

    @Override
    protected void onStopListening(Callback cb) { }
}
