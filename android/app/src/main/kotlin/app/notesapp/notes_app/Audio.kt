package app.notesapp.notes_app

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Audio plumbing around the models: raw PCM in, AAC out, any file decoded, 48 kHz to 16 kHz. */
object Audio {

    /** Audio pulled a chunk at a time: mono floats and their sample rate, null at the end. */
    interface Source : AutoCloseable {
        fun read(): Pair<FloatArray, Int>?
    }

    /** A raw 16-bit little-endian mono PCM file at [rate], [chunk] samples a read. */
    class Pcm16Source(file: File, private val rate: Int, chunk: Int = rate) : Source {
        private val input = BufferedInputStream(FileInputStream(file), 1 shl 16)
        private val bytes = ByteArray(chunk * 2)

        override fun read(): Pair<FloatArray, Int>? {
            var filled = 0
            while (filled < bytes.size) {
                val n = input.read(bytes, filled, bytes.size - filled)
                if (n < 0) break
                filled += n
            }
            val count = filled / 2
            if (count == 0) return null
            val out = FloatArray(count)
            for (i in 0 until count) {
                val s = (bytes[2 * i].toInt() and 0xff) or (bytes[2 * i + 1].toInt() shl 8)
                out[i] = s.toShort() / 32768f
            }
            return out to rate
        }

        override fun close() = input.close()
    }

    /** Any audio file the platform decodes (a path or a content:// URI), downmixed to mono. */
    class DecodedSource(context: Context, source: String) : Source {
        private val extractor = MediaExtractor()
        private val codec: MediaCodec
        private val info = MediaCodec.BufferInfo()
        private var rate: Int
        private var channels: Int
        private var inputDone = false
        private var outputDone = false

        init {
            if (source.startsWith("content://")) extractor.setDataSource(context, Uri.parse(source), null)
            else extractor.setDataSource(source)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IllegalArgumentException("no audio in $source")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()
        }

        override fun read(): Pair<FloatArray, Int>? {
            while (!outputDone) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val n = extractor.readSampleData(codec.getInputBuffer(i)!!, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(i, 0, n, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    rate = codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                } else if (o >= 0) {
                    var out: FloatArray? = null
                    if (info.size > 0) {
                        val pcm = codec.getOutputBuffer(o)!!.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                        val frames = pcm.remaining() / channels
                        out = FloatArray(frames)
                        for (f in 0 until frames) {
                            var sum = 0f
                            for (c in 0 until channels) sum += pcm.get(f * channels + c)
                            out[f] = sum / channels / 32768f
                        }
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    if (out != null && out.isNotEmpty()) return out to rate
                }
            }
            return null
        }

        override fun close() {
            codec.stop()
            codec.release()
            extractor.release()
        }
    }

    /** [source] regrouped into blocks of [seconds] (the last one shorter), for the enhancer. */
    fun blocks(source: Source, seconds: Int): Sequence<Pair<FloatArray, Int>> = sequence {
        var pending = GrowableFloats(1)
        var rate = 0
        while (true) {
            val (chunk, r) = source.read() ?: break
            if (rate != 0 && r != rate && pending.size > 0) {
                yield(pending.toArray() to rate)
                pending = GrowableFloats(1)
            }
            rate = r
            pending.addAll(chunk)
            if (pending.size >= seconds * rate) {
                yield(pending.toArray() to rate)
                pending = GrowableFloats(1)
            }
        }
        if (pending.size > 0) yield(pending.toArray() to rate)
    }

    /**
     * Mono floats to AAC-LC in an .m4a, streamed: [write] as the audio comes, then [finish].
     * 96 kb/s mono keeps cleaned speech transparent at about 0.7 MB a minute.
     */
    class AacWriter(private val file: File, private val rate: Int, bitrate: Int = 96_000) {
        private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        private val muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        private val info = MediaCodec.BufferInfo()
        private var track = -1
        private var queued = 0L // samples handed to the encoder

        init {
            file.parentFile?.mkdirs()
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 shl 16)
            }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
        }

        fun write(samples: FloatArray) {
            val pcm = ShortArray(samples.size) { (samples[it].coerceIn(-1f, 1f) * 32767f).toInt().toShort() }
            var at = 0
            while (at < pcm.size) {
                val i = codec.dequeueInputBuffer(10_000)
                if (i < 0) {
                    drain(false)
                    continue
                }
                val buffer = codec.getInputBuffer(i)!!.order(ByteOrder.LITTLE_ENDIAN)
                val n = minOf(buffer.remaining() / 2, pcm.size - at)
                buffer.asShortBuffer().put(pcm, at, n)
                codec.queueInputBuffer(i, 0, n * 2, queued * 1_000_000L / rate, 0)
                queued += n
                at += n
                drain(false)
            }
        }

        /**
         * End the file. Every step of the shutdown is tried, and an encoder
         * that never produced audio (or a muxer that would not close) is a failed file, deleted,
         * never a silent empty one.
         */
        fun finish() {
            var failure: Exception? = null
            try {
                while (true) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        codec.queueInputBuffer(i, 0, 0, queued * 1_000_000L / rate, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        break
                    }
                    drain(false)
                }
                drain(true)
            } catch (e: Exception) {
                failure = e
            }
            try { codec.stop() } catch (_: Exception) {}
            codec.release()
            try {
                if (track >= 0) muxer.stop() else if (failure == null) failure = IllegalStateException("the encoder produced no audio")
            } catch (e: Exception) {
                failure = failure ?: e
            }
            muxer.release()
            if (failure != null) {
                file.delete()
                throw IllegalStateException("the cleaned audio could not be written: ${failure.message}", failure)
            }
        }

        private fun drain(toEnd: Boolean) {
            while (true) {
                val o = codec.dequeueOutputBuffer(info, if (toEnd) 10_000 else 0)
                when {
                    o == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!toEnd) return
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                    }
                    o >= 0 -> {
                        val buffer = codec.getOutputBuffer(o)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                        if (info.size > 0 && track >= 0) {
                            buffer.position(info.offset).limit(info.offset + info.size)
                            muxer.writeSampleData(track, buffer, info)
                        }
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                }
            }
        }
    }

    /**
     * 48 kHz to 16 kHz for the speech models, streamed across chunks: a 97-tap Blackman-windowed
     * sinc low-pass at 7.2 kHz, then every third sample. Ear and Who would resample on
     * their own; doing it once here keeps one 16 kHz copy of the recording instead of three
     * 48 kHz ones, a third of the memory.
     */
    class Decimator {
        private val taps: FloatArray = run {
            val n = 97
            val cutoff = 7_200.0 / 48_000.0
            val h = DoubleArray(n) { i ->
                val m = i - (n - 1) / 2.0
                val sinc = if (m == 0.0) 2 * cutoff else sin(2 * PI * cutoff * m) / (PI * m)
                val w = 0.42 - 0.5 * cos(2 * PI * i / (n - 1)) + 0.08 * cos(4 * PI * i / (n - 1))
                sinc * w
            }
            val sum = h.sum()
            FloatArray(n) { (h[it] / sum).toFloat() }
        }
        private var history = FloatArray(taps.size - 1)
        private var phase = 0 // where the next kept sample falls in the coming input

        fun process(input: FloatArray, out: GrowableFloats) {
            val joined = FloatArray(history.size + input.size)
            history.copyInto(joined)
            input.copyInto(joined, history.size)
            var i = phase
            while (i < input.size) {
                var acc = 0f
                val base = i // joined[base .. base + taps - 1] ends at input[i]
                for (k in taps.indices) acc += taps[k] * joined[base + k]
                out.add(acc)
                i += 3
            }
            phase = i - input.size
            history = joined.copyOfRange(joined.size - history.size, joined.size)
        }
    }

    /** A float buffer that grows, for audio whose length is known only at the end. */
    class GrowableFloats(initial: Int = 16_000 * 60) {
        private var data = FloatArray(initial)
        var size = 0
            private set

        fun add(v: Float) {
            if (size == data.size) data = data.copyOf(data.size * 2)
            data[size++] = v
        }

        fun addAll(v: FloatArray) {
            if (size + v.size > data.size) data = data.copyOf(maxOf(data.size * 2, size + v.size))
            v.copyInto(data, size)
            size += v.size
        }

        fun toArray(): FloatArray = data.copyOf(size)
    }
}
