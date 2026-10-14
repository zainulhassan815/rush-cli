package dev.rush.live;

import dalvik.system.DexClassLoader;

import java.io.File;
import java.io.IOException;

final class LiveClassLoader extends DexClassLoader {

    private static final String PREFIX = "live-";

    private LiveClassLoader(File dex, File codeCache, ClassLoader app) {
        super(dex.getPath(), codeCache.getPath(), null, app);
    }

    static LiveClassLoader copyOf(File pushed, File codeCache, ClassLoader app) throws IOException {
        for (File old : codeCache.listFiles((dir, name) -> name.startsWith(PREFIX))) {
            old.delete();
        }
        File dex = new File(codeCache, PREFIX + System.currentTimeMillis() + ".jar");
        LiveFiles.copy(pushed, dex);
        dex.setReadOnly();
        return new LiveClassLoader(dex, codeCache, app);
    }

    @Override
    protected synchronized Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
        Class<?> loaded = findLoadedClass(name);
        if (loaded != null) {
            return loaded;
        }
        try {
            return findClass(name);
        } catch (ClassNotFoundException notLive) {
            return super.loadClass(name, resolve);
        }
    }
}
