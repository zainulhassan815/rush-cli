package dev.rush.live;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

final class LiveFiles {

    private LiveFiles() {
    }

    static String read(File file) throws IOException {
        ByteArrayOutputStream text = new ByteArrayOutputStream();
        try (InputStream in = new FileInputStream(file)) {
            copy(in, text);
        }
        return text.toString("UTF-8");
    }

    static void write(File file, String text) throws IOException {
        try (OutputStream out = new FileOutputStream(file)) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
        }
    }

    static List<JSONObject> jsonLines(File file) throws IOException, JSONException {
        List<JSONObject> lines = new ArrayList<>();
        if (file.exists()) {
            for (String line : read(file).split("\n")) {
                if (!line.trim().isEmpty()) {
                    lines.add(new JSONObject(line));
                }
            }
        }
        return lines;
    }

    static void copy(File source, File target) throws IOException {
        try (InputStream in = new FileInputStream(source); OutputStream out = new FileOutputStream(target)) {
            copy(in, out);
        }
    }

    private static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buffer = new byte[64 * 1024];
        for (int read = in.read(buffer); read != -1; read = in.read(buffer)) {
            out.write(buffer, 0, read);
        }
    }
}
