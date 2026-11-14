/*
 * Docket's bridge to Gradium's Phonon text-to-speech (xn-ptts v0.6.0, libptts_ffi.so, MIT OR
 * Apache-2.0): ptts.h's six calls for PhononTts.kt. A small JNI shim instead of JNA, so a release
 * build's R8 has nothing to strip. Built by tool/build_ptts_jni.sh for arm64-v8a and x86_64.
 */
#include <jni.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* ptts.h (xn-ptts v0.6.0) */
typedef struct {
    uint32_t frames;
    size_t samples;
    double ttfa_ms;
    double total_ms;
} PttsResult;
typedef bool (*PttsFrameFn)(const float *pcm, size_t n, void *user);
extern void *ptts_new(const char *model_dir, uint32_t threads, const char *lang);
extern const char *ptts_last_error(void *handle);
extern const char *ptts_voices(void *handle);
extern bool ptts_set_voice(void *handle, const char *name);
extern bool ptts_speak(void *handle, const char *text, PttsFrameFn on_frame, void *user, PttsResult *out);
extern void ptts_free(void *handle);

static jstring error_of(JNIEnv *env, void *handle) {
    const char *e = ptts_last_error(handle);
    return (*env)->NewStringUTF(env, e ? e : "the voice failed");
}

JNIEXPORT jlong JNICALL Java_app_notesapp_notes_1app_PhononTts_nativeNew(JNIEnv *env, jclass cls, jstring dir, jint threads,
                                                                       jstring lang) {
    const char *d = (*env)->GetStringUTFChars(env, dir, NULL);
    const char *l = (*env)->GetStringUTFChars(env, lang, NULL);
    void *h = ptts_new(d, (uint32_t)threads, l);
    (*env)->ReleaseStringUTFChars(env, dir, d);
    (*env)->ReleaseStringUTFChars(env, lang, l);
    return (jlong)(intptr_t)h;
}

JNIEXPORT jstring JNICALL Java_app_notesapp_notes_1app_PhononTts_nativeError(JNIEnv *env, jclass cls, jlong handle) {
    return error_of(env, (void *)(intptr_t)handle);
}

/* The voices: ptts_voices' block of NUL-terminated names, ended by an empty one. */
JNIEXPORT jobjectArray JNICALL Java_app_notesapp_notes_1app_PhononTts_nativeVoices(JNIEnv *env, jclass cls, jlong handle) {
    const char *block = ptts_voices((void *)(intptr_t)handle);
    int n = 0;
    for (const char *p = block; p && *p; p += strlen(p) + 1) n++;
    jobjectArray out = (*env)->NewObjectArray(env, n, (*env)->FindClass(env, "java/lang/String"), NULL);
    int i = 0;
    for (const char *p = block; p && *p; p += strlen(p) + 1) {
        jstring s = (*env)->NewStringUTF(env, p);
        (*env)->SetObjectArrayElement(env, out, i++, s);
        (*env)->DeleteLocalRef(env, s);
    }
    return out;
}

JNIEXPORT jboolean JNICALL Java_app_notesapp_notes_1app_PhononTts_nativeSetVoice(JNIEnv *env, jclass cls, jlong handle,
                                                                               jstring name) {
    const char *v = (*env)->GetStringUTFChars(env, name, NULL);
    bool ok = ptts_set_voice((void *)(intptr_t)handle, v);
    (*env)->ReleaseStringUTFChars(env, name, v);
    return ok ? JNI_TRUE : JNI_FALSE;
}

struct speaking {
    JNIEnv *env;
    jobject listener;
    jmethodID on_audio;
};

/* Each piece of audio to PhononTts.Listener.onAudio(float[]): false (or a Java exception) stops. */
static bool on_frame(const float *pcm, size_t n, void *user) {
    struct speaking *s = user;
    JNIEnv *env = s->env;
    jfloatArray chunk = (*env)->NewFloatArray(env, (jsize)n);
    if (!chunk) return false;
    (*env)->SetFloatArrayRegion(env, chunk, 0, (jsize)n, pcm);
    jboolean go = (*env)->CallBooleanMethod(env, s->listener, s->on_audio, chunk);
    (*env)->DeleteLocalRef(env, chunk);
    if ((*env)->ExceptionCheck(env)) return false;
    return go == JNI_TRUE;
}

JNIEXPORT jboolean JNICALL Java_app_notesapp_notes_1app_PhononTts_nativeSpeak(JNIEnv *env, jclass cls, jlong handle,
                                                                            jstring text, jobject listener) {
    jclass type = (*env)->GetObjectClass(env, listener);
    struct speaking s = {env, listener, (*env)->GetMethodID(env, type, "onAudio", "([F)Z")};
    if (!s.on_audio) return JNI_FALSE;
    const char *t = (*env)->GetStringUTFChars(env, text, NULL);
    PttsResult result;
    memset(&result, 0, sizeof result);
    bool ok = ptts_speak((void *)(intptr_t)handle, t, on_frame, &s, &result);
    (*env)->ReleaseStringUTFChars(env, text, t);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_app_notesapp_notes_1app_PhononTts_nativeFree(JNIEnv *env, jclass cls, jlong handle) {
    ptts_free((void *)(intptr_t)handle);
}
