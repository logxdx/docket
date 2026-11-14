/* Phonon-2.5 speech recognition on the phone (PhononAsr.kt).
 *
 * Fermion Research's engine (libphonon2_enc / libphonon2_tdt, Apache-2.0, fetched by tool/build_asr.sh) runs the encoder
 * and the decode loop; what its docs/android.md leaves to the app is here: the .fermion container records, the log-mel
 * front end and the encoder projector. The engine is opened with dlopen, its tier (dotprod or base) chosen from the CPU's
 * features, so nothing prebuilt is linked. Token ids go back to Kotlin with the encoder frame each was emitted at and its
 * predicted duration (in encoder frames, 80 ms each); Kotlin turns them into timed words. Docket ships its models already
 * unpacked, so there is no .tar.zst unpacking (or zstd) here, nor a hotword bias.
 * One decode at a time per process (the engine's thread pools are process-global; PhononAsr.kt serialises the calls). */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "phonon2.h"

/* ---------------------------------------------------------------- the engine, through dlopen */
#define FN(name) static __typeof__(&name) p_##name
FN(phonon2_cpu_set_threads);
FN(phonon2_tdt_set_threads);
FN(phonon2_cpu_create_onedot_wire_many);
FN(phonon2_cpu_destroy);
FN(phonon2_enc_create);
FN(phonon2_enc_destroy);
FN(phonon2_enc_set_subsampling);
FN(phonon2_enc_set_layer);
FN(phonon2_enc_out_len);
FN(phonon2_enc_forward);
FN(phonon2_tdt_create);
FN(phonon2_tdt_destroy);
FN(phonon2_tdt_decode_timed);

static int engine_open(char *err, size_t cap) {
    if (p_phonon2_enc_forward) return 0;
    /* The dotprod tier needs dot product and LSE atomics (every phone since about 2018); else the NEON-only one. */
    unsigned long h = getauxval(AT_HWCAP);
    int fast = (h & (1ul << 20)) && (h & (1ul << 8));
    const char *enc_name = fast ? "libphonon2_enc-android-arm64-v8a.so" : "libphonon2_enc-android-arm64-v8a-base.so";
    const char *tdt_name = fast ? "libphonon2_tdt-android-arm64-v8a.so" : "libphonon2_tdt-android-arm64-v8a-base.so";
    void *enc = dlopen(enc_name, RTLD_NOW | RTLD_LOCAL);
    void *tdt = dlopen(tdt_name, RTLD_NOW | RTLD_LOCAL);
    if (!enc || !tdt) {
        snprintf(err, cap, "the speech engine is not in this build (%s)", dlerror());
        return -1;
    }
#define SYM(lib, name)                                                         \
    if (!(p_##name = (__typeof__(&name))dlsym(lib, #name))) {                  \
        snprintf(err, cap, "the speech engine lacks %s", #name);               \
        return -1;                                                             \
    }
    SYM(enc, phonon2_cpu_set_threads)
    SYM(enc, phonon2_cpu_create_onedot_wire_many)
    SYM(enc, phonon2_cpu_destroy)
    SYM(enc, phonon2_enc_create)
    SYM(enc, phonon2_enc_destroy)
    SYM(enc, phonon2_enc_set_subsampling)
    SYM(enc, phonon2_enc_set_layer)
    SYM(enc, phonon2_enc_out_len)
    SYM(tdt, phonon2_tdt_set_threads)
    SYM(tdt, phonon2_tdt_create)
    SYM(tdt, phonon2_tdt_destroy)
    SYM(tdt, phonon2_tdt_decode_timed)
    SYM(enc, phonon2_enc_forward)
    return 0;
}

/* ---------------------------------------------------------------- container records */
typedef struct {
    char name[128];
    char kind[16];
    size_t off, bytes;
    int nd, shape[4];
} Rec;

typedef struct {
    const uint8_t *base;
    Rec *recs;
    int n;
} Container;

static Rec *find(Container *c, const char *name) {
    for (int i = 0; i < c->n; i++)
        if (!strcmp(c->recs[i].name, name)) return &c->recs[i];
    return NULL;
}

static int numel(const Rec *r) {
    int n = 1;
    for (int i = 0; i < r->nd; i++) n *= r->shape[i];
    return n;
}

/* A record the file can hold: every dimension positive (none: one value), its bytes inside the file
 * (overflow-safe), and for the kinds decoded here (fp16, int6) enough of them for its shape; the engine's own
 * kinds (five_value, compressed) are sized by the engine. A damaged or crafted model is refused here, not read past
 * its mapping. */
static int rec_ok(const Rec *r, size_t size) {
    if (r->off > size || r->bytes > size - r->off) return 0;
    size_t n = 1;
    for (int i = 0; i < r->nd; i++) {
        if (r->shape[i] <= 0 || n > (size_t)INT32_MAX / (size_t)r->shape[i]) return 0;
        n *= (size_t)r->shape[i];
    }
    if (!strcmp(r->kind, "fp16")) return n * 2 <= r->bytes;
    if (strcmp(r->kind, "int6")) return 1;
    /* int6: 3 bytes for every 4 codes, then a fp16 scale per row at the end. */
    if (r->nd < 1) return 0;
    size_t codes = (n + 3) / 4 * 3, scales = 2 * (size_t)r->shape[0];
    return codes <= r->bytes && scales <= r->bytes - codes;
}

/* A record decoded to floats: fp16 or int6 only (null for any other kind, which only the engine reads). */
static float *decoded(Rec *r, const uint8_t *base);

static float h2f(uint16_t h) {
    _Float16 f;
    memcpy(&f, &h, 2);
    return (float)f;
}

static float *fp16_f32(Rec *r, const uint8_t *base) {
    int n = numel(r);
    float *o = malloc(sizeof(float) * n);
    const uint16_t *p = (const uint16_t *)(base + r->off);
    for (int i = 0; i < n; i++) o[i] = h2f(p[i]);
    return o;
}

/* int6: 3 bytes hold 4 codes, value = code - 32, then one fp16 scale per row at the record's end */
static int8_t *int6_q(Rec *r, const uint8_t *base, const uint16_t **scales) {
    int n = numel(r);
    const uint8_t *p = base + r->off;
    int8_t *out = malloc(n + 4);
    for (int i = 0; i < n; i += 4) {
        uint32_t packed = p[0] | (p[1] << 8) | ((uint32_t)p[2] << 16);
        p += 3;
        for (int k = 0; k < 4 && i + k < n; k++) out[i + k] = (int8_t)(((packed >> (6 * k)) & 63) - 32);
    }
    *scales = (const uint16_t *)(base + r->off + r->bytes - 2 * r->shape[0]);
    return out;
}

static float *int6_f32(Rec *r, const uint8_t *base) {
    const uint16_t *s;
    int8_t *q = int6_q(r, base, &s);
    int n = numel(r), rows = r->shape[0], cols = n / rows;
    float *w = malloc(sizeof(float) * n);
    for (int i = 0; i < rows; i++) {
        float sc = h2f(s[i]);
        for (int j = 0; j < cols; j++) w[i * cols + j] = q[i * cols + j] * sc;
    }
    free(q);
    return w;
}

static float *decoded(Rec *r, const uint8_t *base) {
    if (!strcmp(r->kind, "fp16")) return fp16_f32(r, base);
    if (!strcmp(r->kind, "int6")) return int6_f32(r, base);
    return NULL;
}

/* ---------------------------------------------------------------- the model */
#define D 1024
#define LAYERS 24
#define PROJ 640

typedef struct {
    void *enc, *tdt;
    void *mats[LAYERS * 11];
    float *wp, *bp; /* the encoder projector [PROJ][D], [PROJ] */
} Model;

static Model *model_load(const char *path, const char *index, int threads, char *err, size_t cap) {
    if (engine_open(err, cap)) return NULL;
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        snprintf(err, cap, "cannot open the model: %s", strerror(errno));
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        snprintf(err, cap, "cannot read the model: %s", strerror(errno));
        close(fd);
        return NULL;
    }
    const uint8_t *base = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) {
        snprintf(err, cap, "cannot map the model");
        return NULL;
    }
    /* The index, one record a line: name kind offset bytes shape... (PhononAsr.kt reads it from the header). */
    Container c = {base, calloc(1024, sizeof(Rec)), 0};
    const char *line = index;
    while (*line && c.n < 1024) {
        Rec *r = &c.recs[c.n];
        memset(r, 0, sizeof *r); /* a record refused before must not leave its shape behind */
        int used = 0;
        if (sscanf(line, "%127s %15s %zu %zu%n", r->name, r->kind, &r->off, &r->bytes, &used) == 4) {
            const char *p = line + used;
            int v, k;
            while (r->nd < 4 && *p != '\n' && sscanf(p, "%d%n", &v, &k) == 1) {
                r->shape[r->nd++] = v;
                p += k;
            }
            if (rec_ok(r, (size_t)st.st_size)) c.n++;
        }
        const char *nl = strchr(line, '\n');
        if (!nl) break;
        line = nl + 1;
    }

    Model *m = calloc(1, sizeof(Model));
    p_phonon2_cpu_set_threads(threads);
    p_phonon2_tdt_set_threads(threads);
    static const char *mods[11] = {"feed_forward1.linear1", "feed_forward1.linear2", "self_attn.q_proj", "self_attn.k_proj",
                                   "self_attn.v_proj", "self_attn.o_proj", "self_attn.relative_k_proj", "conv.pointwise_conv1",
                                   "conv.pointwise_conv2", "feed_forward2.linear1", "feed_forward2.linear2"};
    int rows[LAYERS * 11], cols[LAYERS * 11];
    const uint8_t *blobs[LAYERS * 11];
    size_t lens[LAYERS * 11];
    char nm[160];
    int ok = 1;
    for (int l = 0; l < LAYERS && ok; l++)
        for (int k = 0; k < 11; k++) {
            snprintf(nm, sizeof nm, "encoder.layers.%d.%s", l, mods[k]);
            Rec *r = find(&c, nm);
            if (!r || r->nd != 2) { ok = 0; break; }
            int i = l * 11 + k;
            rows[i] = r->shape[0];
            cols[i] = r->shape[1];
            blobs[i] = base + r->off;
            lens[i] = r->bytes;
        }
    if (ok) ok = p_phonon2_cpu_create_onedot_wire_many(LAYERS * 11, rows, cols, blobs, lens, m->mats) == LAYERS * 11;
    /* Every other record, by name; a missing one fails the load. */
#define REC(var, name) Rec *var = find(&c, name); if (!var) ok = 0
    if (ok) {
        m->enc = p_phonon2_enc_create(LAYERS, D, 4096, 8, 9, 128, 256);
        static const char *sub[12] = {"layers.0.weight", "layers.0.bias", "layers.2.weight", "layers.2.bias", "layers.3.weight",
                                      "layers.3.bias", "layers.5.weight", "layers.5.bias", "layers.6.weight", "layers.6.bias",
                                      "linear.weight", "linear.bias"};
        float *s[12] = {0};
        for (int i = 0; i < 12 && ok; i++) {
            snprintf(nm, sizeof nm, "encoder.subsampling.%s", sub[i]);
            Rec *r = find(&c, nm);
            if (!r) { ok = 0; break; }
            if (!(s[i] = decoded(r, base))) ok = 0;
        }
        float inv_freq[D / 2];
        for (int i = 0; i < D / 2; i++) inv_freq[i] = 1.0f / powf(10000.0f, (2.0f * i) / D);
        if (ok && p_phonon2_enc_set_subsampling(m->enc, s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11],
                                                inv_freq))
            ok = 0;
        for (int i = 0; i < 12; i++) free(s[i]);
    }
    static const char *vecn[17] = {"norm_feed_forward1.weight", "norm_feed_forward1.bias", "norm_self_att.weight",
                                   "norm_self_att.bias", "norm_conv.weight", "norm_conv.bias", "norm_feed_forward2.weight",
                                   "norm_feed_forward2.bias", "norm_out.weight", "norm_out.bias", "self_attn.bias_u",
                                   "self_attn.bias_v", "conv.depthwise_conv.weight", "conv.norm.weight", "conv.norm.bias",
                                   "conv.norm.running_mean", "conv.norm.running_var"};
    for (int l = 0; l < LAYERS && ok; l++) {
        float *vecs[17] = {0};
        for (int v = 0; v < 17 && ok; v++) {
            snprintf(nm, sizeof nm, "encoder.layers.%d.%s", l, vecn[v]);
            Rec *r = find(&c, nm);
            if (!r) { ok = 0; break; }
            if (!(vecs[v] = decoded(r, base))) ok = 0;
        }
        if (ok && p_phonon2_enc_set_layer(m->enc, l, &m->mats[l * 11], (const float **)vecs)) ok = 0;
        for (int v = 0; v < 17; v++) free(vecs[v]);
    }
    if (ok) {
        REC(wp, "encoder_projector.weight");
        REC(bp, "encoder_projector.bias");
        if (ok) {
            m->wp = int6_f32(wp, base);
            m->bp = fp16_f32(bp, base);
        }
    }
    if (ok) {
        static const char *tab[7] = {"decoder.embedding.weight", "decoder.lstm.weight_ih_l0", "decoder.lstm.weight_hh_l0",
                                     "decoder.lstm.weight_ih_l1", "decoder.lstm.weight_hh_l1", "decoder.decoder_projector.weight",
                                     "joint.head.weight"};
        static const char *bias[6] = {"decoder.lstm.bias_ih_l0", "decoder.lstm.bias_hh_l0", "decoder.lstm.bias_ih_l1",
                                      "decoder.lstm.bias_hh_l1", "decoder.decoder_projector.bias", "joint.head.bias"};
        int8_t *q[7] = {0};
        const uint16_t *sc[7] = {0}, *b[6] = {0};
        for (int i = 0; i < 7 && ok; i++) {
            Rec *r = find(&c, tab[i]);
            if (!r) { ok = 0; break; }
            /* The shapes the create call below assumes (8192 pieces + blank; + 5 durations in the head). */
            if ((i == 0 && r->shape[0] != 8193) || (i == 6 && r->shape[0] != 8198)) { ok = 0; break; }
            q[i] = int6_q(r, base, &sc[i]);
        }
        for (int i = 0; i < 6 && ok; i++) {
            Rec *r = find(&c, bias[i]);
            if (!r) { ok = 0; break; }
            b[i] = (const uint16_t *)(base + r->off);
        }
        int durations[5] = {0, 1, 2, 3, 4};
        if (ok)
            m->tdt = p_phonon2_tdt_create(8193, PROJ, PROJ, 8198, 5, durations, 8192, 10, q[0], sc[0], q[1], sc[1], b[0], q[2],
                                          sc[2], b[1], q[3], sc[3], b[2], q[4], sc[4], b[3], q[5], sc[5], b[4], q[6], sc[6], b[5]);
        for (int i = 0; i < 7; i++) free(q[i]);
        if (!m->tdt) ok = 0;
    }
    /* Everything is copied or re-packed by now: the file can go. */
    munmap((void *)base, st.st_size);
    free(c.recs);
    if (!ok) {
        snprintf(err, cap, "the model would not load (a record is missing or was refused)");
        if (m->enc) p_phonon2_enc_destroy(m->enc);
        for (int i = 0; i < LAYERS * 11; i++)
            if (m->mats[i]) p_phonon2_cpu_destroy(m->mats[i]);
        free(m->wp);
        free(m->bp);
        free(m);
        return NULL;
    }
    return m;
}

static void model_free(Model *m) {
    if (!m) return;
    p_phonon2_tdt_destroy(m->tdt);
    p_phonon2_enc_destroy(m->enc);
    for (int i = 0; i < LAYERS * 11; i++) p_phonon2_cpu_destroy(m->mats[i]);
    free(m->wp);
    free(m->bp);
    free(m);
}

/* ---------------------------------------------------------------- log-mel front end (HF ParakeetFeatureExtractor) */
#define NFFT 512
#define HOP 160
#define WIN 400
#define NBIN 257
#define NMEL 128

static float window[NFFT];
static float melfb[NMEL][NBIN];
static float tw_re[NFFT / 2], tw_im[NFFT / 2];
static int frontend_ready;

static double hz_to_mel(double f) {
    const double f_sp = 200.0 / 3, min_log_hz = 1000, min_log_mel = min_log_hz / f_sp, logstep = log(6.4) / 27;
    return f < min_log_hz ? f / f_sp : min_log_mel + log(f / min_log_hz) / logstep;
}

static double mel_to_hz(double m) {
    const double f_sp = 200.0 / 3, min_log_hz = 1000, min_log_mel = min_log_hz / f_sp, logstep = log(6.4) / 27;
    return m < min_log_mel ? f_sp * m : min_log_hz * exp(logstep * (m - min_log_mel));
}

static void frontend_init(void) {
    if (frontend_ready) return;
    /* a symmetric Hann of 400, centred in 512 (torch.stft pads a shorter window on both sides) */
    int left = (NFFT - WIN) / 2;
    for (int i = 0; i < WIN; i++) window[left + i] = 0.5 - 0.5 * cos(2 * M_PI * i / (WIN - 1));
    /* librosa mel(16000, 512, n_mels=128, fmin=0, fmax=8000, norm='slaney') */
    double fpts[NMEL + 2], mmin = hz_to_mel(0), mmax = hz_to_mel(8000);
    for (int i = 0; i < NMEL + 2; i++) fpts[i] = mel_to_hz(mmin + (mmax - mmin) * i / (NMEL + 1));
    for (int m = 0; m < NMEL; m++) {
        double fl = fpts[m + 1] - fpts[m], fu = fpts[m + 2] - fpts[m + 1], enorm = 2.0 / (fpts[m + 2] - fpts[m]);
        for (int k = 0; k < NBIN; k++) {
            double f = 8000.0 * k / (NBIN - 1), lower = (f - fpts[m]) / fl, upper = (fpts[m + 2] - f) / fu;
            double w = lower < upper ? lower : upper;
            melfb[m][k] = (float)((w > 0 ? w : 0) * enorm);
        }
    }
    for (int k = 0; k < NFFT / 2; k++) {
        tw_re[k] = cos(-2 * M_PI * k / NFFT);
        tw_im[k] = sin(-2 * M_PI * k / NFFT);
    }
    frontend_ready = 1;
}

static void fft512(float *re, float *im) {
    for (int i = 1, j = 0; i < NFFT; i++) {
        int bit = NFFT >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            float t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (int len = 2; len <= NFFT; len <<= 1) {
        int step = NFFT / len;
        for (int i = 0; i < NFFT; i += len)
            for (int k = 0; k < len / 2; k++) {
                float wr = tw_re[k * step], wi = tw_im[k * step];
                float ur = re[i + k], ui = im[i + k];
                float vr = re[i + k + len / 2] * wr - im[i + k + len / 2] * wi;
                float vi = re[i + k + len / 2] * wi + im[i + k + len / 2] * wr;
                re[i + k] = ur + vr; im[i + k] = ui + vi;
                re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi;
            }
    }
}

/* samples [n] (s16) -> mel [T][128], T = 1 + n/160 */
static float *logmel(const int16_t *x, int n, int *T_out) {
    int T = 1 + n / HOP, pad = NFFT / 2;
    float *y = calloc(n + NFFT, sizeof(float));
    /* pre-emphasis 0.97, centred: 256 zeros on each side */
    for (int i = 0; i < n; i++) y[pad + i] = (x[i] - (i ? 0.97f * x[i - 1] : 0)) / 32768.0f;
    float *mel = malloc(sizeof(float) * T * NMEL);
    float re[NFFT], im[NFFT], pw[NBIN];
    for (int t = 0; t < T; t++) {
        for (int i = 0; i < NFFT; i++) {
            re[i] = y[t * HOP + i] * window[i];
            im[i] = 0;
        }
        fft512(re, im);
        for (int k = 0; k < NBIN; k++) pw[k] = re[k] * re[k] + im[k] * im[k];
        for (int m = 0; m < NMEL; m++) {
            float s = 0;
            for (int k = 0; k < NBIN; k++) s += melfb[m][k] * pw[k];
            mel[t * NMEL + m] = logf(s + 5.9604645e-08f);
        }
    }
    /* per-feature normalisation over the utterance (unbiased std) */
    for (int m = 0; m < NMEL; m++) {
        double mean = 0, var = 0;
        for (int t = 0; t < T; t++) mean += mel[t * NMEL + m];
        mean /= T;
        for (int t = 0; t < T; t++) {
            double d = mel[t * NMEL + m] - mean;
            var += d * d;
        }
        double sd = sqrt(var / (T > 1 ? T - 1 : 1)) + 1e-5;
        for (int t = 0; t < T; t++) mel[t * NMEL + m] = (float)((mel[t * NMEL + m] - mean) / sd);
    }
    free(y);
    *T_out = T;
    return mel;
}

/* pcm (16 kHz mono s16) -> token ids with, for each, the encoder frame it was emitted at and the duration the head
 * predicted (0..4 encoder frames; phonon2.h, phonon2_tdt_decode_timed); -1 if too short (under 8 mel frames) */
static int transcribe(Model *m, const int16_t *pcm, int n, int32_t **ids_out, int32_t **fr_out, int32_t **du_out) {
    frontend_init();
    int T;
    float *mel = logmel(pcm, n, &T);
    if (T < 8) {
        free(mel);
        return -1;
    }
    int T8 = p_phonon2_enc_out_len(m->enc, T);
    float *out = malloc(sizeof(float) * (size_t)T8 * D);
    int rc = p_phonon2_enc_forward(m->enc, mel, T, out);
    free(mel);
    if (rc) {
        free(out);
        return -1;
    }
    float *encp = malloc(sizeof(float) * (size_t)T8 * PROJ);
    for (int t = 0; t < T8; t++)
        for (int j = 0; j < PROJ; j++) {
            const float *w = m->wp + (size_t)j * D, *o = out + (size_t)t * D;
            float s = m->bp[j];
            for (int k = 0; k < D; k++) s += w[k] * o[k];
            encp[(size_t)t * PROJ + j] = s;
        }
    free(out);
    int cap = 12 * T8 + 64;
    int32_t *ids = malloc(sizeof(int32_t) * cap), *fr = malloc(sizeof(int32_t) * cap), *du = malloc(sizeof(int32_t) * cap);
    int count = p_phonon2_tdt_decode_timed(m->tdt, encp, T8, ids, fr, du, cap);
    free(encp);
    *ids_out = ids;
    *fr_out = fr;
    *du_out = du;
    return count;
}

/* ---------------------------------------------------------------- JNI (app.notesapp.notes_app.PhononAsr) */
static jstring jerr(JNIEnv *env, const char *err) { return (*env)->NewStringUTF(env, err); }

/* null when the engine is in this build and this phone can run it, else why not */
JNIEXPORT jstring JNICALL Java_app_notesapp_notes_1app_PhononAsr_nativeEngine(JNIEnv *env, jclass cls) {
    (void)cls;
    char err[512] = {0};
    return engine_open(err, sizeof err) ? jerr(env, err) : NULL;
}

/* -> the model's handle, or 0 with the reason in err[0] */
JNIEXPORT jlong JNICALL Java_app_notesapp_notes_1app_PhononAsr_nativeLoad(JNIEnv *env, jclass cls, jstring path, jstring index,
                                                                         jint threads, jobjectArray errOut) {
    (void)cls;
    char err[512] = {0};
    const char *p = (*env)->GetStringUTFChars(env, path, NULL);
    const char *ix = (*env)->GetStringUTFChars(env, index, NULL);
    Model *m = model_load(p, ix, threads, err, sizeof err);
    (*env)->ReleaseStringUTFChars(env, path, p);
    (*env)->ReleaseStringUTFChars(env, index, ix);
    if (!m && errOut && (*env)->GetArrayLength(env, errOut) > 0) (*env)->SetObjectArrayElement(env, errOut, 0, jerr(env, err));
    return (jlong)(intptr_t)m;
}

/* -> the first n samples of pcm decoded as triples, one a token in decode order: [id, frame, duration, id, frame, ...]
 * (frame = the encoder frame the token was emitted at, duration = its predicted duration in encoder frames; 80 ms per
 * frame). Empty for audio under about 80 ms; null on a null handle or an n outside the array. */
JNIEXPORT jintArray JNICALL Java_app_notesapp_notes_1app_PhononAsr_nativeTranscribe(JNIEnv *env, jclass cls, jlong handle,
                                                                                   jshortArray pcm, jint n) {
    (void)cls;
    Model *m = (Model *)(intptr_t)handle;
    if (!m || !pcm || n < 0 || n > (*env)->GetArrayLength(env, pcm)) return NULL;
    jshort *x = (*env)->GetShortArrayElements(env, pcm, NULL);
    int32_t *ids = NULL, *fr = NULL, *du = NULL;
    int count = transcribe(m, x, n, &ids, &fr, &du);
    (*env)->ReleaseShortArrayElements(env, pcm, x, JNI_ABORT);
    if (count < 0) count = 0;
    int32_t *triples = malloc(sizeof(int32_t) * 3 * (size_t)(count > 0 ? count : 1));
    for (int i = 0; i < count; i++) {
        triples[3 * i] = ids[i];
        triples[3 * i + 1] = fr[i];
        triples[3 * i + 2] = du[i];
    }
    free(ids);
    free(fr);
    free(du);
    jintArray out = (*env)->NewIntArray(env, 3 * count);
    if (out && count > 0) (*env)->SetIntArrayRegion(env, out, 0, 3 * count, (const jint *)triples);
    free(triples);
    return out;
}

JNIEXPORT void JNICALL Java_app_notesapp_notes_1app_PhononAsr_nativeRelease(JNIEnv *env, jclass cls, jlong handle) {
    (void)env;
    (void)cls;
    model_free((Model *)(intptr_t)handle);
}
