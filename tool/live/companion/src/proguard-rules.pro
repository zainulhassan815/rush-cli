# Prevents extension classes (annotated with `@Extension`) from being removed, renamed or repackged.
-keep @com.google.appinventor.components.annotations.Extension public class * {
  public *;
}

# Prevents helper classes from being removed, renamed or repackaged
-keepnames class * implements com.google.appinventor.components.common.OptionList {
  *;
}

# ProGuard sometimes (randomly) renames references to the following classes in 
# the extensions, this rule prevents that from happening. Keep this rule even
# if you don't use these classes in your extension.
-keeppackagenames gnu.kawa**, gnu.expr**

# Repackages all the optimized classes into dev.rush.live.companion.repackaged package in resulting
# AIX. Repackaging is necessary to avoid clashes with the other extensions that
# might be using same libraries as you.
-repackageclasses dev.rush.live.companion.repacked
