/*
 * Copyright (C) 2010, 2011 Mail.RU
 * Copyright (C) 2010, 2011 Yuriy Vostrikov
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#import <util.h>
#import <tbuf.h>

#include <third_party/queue.h>

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>


struct palloc_pool;
extern struct palloc_pool *eter_pool;
int palloc_init(void);
void *palloc(struct palloc_pool *pool, size_t size)
	__attribute__((regparm(2),malloc));
void *p0alloc(struct palloc_pool *pool, size_t size);
void *palloca(struct palloc_pool *pool, size_t size, size_t align);
void prelease(struct palloc_pool *pool);
void prelease_after(struct palloc_pool *pool, size_t after);
struct palloc_pool *palloc_create_pool(const char *name);
void palloc_destroy_pool(struct palloc_pool *);
void palloc_unmap_unused(void);
const char *palloc_name(struct palloc_pool *, const char *);
size_t palloc_allocated(struct palloc_pool *);

void palloc_register_gc_root(struct palloc_pool *pool,
			     void *ptr, void (*copy)(struct palloc_pool *, void *));
void palloc_unregister_gc_root(struct palloc_pool *pool, void *ptr);
void palloc_gc(struct palloc_pool *pool);

void palloc_stat(struct tbuf *buf);
bool palloc_owner(struct palloc_pool *pool, void *ptr);
