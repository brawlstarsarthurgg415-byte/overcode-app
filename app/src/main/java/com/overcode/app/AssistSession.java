package com.overcode.app;

import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.service.voice.VoiceInteractionSession;

public class AssistSession extends VoiceInteractionSession {
    public AssistSession(Context context) {
        super(context);
    }

    @Override
    public void onShow(Bundle args, int flags) {
        super.onShow(args, flags);
        Intent i = new Intent(getContext(), ChatActivity.class);
        i.setAction(Intent.ACTION_ASSIST);
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startAssistantActivity(i);
        finish();
    }
}
