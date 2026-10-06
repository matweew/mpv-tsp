/*
 * SDL2 OpenGL ES GPU context for mpv 0.36.0
 * Targets PowerVR GE8300 on TrimUI Smart Pro via SDL2 mali-fbdev/GE8300 backend.
 *
 * SDL2 built with SDL2_POWERVR_GE8300 passes NULL native window to EGL,
 * which PowerVR accepts for its default framebuffer surface.
 *
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <SDL.h>

#include "video/out/gpu/context.h"
#include "video/out/opengl/common.h"
#include "video/out/opengl/context.h"
#include "video/out/opengl/ra_gl.h"

struct priv {
    GL gl;
    SDL_Window *window;
    SDL_GLContext sdl_ctx;
};

static void sdl_swap_buffers(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    SDL_GL_SwapWindow(p->window);
}

static void *sdl_get_proc_addr(const GLubyte *name)
{
    return SDL_GL_GetProcAddress((const char *)name);
}

static bool sdl_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);

    if (SDL_InitSubSystem(SDL_INIT_VIDEO) < 0) {
        MP_ERR(ctx->vo, "[sdl] SDL_InitSubSystem(VIDEO) failed: %s\n", SDL_GetError());
        return false;
    }

    /* Request OpenGL ES 3.x context */
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_RED_SIZE,   8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE,  8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 0);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 0);

    /* SDL2 GE8300 mali-fbdev: size is ignored (uses display resolution), fullscreen by default */
    p->window = SDL_CreateWindow("mpv",
                                 SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                                 1280, 720,
                                 SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN);
    if (!p->window) {
        MP_ERR(ctx->vo, "[sdl] SDL_CreateWindow failed: %s\n", SDL_GetError());
        goto fail_quit;
    }

    p->sdl_ctx = SDL_GL_CreateContext(p->window);
    if (!p->sdl_ctx) {
        MP_ERR(ctx->vo, "[sdl] SDL_GL_CreateContext failed: %s\n", SDL_GetError());
        goto fail_win;
    }

    SDL_GL_MakeCurrent(p->window, p->sdl_ctx);

    mpgl_load_functions(&p->gl, sdl_get_proc_addr, NULL, ctx->log);

    struct ra_gl_ctx_params params = {
        .swap_buffers = sdl_swap_buffers,
    };

    if (!ra_gl_ctx_init(ctx, &p->gl, params)) {
        MP_ERR(ctx->vo, "[sdl] ra_gl_ctx_init failed\n");
        goto fail_ctx;
    }

    int w, h;
    SDL_GL_GetDrawableSize(p->window, &w, &h);
    MP_INFO(ctx->vo, "[sdl] Screen resolution: %dx%d\n", w, h);
    ctx->vo->dwidth  = w;
    ctx->vo->dheight = h;

    return true;

fail_ctx:
    SDL_GL_DeleteContext(p->sdl_ctx);
fail_win:
    SDL_DestroyWindow(p->window);
fail_quit:
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
    return false;
}

static bool sdl_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    int w, h;
    SDL_GL_GetDrawableSize(p->window, &w, &h);
    ctx->vo->dwidth  = w;
    ctx->vo->dheight = h;
    ra_gl_ctx_resize(ctx->swapchain, w, h, 0);
    return true;
}

static int sdl_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    return VO_NOTIMPL;
}

static void sdl_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    ra_gl_ctx_uninit(ctx);
    if (p->sdl_ctx)
        SDL_GL_DeleteContext(p->sdl_ctx);
    if (p->window)
        SDL_DestroyWindow(p->window);
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
}

const struct ra_ctx_fns ra_ctx_sdl = {
    .type    = "opengl",
    .name    = "sdl",
    .reconfig = sdl_reconfig,
    .control  = sdl_control,
    .init     = sdl_init,
    .uninit   = sdl_uninit,
};
