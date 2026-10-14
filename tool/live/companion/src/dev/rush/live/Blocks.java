package dev.rush.live;

import android.text.TextUtils;

import com.google.appinventor.components.common.OptionList;
import com.google.appinventor.components.runtime.Component;
import com.google.appinventor.components.runtime.util.JsonUtil;
import com.google.appinventor.components.runtime.util.YailDictionary;
import com.google.appinventor.components.runtime.util.YailList;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

final class Blocks {

    interface Components {
        Component named(String name);
    }

    private Blocks() {
    }

    static Method find(Class<?> component, String block, int arity) throws NoSuchMethodException {
        List<String> arities = new ArrayList<>();
        for (Method method : component.getMethods()) {
            if (method.getName().equals(block)) {
                if (method.getParameterTypes().length == arity) {
                    return method;
                }
                arities.add(String.valueOf(method.getParameterTypes().length));
            }
        }
        throw new NoSuchMethodException(arities.isEmpty()
                ? component.getSimpleName() + " has no block named " + block
                : block + " takes " + TextUtils.join(" or ", arities) + " arguments, not " + arity);
    }

    static Object[] coerce(Class<?>[] types, Object[] args, Components components) throws JSONException {
        Object[] values = new Object[args.length];
        for (int i = 0; i < args.length; i++) {
            values[i] = coerce(types[i], args[i], components);
        }
        return values;
    }

    private static Object coerce(Class<?> type, Object arg, Components components) throws JSONException {
        String text = String.valueOf(arg);
        if (type == String.class) {
            return text;
        }
        if (type == int.class || type == Integer.class) {
            return (int) wholeNumber(arg, text);
        }
        if (type == long.class || type == Long.class) {
            return wholeNumber(arg, text);
        }
        if (type == float.class || type == Float.class) {
            return (float) number(arg, text);
        }
        if (type == double.class || type == Double.class) {
            return number(arg, text);
        }
        if (type == boolean.class || type == Boolean.class) {
            return booleanOf(text);
        }
        if (Component.class.isAssignableFrom(type)) {
            return components.named(text);
        }
        if (type.isEnum()) {
            return option(type, text);
        }
        if (type == YailList.class || type == YailDictionary.class) {
            return JsonUtil.getObjectFromJson(arg instanceof String ? text : arg.toString(), true);
        }
        if (arg instanceof JSONArray || arg instanceof JSONObject) {
            return JsonUtil.getObjectFromJson(arg.toString(), true);
        }
        return arg;
    }

    private static double number(Object arg, String text) {
        if (arg instanceof Number) {
            return ((Number) arg).doubleValue();
        }
        try {
            return Double.parseDouble(text);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("Expected a number, got " + text);
        }
    }

    private static long wholeNumber(Object arg, String text) {
        double value = number(arg, text);
        if (value != Math.rint(value)) {
            throw new IllegalArgumentException("Expected a whole number, got " + text);
        }
        return (long) value;
    }

    private static boolean booleanOf(String text) {
        if (text.equalsIgnoreCase("true") || text.equalsIgnoreCase("false")) {
            return Boolean.parseBoolean(text);
        }
        throw new IllegalArgumentException("Expected true or false, got " + text);
    }

    private static Object option(Class<?> type, String text) {
        List<String> names = new ArrayList<>();
        for (Object constant : type.getEnumConstants()) {
            String name = ((Enum<?>) constant).name();
            String value = constant instanceof OptionList
                    ? String.valueOf(((OptionList<?>) constant).toUnderlyingValue())
                    : name;
            if (name.equalsIgnoreCase(text) || value.equalsIgnoreCase(text)) {
                return constant;
            }
            names.add(name);
        }
        throw new IllegalArgumentException(text + " is not one of " + TextUtils.join(", ", names));
    }
}
