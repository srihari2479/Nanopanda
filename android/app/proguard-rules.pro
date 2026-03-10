# tflite_flutter — keep GPU delegate and all TFLite classes from R8 stripping
-keep class org.tensorflow.** { *; }
-dontwarn org.tensorflow.**

# google_mlkit
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# General Flutter
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**