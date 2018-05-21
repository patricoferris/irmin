(*
 * Copyright (c) 2013-2017 Thomas Gazagnaire <thomas@gazagnaire.org>
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
 *)

open Lwt.Infix
open Test_common

let test_db = "test_db_git"

let config =
  let head = Git.Reference.of_string "refs/heads/test" in
  Irmin_git.config ~head ~bare:true test_db

module Net = Git_unix.Net

module type Test_S = sig
  include Irmin.S with type step = string
                   and type key = string list
                   and type contents = string
                   and type branch = string
  module Git: Irmin_git.G
  val author: Repo.t -> commit -> string option Lwt.t
  val init: unit -> unit Lwt.t
end

module Mem = struct
  module G = Irmin_git.Mem(Digestif.SHA1)
  module S = Irmin_git.KV(Net)(G)(Irmin.Contents.String)
  let author repo c =
    S.git_commit repo c >|= function
    | None   -> None
    | Some c -> Some (S.Git.Value.Commit.author c).Git.User.name
  include S
  let init () =
    Git.v ~root:(Fpath.v test_db) () >>= function
      | Ok t -> S.Git.reset t >|= fun _ -> ()
      | _    -> Lwt.return ()
end

let store = (module Mem: Test_S)

let suite =
  let store = (module Mem: Test_common.Test_S) in
  let init () = Mem.init () in
  let clean () = Mem.init () in
  let stats = None in
  { name = "GIT"; kind = `Git; clean; init; store; stats; config }

let get = function
  | Some x -> x
  | None   -> Alcotest.fail "get"

let test_sort_order (module S: Test_S) =
  S.init () >>= fun () ->
  S.Repo.v (Irmin_git.config test_db) >>= fun repo ->
  let commit_t = S.Private.Repo.commit_t repo in
  let node_t = S.Private.Repo.node_t repo in
  let head_tree_id branch =
    S.Head.get branch >>= fun head ->
    S.Private.Commit.find commit_t (S.Commit.hash head) >|= fun commit ->
    S.Private.Commit.Val.node (get commit)
  in
  let ls branch =
    head_tree_id branch >>= fun tree_id ->
    S.Private.Node.find node_t tree_id >|= fun tree ->
    S.Private.Node.Val.list (get tree) |> List.map fst
  in
  let info = Irmin.Info.none in
  S.master repo >>= fun master ->
  S.remove master ~info [] >>= fun () ->
  S.set master ~info ["foo.c"] "foo.c" >>= fun () ->
  S.set master ~info ["foo1"] "foo1" >>= fun () ->
  S.set master ~info ["foo"; "foo.o"] "foo.o" >>= fun () ->
  ls master >>= fun items ->
  Alcotest.(check (list string)) "Sort order" ["foo.c"; "foo"; "foo1"] items;
  head_tree_id master >>= fun tree_id ->
  Alcotest.(check string) "Sort hash" "00c5f5e40e37fde61911f71373813c0b6cad1477"
    (Fmt.to_to_string S.Private.Node.Key.pp tree_id);
  (* Convert dir to file; changes order in listing *)
  S.set master ~info ["foo"] "foo" >>= fun () ->
  ls master >>= fun items ->
  Alcotest.(check (list string)) "Sort order" ["foo"; "foo.c"; "foo1"] items;
  Lwt.return ()

module Ref (S: Irmin_git.G) = Irmin_git.Ref(Git_unix.Net)(S)(Irmin.Contents.String)

let pp_reference ppf = function
  | `Branch s -> Fmt.pf ppf "branch: %s" s
  | `Remote s -> Fmt.pf ppf "remote: %s" s
  | `Tag s    -> Fmt.pf ppf "tag: %s" s
  | `Other s  -> Fmt.pf ppf "other: %s" s

let reference = Alcotest.testable pp_reference (=)

let test_list_refs (module S: Test_S) =
  let module R = Ref(S.Git) in
  S.init () >>= fun () ->
  R.Repo.v (Irmin_git.config test_db) >>= fun repo ->
  R.master repo >>= fun master ->
  R.set master ~info:Irmin.Info.none ["test"] "toto" >>= fun () ->
  R.Head.get master >>= fun head ->
  R.Branch.set repo (`Remote "datakit/master") head >>= fun () ->
  R.Branch.set repo (`Other "foo/bar/toto") head >>= fun () ->
  R.Branch.set repo (`Branch "foo") head >>= fun () ->

  R.Repo.branches repo >>= fun bs ->
  Alcotest.(check (slist reference compare)) "raw branches"
    [`Branch "foo";
     `Branch "master";
     `Other  "foo/bar/toto";
     `Remote "datakit/master";
    ] bs;

  S.Repo.v (Irmin_git.config test_db) >>= fun repo ->
  S.Repo.branches repo >>= fun bs ->
  Alcotest.(check (slist string String.compare)) "filtered branches"
    ["master";"foo"] bs;

(* XXX: re-add
  if S.Git.kind = `Disk then
    let i = Fmt.kstrf Sys.command "cd %s && git gc" test_db in
    if i <> 0 then Alcotest.fail "git gc failed";
    S.Repo.branches repo >|= fun bs ->
    Alcotest.(check (slist string String.compare)) "filtered branches"
      ["master";"foo"] bs
   else *)
    Lwt.return_unit

let tests store =
  let run f () = Lwt_main.run (f store) in
  [
    "Testing sort order"  , `Quick, run test_sort_order;
    "Testing listing refs", `Quick, run test_list_refs;
  ]
