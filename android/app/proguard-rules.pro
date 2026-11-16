# Release builds shrink and rename with R8. Native code that finds Java by name must see the names it was built
# against, or a release build fails where a debug build works.

# The reading voice's JNI shim (cpp/ptts_jni.c) calls Listener.onAudio(float[]) by name.
-keep interface app.notesapp.notes_app.PhononTts$Listener { boolean onAudio(float[]); }

# LiteRT-LM (EmbeddingGemma 2) ships no keep rules, and its native code builds and calls its classes by name.
-keep class com.google.ai.edge.litertlm.** { *; }

# The classes whose native methods are bound by name (Java_app_notesapp_notes_1app_<Class>_<method>).
-keepclasseswithmembernames class app.notesapp.notes_app.** { native <methods>; }
