(* quoteline CLI.

   quoteline run-sim [--seed N] [--events N] [--out DIR]

   Writes DIR/events.csv and DIR/trades.csv. Same seed, same bytes. *)

let usage () =
  prerr_endline "usage: quoteline run-sim [--seed N] [--events N] [--out DIR]";
  exit 2
;;

let rec parse (cfg : Sim.config) out = function
  | [] -> cfg, out
  | "--seed" :: v :: rest -> parse { cfg with seed = int_of_string v } out rest
  | "--events" :: v :: rest -> parse { cfg with n_events = int_of_string v } out rest
  | "--out" :: v :: rest -> parse cfg v rest
  | _ -> usage ()
;;

let run_sim args =
  let cfg, out = parse Sim.default_config "out" args in
  if not (Sys.file_exists out) then Sys.mkdir out 0o755;
  let steps = Sim.run cfg in
  let write name header lines =
    let oc = open_out_bin (Filename.concat out name) in
    output_string oc (header ^ "\n");
    List.iter (fun l -> output_string oc (l ^ "\n")) lines;
    close_out oc
  in
  write
    "events.csv"
    "time_us,id,kind,side,price_ticks,qty"
    (List.map (fun (s : Sim.step) -> Sim.event_to_csv s.event) steps);
  let trade_lines =
    List.concat_map
      (fun (s : Sim.step) ->
        List.map (Sim.trade_to_csv ~time_us:s.event.time_us) s.trades)
      steps
  in
  write "trades.csv" "time_us,taker,maker,taker_side,price_ticks,qty" trade_lines;
  Printf.printf
    "seed=%d events=%d trades=%d -> %s\n"
    cfg.seed
    (List.length steps)
    (List.length trade_lines)
    out
;;

let () =
  match Array.to_list Sys.argv with
  | _ :: "run-sim" :: args -> run_sim args
  | _ -> usage ()
;;
