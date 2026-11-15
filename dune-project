(lang dune 3.0)

(name quoteline)

(generate_opam_files true)

(package
 (name quoteline)
 (synopsis "Matching engine, market-making lab, ETF arbitrage and options risk in OCaml")
 (depends
  (ocaml (>= 4.14))
  dune
  ppx_expect
  ppx_inline_test
  qcheck-core))
