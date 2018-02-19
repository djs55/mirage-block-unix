/*
 * Copyright (c) 2018 Docker Inc
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <assert.h>

#include <stdio.h>

#include <sys/param.h>
#include <sys/mount.h>

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/bigarray.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#include <caml/callback.h>

#include "lwt_unix.h"

struct job_discard {
  struct lwt_unix_job job;
  uint64_t offset;
  uint64_t length;
  int fd;
  int errno_copy;
  const char *error_fn;
};

#ifndef ALIGNUP
#define ALIGNUP(x, a) (((x - 1) & ~(a - 1)) + a)
#endif

#ifndef ALIGNDOWN
#define ALIGNDOWN(x, a) (-(a) & (x))
#endif

static void worker_discard(struct job_discard *job)
{
  job->errno_copy = ENOTSUP;
  job->error_fn = "unknown";
#if defined(__APPLE__)
  /* When a Block device is backed by a file we currently report the sector size as
     512. The macOS F_PUNCHHOLE API requires arguments to be aligned to the `fstatfs`
     `f_bsize` (typically 4096 bytes). Therefore we must manually zero leading and
     trailing unaligned offsets. */
  struct statfs fsbuf;
  if (fstatfs(job->fd, &fsbuf) == -1) {
    job->errno_copy = errno;
    job->error_fn = "fstatfs";
    return;
  }
  size_t delete_alignment = (size_t)fsbuf.f_bsize;
  off_t fp_offset = job->offset;
  off_t fp_length = job->length;


		size_t aligned_offset = ALIGNUP(fp_offset, delete_alignment);
		if (aligned_offset != fp_offset) {
			size_t len_to_zero = MIN(fp_length, aligned_offset - fp_offset);
			assert(len_to_zero < delete_alignment);
      void *zero_buf = (void*)malloc(len_to_zero);
      bzero(zero_buf, len_to_zero);
      fprintf(stderr, "pwrite fp_offset = %lld len_to_zero = %zu\n", fp_offset, len_to_zero);
			ssize_t written = pwrite(job->fd, zero_buf,
				len_to_zero, (off_t)fp_offset);
      if (written == -1) {
        job->errno_copy = errno;
        job->error_fn = "pwrite";
        return;
      }
			fp_offset += len_to_zero;
			fp_length -= len_to_zero;
		}
    fprintf(stderr, "fp_length = %d\n", fp_length);
		size_t aligned_length = ALIGNDOWN(fp_length, delete_alignment);
    fprintf(stderr, "aligned_length = %d\n", aligned_length);

		if (aligned_length >= delete_alignment) {
			assert(fp_offset % delete_alignment == 0);
			struct fpunchhole arg = {
				.fp_flags = 0,
				.reserved = 0,
				.fp_offset = (off_t)fp_offset,
				.fp_length = (off_t)aligned_length
			};
      fprintf(stderr, "fcntl fp_offset = %lld fp_length = %lld\n", fp_offset, aligned_length);
			int punched = fcntl(job->fd, F_PUNCHHOLE, &arg);
			if (punched == -1) {
        job->errno_copy = errno;
        job->error_fn = "fcntl(F_PUNCHHOLE)";
        return;
      }
			fp_offset += aligned_length;
			fp_length -= aligned_length;
		}
		if (fp_length > 0) {
      fprintf(stderr, "fp_length = %lld\n", fp_length);
			assert(fp_length < delete_alignment);
			assert(fp_offset % delete_alignment == 0);
      void *zero_buf = (void*)malloc(fp_length);
      bzero(zero_buf, fp_length);
      fprintf(stderr, "pwrite fp_offset = %lld fp_length = %lld\n", fp_offset, fp_length);
			ssize_t written = pwrite(job->fd, zero_buf,
				fp_length, (off_t)fp_offset);
			if (written == -1) {
        job->errno_copy = errno;
        job->error_fn = "pwrite";
        return;
      }
		}
  job->errno_copy = 0;
  return;
#elif defined(__linux__)
  /* Check if it's a file or a block device */
  struct stat buf;
  if (fstat(job->fd, &buf) == -1) {
    job->errno_copy = errno;
    job->error_fn = "fstat";
    return
  }
  if (S_ISBLK(buf.st_mode)) {
    uint64_t range[2] = { job->offset, job->length };
    if (ioctl(fd, BLKDISCARD, &range)) {
      job->errno_copy = errno;
      job->error_fn = "ioctl";
      return
    }
    job->errno_copy = 0;
    return;
  }

  if (fallocate(job->fd, FALLOC_FL_PUNCH_HOLE, job->offset, job->length) == -1){
    job->errno_copy = errno;
    job->error_fn = "fallocate";
    return;
  }
#endif
}

static value result_discard(struct job_discard *job)
{
  CAMLparam0 ();
  int errno_copy = job->errno_copy;
  const char *error_fn;
  lwt_unix_free_job(&job->job);
  if (errno_copy != 0) {
    unix_error(errno_copy, error_fn, Nothing);
  }
  CAMLreturn(Val_unit);
}

CAMLprim
value mirage_block_unix_discard_job(value handle, value offset, value length)
{
  CAMLparam3(handle, offset, length);
  LWT_UNIX_INIT_JOB(job, discard, 0);
  job->fd = Int_val(handle);
  job->offset = Int64_val(offset);
  job->length = Int64_val(length);
  job->errno_copy = 0;
  job->error_fn = "";
  CAMLreturn(lwt_unix_alloc_job(&(job->job)));
}
