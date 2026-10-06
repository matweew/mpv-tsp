/*
 * Allwinner Cedar (VE) hardware H.264 decoder through libcedarc.
 *
 * Decoded pictures (NV21, in ION memory) are copied into regular frames, so any player can
 * show them. Unsupported streams (High 10/4:2:2/4:4:4 profiles) fail at init, which lets
 * players fall back to the software decoder.
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 */

#include <string.h>

#include <vdecoder.h>
#include <memoryAdapter.h>

#include "libavutil/imgutils.h"
#include "libavutil/opt.h"
#include "libavutil/thread.h"
#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"

/* Not in libcedarc's public headers (AddVDPlugin is declared in vdecoder.h) */
void log_set_level(unsigned level);
#define CEDAR_LOG_LEVEL_ERROR 6

#define MAX_DECODE_STEPS 64 /* DecodeVideoStream() calls per receive_frame() */
#define MAX_PENDING 32      /* packets in flight in the decoder (its stream buffer takes hundreds) */

/* Timestamps are not given to the decoder: with them it drops frames it considers late and
 * treats negative ones (the pre-roll of an MP4 edit list) as missing. Pictures come out in
 * display order, so each one gets the smallest pending input timestamp, together with that
 * packet's discard flag (edit-list pre-roll). */
typedef struct CedarPktInfo {
    int64_t pts;
    int discard;
} CedarPktInfo;

typedef struct CedarDecContext {
    AVClass *class;
    VideoDecoder *dec;
    struct ScMemOpsS *memops;
    AVPacket *pkt;          /* packet waiting for room in the stream buffer */
    int pkt_pending;
    int eof;                /* all input was submitted */
    CedarPktInfo pending[MAX_PENDING]; /* input timestamps not yet given to a picture */
    int nb_pending;
    int64_t nb_submitted, nb_pictures, nb_discarded, nb_no_pts;
} CedarDecContext;

static AVOnce plugins_once = AV_ONCE_INIT;

static void load_plugins(void)
{
    log_set_level(CEDAR_LOG_LEVEL_ERROR);
    AddVDPlugin();          /* the codec plugins next to libvideoengine.so */
    log_set_level(CEDAR_LOG_LEVEL_ERROR);
}

/* High 10/4:2:2/4:4:4 (profile_idc 110/122/244/44) are beyond the hardware */
static int profile_supported(AVCodecContext *avctx)
{
    const uint8_t *p = avctx->extradata;
    int size = avctx->extradata_size, profile = -1;
    if (size >= 2 && p[0] == 1) {                       /* avcC */
        profile = p[1];
    } else {                                            /* Annex B: find the SPS */
        for (int i = 0; i + 4 < size; i++)
            if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 && (p[i + 3] & 0x1f) == 7) {
                profile = p[i + 4];
                break;
            }
    }
    if (profile < 0 && avctx->profile > 0)
        profile = avctx->profile & 0xff;
    return profile < 0 || profile <= 100;
}

static av_cold int cedar_close(AVCodecContext *avctx)
{
    CedarDecContext *s = avctx->priv_data;
    av_log(avctx, AV_LOG_VERBOSE, "%"PRId64" packets, %"PRId64" pictures (%"PRId64" discarded, %"PRId64" without pts)\n",
           s->nb_submitted, s->nb_pictures, s->nb_discarded, s->nb_no_pts);
    if (s->dec)
        DestroyVideoDecoder(s->dec);
    s->dec = NULL;
    if (s->memops)
        CdcMemClose(s->memops);
    s->memops = NULL;
    av_packet_free(&s->pkt);
    return 0;
}

static av_cold int cedar_init(AVCodecContext *avctx)
{
    CedarDecContext *s = avctx->priv_data;
    VideoStreamInfo info;
    VConfig conf;

    if (!profile_supported(avctx)) {
        av_log(avctx, AV_LOG_VERBOSE, "H.264 profile not supported by the hardware\n");
        return AVERROR(ENOSYS);
    }
    ff_thread_once(&plugins_once, load_plugins);

    s->pkt = av_packet_alloc();
    if (!s->pkt)
        return AVERROR(ENOMEM);
    s->memops = MemAdapterGetOpsS();
    if (!s->memops || CdcMemOpen(s->memops) < 0) {
        s->memops = NULL;
        av_log(avctx, AV_LOG_ERROR, "Can't open the ION memory adapter\n");
        return AVERROR_EXTERNAL;
    }
    s->dec = CreateVideoDecoder();
    if (!s->dec) {
        av_log(avctx, AV_LOG_ERROR, "CreateVideoDecoder failed\n");
        return AVERROR_EXTERNAL;
    }

    memset(&info, 0, sizeof(info));
    info.eCodecFormat = VIDEO_CODEC_FORMAT_H264;
    info.nWidth = avctx->width;
    info.nHeight = avctx->height;
    info.bIsFramePackage = 1;           /* one access unit per submitted packet */

    memset(&conf, 0, sizeof(conf));
    conf.eOutputPixelFormat = PIXEL_FORMAT_NV21;
    conf.nDeInterlaceHoldingFrameBufferNum = 2;
    conf.nDisplayHoldingFrameBufferNum = 2;
    conf.nRotateHoldingFrameBufferNum = 0;
    conf.nDecodeSmoothFrameBufferNum = 3;
    conf.nAlignStride = 32;             /* the VE writes 32-aligned rows (GPU_ALIGN_STRIDE) */
    conf.memops = s->memops;
    if (InitializeVideoDecoder(s->dec, &info, &conf)) {
        av_log(avctx, AV_LOG_ERROR, "InitializeVideoDecoder failed\n");
        return AVERROR_EXTERNAL;
    }
    avctx->pix_fmt = AV_PIX_FMT_NV21;
    av_log(avctx, AV_LOG_VERBOSE, "Allwinner Cedar H.264 decoder ready\n");
    return 0;
}

/* Give the next picture the smallest pending input timestamp (see CedarPktInfo). */
static CedarPktInfo cedar_take_pts(CedarDecContext *s)
{
    CedarPktInfo info = { AV_NOPTS_VALUE, 0 };
    int min = 0;

    s->nb_pictures++;
    if (!s->nb_pending) {
        s->nb_no_pts++;
        return info;
    }
    for (int i = 1; i < s->nb_pending; i++)
        if (s->pending[i].pts < s->pending[min].pts)
            min = i;
    info = s->pending[min];
    s->pending[min] = s->pending[--s->nb_pending];
    return info;
}

/* Copy the next decoded picture, if any, into frame. Pictures of discarded packets (edit-list
 * pre-roll) go straight back to the decoder. */
static int cedar_output(AVCodecContext *avctx, AVFrame *frame)
{
    CedarDecContext *s = avctx->priv_data;
    VideoPicture *pic;
    CedarPktInfo info;
    int left, top, width, height, ret;

    for (;;) {
        pic = RequestPicture(s->dec, 0);
        if (!pic)
            return AVERROR(EAGAIN);
        info = cedar_take_pts(s);
        if (!info.discard)
            break;
        s->nb_discarded++;
        ReturnPicture(s->dec, pic);
    }

    if (s->nb_pictures == 1)
        av_log(avctx, AV_LOG_DEBUG, "picture %dx%d stride %d crop l%d t%d r%d b%d, chroma at +%td, buffer %d bytes\n",
               pic->nWidth, pic->nHeight, pic->nLineStride, pic->nLeftOffset, pic->nTopOffset,
               pic->nRightOffset, pic->nBottomOffset, pic->pData1 - pic->pData0, pic->nBufSize);
    left = pic->nLeftOffset;
    top = pic->nTopOffset;
    width = (pic->nRightOffset > left ? pic->nRightOffset : pic->nWidth) - left;
    height = (pic->nBottomOffset > top ? pic->nBottomOffset : pic->nHeight) - top;
    if (avctx->width != width || avctx->height != height) {
        ret = ff_set_dimensions(avctx, width, height);
        if (ret < 0)
            goto out;
    }

    frame->format = AV_PIX_FMT_NV21;
    frame->width = width;
    frame->height = height;
    ret = ff_get_buffer(avctx, frame, 0);
    if (ret < 0)
        goto out;

    /* The hardware wrote to memory the CPU may still have cached */
    CdcMemFlushCache(s->memops, pic->pData0, pic->nLineStride * pic->nHeight);
    CdcMemFlushCache(s->memops, pic->pData1, pic->nLineStride * pic->nHeight / 2);
    av_image_copy_plane(frame->data[0], frame->linesize[0],
                        (const uint8_t *)pic->pData0 + top * pic->nLineStride + left,
                        pic->nLineStride, width, height);
    av_image_copy_plane(frame->data[1], frame->linesize[1],
                        (const uint8_t *)pic->pData1 + (top / 2) * pic->nLineStride + (left & ~1),
                        pic->nLineStride, (width + 1) & ~1, (height + 1) / 2);

    frame->pts = info.pts;
    frame->pkt_dts = AV_NOPTS_VALUE;
    frame->flags &= ~AV_FRAME_FLAG_DISCARD;     /* ff_get_buffer() took it from the last packet */
    if (pic->bIsProgressive == 0) {
        frame->flags |= AV_FRAME_FLAG_INTERLACED;
        if (pic->bTopFieldFirst)
            frame->flags |= AV_FRAME_FLAG_TOP_FIELD_FIRST;
    }
    if (pic->bFrameErrorFlag)
        frame->decode_error_flags |= FF_DECODE_ERROR_INVALID_BITSTREAM;
    ret = 0;
out:
    ReturnPicture(s->dec, pic);
    return ret;
}

/* Put the pending packet into the decoder's stream buffer; AVERROR(EAGAIN) if it's full. */
static int cedar_submit(AVCodecContext *avctx)
{
    CedarDecContext *s = avctx->priv_data;
    AVPacket *pkt = s->pkt;
    VideoStreamDataInfo data;
    char *buf0, *buf1;
    int size0, size1, first;

    if (RequestVideoStreamBuffer(s->dec, pkt->size, &buf0, &size0, &buf1, &size1, 0)
        || size0 + size1 < pkt->size)
        return AVERROR(EAGAIN);
    first = FFMIN(pkt->size, size0);
    memcpy(buf0, pkt->data, first);
    if (first < pkt->size)
        memcpy(buf1, pkt->data + first, pkt->size - first);

    memset(&data, 0, sizeof(data));
    data.pData = buf0;
    data.nLength = pkt->size;
    data.nPts = -1;
    if (pkt->pts != AV_NOPTS_VALUE || pkt->dts != AV_NOPTS_VALUE) {
        if (s->nb_pending == MAX_PENDING) /* frames the decoder dropped: forget the oldest */
            memmove(s->pending, s->pending + 1, --s->nb_pending * sizeof(*s->pending));
        s->pending[s->nb_pending++] = (CedarPktInfo) {
            .pts     = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts,
            .discard = !!(pkt->flags & AV_PKT_FLAG_DISCARD),
        };
    }
    data.bIsFirstPart = 1;
    data.bIsLastPart = 1;
    if (SubmitVideoStreamData(s->dec, &data, 0)) {
        av_log(avctx, AV_LOG_ERROR, "SubmitVideoStreamData failed\n");
        return AVERROR_EXTERNAL;
    }
    av_packet_unref(pkt);
    s->pkt_pending = 0;
    s->nb_submitted++;
    return 0;
}

static int cedar_receive_frame(AVCodecContext *avctx, AVFrame *frame)
{
    CedarDecContext *s = avctx->priv_data;
    int ret, need_input = 0;

    for (int step = 0; step < MAX_DECODE_STEPS; step++) {
        ret = cedar_output(avctx, frame);
        if (ret != AVERROR(EAGAIN))
            return ret;

        /* Feed input: one packet at a time, at most MAX_PENDING ahead of the output */
        if (!s->eof && (s->pkt_pending || s->nb_pending < MAX_PENDING)) {
            if (!s->pkt_pending) {
                ret = ff_decode_get_packet(avctx, s->pkt);
                if (ret == AVERROR_EOF)
                    s->eof = 1;
                else if (ret < 0 && ret != AVERROR(EAGAIN))
                    return ret;
                else if (ret == 0)
                    s->pkt_pending = 1;
                need_input = ret == AVERROR(EAGAIN);
            }
            if (s->pkt_pending) {
                ret = cedar_submit(avctx);
                if (ret < 0 && ret != AVERROR(EAGAIN))
                    return ret;
            }
        }

        ret = DecodeVideoStream(s->dec, s->eof, 0, 0, 0);
        switch (ret) {
        case VDECODE_RESULT_FRAME_DECODED:
        case VDECODE_RESULT_KEYFRAME_DECODED:
        case VDECODE_RESULT_OK:
        case VDECODE_RESULT_CONTINUE:
        case VDECODE_RESULT_NO_FRAME_BUFFER:
        case VDECODE_RESULT_RESOLUTION_CHANGE:
            continue;
        case VDECODE_RESULT_NO_BITSTREAM:
            if (s->eof) {
                ret = cedar_output(avctx, frame);
                return ret == AVERROR(EAGAIN) ? AVERROR_EOF : ret;
            }
            if (need_input && !s->pkt_pending)
                return AVERROR(EAGAIN);
            continue;
        default:
            av_log(avctx, AV_LOG_ERROR, "DecodeVideoStream failed: %d\n", ret);
            return AVERROR_EXTERNAL;
        }
    }
    return AVERROR(EAGAIN);
}

static void cedar_flush(AVCodecContext *avctx)
{
    CedarDecContext *s = avctx->priv_data;
    ResetVideoDecoder(s->dec);
    av_packet_unref(s->pkt);
    s->pkt_pending = 0;
    s->eof = 0;
    s->nb_pending = 0;
}

static const AVClass cedar_h264_dec_class = {
    .class_name = "h264_cedar",
    .version    = LIBAVUTIL_VERSION_INT,
};

const FFCodec ff_h264_cedar_decoder = {
    .p.name         = "h264_cedar",
    CODEC_LONG_NAME("H.264 (Allwinner Cedar hardware decoder)"),
    .p.type         = AVMEDIA_TYPE_VIDEO,
    .p.id           = AV_CODEC_ID_H264,
    .priv_data_size = sizeof(CedarDecContext),
    .init           = cedar_init,
    .close          = cedar_close,
    FF_CODEC_RECEIVE_FRAME_CB(cedar_receive_frame),
    .flush          = cedar_flush,
    .p.priv_class   = &cedar_h264_dec_class,
    .p.capabilities = AV_CODEC_CAP_DELAY | AV_CODEC_CAP_AVOID_PROBING | AV_CODEC_CAP_HARDWARE,
    .p.pix_fmts     = (const enum AVPixelFormat[]) { AV_PIX_FMT_NV21, AV_PIX_FMT_NONE },
    .bsfs           = "h264_mp4toannexb",
    .p.wrapper_name = "cedar",
    .caps_internal  = FF_CODEC_CAP_NOT_INIT_THREADSAFE | FF_CODEC_CAP_INIT_CLEANUP,
};
