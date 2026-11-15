# Desert Ant SDK changes for Docket

Docket uses [Desert Ant Labs' SDK](https://github.com/Desert-Ant-Labs/desert-ant-core) v4.3.0: `ai.desertant:core`
(the LiteRT runtime) from Maven, and its six models built from source with these patches by
`tool/build_desert_ant.sh` into `android/app/libs/` (arm64-v8a):

1. `0001` Align on Android (`ai.desertant:align`): word-timestamp refinement, Desert Ant's Swift code built
   for Android; words are NFC-normalized in Kotlin.
2. `0002` Title on Android (`ai.desertant:title`): a C engine that runs the published 6-bit MLX Granite
   weights as-is, wired through the SDK's native ABI (licensing included).
3. `0003` One native library for the six models (`libDesertAntAndroid.so`): Clear, Ear, Who, Gist, Align and
   Title in one dynamic product, so the static Swift runtime and the shared code are linked once (55 MB)
   instead of once per model (~56 MB each, 339 MB for six). The model AARs then carry Kotlin only.

By hand, the same:

```sh
git clone https://github.com/Desert-Ant-Labs/desert-ant-core && cd desert-ant-core
git checkout v4.3.0 && git am ../desert-ant-core-patches/000[1-3]-*.patch
export DAL_ANDROID_SHARED=DesertAntAndroid
for m in clear ear who gist align title; do mise run build:android $m --abi arm64-v8a; done
mise run build:android-natives shared --abi arm64-v8a   # -> .build-android/shared/jniLibs
```

The SDK and its models are under the Desert Ant Labs Source-Available License
(https://license.desertant.com/1.0).
