/* Docket's JNI shim over Cactus's engine (libcactus.a, linked in statically by tool/build_mirage_jni.sh), for one
 * model only: Mirage, which tags a picture (what is in it, and the text it can read). Called from MirageTagger.kt,
 * one call at a time (the engine holds one model; the Kotlin side serializes). */
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cactus.h"

/* The loaded archive: the engine may keep pointers into it, so it lives as long as the process. */
static unsigned char *model;
static char *out;
static const int out_capacity = 4 << 20;

JNIEXPORT jstring JNICALL Java_app_notesapp_notes_1app_MirageTagger_nativeLoad(JNIEnv *env, jclass cls, jstring jpath) {
    (void) cls;
    if (model) return NULL;
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    FILE *f = fopen(path, "rb");
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    if (!f) return (*env)->NewStringUTF(env, "cannot open the model");
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *data = malloc((size_t) n);
    if (!data || fread(data, 1, (size_t) n, f) != (size_t) n) {
        fclose(f);
        free(data);
        return (*env)->NewStringUTF(env, "cannot read the model");
    }
    fclose(f);
    if (cactus_load(data, (unsigned long long) n) < 0) {
        free(data);
        return (*env)->NewStringUTF(env, cactus_last_error());
    }
    if (!(cactus_models() & CACTUS_VISION)) return (*env)->NewStringUTF(env, "not a Mirage model");
    model = data;
    out = malloc(out_capacity);
    return out ? NULL : (*env)->NewStringUTF(env, "out of memory");
}

JNIEXPORT void JNICALL Java_app_notesapp_notes_1app_MirageTagger_nativeThreads(JNIEnv *env, jclass cls, jint threads) {
    (void) env;
    (void) cls;
    cactus_set_threads(threads);
}

/* [rgb]: width*height*3 bytes. The engine's JSON, or null (then nativeError says why). */
JNIEXPORT jstring JNICALL Java_app_notesapp_notes_1app_MirageTagger_nativeDescribe(
    JNIEnv *env, jclass cls, jbyteArray jrgb, jint width, jint height, jstring joptions) {
    (void) cls;
    if (!model) return NULL;
    jbyte *rgb = (*env)->GetByteArrayElements(env, jrgb, NULL);
    const char *options = (*env)->GetStringUTFChars(env, joptions, NULL);
    int code = cactus_describe((const unsigned char *) rgb, width, height, options, NULL, NULL, out, out_capacity);
    (*env)->ReleaseStringUTFChars(env, joptions, options);
    (*env)->ReleaseByteArrayElements(env, jrgb, rgb, JNI_ABORT);
    return code < 0 ? NULL : (*env)->NewStringUTF(env, out);
}

JNIEXPORT jstring JNICALL Java_app_notesapp_notes_1app_MirageTagger_nativeError(JNIEnv *env, jclass cls) {
    (void) cls;
    return (*env)->NewStringUTF(env, cactus_last_error());
}
