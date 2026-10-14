package dev.rush.live;

import org.json.JSONException;
import org.json.JSONObject;

final class Json {

    private Json() {
    }

    static JSONObject object(Object... keysAndValues) {
        JSONObject object = new JSONObject();
        try {
            for (int i = 0; i < keysAndValues.length; i += 2) {
                object.put((String) keysAndValues[i], keysAndValues[i + 1]);
            }
        } catch (JSONException e) {
            throw new IllegalArgumentException(e);
        }
        return object;
    }
}
