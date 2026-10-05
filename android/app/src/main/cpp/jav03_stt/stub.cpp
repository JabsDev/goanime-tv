// Stub 32-bit (ver CMakeLists): o ONNX Runtime do sherpa só é empacotado em
// 64-bit. A lib existe p/ empacotamento uniforme; qualquer chamada JNI falha
// com UnsatisfiedLinkError, convertido em erro amigável no Dart.
#include <jni.h>

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_example_goanime_1tv_Jav03Bridge_nativeLoad(
    JNIEnv*, jobject, jstring, jstring, jstring, jint,
    jlong, jlong, jlong, jlong, jlong) {
  return 0;
}

JNIEXPORT jstring JNICALL
Java_com_example_goanime_1tv_Jav03Bridge_nativeDecode(
    JNIEnv* env, jobject, jlong, jfloatArray) {
  return env->NewStringUTF("");
}

JNIEXPORT void JNICALL
Java_com_example_goanime_1tv_Jav03Bridge_nativeFree(JNIEnv*, jobject, jlong) {}

}
