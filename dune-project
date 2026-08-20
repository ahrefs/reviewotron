(lang dune 3.13)

(generate_opam_files true)

(name reviewotron)

(version 0.8.1)

(source
 (github ahrefs/reviewotron))

(authors "Ahrefs")

(maintainers "José Nogueira <jose.nogueira@ahrefs.com>")

(license MIT)

(documentation https://github.com/ahrefs/reviewotron)

(package
 (name reviewotron)
 (synopsis "Automated code review bot powered by Claude")
 (depends
  (ocaml
   (>= 4.14))
  (alcotest :with-test)
  base64
  cmdliner
  containers
  curl
  (devkit
   (= dev))
  digestif
  extlib
  fmt
  (lwt
   (< 6.0))
  (lwt_ppx
   (< 6.0))
  melange-json-native
  (mirage-crypto-pk
   (< 2.1.0))
  (ocaml-ai-sdk
   (>= 0.6.1))
  opentelemetry
  opentelemetry-lwt
  opentelemetry-client-ocurl-lwt
  (mirage-crypto-rng
   (< 2.1.0))
  (ppx_deriving_jsonschema
   (>= 0.0.8))
  ptime
  (ocamlformat
   (= 0.29.0))
  re2
  x509
  yojson
  (odoc :with-doc)))
