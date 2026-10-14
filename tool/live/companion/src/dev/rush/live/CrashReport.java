package dev.rush.live;

import android.os.Process;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.IOException;

final class CrashReport {

    interface LastCommand {
        Object get();
    }

    private CrashReport() {
    }

    static void install(File file, LastCommand lastCommand) {
        Thread.UncaughtExceptionHandler platform = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread, error) -> {
            try {
                LiveFiles.write(file, Failures.toJson(error).put("after", lastCommand.get()).toString());
            } catch (IOException | JSONException ignored) {
            }
            try {
                platform.uncaughtException(thread, error);
            } finally {
                Process.killProcess(Process.myPid());
                System.exit(10);
            }
        });
    }

    static Object take(File file) throws IOException, JSONException {
        if (!file.exists()) {
            return JSONObject.NULL;
        }
        JSONObject crash = new JSONObject(LiveFiles.read(file));
        file.delete();
        return crash;
    }
}
