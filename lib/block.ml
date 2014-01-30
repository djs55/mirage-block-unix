(*
 * Copyright (C) 2011-2013 Citrix Inc
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
 * REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
 * INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
 * LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 *)

type buf = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

type id = string

module Raw = struct
  external openfile_unbuffered: string -> bool -> int -> Unix.file_descr = "stub_openfile_direct"
  let openfile_buffered name rw perm =
    Unix.openfile name [ if rw then Unix.O_RDWR else Unix.O_RDONLY ] perm

  external blkgetsize: string -> int64 = "stub_blkgetsize"

  external fsync : Unix.file_descr -> unit = "stub_fsync"
end

open Lwt

type 'a io = 'a Lwt.t

type page_aligned_buffer = Cstruct.t

type error = [
  | `Unknown of string
  | `Unimplemented
  | `Is_read_only
  | `Disconnected
]

type info = {
  read_write: bool;
  sector_size: int;
  size_sectors: int64;
}

let pool_size = 16 (* fds per device *)

type t = {
  mutable fds: Lwt_unix.file_descr list; (* pool of fds *)
  c: unit Lwt_condition.t;
  name: string;
  info: info;
  mutable disconnected: bool;
}

let id { name } = name

let with_fd t f =
  let rec loop () = match t.fds with
  | fd :: fds ->
    t.fds <- fds;
    let finally () =
      t.fds <- fd :: t.fds;
      Lwt_condition.signal t.c () in
    Lwt.catch (fun () -> f fd >>= fun x -> finally (); return x) (fun e -> finally (); fail e)
  | [] ->
    Lwt_condition.wait t.c >>= fun () ->
    loop () in
  loop ()

module Result = struct
  type ('a, 'b) result = [
    | `Ok of 'a
    | `Error of 'b
  ]

  let ( >>= ) x f = match x with
    | `Error y -> `Error y
    | `Ok z -> f z

  let wrap_exn f' x' f x =
    try `Ok (f x)
    with e -> 
      `Error (`Unknown (Printf.sprintf "%s %s: %s" f' x' (Printexc.to_string e)))
end

let stat x = Result.wrap_exn "stat" x Unix.LargeFile.stat x
let blkgetsize x = Result.wrap_exn "BLKGETSIZE" x Raw.blkgetsize x

let get_file_size x =
  let open Result in
  stat x
  >>= fun st -> 
  match st.Unix.LargeFile.st_kind with
  | Unix.S_REG -> `Ok st.Unix.LargeFile.st_size
  | Unix.S_BLK -> blkgetsize x
  | _ -> 
    `Error
      (`Unknown 
         (Printf.sprintf "get_file_size %s: neither a file nor a block device" x))

(* prefix which signals we want to use buffered I/O *)
let buffered_prefix = "buffered:"

let remove_prefix prefix x =
  let prefix' = String.length prefix and x' = String.length x in
  if x' >= prefix' && (String.sub x 0 prefix' = prefix)
  then true, String.sub x prefix' (x' - prefix')
  else false, x

let connect name =
  let buffered, name = remove_prefix buffered_prefix name in
  let openfile = if buffered then Raw.openfile_buffered else Raw.openfile_unbuffered in
  (* first try read/write and then fall back to read/only *)
  try
    let fd, read_write =
      try
        openfile name true 0o0, true
      with _ ->
        openfile name false 0o0, false in
    match get_file_size name with
    | `Error e ->
      Unix.close fd;
      return (`Error e)
    | `Ok x ->
      let sector_size = 512 in (* XXX: hardcoded *)
      let size_sectors = Int64.(div x (of_int sector_size)) in
      let c = Lwt_condition.create () in
      let disconnected = false in
      let t = { name; fds = []; c; info = { sector_size; size_sectors; read_write }; disconnected } in

      for i = 1 to pool_size do
        t.fds <- Lwt_unix.of_unix_file_descr (openfile name read_write 0o0) :: t.fds
      done;
      t.fds <- Lwt_unix.of_unix_file_descr fd :: t.fds;

      return (`Ok t)
  with e ->
    return (`Error (`Unknown (Printf.sprintf "connect %s: failed to oppen file" name)))

let disconnect t =
  let fds = t.fds in
  t.fds <- [];
  t.disconnected <- true;
  Lwt_list.iter_s Lwt_unix.close fds >>= fun () ->
  return ()

let get_info { info } = return info

let complete op fd buffer =
  let open Lwt in
  let ofs = buffer.Cstruct.off in
  let len = buffer.Cstruct.len in
  let buf = buffer.Cstruct.buffer in
  let rec loop acc fd buf ofs len =
    op fd buf ofs len >>= fun n ->
    let len' = len - n in
    let acc' = acc + n in
    if len' = 0 || n = 0
    then return acc'
    else loop acc' fd buf (ofs + n) len' in
  loop 0 fd buf ofs len >>= fun n ->
  if n = 0 && len <> 0
  then fail End_of_file
  else return ()

let really_read = complete Lwt_bytes.read
let really_write = complete Lwt_bytes.write

let lwt_wrap_exn name op offset length f =
  Lwt.catch f
    (function
      | End_of_file ->
        return (`Error 
                  (`Unknown 
                     (Printf.sprintf "%s: End_of_file at file %s offset %Ld with length %d"
                        op name offset length)))
      | Unix.Unix_error(code, fn, arg) -> 
        return (`Error 
                  (`Unknown 
                     (Printf.sprintf "%s: %s in %s '%s' at file %s offset %Ld with length %d"
                        op (Unix.error_message code) fn arg name offset length)))
      | e -> 
        return (`Error 
                  (`Unknown 
                     (Printf.sprintf "%s: %s at file %s offset %Ld with length %d" 
                        op (Printexc.to_string e) name offset length))))

let read x sector_start buffers = match x with
  | { disconnected = true } -> return (`Error `Disconnected)
  | _ ->
  with_fd x
    (fun fd ->
      let offset = Int64.(mul sector_start (of_int x.info.sector_size))  in
      Lwt_unix.LargeFile.lseek fd offset Unix.SEEK_SET >>= fun _ ->
      let rec loop offset = function
      | [] -> return (`Ok ())
      | b :: bs ->
        lwt_wrap_exn x.name "read" offset (Cstruct.len b)
          (fun () ->
            really_read fd b >>= fun () ->
            return (`Ok ())
          ) >>= function
        | `Ok () -> loop Int64.(add offset (of_int (Cstruct.len b))) bs
        | `Error x -> return (`Error x) in
      loop offset buffers
    )

let write x sector_start buffers = match x with
  | { disconnected = true } -> return (`Error `Disconnected)
  | { info = { read_write = false } } -> return (`Error `Is_read_only)
  | _ ->
  with_fd x
    (fun fd ->
      let offset = Int64.(mul sector_start (of_int x.info.sector_size)) in
      Lwt_unix.LargeFile.lseek fd offset Unix.SEEK_SET >>= fun _ ->
      let rec loop offset = function
      | [] -> return (`Ok ())
      | b :: bs ->
        lwt_wrap_exn x.name "write" offset (Cstruct.len b)
          (fun () ->
            really_write fd b >>= fun () ->
            return (`Ok ())
          ) >>= function
          | `Ok () -> 
            loop Int64.(add offset (of_int (Cstruct.len b))) bs
          | `Error x -> 
            return (`Error x) in
      loop offset buffers
    )
