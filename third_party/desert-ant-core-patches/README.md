# Desert Ant SDK changes for Docket

Docket uses [Desert Ant Labs' SDK](https://github.com/Desert-Ant-Labs/desert-ant-core) v4.3.0 from Maven,
plus two models it ships for Apple only, ported to Android here. `tool/build_desert_ant.sh` builds them from
these patches into `android/app/libs/*.aar` (arm64-v8a):

1. `0001` Align on Android (`ai.desertant:align`): word-timestamp refinement, Desert Ant's Swift code built
   for Android; words are NFC-normalized in Kotlin.
2. `0002` Title on Android (`ai.desertant:title`): a C engine that runs the published 6-bit MLX Granite
   weights as-is, wired through the SDK's native ABI (licensing included).
3. `0003` an experiment, not used by the app: Voz's encoder in fp16 math with fp32 accumulation.

By hand, the same:

```sh
git clone https://github.com/Desert-Ant-Labs/desert-ant-core && cd desert-ant-core
git checkout v4.3.0 && git am ../desert-ant-core-patches/000[12]-*.patch
mise run build:android align --abi arm64-v8a && mise run build:android title --abi arm64-v8a
```

The SDK and its models are under the Desert Ant Labs Source-Available License
(https://license.desertant.com/1.0).
