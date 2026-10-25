(lang dune 3.21)
(name ade)

(package
 (name ade)
 (version 0.1.0)
 (synopsis "Manage local agent workbench VMs")
 (depends
  (ocaml (>= 5.4))
  cmdliner
  otoml
  yojson
  digestif
  bos
  rresult
  (alcotest :with-test)
  (hegel (and :with-test (>= 0.25.0)))))
