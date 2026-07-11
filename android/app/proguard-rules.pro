-dontwarn javax.annotation.Nullable
-dontwarn org.conscrypt.Conscrypt
-dontwarn org.conscrypt.OpenSSLProvider

# ONNX Runtime native libraries
-keep class com.microsoft.onnxruntime.** { *; }
-keep class ai.onnxruntime.** { *; }

# TensorFlow Lite native libraries
-keep class org.tensorflow.lite.** { *; }
-keep class com.google.flatbuffers.** { *; }