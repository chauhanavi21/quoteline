(* Throughput of the matching engine.

   Method: generate a stream of events once (outside the timed region), then time
   only the application of those events to the book. Report events per second
   and the median of several repetitions, since a single timing is noisy.

   Run with:  dune exec bench/bench.exe

   Numbers depend on the machine; the README states the one they were taken on.
   The book is a persistent (immutable) structure, so every add allocates a new
   version; a mutable book would be faster but could not be replayed, forked or
   property-tested as simply. *)

let time f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  Unix.gettimeofday () -. t0, r
;;

let median xs =
  let a = Array.of_list xs in
  Array.sort compare a;
  a.(Array.length a / 2)
;;

(* Pre-generate events by running the simulator once, with the given config. *)
let events cfg =
  let flow = Sim.Flow.create cfg in
  let rec go book acc =
    match Sim.Flow.next flow ~book with
    | None -> List.rev acc
    | Some e ->
      let book, _ = Sim.apply book e in
      go book (e :: acc)
  in
  Array.of_list (go Book.empty [])
;;

let run_once evs =
  let book = ref Book.empty in
  let trades = ref 0 in
  Array.iter
    (fun e ->
      let b, t = Sim.apply !book e in
      book := b;
      trades := !trades + List.length t)
    evs;
  !trades, Book.order_count !book
;;

let report name cfg =
  let evs = events cfg in
  let n = Array.length evs in
  ignore (run_once (Array.sub evs 0 (min n 20_000)));
  let reps = 7 in
  let timings = List.init reps (fun _ -> fst (time (fun () -> run_once evs))) in
  let trades, resting = run_once evs in
  let med = median timings in
  let rate = float_of_int n /. med in
  Printf.printf "%-34s %7d events  %6d trades  %6d resting  median %.3fs  %9.0f events/s  %4.0f ns/event
%!"
    name n trades resting med rate (med /. float_of_int n *. 1e9);
  rate
;;

(* A regression guard that does not depend on how fast the machine is: the
   ratio of deep-book to shallow-book throughput. The original list-based book
   scored about 0.05 here (183 K vs 3.6 M events/s); the current one scores
   about 0.4. Failing below 0.15 catches a return of the O(level depth) cancel
   without being flaky on a slow or noisy CI runner. *)
let min_deep_to_shallow_ratio = 0.15

let () =
  let d = Sim.default_config in
  let n = 200_000 in
  print_endline "Matching-engine throughput (7 repetitions, median; event generation excluded)";
  let shallow = report "default (shallow book, ~170 resting)" { d with n_events = n } in
  let _ = report "deep book (lifetime 20k events)" { d with n_events = n; mean_lifetime_events = 20_000. } in
  let deep = report "very deep book (lifetime 100k)" { d with n_events = n; mean_lifetime_events = 100_000. } in
  let _ = report "heavy matching (60% market orders)" { d with n_events = n; market_prob = 0.6 } in
  let ratio = deep /. shallow in
  Printf.printf "
deep / shallow throughput ratio: %.2f (fails below %.2f)
" ratio min_deep_to_shallow_ratio;
  if ratio < min_deep_to_shallow_ratio
  then (
    prerr_endline "FAIL: deep-book throughput collapsed relative to a shallow book";
    exit 1)
;;
