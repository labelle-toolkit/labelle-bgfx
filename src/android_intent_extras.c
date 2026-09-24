// Read the launch intent's string extras (labelle-bgfx#139).
//
// `labelle run --platform=android --scene=X` launches the activity with
// `am start ... --es LABELLE_SCENE X` (labelle-cli#397), because an app the
// system starts has no environment the CLI could write into. The shell turns
// the allow-listed extras back into env vars (`android_intent_env.zig`) so the
// engine's `getenv` reads work unchanged. This is the JNI half:
//   activity.getIntent().getStringExtra(key)
//
// In C for the same reason as android_debuggable.c: <jni.h> already declares
// the JNI vtables. Off Android this is an empty TU.
#ifdef __ANDROID__

#include <jni.h>
#include <stddef.h>
#include <string.h>

// For each of the `count` keys, copy its string extra (NUL-terminated) into
// `buf` back to back and store its length in `lens[i]`; -1 means the extra is
// absent (or not a string), -2 that it did not fit in what was left of `buf`.
// `vm` / `clazz` are `ANativeActivity.vm` / `.clazz`. Returns 1 when the intent
// was read, 0 on any JNI failure (then `lens` is all -1: nothing to apply).
int labelle_bgfx_read_intent_extras(void *vm_ptr, void *clazz_ptr, const char *const *keys, int count,
                                    char *buf, size_t buf_cap, int *lens) {
    for (int i = 0; i < count; i++) lens[i] = -1;
    JavaVM *vm = (JavaVM *)vm_ptr;
    jobject activity = (jobject)clazz_ptr;
    if (vm == NULL || activity == NULL || keys == NULL || buf == NULL || lens == NULL) return 0;

    // `android_main` runs on the glue's own thread, which native_app_glue never
    // attaches. Attach if needed, detach only if WE attached (see
    // android_debuggable.c).
    JNIEnv *env = NULL;
    int we_attached = 0;
    jint rc = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (rc == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return 0;
        we_attached = 1;
    } else if (rc != JNI_OK || env == NULL) {
        return 0;
    }

    int ok = 0;
    // Room for the activity class, intent, its class and, per key, the key and
    // value strings; the frame hands them all back in one pop.
    if ((*env)->PushLocalFrame(env, 4 + 2 * count) == JNI_OK) {
        jclass activity_cls = (*env)->GetObjectClass(env, activity);
        jmethodID get_intent = activity_cls ? (*env)->GetMethodID(env, activity_cls, "getIntent", "()Landroid/content/Intent;") : NULL;
        // A launcher-icon launch still has an intent, just no extras; null only
        // if something unusual cleared it. Either way "no extras" is the answer.
        jobject intent = get_intent ? (*env)->CallObjectMethod(env, activity, get_intent) : NULL;
        if (!(*env)->ExceptionCheck(env) && intent != NULL) {
            jclass intent_cls = (*env)->GetObjectClass(env, intent);
            jmethodID get_extra = intent_cls ? (*env)->GetMethodID(env, intent_cls, "getStringExtra", "(Ljava/lang/String;)Ljava/lang/String;") : NULL;
            if (get_extra != NULL) {
                ok = 1;
                size_t used = 0;
                for (int i = 0; i < count && ok; i++) {
                    jstring jkey = (*env)->NewStringUTF(env, keys[i]);
                    if (jkey == NULL || (*env)->ExceptionCheck(env)) {
                        ok = 0;
                        break;
                    }
                    // getStringExtra answers null for a missing key and for an
                    // extra of another type (`--ei`); both read as "absent".
                    jstring jval = (jstring)(*env)->CallObjectMethod(env, intent, get_extra, jkey);
                    if ((*env)->ExceptionCheck(env)) {
                        ok = 0;
                        break;
                    }
                    if (jval != NULL) {
                        const char *chars = (*env)->GetStringUTFChars(env, jval, NULL);
                        if (chars == NULL) {
                            ok = 0; // OOM: an exception is pending
                            break;
                        }
                        size_t len = strlen(chars);
                        if (len + 1 <= buf_cap - used) {
                            memcpy(buf + used, chars, len + 1);
                            lens[i] = (int)len;
                            used += len + 1;
                        } else {
                            lens[i] = -2;
                        }
                        (*env)->ReleaseStringUTFChars(env, jval, chars);
                    }
                }
            }
        }
        // Never hand a pending exception back to the glue's thread.
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            ok = 0;
        }
        (*env)->PopLocalFrame(env, NULL);
    }

    if (!ok) {
        for (int i = 0; i < count; i++) lens[i] = -1;
    }
    if (we_attached) (*vm)->DetachCurrentThread(vm);
    return ok;
}

#endif /* __ANDROID__ */
