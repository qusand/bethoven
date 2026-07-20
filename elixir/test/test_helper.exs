ExUnit.start()

ExUnit.after_suite(fn _results ->
  File.rm_rf(Path.join(__DIR__, "fixtures/.symphony-state"))
end)

Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
