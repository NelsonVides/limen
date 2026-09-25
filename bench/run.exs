# Request-path benchmarks.
#
#     mix bench                                  # print results
#     mix bench --output bench/output/head.json  # also write them as JSON
#
# Each sample runs the operation 100 times; the JSON output is per operation.
# The JSON output feeds bench/compare.exs, which CI uses to fail pull requests
# that make any scenario more than 10% slower than the base branch.

{opts, _argv} =
  OptionParser.parse!(System.argv(), strict: [output: :string, time: :float, warmup: :float])

Code.require_file("scenarios.exs", __DIR__)
Limen.Bench.Scenarios.setup()

suite =
  Benchee.run(Limen.Bench.Scenarios.all(),
    time: Keyword.get(opts, :time, 2.0),
    warmup: Keyword.get(opts, :warmup, 1.0),
    memory_time: 0,
    print: [fast_warning: false, configuration: false]
  )

if output = opts[:output] do
  results =
    Map.new(suite.scenarios, fn scenario ->
      stats = scenario.run_time_data.statistics
      batch = Limen.Bench.Scenarios.batch()

      {scenario.name,
       %{
         median_ns: stats.median / batch,
         p99_ns: stats.percentiles[99] / batch,
         ops: stats.ips * batch
       }}
    end)

  File.mkdir_p!(Path.dirname(output))
  File.write!(output, JSON.encode!(results))
  Mix.shell().info("Wrote #{output}")
end
