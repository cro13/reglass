#include "ReGlassOpus.h"
#include <opus.h>
#include <opus_multistream.h>

// Audio glasses play replies encoded with restricted-low-delay CELT at a constant bitrate.
void *reglass_opus_reply_encoder_create(int32_t sample_rate, int32_t bitrate, int32_t *error, int32_t *lookahead) {
    int status = OPUS_OK;
    OpusEncoder *encoder = opus_encoder_create(sample_rate, 1, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &status);
    if (!encoder) {
        *error = status;
        return 0;
    }
    opus_int32 delay = 0;
    status = opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
    if (status == OPUS_OK) status = opus_encoder_ctl(encoder, OPUS_SET_VBR(0));
    if (status == OPUS_OK) status = opus_encoder_ctl(encoder, OPUS_GET_LOOKAHEAD(&delay));
    if (status != OPUS_OK) {
        opus_encoder_destroy(encoder);
        *error = status;
        return 0;
    }
    *error = OPUS_OK;
    *lookahead = delay;
    return encoder;
}

int32_t reglass_opus_encode(void *encoder, const int16_t *pcm, int32_t frames, uint8_t *packet, int32_t capacity) {
    return opus_encode((OpusEncoder *)encoder, pcm, frames, packet, capacity);
}

void reglass_opus_encoder_destroy(void *encoder) {
    if (encoder) opus_encoder_destroy((OpusEncoder *)encoder);
}

void *reglass_opus_decoder_create(int32_t sample_rate, int32_t *error) {
    int status = OPUS_OK;
    OpusDecoder *decoder = opus_decoder_create(sample_rate, 1, &status);
    *error = status;
    return decoder;
}

int32_t reglass_opus_decode(void *decoder, const uint8_t *packet, int32_t length, int16_t *pcm, int32_t capacity) {
    return opus_decode((OpusDecoder *)decoder, packet, length, pcm, capacity, 0);
}

void reglass_opus_decoder_destroy(void *decoder) {
    if (decoder) opus_decoder_destroy((OpusDecoder *)decoder);
}

void *reglass_opus_multistream_decoder_create(int32_t sample_rate, int32_t channels, int32_t *error) {
    if (channels < 1 || channels > 8) {
        if (error) *error = OPUS_BAD_ARG;
        return 0;
    }
    unsigned char mapping[8] = {0, 1, 2, 3, 4, 5, 6, 7};
    int status = OPUS_OK;
    OpusMSDecoder *decoder = opus_multistream_decoder_create(sample_rate, channels, channels, 0, mapping, &status);
    if (error) *error = status;
    return decoder;
}

int32_t reglass_opus_multistream_decode(void *decoder, const uint8_t *packet, int32_t length, int16_t *pcm, int32_t frame_size) {
    return opus_multistream_decode((OpusMSDecoder *)decoder, packet, length, pcm, frame_size, 0);
}

void reglass_opus_multistream_decoder_destroy(void *decoder) {
    if (decoder) opus_multistream_decoder_destroy((OpusMSDecoder *)decoder);
}
