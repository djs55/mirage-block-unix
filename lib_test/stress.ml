(*
 * Copyright (C) 2016-2018 Docker Inc
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

module type DISCARDABLE = sig
  include Mirage_block_lwt.S

  val discard: t -> int64 -> int64 -> (unit, write_error) result io
end

let debug = ref false

module Make(B: DISCARDABLE) = struct
  module SectorSet = Diet.Make(struct
    include Int64
    open Sexplib.Std
    type t' = int64 [@@deriving sexp]
    let sexp_of_t = sexp_of_t'
    let t_of_sexp = t'_of_sexp
  end)


  (* Randomly write and discard, checking with read whether the expected data is in
    each sector. By convention we write the sector index into each sector so we
    can detect if they permute or alias. *)
  let random_write_discard stop_after block =
    let open Lwt.Infix in
    B.get_info block
    >>= fun info ->
    let nr_sectors = info.Mirage_block.size_sectors in
  
    (* add to this set on write, remove on discard *)
    let written = ref SectorSet.empty in
    let i = SectorSet.Interval.make 0L (Int64.pred info.Mirage_block.size_sectors) in
    let empty = ref SectorSet.(add i empty) in
    let nr_iterations = ref 0 in

    let buffer_size = 1048576 in (* perform 1MB of I/O at a time, maximum *)
    let buffer_size_sectors = Int64.of_int (buffer_size / info.Mirage_block.sector_size) in
    let write_buffer = Io_page.(to_cstruct @@ get (buffer_size / page_size)) in
    let read_buffer = Io_page.(to_cstruct @@ get (buffer_size / page_size)) in

    let write x n =
      assert (Int64.add x n <= nr_sectors);
      let one_write x n =
        assert (n <= buffer_size_sectors);
        let buf = Cstruct.sub write_buffer 0 (Int64.to_int n * info.Mirage_block.sector_size) in
        let rec for_each_sector x remaining =
          if Cstruct.len remaining = 0 then () else begin
            let sector = Cstruct.sub remaining 0 512 in
            (* Only write the first byte *)
            Cstruct.BE.set_uint64 sector 0 x;
            for_each_sector (Int64.succ x) (Cstruct.shift remaining 512)
          end in
        for_each_sector x buf;
        B.write block x [ buf ]
        >>= function
        | Error _ -> failwith "write"
        | Ok () -> Lwt.return_unit in
      let rec loop x n =
        if n = 0L then Lwt.return_unit else begin
          let n' = min buffer_size_sectors n in
          one_write x n'
          >>= fun () ->
          loop (Int64.add x n') (Int64.sub n n')
        end in
      loop x n
      >>= fun () ->
      if n > 0L then begin
        let y = Int64.(add x (pred n)) in
        let i = SectorSet.Interval.make x y in
        written := SectorSet.add i !written;
        empty := SectorSet.remove i !empty;
      end;
      Lwt.return_unit in

    let discard x n =
      assert (Int64.add x n <= nr_sectors);
      let y = Int64.(add x (pred n)) in
      B.discard block x n
      >>= function
      | Error _ -> failwith "discard"
      | Ok () ->
      if n > 0L then begin
        let i = SectorSet.Interval.make x y in
        written := SectorSet.remove i !written;
        empty := SectorSet.add i !empty;
      end;
      Lwt.return_unit in
    let check_contents sector buf expected =
      (* Only check the first byte: assume the rest of the sector are the same *)
      let actual = Cstruct.BE.get_uint64 buf 0 in
      if actual <> expected
      then failwith (Printf.sprintf "contents of sector %Ld incorrect: expected %Ld but actual %Ld" sector expected actual) in
    let check_all_clusters () =
      let rec check p set = match SectorSet.choose set with
        | i ->
          let x = SectorSet.Interval.x i in
          let y = SectorSet.Interval.y i in
          begin
            let n = Int64.(succ (sub y x)) in
            assert (Int64.add x n <= nr_sectors);
            let one_read x n =
              assert (n <= buffer_size_sectors);
              let buf = Cstruct.sub read_buffer 0 (Int64.to_int n * info.Mirage_block.sector_size) in
              B.read block x [ buf ]
              >>= function
              | Error _ -> failwith "read"
              | Ok () ->
                let rec for_each_sector x remaining =
                  if Cstruct.len remaining = 0 then () else begin
                    let expected = p x in
                    let sector = Cstruct.sub remaining 0 512 in
                    check_contents x sector expected;
                    for_each_sector (Int64.succ x) (Cstruct.shift remaining 512)
                  end in
                for_each_sector x buf;
                Lwt.return_unit in
            let rec loop x n =
              if n = 0L then Lwt.return_unit else begin
                let n' = min buffer_size_sectors n in
                one_read x n'
                >>= fun () ->
                loop (Int64.add x n') (Int64.sub n n')
              end in
            loop x n
            >>= fun () ->
            check p (SectorSet.remove i set)
          end
        | exception Not_found ->
          Lwt.return_unit in
      Lwt.pick [
        check (fun _ -> 0L) !empty;
        Lwt_unix.sleep 30. >>= fun () -> Lwt.fail (Failure "check empty")
      ]
      >>= fun () ->
      Lwt.pick [
        check (fun x -> x) !written;
        Lwt_unix.sleep 30. >>= fun () -> Lwt.fail (Failure "check written")
      ] in
    Random.init 0;
    let offset = 23856 in
    let sequence = [
      `Write(0, 1);       (* allocate block 0 *)
      `Discard(8, 8);     (* deallocate block 1 *)

      `Write(8, 1);       (* allocate block 1 *)
      `Write(16, 1);      (* allocate blocks 2 *)
      `Discard(16, 8);    (* deallocate block 2 *)
    ] in

    let rec loop sequence =
      check_all_clusters ()
      >>= fun () ->
      incr nr_iterations;
      match sequence with
      | [] -> Lwt.return_unit
      | `Discard (sector, n) :: rest ->
        let sector = Int64.of_int sector and n = Int64.of_int n in
        if !debug then Printf.fprintf stderr "discard %Ld %Ld\n%!" sector n;
        Printf.printf "-%!";
        Lwt.pick [
          discard sector n;
          Lwt_unix.sleep 30. >>= fun () -> Lwt.fail (Failure "discard timeout")
        ]
        >>= fun () -> loop rest
      | `Write (sector, n) :: rest ->
        let sector = Int64.of_int sector and n = Int64.of_int n in
        if !debug then Printf.fprintf stderr "write %Ld %Ld\n%!" sector n;
        Printf.printf ".%!";
        Lwt.pick [
          write sector n;
          Lwt_unix.sleep 30. >>= fun () -> Lwt.fail (Failure "write timeout")
        ]
        >>= fun () -> loop rest in
    Lwt.catch (fun () -> loop sequence)
      (fun e ->
        Printf.fprintf stderr "Test failed on iteration # %d\n%!" !nr_iterations;
        Printexc.print_backtrace stderr;
        let s = Sexplib.Sexp.to_string_hum (SectorSet.sexp_of_t !written) in
        Lwt_io.open_file ~flags:[Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] ~perm:0o644 ~mode:Lwt_io.output "/tmp/written.sexp"
        >>= fun oc ->
        Lwt_io.write oc s
        >>= fun () ->
        Lwt_io.close oc
        >>= fun () ->
        let s = Sexplib.Sexp.to_string_hum (SectorSet.sexp_of_t !empty) in
        Lwt_io.open_file ~flags:[Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] ~perm:0o644 ~mode:Lwt_io.output "/tmp/empty.sexp"
        >>= fun oc ->
        Lwt_io.write oc s
        >>= fun () ->
        Lwt_io.close oc
        >>= fun () ->
        Lwt.fail e
      )
end

module Test = Make(Block)

let create_file path nsectors =
  let open Lwt.Infix in
  Lwt_unix.openfile path [ Unix.O_CREAT; Unix.O_TRUNC; Lwt_unix.O_WRONLY ] 0o0644
  >>= fun fd ->
  Lwt_unix.ftruncate fd (Int64.to_int nsectors * 512)
  >>= fun () ->
  Lwt_unix.close fd

let _ =
  Logs.set_reporter (Logs_fmt.reporter ());
  let sectors = ref 65536 in
  let stop_after = ref 1024 in
  Arg.parse [
    "-sectors", Arg.Set_int sectors, Printf.sprintf "Total number of sectors (default %d)" !sectors;
    "-stop-after", Arg.Set_int stop_after, Printf.sprintf "Number of iterations to stop after (default: 1024, 0 means never)";
    "-debug", Arg.Set debug, "enable debug";
  ] (fun x ->
      Printf.fprintf stderr "Unexpected argument: %s\n" x;
      exit 1
    ) "Perform random read/write/discard/compact operations on a file or block device";

  Lwt_main.run begin
    let open Lwt.Infix in
    let sectors = Int64.of_int (!sectors) in
    let path = Filename.concat "." (Int64.to_string sectors) ^ ".compact" in

    create_file path sectors
    >>= fun () ->
    Block.connect path
    >>= fun block ->

    Lwt.catch
      (fun () ->
        Test.random_write_discard (!stop_after) block
        (* >>= fun () ->
        Lwt_unix.unlink path *)
      ) (fun e ->
        Printf.fprintf stderr "Block device file is: %s\n%!" path;
        (* Don't delete it so it can be analysed *)
        Lwt.fail e
      )
  end