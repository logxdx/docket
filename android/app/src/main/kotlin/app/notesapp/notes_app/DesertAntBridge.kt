package app.notesapp.notes_app

import ai.desertant.clear.Clear
import ai.desertant.clear.Options as ClearOptions
import ai.desertant.ear.Ear
import ai.desertant.eye.Eye
import ai.desertant.gist.Gist
import ai.desertant.who.Who
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Desert Ant's on-device models for the notes (lib/app/desert_ant.dart), over one channel:
 *
 *  - the microphone ([Recorder]);
 *  - a recording's steps, each a call so the Dart side decides the route and keeps whatever
 *    a step gives even when a later one fails: prepare (Clear cleans the audio, written as
 *    .m4a, and a 16 kHz copy is kept here), identify (Ear), transcribe with Phonon-2.5 or with
 *    the phone's own on-device recognizer, diarize (Who), refine word times (Align);
 *  - text: topics (Gist), a title (Title);
 *  - pictures: what kind each is and what is in it (Eye; Mirage, PictureEye.kt and MirageTagger.kt).
 *
 * Every model is built from the folder [OfflineModels] filled (from the APK, or downloaded when the
 * user asked), and only when that folder is complete; a missing model is a step the notes do without.
 */
class DesertAntBridge(private val context: Context, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "notes/desertant")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val liveScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var live: LiveTranscriber? = null
    private val offline = OfflineModels(context)
    private val embedder = Embedder(File(context.cacheDir, "embedder"))
    private val recorder = Recorder()
    private val sessions = ConcurrentHashMap<String, Session>()
    private val work = Mutex() // one heavy model job at a time: they share the CPU and memory
    private val extras = Extras(context, offline) { releaseHeavy() }

    /** Notes read aloud (Phonon TTS, English), from its offline folder. */
    private val reader = ReadAloud(
        context,
        modelDir = { offline.directory("phonon-tts")?.let(::File) },
        // App storage the user (and adb) can reach; the models' own folder is replaced when they are pushed.
        customDir = File(context.getExternalFilesDir(null) ?: context.filesDir, "voices"),
    )

    /** Notes read aloud with Android's own voices instead (Settings › Speech). */
    private val androidReader = AndroidReader(context)

    /** A recording being processed: its 16 kHz (or native-rate) copy for the speech models. */
    private class Session(val samples: FloatArray, val rate: Int, val durationSec: Double) {
        var pcm16: File? = null // made on demand for the phone's recognizer
    }

    // Models, built on first use from their offline folders; never one without its folder.
    private val built = HashMap<String, AutoCloseable>()

    /**
     * The models that take hundreds of MB once loaded (the runtime keeps a packed copy of their
     * weights). Only one is kept at a time: loading one closes the others first, so a recording's
     * steps never hold Clear, Ear and Phonon together, which
     * on a 4-6 GB phone gets the app killed by Android's low-memory killer. The last one stays
     * loaded, so using it again is quick. Gist is small and runs on every save: it stays.
     */
    private val heavy = setOf("clear", "ear", "who", "phonon-en", "phonon-p25")

    @Suppress("UNCHECKED_CAST")
    @Synchronized
    private fun <T : AutoCloseable> model(id: String, make: (String) -> T): T? {
        built[id]?.let { return it as T }
        val dir = offline.directory(id) ?: return null
        if (id in heavy) {
            for (other in heavy - id) built.remove(other)?.close()
            extras.release()
        }
        return make(dir).also { built[id] = it }
    }

    /** Close the heavy models (before Align or Title loads, the same rule). */
    @Synchronized
    private fun releaseHeavy() {
        for (id in heavy) built.remove(id)?.close()
    }

    private fun clear() = model("clear") { Clear(context, it) }
    private fun ear() = model("ear") { Ear(context, it) }
    private fun who() = model("who") { Who(context, it) }
    private fun gist() = model("gist") { Gist(context, it) }
    private fun eye() = model("eye") { Eye(context, it) }

    /** A Phonon-2.5 model kept like the SDK models (one heavy model at a time). */
    private class PhononHandle(val model: PhononAsr.Model) : AutoCloseable {
        override fun close() = model.release()
    }

    /**
     * Phonon-2.5 (Fermion Research): the English model for [language] "en", else the 25-language one;
     * null when it cannot run (its models not here, or not an arm64 phone). Pads and Greek final sigma
     * as Fermion's catalog has them.
     */
    private fun phonon(language: String): PhononAsr.Model? {
        if (PhononAsr.unavailable != null) return null
        val english = language.lowercase().startsWith("en") && offline.isReady("phonon-en")
        val id = if (english) "phonon-en" else "phonon-p25"
        return model(id) { dir ->
            PhononHandle(
                PhononAsr.load(
                    java.io.File(dir),
                    threads = 4,
                    leadPadSec = if (english) 0.0 else 0.25,
                    finalSigma = !english,
                ),
            )
        }?.model
    }

    private val canPhonon: Boolean
        get() = PhononAsr.unavailable == null && offline.isReady("phonon-p25")

    init {
        channel.setMethodCallHandler { call, result ->
            scope.launch {
                try {
                    result.success(handle(call))
                } catch (e: Throwable) {
                    result.error("desertant", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    private suspend fun handle(call: MethodCall): Any? = when (call.method) {
        // Models
        "models.prepare" -> withContext(Dispatchers.IO) {
            var last = -1
            offline.install { done, total ->
                val pct = if (total > 0) (done * 100 / total).toInt() else 100
                if (pct != last) {
                    last = pct
                    scope.launch { channel.invokeMethod("models.progress", pct / 100.0) }
                }
            }
            // Models copied over USB for an offline phone (OfflineModels.adopt), checked as downloads are.
            offline.adopt().forEach { android.util.Log.i("OfflineModels", "$it: taken from the copy on the phone") }
            status()
        }
        "models.status" -> status()
        // A Desert Ant model from Hugging Face (Settings › On-device models), each file checked.
        "models.download" -> withContext(Dispatchers.IO) {
            val id = call.argument<String>("id")!!
            var last = -1
            offline.download(id) { done, total ->
                val pct = if (total > 0) (done * 1000 / total).toInt() else 1000
                if (pct != last) {
                    last = pct
                    scope.launch { channel.invokeMethod("models.downloadProgress", mapOf("id" to id, "fraction" to pct / 1000.0)) }
                }
            }
            status()
        }
        "models.cancel" -> offline.cancel(call.argument<String>("id")!!).let { null }
        "models.remove" -> work.withLock {
            val id = call.argument<String>("id")!!
            synchronized(this) { built.remove(id)?.close() }
            extras.release()
            offline.remove(id)
            status()
        }

        // Mirage's tags for a picture (hidden search terms: things in it, text read from it, a description), or null
        // when Mirage is not on the phone.
        "pictures.tag" -> withContext(Dispatchers.Default) {
            val dir = offline.directory("mirage") ?: return@withContext null
            MirageTagger.tag(dir, call.argument<ByteArray>("bytes")!!)
        }

        // Eye's look at a picture (PictureEye: its kind, what is in it, a rotation), or null when Eye is not on the phone.
        "pictures.look" -> withContext(Dispatchers.Default) {
            val eye = eye() ?: return@withContext null
            val bitmap = uprightPicture(call.argument<ByteArray>("bytes")!!, PictureEye.SIDE)
                ?: throw IllegalArgumentException("not a picture Android can read")
            try {
                PictureEye.read(eye.analyze(bitmap))
            } finally {
                bitmap.recycle()
            }
        }

        // EmbeddingGemma 2's vectors for search by meaning (texts carry their prompts; pictures as they are), or null
        // when it is not on the phone.
        "embed.texts" -> withContext(Dispatchers.Default) {
            val dir = offline.directory("embeddinggemma") ?: return@withContext null
            embedder.texts(dir, call.argument<List<String>>("texts")!!)
        }
        "embed.image" -> withContext(Dispatchers.Default) {
            val dir = offline.directory("embeddinggemma") ?: return@withContext null
            embedder.image(dir, call.argument<ByteArray>("bytes")!!)
        }

        // Microphone
        "record.start" -> {
            if (call.argument<Boolean>("live") == true) startLive() else stopLive()
            recorder.start(File(call.argument<String>("path")!!))
            // Keeps the microphone on with the screen locked (Android silences a backgrounded app).
            RecordingService.recording(context, true)
            recordState()
        }
        "record.pause" -> recorder.pause().let { recordState() }
        "record.resume" -> recorder.resume().let { recordState() }
        "record.state" -> recordState()
        "record.stop" -> withContext(Dispatchers.IO) {
            val stopped = recorder.stop()
            stopLive()
            RecordingService.recording(context, false)
            stopped?.let { mapOf("path" to it.first.path, "ms" to it.second) }
        }
        // Recordings being processed ("Transcribing on this phone"), or none (null): full speed with the app left.
        "work" -> RecordingService.working(context, call.argument<String>("what")).let { null }

        // A recording's steps
        "session.prepare" -> work.withLock { withContext(Dispatchers.Default) { prepare(call) } }
        "session.identify" -> work.withLock { identify(session(call)) }
        "session.phonon" -> work.withLock {
            transcribePhonon(session(call), call.argument<String>("language") ?: "")
        }
        "session.device" -> work.withLock {
            transcribeOnDevice(session(call), call.argument<String>("language")!!)
        }
        "session.diarize" -> work.withLock { diarize(session(call)) }
        "session.align" -> work.withLock {
            val s = session(call)
            extras.align(s.samples, s.rate, call.argument<List<List<Any>>>("words")!!, call.argument<String>("language") ?: "")
        }
        "session.close" -> {
            sessions.remove(call.argument<String>("id"))?.pcm16?.delete()
            null
        }

        // Reading aloud
        // "engine": "android" reads with Android's own voices; otherwise Docket's (Phonon TTS).
        "speech.voices" -> if (call.argument<String>("engine") == "android") {
            suspendCancellableCoroutine { done -> androidReader.voices { done.resume(it) } }
        } else {
            withContext(Dispatchers.IO) { if (reader.available()) reader.voices() else emptyList() }
        }
        "speech.start" -> if (call.argument<String>("engine") == "android") {
            androidReader.start(
                call.argument<List<String>>("sentences")!!,
                call.argument<Int>("from") ?: 0,
                call.argument<String>("voice"),
                (call.argument<Double>("speed") ?: 1.0).toFloat(),
                onSentence = { i -> channel.invokeMethod("speech.sentence", mapOf("index" to i)) },
                onDone = { completed, error ->
                    channel.invokeMethod("speech.done", mapOf("completed" to completed, "error" to error))
                },
            )
            null
        } else {
            if (!reader.available()) throw IllegalStateException("the reading voice is not on this phone")
            reader.start(
                call.argument<List<String>>("sentences")!!,
                call.argument<Int>("from") ?: 0,
                call.argument<String>("voice"),
                (call.argument<Double>("speed") ?: 1.0).toFloat(),
                onSentence = { i -> channel.invokeMethod("speech.sentence", mapOf("index" to i)) },
                onDone = { completed, error ->
                    channel.invokeMethod("speech.done", mapOf("completed" to completed, "error" to error))
                },
            )
            null
        }
        "speech.custom" -> withContext(Dispatchers.IO) { reader.customVoices() }
        "speech.addVoice" -> withContext(Dispatchers.IO) {
            val source = File(call.argument<String>("path")!!)
            try {
                reader.addVoice(source, call.argument<String>("name")!!)
            } finally {
                if (source.path.startsWith(context.cacheDir.path)) source.delete()
            }
        }
        "speech.removeVoice" -> withContext(Dispatchers.IO) { reader.removeVoice(call.argument<String>("name")!!); null }
        "speech.renameVoice" -> withContext(Dispatchers.IO) {
            reader.renameVoice(call.argument<String>("from")!!, call.argument<String>("to")!!)
        }
        "speech.pause" -> (if (call.argument<String>("engine") == "android") androidReader.pause() else reader.pause()).let { null }
        "speech.resume" -> (if (call.argument<String>("engine") == "android") androidReader.resume() else reader.resume()).let { null }
        "speech.stop" -> {
            // Both: switching engine while one reads leaves nothing reading.
            reader.stop()
            androidReader.stop()
            null
        }

        // Text
        "text.topics" -> gist()?.classify(call.argument<String>("text")!!, topK = call.argument<Int>("limit") ?: 3)
            ?.map { mapOf("slug" to it.slug, "name" to it.name, "score" to it.score) }
        "text.title" -> work.withLock { extras.title(call.argument<String>("text")!!) }

        else -> throw IllegalArgumentException("no such call: ${call.method}")
    }

    /**
     * Words while recording: Phonon-2.5's passes (LiveTranscriber) on the microphone, decimated
     * to 16 kHz. A pass runs only when no other model job is (it never waits on, or unloads a model
     * under, an earlier recording still being processed); a skipped pass is caught up by the next.
     */
    private fun startLive() {
        stopLive()
        // Phonon-2.5 (25 languages, no language needed up front): a pass over the held audio takes a
        // fraction of a second, so the words refresh every second.
        if (!canPhonon) return
        val decimator = Audio.Decimator()
        val transcriber = LiveTranscriber(
            liveScope,
            transcribe = { samples ->
                if (!work.tryLock()) null
                else try {
                    val pcm = ShortArray(samples.size) { (samples[it].coerceIn(-1f, 1f) * 32767f).toInt().toShort() }
                    phonon("")?.transcribe(pcm)?.map { LiveTranscriber.Word(it.text, it.start, it.end) }
                } finally {
                    work.unlock()
                }
            },
            onUpdate = { settled, tentative ->
                scope.launch {
                    channel.invokeMethod(
                        "live.update",
                        mapOf("settled" to settled.map { it.text }, "tentative" to tentative.map { it.text }),
                    )
                }
            },
        )
        live = transcriber
        recorder.onAudio = { block ->
            val out = Audio.GrowableFloats(block.size / 3 + 2)
            decimator.process(block, out)
            transcriber.append(out.toArray())
        }
    }

    private fun stopLive() {
        recorder.onAudio = null
        live?.stop()
        live = null
    }

    private fun status(): Map<String, Any?> = mapOf(
        "bundled" to offline.bundledIds(),
        // Ready: carried by the APK, or downloaded, with every file in place.
        "ready" to (offline.bundledIds() + offline.downloadIds()).filter(offline::isReady),
        "align" to extras.canAlign,
        "phonon" to canPhonon,
        // The models to download, and the bytes each takes.
        "downloads" to offline.downloadIds().associateWith { offline.sizeOf(it) },
        "speech" to reader.available(),
        "title" to extras.canTitle,
    )

    private fun recordState() = mapOf(
        "recording" to recorder.isRecording,
        "paused" to recorder.isPaused,
        "ms" to recorder.elapsedMs,
        "level" to recorder.micLevel,
        "problem" to recorder.problem,
    )

    private fun session(call: MethodCall): Session =
        sessions[call.argument<String>("id")] ?: throw IllegalStateException("that recording is no longer open")

    /**
     * Read a recording: a raw 48 kHz PCM file just recorded, or any audio file (a note's .m4a to
     * transcribe again). With `out`, Clear cleans it first and the cleaned audio is written there
     * as AAC; either way a 16 kHz copy is kept for the speech models.
     *
     * Clear is fed two minutes at a time, each with one second of the audio before it so its
     * filters have settled when the kept part begins, so memory stays flat for a long recording.
     */
    private suspend fun prepare(call: MethodCall): Map<String, Any?> {
        val source = call.argument<String>("source")!!
        val raw = call.argument<Boolean>("raw") ?: false
        val out = call.argument<String>("out")?.let(::File)
        val id = call.argument<String>("id")!!
        // Clear only when asked: a recording is kept as recorded until the user cleans it up.
        val clean = call.argument<Boolean>("clean") ?: false
        val enhancer = if (out != null && clean) clear() else null
        var enhanced = enhancer != null
        var problem: String? = null

        val analysis = Audio.GrowableFloats()
        val decimator = Audio.Decimator()
        var analysisRate = 16_000
        var writer: Audio.AacWriter? = null
        val chunkSec = 120
        val warmSec = 1
        var carry = FloatArray(0)
        var seconds = 0.0
        val total = if (raw) File(source).length() / 2.0 / Recorder.SAMPLE_RATE else 0.0

        suspend fun emit(block: FloatArray, rate: Int) {
            // The kept audio, at the delivery rate: through Clear, or as it came.
            var kept: FloatArray
            var keptRate = rate
            if (enhanced && enhancer != null) {
                try {
                    val input = if (carry.isEmpty()) block else carry + block
                    val r = enhancer.enhance(input, rate.toDouble(), ClearOptions())
                    val drop = (carry.size.toDouble() / rate * r.sampleRate).toInt()
                    kept = r.samples.copyOfRange(minOf(drop, r.samples.size), r.samples.size)
                    keptRate = r.sampleRate.toInt()
                } catch (e: Exception) {
                    // Keep the recording rather than lose it: the rest goes through as recorded.
                    enhanced = false
                    problem = "Audio cleanup failed (${e.message}); the recording is kept as recorded."
                    kept = block
                }
                carry = block.copyOfRange(maxOf(0, block.size - warmSec * rate), block.size)
            } else {
                kept = block
            }
            if (out != null) {
                val w = writer ?: Audio.AacWriter(out, keptRate).also { writer = it }
                w.write(kept)
            }
            if (keptRate == 48_000) {
                decimator.process(kept, analysis)
            } else {
                analysisRate = keptRate
                analysis.addAll(kept)
            }
            seconds += block.size.toDouble() / rate
            if (total > 0) scope.launch {
                channel.invokeMethod("session.progress", mapOf("id" to id, "fraction" to (seconds / total).coerceAtMost(1.0)))
            }
        }

        val input: Audio.Source =
            if (raw) Audio.Pcm16Source(File(source), Recorder.SAMPLE_RATE, Recorder.SAMPLE_RATE)
            else Audio.DecodedSource(context, source)
        input.use { for ((block, rate) in Audio.blocks(it, chunkSec)) emit(block, rate) }
        writer?.finish()
        if (out != null && clean && enhancer == null) problem = "Audio cleanup needs the STT model (Settings › On-device models); the recording is kept as recorded."
        val samples = analysis.toArray()
        if (samples.isEmpty()) throw IllegalStateException("the recording is empty")
        sessions[id] = Session(samples, analysisRate, samples.size.toDouble() / analysisRate)
        return mapOf(
            "id" to id,
            "ms" to (samples.size * 1000L / analysisRate),
            "enhanced" to (out != null && enhanced),
            "problem" to problem,
        )
    }

    private suspend fun identify(s: Session): Map<String, Any?>? {
        val ear = ear() ?: return null
        val d = ear.identify(s.samples, s.rate.toDouble())
        return mapOf(
            "candidates" to d.candidates.map { listOf(it.language, it.probability) },
            "reliable" to d.isReliable,
        )
    }

    private suspend fun transcribePhonon(s: Session, language: String): Map<String, Any?>? {
        val model = phonon(language) ?: return null
        val pcm = toPcm16k(s)
        val words = withContext(Dispatchers.Default) { model.transcribeLong(pcm) }
        return mapOf("text" to words.joinToString(" ") { it.text }, "words" to words.map { listOf(it.text, it.start, it.end) }, "timed" to true)
    }

    /** The session's audio as 16 kHz 16-bit samples (what Phonon reads). */
    private fun toPcm16k(s: Session): ShortArray {
        val samples = if (s.rate == 16_000) s.samples else resampleLinear(s.samples, s.rate, 16_000)
        return ShortArray(samples.size) { (samples[it].coerceIn(-1f, 1f) * 32767f).toInt().toShort() }
    }

    private suspend fun transcribeOnDevice(s: Session, language: String): Map<String, Any?> {
        val pcm = s.pcm16 ?: withContext(Dispatchers.IO) { writePcm16(s) }.also { s.pcm16 = it }
        return when (val o = OnDeviceRecognizer.transcribe(context, pcm, s.durationSec, language)) {
            is OnDeviceRecognizer.Outcome.Heard -> mapOf(
                "text" to o.text,
                "words" to o.words.map { listOf(it.text, it.start, it.end) },
                "timed" to o.timed,
                "tag" to o.tag,
            )
            is OnDeviceRecognizer.Outcome.Unavailable -> mapOf("problem" to o.reason)
        }
    }

    private suspend fun diarize(s: Session): Map<String, Any?>? {
        val who = who() ?: return null
        // A cough, a laugh or a jingle can get a number of its own; under 3% of the talk is not a speaker.
        val d = who.diarize(s.samples, s.rate.toDouble()).keepingSpeakers(0.03)
        return mapOf("speakers" to d.speakerCount, "turns" to d.turns.map { listOf(it.speaker, it.start, it.end) })
    }

    /** The session's audio as 16 kHz 16-bit PCM, for the phone's recognizer. */
    private fun writePcm16(s: Session): File {
        val samples = if (s.rate == 16_000) s.samples else resampleLinear(s.samples, s.rate, 16_000)
        val file = File.createTempFile("ondevice", ".pcm", context.cacheDir)
        file.outputStream().buffered(1 shl 16).use { out ->
            for (v in samples) {
                val x = (v.coerceIn(-1f, 1f) * 32767f).toInt()
                out.write(x and 0xff)
                out.write(x shr 8 and 0xff)
            }
        }
        return file
    }

    private fun resampleLinear(x: FloatArray, from: Int, to: Int): FloatArray {
        val n = (x.size.toLong() * to / from).toInt()
        return FloatArray(n) { i ->
            val t = i.toDouble() * from / to
            val a = t.toInt().coerceAtMost(x.size - 1)
            val b = (a + 1).coerceAtMost(x.size - 1)
            val f = (t - a).toFloat()
            x[a] * (1 - f) + x[b] * f
        }
    }
}
