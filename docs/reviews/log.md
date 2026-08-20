# Bundle Update Log

## 2026-08-20

* **Addition**: REV-1 records the incremental model review of the v0.3.0.0..v0.4.0.0
  release range: fifteen findings survived adversarial verification (seven correctness,
  two performance, six design) and changes are requested. The most severe finding,
  migration 0011's session search_path leak, was independently rediscovered and is
  already tracked as BUG-1 with ExecPlan 32.
* **Addition**: the bundle is created, on the `assurance.reviews` profile pinned at
  okf-profiles commit d1a44c2, because the profile ships in 0.11.0 and upstream's latest
  tag is still v0.10.0; repin to v0.11.0 once it is released.
