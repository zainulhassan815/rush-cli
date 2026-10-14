package dev.rush.live;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayDeque;

final class EventLog {

    private static final int CAPACITY = 2000;

    private final ArrayDeque<JSONObject> entries = new ArrayDeque<>();
    private long last = System.currentTimeMillis() * 1000;

    synchronized void add(String component, String event, JSONArray arguments) {
        entries.addLast(Json.object(
                "seq", ++last,
                "time", System.currentTimeMillis(),
                "component", component,
                "event", event,
                "args", arguments));
        if (entries.size() > CAPACITY) {
            entries.removeFirst();
        }
    }

    synchronized long last() {
        return last;
    }

    synchronized JSONObject since(long seq) {
        JSONArray newer = new JSONArray();
        for (JSONObject entry : entries) {
            if (entry.optLong("seq") > seq) {
                newer.put(entry);
            }
        }
        return Json.object("last", last, "events", newer);
    }
}
