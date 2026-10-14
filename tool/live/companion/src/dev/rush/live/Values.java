package dev.rush.live;

import com.google.appinventor.components.common.OptionList;
import com.google.appinventor.components.runtime.Component;
import com.google.appinventor.components.runtime.util.JsonUtil;

import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;

final class Values {

    interface Names {
        String of(Component component);
    }

    private Values() {
    }

    static Object toJson(Object value, Names names) {
        if (value == null) {
            return JSONObject.NULL;
        }
        if (value instanceof Boolean || value instanceof Number || value instanceof String) {
            return value;
        }
        if (value instanceof OptionList) {
            return toJson(((OptionList<?>) value).toUnderlyingValue(), names);
        }
        if (value instanceof Component) {
            return names.of((Component) value);
        }
        try {
            return new JSONTokener(JsonUtil.getJsonRepresentation(value)).nextValue();
        } catch (JSONException e) {
            return String.valueOf(value);
        }
    }
}
