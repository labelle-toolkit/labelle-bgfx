// Is the RUNNING apk marked `android:debuggable`? (labelle-assembler#737)
//
// The generated Android main reads verification knobs from a `labelle_env`
// file in the app's own internal data dir. That file can only be CREATED
// through `adb shell run-as <package>`, which the platform grants only for a
// debuggable APK — but `run-as` gates creation, not the runtime READ. Updating
// a debuggable build to a release build leaves the file in place, and the
// release build would go on honouring it. So the read itself has to be gated
// on this process's OWN `ApplicationInfo.FLAG_DEBUGGABLE`.
//
// There is no NDK C API for that flag, so this is the JNI walk:
//   activity.getApplicationInfo().flags & FLAG_DEBUGGABLE
//
// It lives in C rather than Zig because <jni.h> already declares the
// JNINativeInterface / JNIInvokeInterface vtables; hand-rolling those ~230
// ordered function-pointer slots in Zig to reach four of them would be a
// silent-wrong-field hazard for no gain. The NDK sysroot is already wired onto
// this module for `android_native_app_glue.c`.
//
// Off Android this is an empty TU (same convention as
// `android_gamepad_jni.c`).
#ifdef __ANDROID__

#include <jni.h>
#include <stddef.h>

// android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE. A platform constant
// since API 1; spelled out here because the NDK exposes no header for it.
#define LABELLE_FLAG_DEBUGGABLE 0x00000002

// `vm` is `ANativeActivity.vm`, `clazz` the activity's own jobject
// (`ANativeActivity.clazz`). Returns 1 (debuggable), 0 (not), or 0 on any JNI
// failure — fail CLOSED: an unanswerable question must not enable the knob
// channel.
int labelle_bgfx_app_is_debuggable(void *vm_ptr, void *clazz_ptr) {
    JavaVM *vm = (JavaVM *)vm_ptr;
    jobject activity = (jobject)clazz_ptr;
    if (vm == NULL || activity == NULL) return 0;

    // `android_main` runs on the glue's own thread, which the NDK's
    // native_app_glue never attaches to the VM. Attach if needed, and detach
    // again only if WE attached — detaching a thread someone else attached
    // would tear down their env.
    JNIEnv *env = NULL;
    int we_attached = 0;
    jint rc = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (rc == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return 0;
        we_attached = 1;
    } else if (rc != JNI_OK || env == NULL) {
        return 0;
    }

    int debuggable = 0;

    // PushLocalFrame bounds the local refs below: the walk allocates five and
    // this returns them all in one call, so a repeated query (it is cached on
    // the Zig side, but cheap insurance) cannot leak the local-ref table.
    if ((*env)->PushLocalFrame(env, 8) == JNI_OK) {
        jclass activity_cls = (*env)->GetObjectClass(env, activity);
        if (activity_cls != NULL) {
            // android.content.Context.getApplicationInfo()
            jmethodID get_app_info = (*env)->GetMethodID(
                env, activity_cls, "getApplicationInfo",
                "()Landroid/content/pm/ApplicationInfo;");
            if (get_app_info != NULL) {
                jobject app_info =
                    (*env)->CallObjectMethod(env, activity, get_app_info);
                if (!(*env)->ExceptionCheck(env) && app_info != NULL) {
                    jclass app_info_cls = (*env)->GetObjectClass(env, app_info);
                    if (app_info_cls != NULL) {
                        jfieldID flags_fid =
                            (*env)->GetFieldID(env, app_info_cls, "flags", "I");
                        if (flags_fid != NULL) {
                            jint flags =
                                (*env)->GetIntField(env, app_info, flags_fid);
                            debuggable =
                                (flags & LABELLE_FLAG_DEBUGGABLE) ? 1 : 0;
                        }
                    }
                }
            }
        }
        // Any JNI lookup above may have raised; clear before popping so we
        // never hand a pending exception back to the glue's thread.
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            debuggable = 0;
        }
        (*env)->PopLocalFrame(env, NULL);
    }

    if (we_attached) (*vm)->DetachCurrentThread(vm);
    return debuggable;
}

#endif /* __ANDROID__ */
