// Stub 32-bit (ver CMakeLists): o ONNX Runtime do sherpa só é empacotado em
// 64-bit. A lib existe p/ empacotamento uniforme; chamadas JNI falham no Dart.
#include <jni.h>

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_example_goanime_1tv_Seq2SeqBridge_nativeLoad(
    JNIEnv*, jobject, jstring, jstring, jint) {
  return 0;
}

JNIEXPORT jstring JNICALL
Java_com_example_goanime_1tv_Seq2SeqBridge_nativeFix(
    JNIEnv* env, jobject, jlong, jstring) {
  return env->NewStringUTF("");
}

JNIEXPORT void JNICALL
Java_com_example_goanime_1tv_Seq2SeqBridge_nativeFree(JNIEnv*, jobject, jlong) {}

}
