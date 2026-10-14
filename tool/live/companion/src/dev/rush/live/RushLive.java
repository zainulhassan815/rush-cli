package dev.rush.live;

import android.Manifest;
import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.util.Base64;
import android.util.Log;
import android.view.WindowManager;

import com.google.appinventor.components.annotations.Extension;
import com.google.appinventor.components.annotations.SimpleFunction;
import com.google.appinventor.components.runtime.AndroidNonvisibleComponent;
import com.google.appinventor.components.runtime.Component;
import com.google.appinventor.components.runtime.ComponentContainer;
import com.google.appinventor.components.runtime.OnDestroyListener;
import com.google.appinventor.components.runtime.util.OnInitializeListener;
import com.google.appinventor.components.runtime.util.YailList;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.IOException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@Extension(
        description = "Runs extension code pushed by rush live, without rebuilding the app.",
        icon = "icon.png"
)
public class RushLive extends AndroidNonvisibleComponent implements OnInitializeListener, OnDestroyListener {

    private static final String TAG = "RushLive";
    private static final String ACTION = "dev.rush.live.COMMAND";
    private static final String BUILT_IN_PACKAGE = "com.google.appinventor.components.runtime.";

    private final Map<String, Component> components = new LinkedHashMap<>();
    private final Map<String, String> extensionClasses = new HashMap<>();
    private final EventLog events = new EventLog();
    private final JSONArray replayFailures = new JSONArray();
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            setResult(Activity.RESULT_OK, respond(intent.getStringExtra("request")), null);
        }
    };
    private final File pushed;
    private final List<JSONObject> session;
    private final Object previousCrash;
    private ClassLoader extensionLoader;
    private String loadedStamp = "";
    private Object lastCommand = JSONObject.NULL;
    private boolean ready;

    public RushLive(ComponentContainer container) throws IOException, JSONException {
        super(container.$form());
        pushed = form.getExternalFilesDir("live");
        File crash = new File(pushed, "crash.json");
        previousCrash = CrashReport.take(crash);
        CrashReport.install(crash, () -> lastCommand);
        session = LiveFiles.jsonLines(new File(pushed, "session.jsonl"));
        load();
        keepVisible();
        IntentFilter commands = new IntentFilter(ACTION);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            form.registerReceiver(receiver, commands, Manifest.permission.DUMP, null, Context.RECEIVER_EXPORTED);
        } else {
            form.registerReceiver(receiver, commands, Manifest.permission.DUMP, null);
        }
        form.registerForOnInitialize(this);
        form.registerForOnDestroy(this);
    }

    private void keepVisible() {
        form.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            form.setShowWhenLocked(true);
            form.setTurnScreenOn(true);
        }
    }

    @SimpleFunction(description = "Records an event raised by a live component.")
    public void Report(Component component, String event, YailList arguments) {
        JSONArray values = new JSONArray();
        for (Object argument : arguments.toArray()) {
            values.put(Values.toJson(argument, this::nameOf));
        }
        events.add(nameOf(component), event, values);
    }

    @Override
    public void onInitialize() {
        for (JSONObject step : session) {
            lastCommand = step;
            try {
                execute(step.getString("command"), step.getJSONArray("args"));
            } catch (Exception e) {
                Log.w(TAG, e);
                replayFailures.put(Json.object("step", step, "error", Failures.toJson(e)));
            }
        }
        ready = true;
    }

    @Override
    public void onDestroy() {
        form.unregisterReceiver(receiver);
    }

    private void load() throws IOException, JSONException {
        File dex = new File(pushed, "classes.jar");
        if (!dex.exists()) {
            extensionLoader = form.getClassLoader();
            return;
        }
        extensionLoader = LiveClassLoader.copyOf(dex, form.getCodeCacheDir(), form.getClassLoader());
        loadedStamp = LiveFiles.read(new File(pushed, "stamp")).trim();
        JSONArray descriptors = new JSONArray(LiveFiles.read(new File(pushed, "components.json")));
        for (int i = 0; i < descriptors.length(); i++) {
            extensionClasses.put(descriptors.getJSONObject(i).getString("name"),
                    descriptors.getJSONObject(i).getString("type"));
        }
    }

    private String respond(String request) {
        long cursor = events.last();
        try {
            JSONObject parsed = new JSONObject(new String(Base64.decode(request, Base64.DEFAULT),
                    StandardCharsets.UTF_8));
            String command = parsed.getString("command");
            if (command.equals("create") || command.equals("call")) {
                lastCommand = parsed;
            }
            Object result = execute(command, parsed.optJSONArray("args"));
            return Json.object("ok", true, "result", result, "cursor", cursor).toString();
        } catch (Exception e) {
            Log.w(TAG, e);
            return Json.object("ok", false, "error", Failures.toJson(e), "cursor", cursor).toString();
        }
    }

    private Object execute(String command, JSONArray args) throws Exception {
        switch (command) {
            case "status":
                return status();
            case "create":
                return create(args.getString(0), args.getString(1));
            case "call":
                return call(args.getString(0), args.getString(1), rest(args, 2));
            case "events":
                return events.since(args.optLong(0, 0));
            default:
                throw new IllegalArgumentException("Unknown command " + command);
        }
    }

    private JSONObject status() {
        JSONArray live = new JSONArray();
        for (Map.Entry<String, Component> entry : components.entrySet()) {
            live.put(Json.object("name", entry.getKey(), "type", entry.getValue().getClass().getSimpleName()));
        }
        return Json.object(
                "ready", ready,
                "loaded", loadedStamp,
                "components", live,
                "replayed", session.size(),
                "replayFailures", replayFailures,
                "previousCrash", previousCrash);
    }

    private JSONObject create(String type, String name) throws ReflectiveOperationException {
        Component existing = components.get(name);
        if (existing != null) {
            String existingType = existing.getClass().getSimpleName();
            if (!existingType.equals(type)) {
                throw new IllegalArgumentException(name + " already exists as a " + existingType);
            }
            return Json.object("name", name, "created", false);
        }
        Component component = (Component) componentClass(type)
                .getConstructor(ComponentContainer.class)
                .newInstance(form);
        components.put(name, component);
        if (component instanceof OnInitializeListener) {
            ((OnInitializeListener) component).onInitialize();
        }
        return Json.object("name", name, "created", true);
    }

    private Class<?> componentClass(String type) throws ClassNotFoundException {
        String extensionClass = extensionClasses.get(type);
        if (extensionClass == null) {
            return Class.forName(BUILT_IN_PACKAGE + type);
        }
        return extensionLoader.loadClass(extensionClass);
    }

    private Object call(String name, String block, Object[] args) throws Exception {
        Object target = component(name);
        Method method = Blocks.find(target.getClass(), block, args.length);
        Object result = method.invoke(target, Blocks.coerce(method.getParameterTypes(), args, this::component));
        return method.getReturnType() == void.class ? JSONObject.NULL : Values.toJson(result, this::nameOf);
    }

    private static Object[] rest(JSONArray args, int from) throws JSONException {
        Object[] values = new Object[args.length() - from];
        for (int i = from; i < args.length(); i++) {
            values[i - from] = args.get(i);
        }
        return values;
    }

    private Component component(String name) {
        if (name.equals(form.getClass().getSimpleName())) {
            return form;
        }
        Component component = components.get(name);
        if (component == null) {
            throw new IllegalArgumentException("No component named " + name);
        }
        return component;
    }

    private String nameOf(Component component) {
        for (Map.Entry<String, Component> entry : components.entrySet()) {
            if (entry.getValue() == component) {
                return entry.getKey();
            }
        }
        return component.getClass().getSimpleName();
    }
}
