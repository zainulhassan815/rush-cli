package dev.rush.live;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.reflect.InvocationTargetException;

final class Failures {

    private static final String[] PLATFORM_PACKAGES = {
            "java.", "javax.", "jdk.", "sun.", "libcore.", "dalvik.", "android.", "androidx.", "com.android.",
            "kotlin.", "kotlinx.", "com.google.appinventor.", "gnu.", "kawa.", "dev.rush.live."
    };

    private Failures() {
    }

    static JSONObject toJson(Throwable failure) {
        Throwable cause = failure instanceof InvocationTargetException ? failure.getCause() : failure;
        return Json.object(
                "type", cause.getClass().getName(),
                "message", cause.getMessage() == null ? JSONObject.NULL : cause.getMessage(),
                "at", extensionFrames(cause));
    }

    private static JSONArray extensionFrames(Throwable failure) {
        JSONArray frames = new JSONArray();
        for (StackTraceElement frame : failure.getStackTrace()) {
            if (!isPlatform(frame.getClassName())) {
                frames.put(frame.toString());
            }
        }
        return frames;
    }

    private static boolean isPlatform(String className) {
        for (String prefix : PLATFORM_PACKAGES) {
            if (className.startsWith(prefix)) {
                return true;
            }
        }
        return false;
    }
}
