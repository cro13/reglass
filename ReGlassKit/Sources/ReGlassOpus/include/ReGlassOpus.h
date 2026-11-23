// A typed bridge to libopus (swift-opus's Copus) for ReGlassKit's assistant service. Swift cannot call the variadic
// opus_encoder_ctl, so the reply encoder is configured here.
#ifndef REGLASS_OPUS_H
#define REGLASS_OPUS_H
#include <stdint.h>

/// The glasses' reply encoder: mono, CELT only (restricted low delay), constant bitrate. Returns NULL and sets
/// `error` on failure; `lookahead` receives the encoder delay in samples.
void *reglass_opus_reply_encoder_create(int32_t sample_rate, int32_t bitrate, int32_t *error, int32_t *lookahead);
/// Encodes one frame of `frames` samples. Returns the packet length, or a negative libopus error.
int32_t reglass_opus_encode(void *encoder, const int16_t *pcm, int32_t frames, uint8_t *packet, int32_t capacity);
void reglass_opus_encoder_destroy(void *encoder);

/// A mono decoder producing `sample_rate` PCM. Returns NULL and sets `error` on failure.
void *reglass_opus_decoder_create(int32_t sample_rate, int32_t *error);
/// Decodes one packet into at most `capacity` samples. Returns the sample count, or a negative libopus error.
int32_t reglass_opus_decode(void *decoder, const uint8_t *packet, int32_t length, int16_t *pcm, int32_t capacity);
void reglass_opus_decoder_destroy(void *decoder);

/// A multi-stream uncoupled Opus decoder (`streams = channels, coupled_streams = 0`) for the glasses' 6-channel
/// live-translation microphone (RFC 6716 self-delimiting framing).
void *reglass_opus_multistream_decoder_create(int32_t sample_rate, int32_t channels, int32_t *error);
/// Decodes one multi-stream packet into interleaved `pcm` (`frame_size * channels` Int16 samples). Returns the
/// decoded frame count per channel (e.g. 320 at 16 kHz / 20 ms), or a negative libopus error.
int32_t reglass_opus_multistream_decode(void *decoder, const uint8_t *packet, int32_t length, int16_t *pcm, int32_t frame_size);
void reglass_opus_multistream_decoder_destroy(void *decoder);

#endif
